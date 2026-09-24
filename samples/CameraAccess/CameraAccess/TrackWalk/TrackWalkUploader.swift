import AVFoundation
import Foundation
import Network
import UIKit

/// Sends each reported Track Walk's video to SPECTRE: create (or re-token), one
/// whole-file background PUT, then complete. Background URLSessions carry the
/// bytes, so an upload keeps going with the phone locked or the app suspended,
/// and iOS relaunches the app to report the result. One session is Wi-Fi only;
/// the other may use cellular, once the owner has said yes.
@MainActor
final class TrackWalkUploader: ObservableObject {
  static let shared = TrackWalkUploader()

  /// 0...1 per capture while its bytes are moving.
  @Published private(set) var progress: [UUID: Double] = [:]
  @Published private(set) var onWiFi = false
  @Published private(set) var cellularAvailable = false

  private static let retryDelay: Duration = .seconds(60)

  private let client = SpectreMediaClient()
  private let delegate = UploadSessionDelegate()
  private lazy var wifiSession = makeSession(cellular: false)
  private lazy var cellularSession = makeSession(cellular: true)
  private var started = false
  /// False until both sessions have reported the tasks still running from before a relaunch.
  private var tasksKnown = false
  /// The task key (see `UploadSessionDelegate.key`) of each capture's current upload.
  private var liveTasks: [UUID: String] = [:]
  /// Keys of tasks cancelled on purpose; their completions are ignored.
  private var abandoned: Set<String> = []
  private var working: Set<UUID> = []
  private var backgroundCompletions: [String: () -> Void] = [:]
  private var retryTimer: Task<Void, Never>?
  private let pathMonitor = NWPathMonitor()

  private init() {}

  /// At launch, foreground or background: reattach both sessions, learn which
  /// uploads are still in flight, then drive the rest. Safe to call repeatedly.
  func start() {
    guard !started else { return }
    started = true
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let satisfied = path.status == .satisfied
      let wifi = satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
      let cellular = satisfied && path.usesInterfaceType(.cellular)
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.onWiFi = wifi
        self.cellularAvailable = cellular
        self.resumeAll()
      }
    }
    pathMonitor.start(queue: DispatchQueue(label: "scout-upload-network"))
    Task {
      for session in [wifiSession, cellularSession] {
        for task in await session.allTasks where task.state == .running || task.state == .suspended {
          if let id = task.taskDescription.flatMap(UUID.init(uuidString:)) {
            liveTasks[id] = UploadSessionDelegate.key(session, task)
          }
        }
      }
      tasksKnown = true
      resumeAll()
    }
  }

  /// Drives every walk whose video still has to go. Safe to call at any time.
  func resumeAll() {
    guard started, tasksKnown else { return }
    let enabled = SettingsManager.shared.trackWalkReportsEnabled
    for capture in ScoutOutbox.shared.captures
    where OutboxRules.needsUpload(capture, trackWalkReportsEnabled: enabled) && liveTasks[capture.id] == nil {
      Task { await advance(capture.id) }
    }
  }

  /// The owner's answer to "Upload now on cellular?". Switching to cellular
  /// abandons any Wi-Fi task still waiting and starts again on the cellular session.
  func choose(_ network: UploadNetwork, for id: UUID) {
    ScoutOutbox.shared.update(id) { $0.uploadNetwork = network }
    UploadPrompt.shared.withdraw(for: id)
    Task {
      if network == .cellularAllowed {
        await cancelTasks(for: id, in: [wifiSession])
      }
      await advance(id)
    }
  }

  /// The owner's Delete: stops any upload, removes the local files, drops the capture.
  func delete(_ id: UUID) async {
    await cancelTasks(for: id, in: [wifiSession, cellularSession])
    progress[id] = nil
    UploadPrompt.shared.withdraw(for: id)
    for ext in ["mov", "mp4", "m4a"] {
      try? FileManager.default.removeItem(at: TrackWalkMedia.url(for: id, ext: ext))
    }
    ScoutOutbox.shared.remove(id)
  }

  // MARK: - Background session events (from the app delegate and the session delegate)

  func handleBackgroundEvents(_ identifier: String, completion: @escaping () -> Void) {
    backgroundCompletions[identifier] = completion
    start()
  }

  func backgroundEventsFinished(_ identifier: String?) {
    guard let identifier, let completion = backgroundCompletions.removeValue(forKey: identifier) else { return }
    completion()
  }

  func uploadProgress(_ id: UUID, _ fraction: Double) {
    if let old = progress[id], fraction - old < 0.01 { return }
    progress[id] = fraction
  }

  func uploadFinished(_ id: UUID, key: String, status: Int?, error: String?) {
    if abandoned.remove(key) != nil { return }
    // An older task for this walk; a newer one is carrying it now.
    if let live = liveTasks[id], live != key { return }
    liveTasks[id] = nil
    guard let capture = ScoutOutbox.shared.capture(id), capture.state == .uploading,
          let mediaId = capture.mediaId
    else {
      progress[id] = nil
      return
    }
    let step = UploadRules.classifyStorage(status: status, mediaId: mediaId, networkError: error)
    if case .complete(let mediaId) = step {
      Task { await complete(id, mediaId: mediaId) }
    } else {
      finish(id, step)
    }
  }

  // MARK: - Steps

  private func advance(_ id: UUID) async {
    guard tasksKnown, !working.contains(id), liveTasks[id] == nil,
          let capture = ScoutOutbox.shared.capture(id),
          OutboxRules.needsUpload(capture, trackWalkReportsEnabled: SettingsManager.shared.trackWalkReportsEnabled),
          let name = capture.videoFileName
    else { return }
    let file = TrackWalkMedia.folder.appending(path: name, directoryHint: .notDirectory)
    guard FileManager.default.fileExists(atPath: file.path) else {
      // The video is gone (lost in a crash, or removed): the report stands alone.
      ScoutOutbox.shared.update(id) {
        $0.state = .done
        $0.lastError = "Video missing — report sent without it"
      }
      return
    }
    let session: URLSession
    switch UploadRules.route(for: capture, onWiFi: onWiFi, cellularAvailable: cellularAvailable) {
    case .wait:
      return
    case .askUser:
      UploadPrompt.shared.ask(for: capture, sizeBytes: Self.size(of: file))
      session = wifiSession
    case .wifiSession:
      session = wifiSession
    case .cellularSession:
      session = cellularSession
    }
    working.insert(id)
    defer { working.remove(id) }
    let background = UIApplication.shared.beginBackgroundTask(withName: "ScoutUpload")
    defer {
      if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
    }

    let step: UploadStep
    if let mediaId = capture.mediaId {
      step = await client.token(mediaId: mediaId)
    } else if let duration = await Self.durationSeconds(of: file) {
      step = await client.create(capture, sizeBytes: Self.size(of: file), durationSec: duration)
    } else {
      step = .rejected("Video length unknown")
    }

    switch step {
    case .upload(let mediaId, let putURL):
      ScoutOutbox.shared.update(id) { OutboxRules.beginUpload(&$0, mediaId: mediaId) }
      var request = URLRequest(url: putURL)
      request.httpMethod = "PUT"
      request.setValue(MediaRequest.mimeType, forHTTPHeaderField: "Content-Type")
      request.setValue("true", forHTTPHeaderField: "x-upsert")
      let task = session.uploadTask(with: request, fromFile: file)
      task.taskDescription = id.uuidString
      liveTasks[id] = UploadSessionDelegate.key(session, task)
      progress[id] = 0
      task.resume()
      NSLog("[Upload] %@ started on %@", id.uuidString, session.configuration.identifier ?? "?")
    case .complete(let mediaId):
      ScoutOutbox.shared.update(id) { OutboxRules.beginUpload(&$0, mediaId: mediaId) }
      await complete(id, mediaId: mediaId)
    default:
      finish(id, step)
    }
  }

  private func complete(_ id: UUID, mediaId: String) async {
    let background = UIApplication.shared.beginBackgroundTask(withName: "ScoutUploadComplete")
    defer {
      if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
    }
    finish(id, await client.complete(mediaId: mediaId))
  }

  /// Records a finished step. Only a completed upload deletes the local video;
  /// a failed one keeps it until Retry or Delete.
  private func finish(_ id: UUID, _ step: UploadStep) {
    progress[id] = nil
    ScoutOutbox.shared.update(id) { OutboxRules.applyUpload(step, to: &$0) }
    switch step {
    case .completed:
      for ext in ["mp4", "mov"] {
        try? FileManager.default.removeItem(at: TrackWalkMedia.url(for: id, ext: ext))
      }
      NSLog("[Upload] %@ done", id.uuidString)
    case .reupload:
      if ScoutOutbox.shared.capture(id)?.state == .reported {
        Task { await advance(id) }
      }
    case .transient(let reason):
      NSLog("[Upload] %@ will retry: %@", id.uuidString, reason)
      scheduleRetry()
    case .rejected(let reason):
      NSLog("[Upload] %@ refused: %@", id.uuidString, reason)
    case .upload, .complete:
      break
    }
  }

  private func cancelTasks(for id: UUID, in sessions: [URLSession]) async {
    for session in sessions {
      for task in await session.allTasks where task.taskDescription == id.uuidString {
        abandoned.insert(UploadSessionDelegate.key(session, task))
        task.cancel()
      }
    }
    liveTasks[id] = nil
  }

  private func scheduleRetry() {
    retryTimer?.cancel()
    retryTimer = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.retryDelay)
      guard !Task.isCancelled else { return }
      self?.resumeAll()
    }
  }

  private func makeSession(cellular: Bool) -> URLSession {
    let base = Bundle.main.bundleIdentifier ?? "CameraAccess"
    let config = URLSessionConfiguration.background(withIdentifier: "\(base).upload.\(cellular ? "cellular" : "wifi")")
    config.allowsCellularAccess = cellular
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }

  private static func size(of file: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
  }

  private static func durationSeconds(of file: URL) async -> Double? {
    guard let duration = try? await AVURLAsset(url: file).load(.duration),
          duration.isNumeric, duration.seconds > 0
    else { return nil }
    return duration.seconds
  }
}

/// Background-session callbacks arrive on URLSession's own queue; each hops to the main actor.
final class UploadSessionDelegate: NSObject, URLSessionDataDelegate {
  /// Identifies one task across both sessions (task identifiers are only unique per session).
  static func key(_ session: URLSession, _ task: URLSessionTask) -> String {
    "\(session.configuration.identifier ?? "")#\(task.taskIdentifier)"
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0,
          let id = task.taskDescription.flatMap(UUID.init(uuidString:))
    else { return }
    let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
    Task { @MainActor in TrackWalkUploader.shared.uploadProgress(id, fraction) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
    let key = Self.key(session, task)
    let status = (task.response as? HTTPURLResponse)?.statusCode
    let reason = error?.localizedDescription
    Task { @MainActor in
      TrackWalkUploader.shared.uploadFinished(id, key: key, status: status, error: reason)
    }
  }

  /// Storage never redirects a signed upload; a redirect is refused and fails the task.
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let identifier = session.configuration.identifier
    Task { @MainActor in TrackWalkUploader.shared.backgroundEventsFinished(identifier) }
  }
}

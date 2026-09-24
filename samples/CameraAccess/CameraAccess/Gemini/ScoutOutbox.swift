import Foundation
import Network
import UIKit

/// Saved queue of Scout reports on their way to SPECTRE. Every change is
/// written to Application Support/ScoutOutbox/manifest.json before a send
/// starts, so a crash, a kill or a dead signal never loses a report.
/// Reconciles at launch, when the network comes back, 60 s after a temporary
/// failure, and on Retry.
@MainActor
final class ScoutOutbox: ObservableObject {
  static let shared = ScoutOutbox()

  @Published private(set) var captures: [Capture] = []

  private static let keepDone = 20
  private static let retryDelay: Duration = .seconds(60)

  private let bridge = SpectreScoutBridge()
  private let fileURL: URL
  private var inFlight: Set<UUID> = []
  private var started = false
  private var retryTimer: Task<Void, Never>?
  private let pathMonitor = NWPathMonitor()

  private init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let folder = support.appendingPathComponent("ScoutOutbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    fileURL = folder.appendingPathComponent("manifest.json")
    load()
  }

  /// Called once at app launch: resumes anything left from a previous run and
  /// retries whenever the network comes back.
  func start() {
    guard !started else { return }
    started = true
    pathMonitor.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { @MainActor [weak self] in self?.reconcile() }
    }
    pathMonitor.start(queue: DispatchQueue(label: "scout-outbox-network"))
    reconcile()
  }

  /// Saves the capture, then makes its first send attempt. Returns the state
  /// after that attempt (.done when SPECTRE has it).
  func submit(_ capture: Capture) async -> CaptureState {
    captures.append(capture)
    save()
    await send(capture.id)
    return captures.first { $0.id == capture.id }?.state ?? .failed
  }

  /// Retries anything waiting, when the app comes back to the foreground.
  func resume() {
    guard started else { return }
    reconcile()
  }

  func retry(_ id: UUID) {
    guard let index = captures.firstIndex(where: { $0.id == id }) else { return }
    OutboxRules.retry(&captures[index])
    save()
    reconcile()
  }

  private func reconcile() {
    for capture in captures where OutboxRules.needsSend(capture) && !inFlight.contains(capture.id) {
      Task { await send(capture.id) }
    }
  }

  private func send(_ id: UUID) async {
    guard !inFlight.contains(id),
          let index = captures.firstIndex(where: { $0.id == id }),
          OutboxRules.needsSend(captures[index])
    else { return }
    inFlight.insert(id)
    // A report send must finish even if the phone locks right after End.
    let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ScoutReport")
    defer {
      if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
    }
    OutboxRules.beginSend(&captures[index])
    save()
    let outcome = await bridge.deliver(captures[index])
    inFlight.remove(id)
    guard let current = captures.firstIndex(where: { $0.id == id }) else { return }
    OutboxRules.apply(outcome, to: &captures[current])
    captures = OutboxRules.pruned(captures, keepingDone: Self.keepDone)
    save()
    if case .transientFailure(let reason) = outcome {
      NSLog("[ScoutOutbox] %@ will retry: %@", id.uuidString, reason)
      scheduleRetry()
    }
  }

  private func scheduleRetry() {
    retryTimer?.cancel()
    retryTimer = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.retryDelay)
      guard !Task.isCancelled else { return }
      self?.reconcile()
    }
  }

  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    do {
      captures = try OutboxCoding.decode(data)
    } catch {
      // Keep the unreadable file for inspection rather than overwriting it.
      let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
      try? FileManager.default.moveItem(at: fileURL, to: aside)
      NSLog("[ScoutOutbox] Manifest unreadable, moved aside: %@", String(describing: error))
    }
  }

  private func save() {
    do {
      try OutboxCoding.encode(captures).write(to: fileURL, options: [.atomic])
    } catch {
      NSLog("[ScoutOutbox] Save failed: %@", error.localizedDescription)
    }
  }
}

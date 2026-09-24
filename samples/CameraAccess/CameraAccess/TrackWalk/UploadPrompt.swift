import Foundation
import UserNotifications

/// "Upload now on cellular?" as a notification with two answers, so the owner
/// can decide from the lock screen. Until they answer, the video waits on the
/// Wi-Fi-only session; Scout reports offers the same choice in the app.
@MainActor
final class UploadPrompt: NSObject, UNUserNotificationCenterDelegate {
  static let shared = UploadPrompt()

  nonisolated static let category = "SCOUT_UPLOAD_CELLULAR"
  nonisolated static let uploadNow = "UPLOAD_NOW"
  nonisolated static let later = "UPLOAD_LATER"

  /// Walks already asked about during this run of the app.
  private var asked: Set<UUID> = []

  /// At launch, so an answer tapped on the lock screen reaches the app even from a cold start.
  func install() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let now = UNNotificationAction(identifier: Self.uploadNow, title: "Upload now", options: [])
    let later = UNNotificationAction(identifier: Self.later, title: "Later (Wi-Fi)", options: [])
    center.setNotificationCategories([
      UNNotificationCategory(identifier: Self.category, actions: [now, later], intentIdentifiers: [], options: [])
    ])
  }

  /// When the owner turns Track Walk reports on, so the first question can reach the lock screen.
  func requestPermission() {
    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
  }

  /// Asks once per walk per run of the app.
  func ask(for capture: Capture, sizeBytes: Int64) {
    guard asked.insert(capture.id).inserted else { return }
    let megabytes = max(1, Int((Double(sizeBytes) / 1_000_000).rounded()))
    let walk = capture.trackName.isEmpty ? "the Track Walk" : "the \(capture.trackName) Track Walk"
    let content = UNMutableNotificationContent()
    content.title = "Upload on cellular?"
    content.body = "Send \(walk) video (about \(megabytes) MB) now on cellular? Otherwise it waits for Wi-Fi."
    content.categoryIdentifier = Self.category
    content.userInfo = ["captureId": capture.id.uuidString]
    content.sound = .default
    let request = UNNotificationRequest(identifier: Self.identifier(capture.id), content: content, trigger: nil)
    Task { try? await UNUserNotificationCenter.current().add(request) }
  }

  /// Removes the question once it no longer applies.
  func withdraw(for id: UUID) {
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifier(id)])
  }

  private static func identifier(_ id: UUID) -> String { "scout-upload-\(id.uuidString)" }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let raw = response.notification.request.content.userInfo["captureId"] as? String,
          let id = UUID(uuidString: raw)
    else { return }
    switch response.actionIdentifier {
    case Self.uploadNow: await TrackWalkUploader.shared.choose(.cellularAllowed, for: id)
    case Self.later: await TrackWalkUploader.shared.choose(.wifiOnly, for: id)
    default: break  // Tapped to open the app: Scout reports offers the same choice.
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }
}

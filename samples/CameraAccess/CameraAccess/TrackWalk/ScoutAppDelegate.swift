import UIKit

/// What SwiftUI's App lacks: background upload events, and the notification
/// delegate set before any answer can arrive.
final class ScoutAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UploadPrompt.shared.install()
    TrackWalkUploader.shared.start()
    return true
  }

  func application(
    _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    TrackWalkUploader.shared.handleBackgroundEvents(identifier, completion: completionHandler)
  }
}

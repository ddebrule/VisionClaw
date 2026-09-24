import Foundation

/// App-wide log of glasses SDK events, shown under Settings → Glasses event log.
/// The owner shares it from there, because there is no Mac console to read
/// NSLog output on.
@MainActor
final class GlassesEventLogStore: ObservableObject {
  static let shared = GlassesEventLogStore()

  @Published private(set) var log = EventLog(capacity: 500)

  private init() {}

  func record(_ text: String) {
    log.append(text)
    NSLog("[Glasses] %@", text)
  }

  func clear() {
    log.clear()
  }
}

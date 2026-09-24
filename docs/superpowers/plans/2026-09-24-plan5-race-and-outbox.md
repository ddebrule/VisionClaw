# Plan 5: Race Mode + Outbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Scout into **Race**: one spoken vehicle question, a fixed "Driver Stand" context, and an end triggered by folding the glasses (10 s, cancelled by unfolding) or by tapping End. Add an idle guard at 30/45 minutes. Every report goes through a **saved Outbox** that retries on its own, so a report is never lost to a weak signal.

**Architecture:** The pure parts live in `ScoutCore` and are unit-tested in CI:
- the Capture record and its JSON manifest coding;
- the Outbox state rules;
- the idle-guard timing.

The app-side `ScoutOutbox` saves the manifest in Application Support, sends through `SpectreScoutBridge`, and reconciles:
- at launch;
- when the network comes back;
- 60 s after a temporary failure;
- when the user taps Retry.

`GeminiSessionViewModel.endScout()` hands the transcript to the Outbox, which saves it to disk before sending. A new `SpokenCues` helper (AVSpeechSynthesizer) speaks the fold-to-end and idle prompts.

**Tech Stack:** SwiftUI, Swift 5 language mode, iOS 26.0, Foundation, Network (`NWPathMonitor`), AVFoundation (`AVSpeechSynthesizer`), XCTest through `swift test`.

**Spec:** `docs/superpowers/specs/2026-09-23-upstream-catchup-and-scout-modes-design.md` §B1 (Race only), §B2, §B3, §B5 (Outbox and report idempotency), §B7 (roadmap plan 5).

## Global Constraints

- iOS 26.0. Swift 5 mode in the app. `ScoutCore` uses swift-tools 6.0, is Foundation-only, and compiles into the app **without `import ScoutCore`**.
- `POST /api/scout` body: `session_id`, `transcript` (`[{role,text}]`), `duration_min`, `scout_context`, `vehicle_model`, plus **`capture_id`** (lower-case UUID string). SPECTRE strips unknown fields today (a non-strict Zod schema), so sending `capture_id` is safe before SPECTRE ships §B6 item 3.
- Race always sends `scout_context = "Driver Stand"`. `vehicle_model` stays the client-side extraction from the racer's words, as today. Race and Track Walk are never distinguished by keyword guessing.
- Fold-to-end: `hingesClosed` during an active Race starts a **10 s** countdown. The phone speaker says "Ending Race in 10 seconds, unfold to cancel". A frame arriving (unfolding) cancels it and the phone says "Race continues". After 10 s still folded, the report goes to the Outbox and the phone says "Report sent to Setup_IQ" or "Report saved. It will send when you have signal." A bare stream stop **never** ends a Race.
- Idle guard: after **30 min** of silence, say "Scout still running" (once per silence stretch). After **45 min**, end the Race and send the report.
- Outbox:
  - The manifest is `Application Support/ScoutOutbox/manifest.json`, saved **before** every send.
  - Race states: `reportPending → done`, with `failed`, which is either retryable or not.
    - 2xx means sent.
    - 400/401/403/404 is a non-retryable failure; only the manual Retry clears it.
    - Anything else, including a network error, is retryable.
  - Keep the newest **20** `done` captures; older ones are pruned.
- Scout test mode is unchanged: nothing goes to the Outbox.
- No Track Walk UI in this plan. That's Plan 6.
- Before editing any `.swift` file, read `.claude/skills/swiftui-pro/SKILL.md` and follow it.
- **No Swift toolchain on this PC; CI is the compiler.** Push once, after the final review. Before pushing, run `git pull --rebase origin main`.
- Commit messages end with exactly: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## Review Focus

1. **Airplane mode at End.** Expected: the report is saved and sends when signal returns, with no duplicate. Pinned by:
   - `testTransientFailureIsRetryable` and `testNeedsSendAfterTransientFailure` (Task 1);
   - the reconnect-on-network trigger (Task 2, reviewer check).
2. **The app is killed mid-send.** Expected: on relaunch the capture, still in `reportPending`, is re-sent with the same `capture_id`. Pinned by:
   - `testPendingNeedsSend` and `testManifestRoundTrip` (Task 1);
   - `start()` reconciling at launch (Task 2).
3. **SPECTRE rejects the report (404: session archived).** Expected: it is not retried forever, and it shows as failed with Retry. Pinned by `testRejectedIsNotAutoRetried` (Task 1).
4. **The racer unfolds at 9 s.** Expected: the countdown is cancelled and the Race continues. Covered by the cancel path in Task 4 (reviewer check).
5. **A 45-minute idle end during a network outage.** Expected: the report is queued, not lost. Pinned by `testEndsAfterFortyFiveMinutes` (Task 1) plus `endScout` going through the Outbox (Task 3).

## File map

| File | Change | Task |
|---|---|---|
| `samples/CameraAccess/ScoutCore/Sources/ScoutCore/Capture.swift` | Create: `Capture`, `OutboxRules`, `OutboxCoding` | 1 |
| `samples/CameraAccess/ScoutCore/Sources/ScoutCore/IdleGuard.swift` | Create | 1 |
| `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/CaptureTests.swift`, `IdleGuardTests.swift` | Create | 1 |
| `samples/CameraAccess/CameraAccess/Gemini/SpectreScoutBridge.swift` | `deliver(_ capture:) -> ReportOutcome`, the no-session message | 2 |
| `samples/CameraAccess/CameraAccess/Gemini/ScoutOutbox.swift` | Create (pbxproj `…0C`) | 2 |
| `samples/CameraAccess/CameraAccess/CameraAccessApp.swift` | Start the Outbox at launch | 2 |
| `samples/CameraAccess/CameraAccess/Gemini/SpokenCues.swift` | Create (pbxproj `…0D`) | 3 |
| `samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift` | A single vehicle question | 3 |
| `samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift` | Race context, `endScout` through the Outbox, idle guard | 3 |
| `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift` | Fold-to-end | 4 |
| `samples/CameraAccess/CameraAccess/Views/StreamView.swift` | Race button and wording | 4 |
| `samples/CameraAccess/CameraAccess/Settings/ScoutReportsView.swift` | Create (pbxproj `…0E`) | 4 |
| `samples/CameraAccess/CameraAccess/Settings/SettingsView.swift` | "Scout reports" link | 4 |

---

### Task 1: Capture, Outbox rules and idle guard in ScoutCore

**Files:**
- Create: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/Capture.swift`
- Create: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/IdleGuard.swift`
- Test: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/CaptureTests.swift`
- Test: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/IdleGuardTests.swift`

**Interfaces (produces):**
- `public enum CaptureMode: String, Codable, Sendable { case race, trackWalk }`
- `public enum CaptureState: String, Codable, Sendable { case reportPending, reported, done, failed }`
- `public struct TranscriptLine: Codable, Equatable, Sendable { role: String; text: String }`
- `public struct Capture: Codable, Equatable, Identifiable, Sendable`, with these fields:
  - `id: UUID` (this is the `capture_id`)
  - `mode`, `sessionId`, `trackName`, `transcript`, `scoutContext`, `vehicleModel`, `durationMin`, `createdAt`
  - `var state`, `var attempts`, `var lastError: String?`, `var retryable: Bool`
  - `init(id:mode:sessionId:trackName:transcript:scoutContext:vehicleModel:durationMin:createdAt:)`
- `public enum ReportOutcome: Equatable, Sendable { case accepted, rejected(String), transientFailure(String) }`
- `public enum OutboxRules` with `needsSend(_:) -> Bool`, `beginSend(_: inout Capture)`, `apply(_: ReportOutcome, to: inout Capture)`, `retry(_: inout Capture)`, `pruned(_: [Capture], keepingDone: Int) -> [Capture]`
- `public enum OutboxCoding` with `encode(_: [Capture]) throws -> Data` and `decode(_: Data) throws -> [Capture]`
- `public enum IdleGuardAction: Equatable, Sendable { case none, warn, end }`
- `public struct IdleGuard: Equatable, Sendable` with `warnAfter`, `endAfter`, `init(now:)`, `noteActivity(at:)`, `check(at:) -> IdleGuardAction`

- [ ] **Step 1: Write the failing tests: `CaptureTests.swift`**

```swift
import XCTest
@testable import ScoutCore

final class CaptureTests: XCTestCase {
  private func race(createdAt: TimeInterval = 0) -> Capture {
    Capture(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      mode: .race,
      sessionId: "c0ffee00-0000-4000-8000-000000000001",
      trackName: "Mile High",
      transcript: [TranscriptLine(role: "user", text: "pushing in the sweeper")],
      scoutContext: "Driver Stand",
      vehicleModel: "Nitro Buggy",
      durationMin: 12,
      createdAt: Date(timeIntervalSince1970: createdAt))
  }

  func testNewCaptureIsPending() {
    let capture = race()
    XCTAssertEqual(capture.state, .reportPending)
    XCTAssertEqual(capture.attempts, 0)
    XCTAssertNil(capture.lastError)
    XCTAssertTrue(capture.retryable)
  }

  func testPendingNeedsSend() {
    XCTAssertTrue(OutboxRules.needsSend(race()))
  }

  func testBeginSendCountsAttempt() {
    var capture = race()
    OutboxRules.beginSend(&capture)
    XCTAssertEqual(capture.state, .reportPending)
    XCTAssertEqual(capture.attempts, 1)
  }

  func testAcceptedRaceIsDone() {
    var capture = race()
    OutboxRules.beginSend(&capture)
    OutboxRules.apply(.accepted, to: &capture)
    XCTAssertEqual(capture.state, .done)
    XCTAssertNil(capture.lastError)
    XCTAssertFalse(OutboxRules.needsSend(capture))
  }

  func testAcceptedTrackWalkIsReported() {
    var capture = Capture(
      mode: .trackWalk, sessionId: "s", trackName: "t", transcript: [],
      scoutContext: "Track Walk", vehicleModel: "", durationMin: 7)
    OutboxRules.apply(.accepted, to: &capture)
    XCTAssertEqual(capture.state, .reported)
  }

  func testTransientFailureIsRetryable() {
    var capture = race()
    OutboxRules.beginSend(&capture)
    OutboxRules.apply(.transientFailure("offline"), to: &capture)
    XCTAssertEqual(capture.state, .failed)
    XCTAssertTrue(capture.retryable)
    XCTAssertEqual(capture.lastError, "offline")
  }

  func testNeedsSendAfterTransientFailure() {
    var capture = race()
    OutboxRules.apply(.transientFailure("offline"), to: &capture)
    XCTAssertTrue(OutboxRules.needsSend(capture))
    OutboxRules.beginSend(&capture)
    XCTAssertEqual(capture.state, .reportPending)
    XCTAssertEqual(capture.attempts, 1)
  }

  func testRejectedIsNotAutoRetried() {
    var capture = race()
    OutboxRules.apply(.rejected("HTTP 404"), to: &capture)
    XCTAssertEqual(capture.state, .failed)
    XCTAssertFalse(capture.retryable)
    XCTAssertFalse(OutboxRules.needsSend(capture))
  }

  func testManualRetryRevivesRejected() {
    var capture = race()
    OutboxRules.apply(.rejected("HTTP 404"), to: &capture)
    OutboxRules.retry(&capture)
    XCTAssertEqual(capture.state, .reportPending)
    XCTAssertTrue(capture.retryable)
    XCTAssertNil(capture.lastError)
    XCTAssertTrue(OutboxRules.needsSend(capture))
  }

  func testRetryLeavesDoneAlone() {
    var capture = race()
    OutboxRules.apply(.accepted, to: &capture)
    OutboxRules.retry(&capture)
    XCTAssertEqual(capture.state, .done)
  }

  func testPruneKeepsNewestDoneAndAllOthers() {
    var captures: [Capture] = []
    for index in 0..<5 {
      var done = Capture(
        mode: .race, sessionId: "s", trackName: "t", transcript: [],
        scoutContext: "Driver Stand", vehicleModel: "", durationMin: 1,
        createdAt: Date(timeIntervalSince1970: Double(index)))
      OutboxRules.apply(.accepted, to: &done)
      captures.append(done)
    }
    captures.append(race(createdAt: -100))  // old but still pending
    let kept = OutboxRules.pruned(captures, keepingDone: 2)
    XCTAssertEqual(kept.count, 3)
    XCTAssertEqual(kept.filter { $0.state == .done }.map(\.createdAt.timeIntervalSince1970), [3, 4])
    XCTAssertTrue(kept.contains { $0.state == .reportPending })
  }

  func testManifestRoundTrip() throws {
    var failed = race(createdAt: 1_700_000_000)
    OutboxRules.apply(.transientFailure("offline"), to: &failed)
    let data = try OutboxCoding.encode([failed, race(createdAt: 1_700_000_100)])
    XCTAssertEqual(try OutboxCoding.decode(data), [failed, race(createdAt: 1_700_000_100)])
  }

  func testDecodeRejectsUnknownVersion() {
    let data = Data(#"{"version":99,"captures":[]}"#.utf8)
    XCTAssertThrowsError(try OutboxCoding.decode(data))
  }
}
```

- [ ] **Step 2: Write the failing tests: `IdleGuardTests.swift`**

```swift
import XCTest
@testable import ScoutCore

final class IdleGuardTests: XCTestCase {
  func testQuietBeforeThirtyMinutes() {
    var idle = IdleGuard(now: 0)
    XCTAssertEqual(idle.check(at: 29 * 60), .none)
  }

  func testWarnsOnceAtThirtyMinutes() {
    var idle = IdleGuard(now: 0)
    XCTAssertEqual(idle.check(at: 30 * 60), .warn)
    XCTAssertEqual(idle.check(at: 31 * 60), .none)
  }

  func testEndsAfterFortyFiveMinutes() {
    var idle = IdleGuard(now: 0)
    _ = idle.check(at: 30 * 60)
    XCTAssertEqual(idle.check(at: 45 * 60), .end)
  }

  func testEndsEvenIfWarningWasMissed() {
    var idle = IdleGuard(now: 0)
    XCTAssertEqual(idle.check(at: 50 * 60), .end)
  }

  func testActivityResetsTheClockAndTheWarning() {
    var idle = IdleGuard(now: 0)
    XCTAssertEqual(idle.check(at: 30 * 60), .warn)
    idle.noteActivity(at: 40 * 60)
    XCTAssertEqual(idle.check(at: 69 * 60), .none)
    XCTAssertEqual(idle.check(at: 70 * 60), .warn)
    XCTAssertEqual(idle.check(at: 85 * 60), .end)
  }

  func testConstants() {
    XCTAssertEqual(IdleGuard.warnAfter, 1800)
    XCTAssertEqual(IdleGuard.endAfter, 2700)
  }
}
```

- [ ] **Step 3: Confirm the tests would fail.** Grep finds no `struct Capture`, `OutboxRules` or `IdleGuard` in `ScoutCore/Sources`.

- [ ] **Step 4: Implement `Capture.swift`**

```swift
import Foundation

/// Which Scout mode produced a capture.
public enum CaptureMode: String, Codable, Sendable {
  case race
  case trackWalk
}

/// Where a capture is in its trip to SPECTRE. Race: reportPending → done.
/// Track Walk (Plan 6/7) continues from reported to its video upload.
public enum CaptureState: String, Codable, Sendable {
  case reportPending
  case reported
  case done
  case failed
}

public struct TranscriptLine: Codable, Equatable, Sendable {
  public let role: String
  public let text: String

  public init(role: String, text: String) {
    self.role = role
    self.text = text
  }
}

/// One report on its way to SPECTRE. `id` is sent as `capture_id`, so a
/// retried send can never create a second report once SPECTRE dedupes on it.
public struct Capture: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let mode: CaptureMode
  public let sessionId: String
  public let trackName: String
  public let transcript: [TranscriptLine]
  public let scoutContext: String
  public let vehicleModel: String
  public let durationMin: Int
  public let createdAt: Date
  public var state: CaptureState
  public var attempts: Int
  public var lastError: String?
  /// False after SPECTRE refused the report outright; only a manual Retry sends it again.
  public var retryable: Bool

  public init(
    id: UUID = UUID(),
    mode: CaptureMode,
    sessionId: String,
    trackName: String,
    transcript: [TranscriptLine],
    scoutContext: String,
    vehicleModel: String,
    durationMin: Int,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.mode = mode
    self.sessionId = sessionId
    self.trackName = trackName
    self.transcript = transcript
    self.scoutContext = scoutContext
    self.vehicleModel = vehicleModel
    self.durationMin = durationMin
    self.createdAt = createdAt
    self.state = .reportPending
    self.attempts = 0
    self.lastError = nil
    self.retryable = true
  }
}

/// The result of one attempt to post a capture's report.
public enum ReportOutcome: Equatable, Sendable {
  case accepted
  /// SPECTRE refused it (4xx); sending again unchanged would fail the same way.
  case rejected(String)
  /// Network error or server trouble; worth sending again later.
  case transientFailure(String)
}

/// Pure state rules for the Outbox. Every step is safe to repeat.
public enum OutboxRules {
  public static func needsSend(_ capture: Capture) -> Bool {
    switch capture.state {
    case .reportPending: return true
    case .failed: return capture.retryable
    case .reported, .done: return false
    }
  }

  public static func beginSend(_ capture: inout Capture) {
    capture.state = .reportPending
    capture.attempts += 1
  }

  public static func apply(_ outcome: ReportOutcome, to capture: inout Capture) {
    switch outcome {
    case .accepted:
      capture.state = capture.mode == .race ? .done : .reported
      capture.lastError = nil
      capture.retryable = true
    case .rejected(let reason):
      capture.state = .failed
      capture.lastError = reason
      capture.retryable = false
    case .transientFailure(let reason):
      capture.state = .failed
      capture.lastError = reason
      capture.retryable = true
    }
  }

  /// The user's Retry: revives any failed capture, including a rejected one.
  public static func retry(_ capture: inout Capture) {
    guard capture.state == .failed else { return }
    capture.state = .reportPending
    capture.lastError = nil
    capture.retryable = true
  }

  /// Keeps every capture that is not done, plus the newest `keepingDone` done ones.
  public static func pruned(_ captures: [Capture], keepingDone: Int) -> [Capture] {
    let done = captures.filter { $0.state == .done }.sorted { $0.createdAt < $1.createdAt }
    let keptDone = Set(done.suffix(keepingDone).map(\.id))
    return captures.filter { $0.state != .done || keptDone.contains($0.id) }
  }
}

/// The Outbox manifest on disk: `{"version":1,"captures":[…]}`, dates in ISO 8601.
public enum OutboxCoding {
  public static let version = 1

  private struct Manifest: Codable {
    let version: Int
    let captures: [Capture]
  }

  public struct UnsupportedVersion: Error, Equatable {
    public let version: Int
  }

  public static func encode(_ captures: [Capture]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(Manifest(version: version, captures: captures))
  }

  public static func decode(_ data: Data) throws -> [Capture] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(Manifest.self, from: data)
    guard manifest.version == version else { throw UnsupportedVersion(version: manifest.version) }
    return manifest.captures
  }
}
```

Note on `testManifestRoundTrip`: ISO 8601 drops sub-second precision. The test dates are whole seconds (`1_700_000_000`), so they round-trip exactly.

- [ ] **Step 5: Implement `IdleGuard.swift`**

```swift
import Foundation

public enum IdleGuardAction: Equatable, Sendable {
  case none
  /// Say "Scout still running" (once per silence stretch).
  case warn
  /// End the Race and send the report.
  case end
}

/// Race silence rule: warn after 30 minutes with no speech, end after 45.
public struct IdleGuard: Equatable, Sendable {
  public static let warnAfter: TimeInterval = 30 * 60
  public static let endAfter: TimeInterval = 45 * 60

  private var lastActivity: TimeInterval
  private var warned = false

  public init(now: TimeInterval) {
    lastActivity = now
  }

  public mutating func noteActivity(at now: TimeInterval) {
    lastActivity = now
    warned = false
  }

  public mutating func check(at now: TimeInterval) -> IdleGuardAction {
    let silence = now - lastActivity
    if silence >= Self.endAfter { return .end }
    if silence >= Self.warnAfter, !warned {
      warned = true
      return .warn
    }
    return .none
  }
}
```

- [ ] **Step 6: Trace every test by hand** and put the traces in the report.

- [ ] **Step 7: Commit (do not push)**, as two commits:

```bash
git add samples/CameraAccess/ScoutCore/Sources/ScoutCore/Capture.swift samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/CaptureTests.swift
git commit -m "feat(scoutcore): Capture record, Outbox rules and manifest coding"
git add samples/CameraAccess/ScoutCore/Sources/ScoutCore/IdleGuard.swift samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/IdleGuardTests.swift
git commit -m "feat(scoutcore): IdleGuard for the 30/45-minute Race silence rule"
```

---

### Task 2: The saved Outbox

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Gemini/SpectreScoutBridge.swift`
- Create: `samples/CameraAccess/CameraAccess/Gemini/ScoutOutbox.swift`
- Modify: `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj`
- Modify: `samples/CameraAccess/CameraAccess/CameraAccessApp.swift`

**Interfaces:**
- Consumes: `Capture`, `ReportOutcome`, `OutboxRules` and `OutboxCoding` (Task 1).
- Produces:
  - `SpectreScoutBridge.deliver(_ capture: Capture) async -> ReportOutcome`
  - `@MainActor final class ScoutOutbox: ObservableObject` with:
    - `static let shared`
    - `@Published private(set) var captures: [Capture]`
    - `func start()`
    - `func submit(_ capture: Capture) async -> CaptureState`: saves, makes the first send attempt, and returns the resulting state.
    - `func retry(_ id: UUID)`

- [ ] **Step 1: `SpectreScoutBridge`: send a Capture, classify the result**

1a. In `fetchActiveSession()`, change the 404 error text to `"No live session — activate one in SPECTRE first."`.

1b. Replace `sendReport(sessionId:transcript:durationMin:scoutContext:vehicleModel:)` with:

```swift
  /// Posts one capture's report. Never throws: the Outbox needs to know whether
  /// to retry, not why a Swift error surfaced.
  func deliver(_ capture: Capture) async -> ReportOutcome {
    guard let url = URL(string: GeminiConfig.spectreScoutURL) else {
      return .rejected("SPECTRE URL not configured")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(GeminiConfig.spectreUserToken, forHTTPHeaderField: "X-Scout-Token")

    let body: [String: Any] = [
      "capture_id": capture.id.uuidString.lowercased(),
      "session_id": capture.sessionId,
      "transcript": capture.transcript.map { ["role": $0.role, "text": $0.text] },
      "duration_min": capture.durationMin,
      "scout_context": capture.scoutContext,
      "vehicle_model": capture.vehicleModel,
    ]
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .transientFailure("No HTTP response")
      }
      switch http.statusCode {
      case 200...299:
        NSLog("[SpectreScout] Report %@ accepted (%d turns, %d min)",
              capture.id.uuidString, capture.transcript.count, capture.durationMin)
        return .accepted
      case 400, 401, 403, 404:
        return .rejected("SPECTRE refused the report (HTTP \(http.statusCode))")
      default:
        return .transientFailure("SPECTRE error (HTTP \(http.statusCode))")
      }
    } catch {
      return .transientFailure(error.localizedDescription)
    }
  }
```

Leave `ScoutTranscriptEntry` and `ActiveSessionInfo` as they are.

- [ ] **Step 2: Create `Gemini/ScoutOutbox.swift`**

```swift
import Foundation
import Network

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
```

- [ ] **Step 3: Add `ScoutOutbox.swift` to the Gemini group in `project.pbxproj`**

Use the same four-place pattern as `SpectreScoutBridge.swift` (`A1B2C3D42F0A000100000006` / `…0002…06`), with these IDs:
- File reference: `A1B2C3D42F0A00010000000C /* ScoutOutbox.swift */`.
- Build file: `A1B2C3D42F0A00020000000C /* ScoutOutbox.swift in Sources */`.

Add the file reference to the Gemini group's children (group `A1B2C3D42F0A000300000001`) and the build file to the app target's Sources phase, the one listing `SpectreScoutBridge.swift in Sources`. Confirm the IDs are unused before adding them.

- [ ] **Step 4: Start the Outbox at launch**

In `CameraAccessApp.swift`, on the `MainAppView(…)` inside `WindowGroup`, add:

```swift
        .task {
          ScoutOutbox.shared.start()
        }
```

Place it directly after the `MainAppView(wearables: Wearables.shared, viewModel: wearablesViewModel)` line, before `.alert(…)`.

- [ ] **Step 5: Self-check by reading.**
  - `sendReport` has no remaining callers. `GeminiSessionViewModel.endScout` still calls it, and Task 3 replaces that call, so **this task leaves the build broken until Task 3**. This is accepted because nothing is pushed between the tasks. Say so in the report.
  - `Network` is a system framework and needs no project change.

- [ ] **Step 6: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/Gemini/SpectreScoutBridge.swift samples/CameraAccess/CameraAccess/Gemini/ScoutOutbox.swift samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj samples/CameraAccess/CameraAccess/CameraAccessApp.swift
git commit -m "feat(scout): saved Outbox that retries reports with a capture_id"
```

---

### Task 3: Race in the Gemini session

**Files:**
- Create: `samples/CameraAccess/CameraAccess/Gemini/SpokenCues.swift`
- Modify: `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj`
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift`
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift`

**Interfaces:**
- Consumes: `ScoutOutbox.shared.submit(_:)` (Task 2); `Capture`, `TranscriptLine`, `CaptureState` and `IdleGuard` (Task 1).
- Produces:
  - `final class SpokenCues: NSObject` with `static let shared` and `func speak(_ text: String, onPhoneSpeaker: Bool = false)`.
  - `enum EndScoutResult { case sent, queued, nothingToSend, testMode }`.
  - `GeminiSessionViewModel.endScout() async -> EndScoutResult`, marked `@discardableResult`.

- [ ] **Step 1: Create `Gemini/SpokenCues.swift`**

```swift
import AVFoundation

/// Short spoken prompts from the phone itself (not Gemini): the fold-to-end
/// countdown and the idle guard. `onPhoneSpeaker` routes the prompt to the
/// phone speaker, because folded glasses may have dropped their audio.
final class SpokenCues: NSObject, AVSpeechSynthesizerDelegate {
  static let shared = SpokenCues()

  private let synthesizer = AVSpeechSynthesizer()
  private var overrodeSpeaker = false

  override private init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(_ text: String, onPhoneSpeaker: Bool = false) {
    if onPhoneSpeaker {
      overrodeSpeaker = (try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)) != nil
    }
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synthesizer.speak(utterance)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    // Put the route back unless the owner chose the phone speaker in Settings.
    guard overrodeSpeaker, !synthesizer.isSpeaking else { return }
    overrodeSpeaker = false
    if !SettingsManager.shared.speakerOutputEnabled {
      try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
    }
  }
}
```

Add it to the Gemini group in `project.pbxproj` with `A1B2C3D42F0A00010000000D /* SpokenCues.swift */` and `A1B2C3D42F0A00020000000D /* SpokenCues.swift in Sources */`, using the same four-place pattern as Task 2.

- [ ] **Step 2: `GeminiConfig`: a single vehicle question**

In `defaultSystemInstruction`, replace the block from `─── OPENING SEQUENCE — REQUIRED AT SESSION START ───` through the closing `────────────────────────────────────────────────────` line with:

```
    ─── OPENING QUESTION — REQUIRED AT SESSION START ───
    The racer is at the driver's stand. When a new session begins, ask one
    question: read the vehicle list from VEHICLES IN RACER'S GARAGE and ask
    "Which vehicle — [list models]?"
    Wait for the answer, then say: "Locked in, [vehicle]. Go ahead."
    Do not start gathering observations until the vehicle is confirmed.
    If the racer doesn't match a vehicle name exactly, confirm the closest match.
    ────────────────────────────────────────────────────
```

Keep the indentation of the surrounding multi-line string literal (four spaces).

- [ ] **Step 3: `GeminiSessionViewModel`: Race context and track name**

- Replace `private(set) var scoutContext: String = ""` with:
  ```swift
  /// Race always reports from the driver's stand (spec §B2).
  static let raceContext = "Driver Stand"
  private(set) var spectreTrackName: String = ""
  ```
- In `startSession()`, replace `scoutContext = ""` with `spectreTrackName = sessionInfo.track`.
- In `extractOpeningSequenceAnswers(from:)`, delete the whole `if scoutContext.isEmpty { … }` block, and change the doc comment to: `/// Pick out which vehicle the racer named, from their own words.`
- Grep for any other `scoutContext` use in the app and fix it. There should be none left besides `endScout`, which Step 4 rewrites.

- [ ] **Step 4: `endScout` through the Outbox**

Add this above the class, after the imports:

```swift
/// How an End went, so callers (the fold-to-end countdown) can say so.
enum EndScoutResult {
  case sent
  case queued
  case nothingToSend
  case testMode
}
```

Replace `endScout()` entirely with:

```swift
  /// Ends the Race and hands the transcript to the Outbox, which saves it
  /// before sending and keeps retrying if the signal is gone.
  @discardableResult
  func endScout() async -> EndScoutResult {
    flushPendingTurn()
    guard !spectreSessionId.isEmpty, !scoutHistory.isEmpty else {
      stopSession()
      return .nothingToSend
    }

    if SettingsManager.shared.scoutTestMode {
      stopSession()
      let turns = scoutHistory.count
      let minutes = scoutStartTime.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
      NSLog("[ScoutVM] Test mode: report not sent (%d turns, %d min)", turns, minutes)
      scoutReportSent = true
      errorMessage = "Test mode — report not sent (\(turns) turns, \(minutes) min)"
      return .testMode
    }

    isSendingScoutReport = true
    stopSession()
    let capture = Capture(
      mode: .race,
      sessionId: spectreSessionId,
      trackName: spectreTrackName,
      transcript: scoutHistory.map { TranscriptLine(role: $0.role, text: $0.text) },
      scoutContext: Self.raceContext,
      vehicleModel: scoutVehicleModel.isEmpty ? "Unspecified" : scoutVehicleModel,
      durationMin: scoutStartTime.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0)
    // Saved to disk inside submit before the first attempt, so the transcript
    // is safe from here on even if this send fails.
    scoutReportSent = true
    let state = await ScoutOutbox.shared.submit(capture)
    isSendingScoutReport = false
    if state == .done {
      return .sent
    }
    errorMessage = "No signal — the report is saved and will send automatically. See Settings → Scout reports."
    return .queued
  }
```

- [ ] **Step 5: Idle guard**

Add these properties after `private var reconnectWhenIdle = false`:

```swift
  // Race silence rule (30 min warn, 45 min end); checked every 30 s while active.
  private var idleGuard = IdleGuard(now: 0)
  private var idleTicker: Task<Void, Never>?
```

In `startSession()`, after `geminiService.resetResumption()`, add:

```swift
    idleGuard = IdleGuard(now: ProcessInfo.processInfo.systemUptime)
    startIdleTicker()
```

In both `geminiService.onOutputTranscription` and `geminiService.onInputTranscription` handlers, inside their `Task { @MainActor in … }`, add as the first line:

```swift
        self.idleGuard.noteActivity(at: ProcessInfo.processInfo.systemUptime)
```

In `stopSession()`, add `idleTicker?.cancel()` and `idleTicker = nil` after `reconnectTask = nil`.

Add this method in the `// MARK: - Private` section:

```swift
  private func startIdleTicker() {
    idleTicker?.cancel()
    idleTicker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard let self, !Task.isCancelled, self.isGeminiActive else { return }
        switch self.idleGuard.check(at: ProcessInfo.processInfo.systemUptime) {
        case .none:
          break
        case .warn:
          NSLog("[ScoutVM] Idle 30 min: reminding")
          SpokenCues.shared.speak("Scout still running")
        case .end:
          NSLog("[ScoutVM] Idle 45 min: ending the Race")
          await self.endScout()
          return
        }
      }
    }
  }
```

- [ ] **Step 6: Self-check by reading.**
  - `endScout` can be called while an idle-ticker `endScout` is running. `flushPendingTurn` plus the `scoutHistory` guard make the second call harmless, because `scoutReportSent` is already true. Note: `hasUnsentReport` becomes false once `scoutReportSent` is set.
  - The build compiles again now: nothing calls `sendReport` any more.
  - The `ScoutTranscriptEntry` → `TranscriptLine` mapping keeps role and text as they are.

- [ ] **Step 7: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/Gemini/SpokenCues.swift samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift
git commit -m "feat(race): one vehicle question, Driver Stand context, Outbox end, idle guard"
```

---

### Task 4: Fold-to-end, the Race button and the Scout reports list

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift`
- Modify: `samples/CameraAccess/CameraAccess/Views/StreamView.swift`
- Create: `samples/CameraAccess/CameraAccess/Settings/ScoutReportsView.swift`
- Modify: `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj`
- Modify: `samples/CameraAccess/CameraAccess/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `SpokenCues.shared.speak(_:onPhoneSpeaker:)`, `GeminiSessionViewModel.endScout() -> EndScoutResult` (Task 3); `ScoutOutbox.shared` (Task 2).

- [ ] **Step 1: Fold-to-end in `StreamSessionViewModel`**

Add these properties after `private var statusTicker: Task<Void, Never>?`:

```swift
  // Folding the glasses during a Race ends it after 10 s unless they are
  // unfolded first (spec §B2). A bare stream stop never ends a Race.
  private var foldEndTask: Task<Void, Never>?
  private static let foldEndDelay: Duration = .seconds(10)
```

In the `errorPublisher` listener's `if case .hingesClosed = error { … }` block, after `self.refreshGlassesStatus()`, add `self.startFoldToEndIfRacing()`.

At the top of `noteDeliveredFrame(_:)`, **before** the existing `glassesReportedFolded = false` line, add:

```swift
    if glassesReportedFolded, foldEndTask != nil {
      foldEndTask?.cancel()
      foldEndTask = nil
      logEvent("fold: unfolded, Race continues")
      SpokenCues.shared.speak("Race continues", onPhoneSpeaker: true)
    }
```

In `markStopped()`, add `foldEndTask?.cancel()` and `foldEndTask = nil` next to the other cancellations.

Add these methods:

```swift
  private func startFoldToEndIfRacing() {
    guard foldEndTask == nil, let gemini = geminiSessionVM, gemini.isGeminiActive else { return }
    logEvent("fold: ending Race in 10 s unless unfolded")
    SpokenCues.shared.speak("Ending Race in 10 seconds, unfold to cancel", onPhoneSpeaker: true)
    foldEndTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.foldEndDelay)
      guard let self, !Task.isCancelled else { return }
      self.foldEndTask = nil
      guard self.glassesReportedFolded, let gemini = self.geminiSessionVM, gemini.isGeminiActive else { return }
      self.logEvent("fold: ending Race")
      switch await gemini.endScout() {
      case .sent:
        SpokenCues.shared.speak("Report sent to Setup_IQ", onPhoneSpeaker: true)
      case .queued:
        SpokenCues.shared.speak("Report saved. It will send when you have signal.", onPhoneSpeaker: true)
      case .testMode:
        SpokenCues.shared.speak("Test mode. Report not sent.", onPhoneSpeaker: true)
      case .nothingToSend:
        SpokenCues.shared.speak("Race ended", onPhoneSpeaker: true)
      }
    }
  }
```

- [ ] **Step 2: `StreamView`: the Race wording**

In `ControlsView`:
- The Scout `CircleButton`: change `text: "Scout"` to `text: "Race"`.
- The End dialog: change `"End Scout session?"` to `"End Race?"`.
- Keep the "Send Report to Setup_IQ" button as it is (it calls `await geminiVM.endScout()`, whose result it ignores, as `@discardableResult` allows).

In `StreamView`'s `.onChange(of: geminiVM.isGeminiActive)` handler, change the announcement to `A11y.announce(isActive ? "Race started" : "Race ended")`.

- [ ] **Step 3: Create `Settings/ScoutReportsView.swift`**

```swift
import SwiftUI

/// The Outbox as a list: every Scout report, where it is, and Retry for failures.
struct ScoutReportsView: View {
  @ObservedObject private var outbox = ScoutOutbox.shared

  var body: some View {
    List {
      if outbox.captures.isEmpty {
        Text("No Scout reports yet.")
          .foregroundStyle(.secondary)
      }
      ForEach(outbox.captures.sorted { $0.createdAt > $1.createdAt }) { capture in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(capture.trackName.isEmpty ? "Session" : capture.trackName)
              .font(.headline)
            Spacer()
            Text(Self.stateLabel(capture))
              .font(.subheadline)
              .foregroundStyle(capture.state == .failed ? .red : .secondary)
          }
          Text("\(capture.vehicleModel) · \(capture.durationMin) min · \(capture.createdAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption)
            .foregroundStyle(.secondary)
          if let error = capture.lastError {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
          }
          if capture.state == .failed {
            Button("Retry") {
              outbox.retry(capture.id)
            }
            .buttonStyle(.bordered)
          }
        }
        .accessibilityElement(children: .contain)
      }
    }
    .navigationTitle("Scout reports")
  }

  private static func stateLabel(_ capture: Capture) -> String {
    switch capture.state {
    case .reportPending: return "Sending…"
    case .reported, .done: return "Sent"
    case .failed: return capture.retryable ? "Waiting for signal" : "Failed"
    }
  }
}
```

Add it to the Settings group in `project.pbxproj` (group `9DD894B12F4047630090B9B9`, the one listing `GlassesEventLogView.swift`), with `A1B2C3D42F0A00010000000E /* ScoutReportsView.swift */` and `A1B2C3D42F0A00020000000E /* ScoutReportsView.swift in Sources */`, using the same four-place pattern.

- [ ] **Step 4: `SettingsView`: the link**

In the existing `Section(header: Text("Diagnostics"), …)`, above the `NavigationLink("Glasses event log")`, add:

```swift
          NavigationLink("Scout reports") {
            ScoutReportsView()
          }
```

- [ ] **Step 5: Self-check by reading.**
  - A fold only starts the countdown while `isGeminiActive`.
  - A second `hingesClosed` during a countdown does not start another one (`foldEndTask == nil` guard).
  - Unfolding cancels it on the first frame.
  - `markStopped` cancels it.
  - `endScout` stops Gemini, so `keepGlassesAlive` then turns false and the glasses reconnect loop winds down by itself.

- [ ] **Step 6: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift samples/CameraAccess/CameraAccess/Views/StreamView.swift samples/CameraAccess/CameraAccess/Settings/ScoutReportsView.swift samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj samples/CameraAccess/CameraAccess/Settings/SettingsView.swift
git commit -m "feat(race): fold-to-end countdown, Race button and Scout reports list"
```

The controller pushes after the final review.

---

## Device checklist (end-of-project device pass; owner)

1. **Race opening:** Scout asks only "Which vehicle — …?", and SPECTRE's report shows context "Driver Stand".
2. **End from the phone:** the report shows as Sent under Settings → Scout reports.
3. **Airplane mode, then End:** "No signal — the report is saved…". Turn airplane mode off and the report sends within about a minute, once.
4. **Fold the glasses mid-Race:** "Ending Race in 10 seconds…". Unfold at about 5 s and hear "Race continues". Fold again and wait 10 s: the report is sent.
5. **Force-quit the app while a report shows "Waiting for signal":** relaunch and it sends.

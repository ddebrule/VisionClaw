# Plan 6: Track Walk Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a **Track Walk** mode that records a real `.mp4` (H.264 + AAC) with narration from the phone camera or the glasses. It saves the video to Photos, transcribes it on the device, and queues a "Track Walk" text report in the Outbox. The report is **held** until the owner turns on "Send Track Walk reports", because SPECTRE's Track Walk changes (§B6) are being built in parallel. The video upload is Plan 7.

**Architecture:**

The pure parts live in `ScoutCore` and are tested in CI:
- the extended `Capture` (Track Walk states, optional video fields, held reports);
- `RecordingClock` (pause-aware media time);
- `TrackWalkLimits` (cue times, storage floors, bitrate).

The app-side work lives in a new synchronized folder, `CameraAccess/TrackWalk/`:
- `TrackWalkRecorder`: an `AVAssetWriter` writing a fragmented QuickTime `.mov`. Video comes from `FrameHub` pixel buffers; audio comes from its own `AVCaptureSession` with automatic audio configuration off.
- `TrackWalkMedia`: remux to `.mp4`, Photos, audio extraction, and `SpeechAnalyzer` transcription.
- `TrackWalkFinisher`: the after-Stop pipeline, which also recovers after a crash.
- `TrackWalkController`: preflight, cues, pause and resume, limits and glasses events.

`StreamSessionViewModel` owns the controller and forwards glasses fold and drop events to it.

**Tech Stack:** SwiftUI, Swift 5 language mode, iOS 26.0, AVFoundation (`AVAssetWriter`, `AVCaptureSession`, `AVAssetExportSession`), Speech (`SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`), Photos, XCTest through `swift test`.

**Spec:** `docs/superpowers/specs/2026-09-23-upstream-catchup-and-scout-modes-design.md` §B1 (Track Walk picker), §B4, §B5 (Track Walk Outbox states up to `reported`), §B7 (roadmap plan 6). Research: `.superpowers/sdd/plan6-research.md`.

## Global Constraints

- iOS 26.0. Swift 5 mode in the app. `ScoutCore` uses swift-tools 6.0 (Swift 6 mode), is Foundation-only, and compiles into the app **without `import ScoutCore`**.
- **Do not touch the SPECTRE repo.** Track Walk reports are held in the Outbox (`reportPending`, not sent) while `SettingsManager.shared.trackWalkReportsEnabled` is false, which is the default.
- Track Walk report body: `scout_context = "Track Walk"`, `capture_id`, `session_id`, `transcript` (`role: "user"` lines), `duration_min`, `no_narration` (Bool). **No `vehicle_model` key.**
- **Silent walk** (no recognised speech): `no_narration: true`, with exactly one transcript line: `{"role":"user","text":"(Silent walk — no narration recorded.)"}`.
- Recording:
  - H.264 video at `TrackWalkLimits.videoBitRate(width:height:)`, which is **10 Mbps for 1920×1080**, scaled by pixel count, with a floor of 2 Mbps.
  - AAC mono audio at 44.1 kHz, 64 kbps.
  - A fragmented QuickTime `.mov` (`movieFragmentInterval` = 2 s), remuxed with passthrough to `.mp4` after Stop.
- Limits:
  - Starting needs **3 GB** free.
  - A spoken **"Two minutes left"** at **12:55** of recorded time.
  - Auto-stop at **14:55** with "Stopped".
  - Below **300 MB** free while recording: stop and say "Storage full, saved".
  - Glasses folded or paused for **2 minutes**: the walk finishes.
- Cues come from `SpokenCues.shared.speak(_:)` on the current route: "Recording started", "Paused", "Recording", "Two minutes left", "Stopped" and "Storage full, saved".
- Glasses controls:
  - `hingesClosed` → pause.
  - Frames returning after a fold → resume.
  - Any stream stop that does not get a `hingesClosed` within **1.0 s** → the walk finishes.
  - During a walk `keepGlassesAlive` is true, so a fold's stream stop reconnects. Once the walk has finished, the link winds down on its own.
- Phone controls: Pause/Resume and Stop buttons, which work in both source modes.
- Photos: save when `SettingsManager.shared.trackWalkSaveToPhotos` is on (the default), with add-only permission. A failure to save never blocks the report.
- Files live in `Application Support/TrackWalks/<capture-id>.mov|.mp4|.m4a`. The `.mov` and `.m4a` are deleted once the `.mp4` exists and transcription is done. The `.mp4` stays for Plan 7's upload.
- A `recording` capture with no live recorder at launch is a crash. The finisher recovers its partial `.mov`.
- New `Capture` fields are **optional**, so older manifests still decode (Plan 5 finding).
- Before editing any `.swift` file, read `.claude/skills/swiftui-pro/SKILL.md` and follow it.
- **No Swift toolchain on this PC; CI is the compiler.** Push once, after the final review. Before pushing, run `git pull --rebase origin main`.
- Commit messages end with exactly: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## Review Focus

1. **The app is killed mid-walk.** Expected: on relaunch the partial `.mov` is recovered (up to the last 2 s fragment), remuxed, transcribed, and the report is queued. Covered by:
   - `testRecordingCaptureIsNotSendable` and `testMarkRecordedMovesToRecorded` (Task 1);
   - the finisher's `recording`-without-live-recorder branch (Task 4).
2. **A pause mid-walk.** Expected: the paused time is cut out of the video, and audio and video stay in sync. Covered by `RecordingClock` tests (Task 1), and by the recorder dropping out-of-order samples per track (Task 3).
3. **A silent walk.** Expected: `no_narration: true` with one placeholder line, and SPECTRE is never sent an empty transcript. Covered by `testSilentWalkGetsPlaceholder` (Task 1).
4. **Track Walk reports are held until the owner enables them, while Race reports are unaffected.** Covered by `testHeldTrackWalkIsNotSent` and `testRaceIgnoresTrackWalkGate` (Task 1).
5. **An old Plan 5 manifest** (no video fields) still decodes. Covered by `testDecodesManifestWithoutTrackWalkFields` (Task 1).

## File map

| File | Change | Task |
|---|---|---|
| `ScoutCore/Sources/ScoutCore/Capture.swift` | Track Walk states, optional fields, rules | 1 |
| `ScoutCore/Sources/ScoutCore/RecordingClock.swift`, `TrackWalkLimits.swift` | Create | 1 |
| `ScoutCore/Tests/ScoutCoreTests/CaptureTests.swift` (extend), `RecordingClockTests.swift`, `TrackWalkLimitsTests.swift` | Tests | 1 |
| `CameraAccess/Settings/SettingsManager.swift`, `SettingsView.swift` | Two Track Walk switches | 2 |
| `CameraAccess/Gemini/GeminiConfig.swift`, `SpectreScoutBridge.swift` | `fetchSessions`, the Track Walk report body | 2 |
| `CameraAccess/Gemini/ScoutOutbox.swift` | `add`, `update`, held Track Walk reports | 2 |
| `CameraAccess/Settings/ScoutReportsView.swift` | Labels for the new states | 2 |
| `CameraAccess/Gemini/GeminiSessionViewModel.swift` | Plan 5 carry-over: all four end results worded | 2 |
| `CameraAccess/Info.plist` | Speech usage string; wording | 2 |
| `CameraAccess.xcodeproj/project.pbxproj` | New synchronized folder `TrackWalk` | 3 |
| `CameraAccess/TrackWalk/TrackWalkRecorder.swift`, `TrackWalkMedia.swift` | Create | 3 |
| `CameraAccess/TrackWalk/TrackWalkFinisher.swift` | Create | 4 |
| `CameraAccess/CameraAccessApp.swift` | Resume the finisher at launch and on becoming active | 4 |
| `CameraAccess/TrackWalk/TrackWalkController.swift` | Create | 5 |
| `CameraAccess/ViewModels/StreamSessionViewModel.swift` | Own the controller; frame subscription; glasses hooks | 5 |
| `CameraAccess/TrackWalk/TrackWalkViews.swift` | Create: picker sheet and recording bar | 6 |
| `CameraAccess/Views/StreamView.swift` | Walk button, bar, `onDisappear` | 6 |

---

### Task 1: ScoutCore — Track Walk capture, recording clock, limits

**Files:**
- Modify: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/Capture.swift`
- Create: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/RecordingClock.swift`
- Create: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/TrackWalkLimits.swift`
- Test: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/CaptureTests.swift` (append)
- Test: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/RecordingClockTests.swift`
- Test: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/TrackWalkLimitsTests.swift`

**Interfaces (produces):**
- `CaptureState` gains `recording` and `recorded`. Raw values are the case names.
- `Capture`:
  - `transcript` and `durationMin` become `var`.
  - New optional fields: `var videoFileName: String?`, `var noNarration: Bool?`, `var savedToPhotos: Bool?`.
  - `init` gains trailing parameters `state: CaptureState = .reportPending` and `videoFileName: String? = nil`.
- `OutboxRules`:
  - `needsSend(_:trackWalkReportsEnabled: Bool = true)`
  - `markRecorded(_: inout Capture, videoFileName: String?, savedToPhotos: Bool)`
  - `markTranscribed(_: inout Capture, lines: [String])`
  - `static let silentWalkLine: String`
- `public struct RecordingClock: Equatable, Sendable` with `start(at:)`, `pause(at:)`, `resume(at:)`, `isStarted`, `isPaused`, `mediaTime(for:) -> TimeInterval?`, `elapsed(at:) -> TimeInterval`.
- `public enum TrackWalkLimits`:
  - `warnAt`, `stopAt`, `pausedFinishAfter`, `minFreeBytesToStart`, `minFreeBytesWhileRecording`
  - `enum Cue { none, twoMinutesLeft, stop }`
  - `cue(elapsed:warned:) -> Cue`
  - `videoBitRate(width:height:) -> Int`

- [ ] **Step 1: Append failing tests to `CaptureTests.swift`** (inside the existing class):

```swift
  private func walk(state: CaptureState = .recording) -> Capture {
    Capture(
      id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
      mode: .trackWalk, sessionId: "c0ffee00-0000-4000-8000-000000000002",
      trackName: "Mile High", transcript: [], scoutContext: "Track Walk",
      vehicleModel: "", durationMin: 0,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      state: state, videoFileName: "22222222-3333-4444-5555-666666666666.mov")
  }

  func testRecordingCaptureIsNotSendable() {
    XCTAssertFalse(OutboxRules.needsSend(walk()))
    XCTAssertFalse(OutboxRules.needsSend(walk(state: .recorded)))
  }

  func testMarkRecordedMovesToRecorded() {
    var capture = walk()
    OutboxRules.markRecorded(&capture, videoFileName: "x.mp4", savedToPhotos: true)
    XCTAssertEqual(capture.state, .recorded)
    XCTAssertEqual(capture.videoFileName, "x.mp4")
    XCTAssertEqual(capture.savedToPhotos, true)
  }

  func testMarkTranscribedWithSpeech() {
    var capture = walk(state: .recorded)
    OutboxRules.markTranscribed(&capture, lines: ["double into the triple", "  ", "sweeper is blown out"])
    XCTAssertEqual(capture.state, .reportPending)
    XCTAssertEqual(capture.noNarration, false)
    XCTAssertEqual(capture.transcript, [
      TranscriptLine(role: "user", text: "double into the triple"),
      TranscriptLine(role: "user", text: "sweeper is blown out"),
    ])
  }

  func testSilentWalkGetsPlaceholder() {
    var capture = walk(state: .recorded)
    OutboxRules.markTranscribed(&capture, lines: ["", "   "])
    XCTAssertEqual(capture.noNarration, true)
    XCTAssertEqual(capture.transcript, [TranscriptLine(role: "user", text: "(Silent walk — no narration recorded.)")])
    XCTAssertEqual(OutboxRules.silentWalkLine, "(Silent walk — no narration recorded.)")
  }

  func testHeldTrackWalkIsNotSent() {
    var capture = walk(state: .recorded)
    OutboxRules.markTranscribed(&capture, lines: ["line"])
    XCTAssertFalse(OutboxRules.needsSend(capture, trackWalkReportsEnabled: false))
    XCTAssertTrue(OutboxRules.needsSend(capture, trackWalkReportsEnabled: true))
    OutboxRules.apply(.transientFailure("offline"), to: &capture)
    XCTAssertFalse(OutboxRules.needsSend(capture, trackWalkReportsEnabled: false))
  }

  func testRaceIgnoresTrackWalkGate() {
    XCTAssertTrue(OutboxRules.needsSend(race(), trackWalkReportsEnabled: false))
  }

  func testTrackWalkRoundTripKeepsVideoFields() throws {
    var capture = walk()
    OutboxRules.markRecorded(&capture, videoFileName: "a.mp4", savedToPhotos: false)
    XCTAssertEqual(try OutboxCoding.decode(OutboxCoding.encode([capture])), [capture])
  }

  func testDecodesManifestWithoutTrackWalkFields() throws {
    let json = #"""
    {"captures":[{"attempts":0,"createdAt":"2023-11-14T22:13:20Z","durationMin":12,"id":"11111111-2222-3333-4444-555555555555","mode":"race","retryable":true,"scoutContext":"Driver Stand","sessionId":"s","state":"reportPending","trackName":"t","transcript":[],"vehicleModel":"Nitro Buggy"}],"version":1}
    """#
    let captures = try OutboxCoding.decode(Data(json.utf8))
    XCTAssertEqual(captures.count, 1)
    XCTAssertNil(captures[0].videoFileName)
    XCTAssertNil(captures[0].noNarration)
  }
```

- [ ] **Step 2: Write `RecordingClockTests.swift`**

```swift
import XCTest
@testable import ScoutCore

final class RecordingClockTests: XCTestCase {
  func testNothingBeforeStart() {
    let clock = RecordingClock()
    XCTAssertFalse(clock.isStarted)
    XCTAssertNil(clock.mediaTime(for: 10))
    XCTAssertEqual(clock.elapsed(at: 10), 0)
  }

  func testMediaTimeCountsFromStart() {
    var clock = RecordingClock()
    clock.start(at: 100)
    XCTAssertEqual(clock.mediaTime(for: 100), 0)
    XCTAssertEqual(clock.mediaTime(for: 102.5), 2.5)
    XCTAssertNil(clock.mediaTime(for: 99))
    XCTAssertEqual(clock.elapsed(at: 110), 10)
  }

  func testPauseCutsTimeOut() {
    var clock = RecordingClock()
    clock.start(at: 100)
    clock.pause(at: 110)
    XCTAssertTrue(clock.isPaused)
    XCTAssertNil(clock.mediaTime(for: 112))
    XCTAssertEqual(clock.elapsed(at: 130), 10)
    clock.resume(at: 130)
    XCTAssertFalse(clock.isPaused)
    XCTAssertEqual(clock.mediaTime(for: 131), 11)
    XCTAssertEqual(clock.elapsed(at: 140), 20)
  }

  func testSampleFromInsideAPauseIsDropped() {
    var clock = RecordingClock()
    clock.start(at: 0)
    clock.pause(at: 10)
    clock.resume(at: 20)
    // Captured at 15 (while paused) but delivered after resume.
    XCTAssertNil(clock.mediaTime(for: 15))
    XCTAssertEqual(clock.mediaTime(for: 20), 10)
  }

  func testRepeatedCallsAreIgnored() {
    var clock = RecordingClock()
    clock.start(at: 0)
    clock.start(at: 50)
    clock.pause(at: 10)
    clock.pause(at: 12)
    clock.resume(at: 20)
    clock.resume(at: 25)
    XCTAssertEqual(clock.elapsed(at: 30), 20)
  }
}
```

- [ ] **Step 3: Write `TrackWalkLimitsTests.swift`**

```swift
import XCTest
@testable import ScoutCore

final class TrackWalkLimitsTests: XCTestCase {
  func testConstants() {
    XCTAssertEqual(TrackWalkLimits.warnAt, 775)
    XCTAssertEqual(TrackWalkLimits.stopAt, 895)
    XCTAssertEqual(TrackWalkLimits.pausedFinishAfter, 120)
    XCTAssertEqual(TrackWalkLimits.minFreeBytesToStart, 3_000_000_000)
    XCTAssertEqual(TrackWalkLimits.minFreeBytesWhileRecording, 300_000_000)
  }

  func testCues() {
    XCTAssertEqual(TrackWalkLimits.cue(elapsed: 774, warned: false), .none)
    XCTAssertEqual(TrackWalkLimits.cue(elapsed: 775, warned: false), .twoMinutesLeft)
    XCTAssertEqual(TrackWalkLimits.cue(elapsed: 800, warned: true), .none)
    XCTAssertEqual(TrackWalkLimits.cue(elapsed: 895, warned: true), .stop)
    XCTAssertEqual(TrackWalkLimits.cue(elapsed: 900, warned: false), .stop)
  }

  func testBitRateScalesByPixels() {
    XCTAssertEqual(TrackWalkLimits.videoBitRate(width: 1080, height: 1920), 10_000_000)
    XCTAssertEqual(TrackWalkLimits.videoBitRate(width: 720, height: 1280), 4_444_444)
    XCTAssertEqual(TrackWalkLimits.videoBitRate(width: 360, height: 640), 2_000_000)
  }
}
```

- [ ] **Step 4: Confirm the tests would fail.** Grep shows that `RecordingClock`, `TrackWalkLimits`, `markRecorded` and `CaptureState.recording` are not present.

- [ ] **Step 5: Implement `Capture.swift` changes**
- `CaptureState`: add `case recording` and `case recorded` **before** `reportPending`. Update the doc comment to: `/// Where a capture is in its trip to SPECTRE. Race: reportPending → done. Track Walk: recording → recorded → reportPending → reported (Plan 7 continues to the video upload).`
- `Capture`:
  - Change `public let transcript` to `public var transcript`, and `public let durationMin` to `public var durationMin`.
  - Add after `retryable`:

```swift
  /// Track Walk: the recording's file name inside Application Support/TrackWalks.
  public var videoFileName: String?
  /// Track Walk: true when no speech was recognised (SPECTRE then skips layout extraction).
  public var noNarration: Bool?
  /// Track Walk: already saved to the Photos library.
  public var savedToPhotos: Bool?
```

- In `init`, add trailing parameters `state: CaptureState = .reportPending, videoFileName: String? = nil`. Assign `self.state = state` in place of the hard-coded `.reportPending`, set `self.videoFileName = videoFileName`, and set `noNarration` and `savedToPhotos` to `nil`.
- `OutboxRules`:

```swift
  public static let silentWalkLine = "(Silent walk — no narration recorded.)"

  public static func needsSend(_ capture: Capture, trackWalkReportsEnabled: Bool = true) -> Bool {
    if capture.mode == .trackWalk && !trackWalkReportsEnabled { return false }
    switch capture.state {
    case .reportPending: return true
    case .failed: return capture.retryable
    case .recording, .recorded, .reported, .done: return false
    }
  }

  /// A Track Walk's recording is finalized (the file exists as .mp4, or was lost).
  public static func markRecorded(_ capture: inout Capture, videoFileName: String?, savedToPhotos: Bool) {
    capture.videoFileName = videoFileName
    capture.savedToPhotos = savedToPhotos
    capture.state = .recorded
  }

  /// Transcription done: the report is ready. Blank lines are dropped; no speech
  /// at all becomes a single placeholder line with noNarration set.
  public static func markTranscribed(_ capture: inout Capture, lines: [String]) {
    let spoken = lines
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    capture.noNarration = spoken.isEmpty
    capture.transcript = spoken.isEmpty
      ? [TranscriptLine(role: "user", text: silentWalkLine)]
      : spoken.map { TranscriptLine(role: "user", text: $0) }
    capture.state = .reportPending
  }
```

(Replace the existing `needsSend`. Its existing callers pass one argument and keep working through the default.)

- [ ] **Step 6: Implement `RecordingClock.swift`**

```swift
import Foundation

/// Pause-aware recording time. Host-clock seconds go in; media time (seconds
/// since the start, with every pause cut out) comes out. Samples captured
/// during a pause have no media time and are dropped.
public struct RecordingClock: Equatable, Sendable {
  private var startedAt: TimeInterval?
  private var pausedAt: TimeInterval?
  private var pausedTotal: TimeInterval = 0
  private var pauses: [ClosedRange<TimeInterval>] = []

  public init() {}

  public var isStarted: Bool { startedAt != nil }
  public var isPaused: Bool { pausedAt != nil }

  public mutating func start(at time: TimeInterval) {
    guard startedAt == nil else { return }
    startedAt = time
  }

  public mutating func pause(at time: TimeInterval) {
    guard startedAt != nil, pausedAt == nil else { return }
    pausedAt = time
  }

  public mutating func resume(at time: TimeInterval) {
    guard let pausedAt else { return }
    pausedTotal += time - pausedAt
    pauses.append(pausedAt...time)
    self.pausedAt = nil
  }

  public func mediaTime(for time: TimeInterval) -> TimeInterval? {
    guard let startedAt, time >= startedAt else { return nil }
    if let pausedAt, time >= pausedAt { return nil }
    var cut: TimeInterval = 0
    for pause in pauses {
      if pause.contains(time) && time < pause.upperBound { return nil }
      if time >= pause.upperBound { cut += pause.upperBound - pause.lowerBound }
    }
    return time - startedAt - cut
  }

  public func elapsed(at now: TimeInterval) -> TimeInterval {
    guard let startedAt else { return 0 }
    let end = pausedAt ?? now
    return max(0, end - startedAt - pausedTotal)
  }
}
```

Check against the tests. `testSampleFromInsideAPauseIsDropped`: the pause is 10...20, so a sample at 15 → nil, and a sample at 20 is not `< upperBound`, so cut = 10 and the result is 20 − 0 − 10 = 10. `testPauseCutsTimeOut`: 131 → cut 20, so 131 − 100 − 20 = 11.

- [ ] **Step 7: Implement `TrackWalkLimits.swift`**

```swift
import Foundation

/// Track Walk timing, storage and quality limits (spec §B4). SPECTRE refuses
/// walks over 15:00, so recording stops at 14:55.
public enum TrackWalkLimits {
  public static let warnAt: TimeInterval = 12 * 60 + 55
  public static let stopAt: TimeInterval = 14 * 60 + 55
  /// Folded or paused this long, and the walk finishes.
  public static let pausedFinishAfter: TimeInterval = 120
  public static let minFreeBytesToStart: Int64 = 3_000_000_000
  public static let minFreeBytesWhileRecording: Int64 = 300_000_000

  public enum Cue: Equatable, Sendable {
    case none
    case twoMinutesLeft
    case stop
  }

  public static func cue(elapsed: TimeInterval, warned: Bool) -> Cue {
    if elapsed >= stopAt { return .stop }
    if elapsed >= warnAt && !warned { return .twoMinutesLeft }
    return .none
  }

  /// About 10 Mbps for 1080p, scaled by pixel count, never below 2 Mbps.
  public static func videoBitRate(width: Int, height: Int) -> Int {
    let scaled = 10_000_000.0 * Double(width * height) / Double(1920 * 1080)
    return max(2_000_000, Int(scaled))
  }
}
```

Check: 720×1280 = 921,600, and 10 M × 921,600 / 2,073,600 = 4,444,444.4, which `Int` truncates to 4,444,444.

- [ ] **Step 8: Trace every new test by hand** and put the traces in the report.

- [ ] **Step 9: Commit (do not push)**

```bash
git add samples/CameraAccess/ScoutCore
git commit -m "feat(scoutcore): Track Walk capture states, recording clock and limits"
```

Note: the app's `ScoutReportsView` switches over `CaptureState` and will not compile until Task 2 adds the new cases. This is accepted because nothing is pushed between tasks.

---

### Task 2: App plumbing — settings, bridge, Outbox, labels, carry-over

**Files:**
- Modify: `Settings/SettingsManager.swift`, `Settings/SettingsView.swift`, `Settings/ScoutReportsView.swift`
- Modify: `Gemini/GeminiConfig.swift`, `Gemini/SpectreScoutBridge.swift`, `Gemini/ScoutOutbox.swift`, `Gemini/GeminiSessionViewModel.swift`
- Modify: `Info.plist`

(All paths are under `samples/CameraAccess/CameraAccess/`.)

**Interfaces (produces):**
- `SettingsManager.trackWalkSaveToPhotos: Bool` (default `true`) and `trackWalkReportsEnabled: Bool` (default `false`).
- `struct ScoutSessionSummary: Identifiable, Equatable { let id: String; let track: String; let status: String; let scheduledDate: String? }`
- `SpectreScoutBridge.fetchSessions() async throws -> [ScoutSessionSummary]`
- `ScoutOutbox.add(_:)`, `ScoutOutbox.update(_:_:)`, `ScoutOutbox.capture(_:) -> Capture?`

- [ ] **Step 1: Settings**

In `SettingsManager`, add the keys `trackWalkSaveToPhotos` and `trackWalkReportsEnabled` to `Key`, add both to the `resetAll()` array, and add:

```swift
  // MARK: - Track Walk

  var trackWalkSaveToPhotos: Bool {
    get { defaults.object(forKey: Key.trackWalkSaveToPhotos.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.trackWalkSaveToPhotos.rawValue) }
  }

  /// Off until SPECTRE handles Track Walk reports (no_narration, no vehicle);
  /// until then walks are recorded and their reports wait in the Outbox.
  var trackWalkReportsEnabled: Bool {
    get { defaults.bool(forKey: Key.trackWalkReportsEnabled.rawValue) }
    set { defaults.set(newValue, forKey: Key.trackWalkReportsEnabled.rawValue) }
  }
```

In `SettingsView`, follow how `scoutTestMode` is loaded and saved (the `@State` property, the load in the on-appear/load function, and the save function). Add `@State private var trackWalkSaveToPhotos = true` and `@State private var trackWalkReportsEnabled = false`, load and save them the same way, and add this section after the "Scout" section:

```swift
        Section(header: Text("Track Walk"), footer: Text("Reports wait in Settings → Scout reports until sending is on. Turn it on once SPECTRE supports Track Walk reports.")) {
          Toggle("Save walk videos to Photos", isOn: $trackWalkSaveToPhotos)
          Toggle("Send Track Walk reports", isOn: $trackWalkReportsEnabled)
        }
```

Read `SettingsView` first. If it saves on a Save button, follow that. If toggles write through immediately, follow that instead.

- [ ] **Step 2: `GeminiConfig`: sessions URL**

After `spectreActiveSessionURL`, add:

```swift
  static var spectreSessionsURL: String { spectreScoutURL + "/sessions" }
```

- [ ] **Step 3: `SpectreScoutBridge`: session list and Track Walk body**

Add near `ActiveSessionInfo`:

```swift
/// One session in the Track Walk picker (SPECTRE `GET /api/scout/sessions`).
struct ScoutSessionSummary: Identifiable, Equatable {
  let id: String
  let track: String
  let status: String
  let scheduledDate: String?
}
```

Add to `SpectreScoutBridge`:

```swift
  /// Planned and active sessions for the Track Walk picker, active first.
  /// Falls back to the active session alone while SPECTRE lacks the list route.
  func fetchSessions() async throws -> [ScoutSessionSummary] {
    guard let url = URL(string: GeminiConfig.spectreSessionsURL) else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(GeminiConfig.spectreUserToken, forHTTPHeaderField: "X-Scout-Token")
    let (data, response) = try await session.data(for: request, delegate: RedirectRefuser())
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    if http.statusCode == 404 || (300...399).contains(http.statusCode) {
      // Older SPECTRE: no list route yet. Offer the active session if there is one.
      do {
        let active = try await fetchActiveSession()
        return [ScoutSessionSummary(id: active.sessionId, track: active.track, status: "active", scheduledDate: nil)]
      } catch {
        return []
      }
    }
    guard (200...299).contains(http.statusCode),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = json["sessions"] as? [[String: Any]]
    else { throw URLError(.cannotParseResponse) }
    return rows.compactMap { row in
      guard let id = row["session_id"] as? String else { return nil }
      return ScoutSessionSummary(
        id: id,
        track: row["track"] as? String ?? "Session",
        status: row["status"] as? String ?? "planned",
        scheduledDate: row["scheduled_date"] as? String)
    }
  }
```

In `deliver(_:)`, make `body` a `var`, remove the `"vehicle_model"` entry from the literal, and add after it:

```swift
    if capture.mode == .trackWalk {
      body["no_narration"] = capture.noNarration ?? false
    } else {
      body["vehicle_model"] = capture.vehicleModel
    }
```

(Track Walk sends no vehicle, per the global constraints. Race behaves as before.)

- [ ] **Step 4: `ScoutOutbox`: add, update, held walks**
- Add these methods:

```swift
  /// Saves a capture without sending it (a Track Walk starting to record).
  func add(_ capture: Capture) {
    captures.append(capture)
    save()
  }

  func capture(_ id: UUID) -> Capture? {
    captures.first { $0.id == id }
  }

  /// Changes one capture and saves before returning, so the change is on disk
  /// before whatever step it unlocks.
  func update(_ id: UUID, _ change: (inout Capture) -> Void) {
    guard let index = captures.firstIndex(where: { $0.id == id }) else { return }
    change(&captures[index])
    save()
  }
```

- In `reconcile()` and in `send(_:)`'s guard, change both `OutboxRules.needsSend(…)` calls to `OutboxRules.needsSend(…, trackWalkReportsEnabled: SettingsManager.shared.trackWalkReportsEnabled)`.
- Make `resume()` public-callable as it is, and add a doc line: a Settings change enabling Track Walk reports should call `ScoutOutbox.shared.resume()`. In `SettingsView`, call it right after `trackWalkReportsEnabled` is saved as true.

- [ ] **Step 5: `ScoutReportsView` labels**

Replace `stateLabel` with:

```swift
  private static func stateLabel(_ capture: Capture) -> String {
    switch capture.state {
    case .recording: return "Recording…"
    case .recorded: return "Processing…"
    case .reportPending:
      if capture.mode == .trackWalk && !SettingsManager.shared.trackWalkReportsEnabled {
        return "Held"
      }
      return "Sending…"
    case .reported: return capture.mode == .trackWalk ? "Report sent · video waiting" : "Sent"
    case .done: return "Sent"
    case .failed: return capture.retryable ? "Waiting for signal" : "Failed"
    }
  }
```

In the row's detail `Text`, show `"Track Walk"` in place of an empty `vehicleModel`: `(capture.vehicleModel.isEmpty ? "Track Walk" : capture.vehicleModel)`.

- [ ] **Step 6: Plan 5 carry-over (ledger ruling): word all four end results**

In `GeminiSessionViewModel`, the reconnect give-up branch and the idle-guard `.end` branch each speak a `result == .sent ? … : …` ternary. Replace both with a `switch result` over all four `EndScoutResult` cases:
- Reconnect give-up:
  - `.sent`: "Scout connection lost. Report sent to Setup_IQ."
  - `.queued`: "Scout connection lost. Report saved."
  - `.nothingToSend`: "Scout connection lost. Race ended."
  - `.testMode`: "Scout connection lost. Test mode, report not sent."
- Idle end:
  - `.sent`: "Race ended after 45 quiet minutes. Report sent to Setup_IQ."
  - `.queued`: "Race ended after 45 quiet minutes. Report saved."
  - `.nothingToSend`: "Race ended after 45 quiet minutes."
  - `.testMode`: "Race ended after 45 quiet minutes. Test mode, report not sent."

Keep `onPhoneSpeaker: true`.

- [ ] **Step 7: `Info.plist`**
- Add `NSSpeechRecognitionUsageDescription`: "Track Walk turns your narration into text on this iPhone for your SPECTRE report."
- Change `NSMicrophoneUsageDescription` to: "The microphone carries your voice to Scout during a Race and records your narration during a Track Walk."
- Change `NSPhotoLibraryAddUsageDescription` to: "Saves photos from your glasses and Track Walk videos to your library."

Keep the file's existing tab indentation.

- [ ] **Step 8: Self-check by reading.**
  - Every `switch` over `CaptureState` in the app is exhaustive (grep `case .reportPending`).
  - `RedirectRefuser` is `private` in `SpectreScoutBridge.swift`, so `fetchSessions` can use it because it is in the same file.

- [ ] **Step 9: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/Settings samples/CameraAccess/CameraAccess/Gemini samples/CameraAccess/CameraAccess/Info.plist
git commit -m "feat(trackwalk): settings, session list, held Track Walk reports, report labels"
```

---

### Task 3: Recorder and media helpers (new `TrackWalk` folder)

**Files:**
- Modify: `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj`
- Create: `samples/CameraAccess/CameraAccess/TrackWalk/TrackWalkRecorder.swift`
- Create: `samples/CameraAccess/CameraAccess/TrackWalk/TrackWalkMedia.swift`

**Interfaces (produces):**
- `final class TrackWalkRecorder: NSObject`, with:
  - `init(outputURL: URL)`
  - `func start() throws` (starts audio capture)
  - `func appendVideo(_ pixelBuffer: CVPixelBuffer, hostTime: TimeInterval)`
  - `func pause(at:)` and `func resume(at:)`
  - `func elapsed(at:) -> TimeInterval`
  - `func finish() async -> Bool`
- `enum TrackWalkMedia`, with:
  - `static let folder: URL`
  - `static func url(for id: UUID, ext: String) -> URL`
  - `static func freeBytes() -> Int64?`
  - `static func remux(_ mov: URL, to mp4: URL) async throws`
  - `static func saveToPhotos(_ url: URL) async -> Bool`
  - `static func extractAudio(from video: URL, to m4a: URL) async throws`
  - `static func ensureSpeechModel() async -> Bool`
  - `static func transcribe(_ audio: URL) async throws -> [String]`

- [ ] **Step 1: Register the synchronized folder in `project.pbxproj`**

Mirror the `iPhone` synchronized group (`9D3C69602F367CF700E641A5`) in all three places it appears. Use the new ID `5C0E00012F9A000000000002`, after confirming by grep that it is unused:
1. In the `PBXFileSystemSynchronizedRootGroup` section:
   `5C0E00012F9A000000000002 /* TrackWalk */ = {isa = PBXFileSystemSynchronizedRootGroup; explicitFileTypes = {}; explicitFolders = (); path = TrackWalk; sourceTree = "<group>"; };`
2. In the parent group's `children`, where `9D3C69602F367CF700E641A5 /* iPhone */,` is listed: add `5C0E00012F9A000000000002 /* TrackWalk */,`.
3. In the **app** target's `fileSystemSynchronizedGroups` (the one listing iPhone and ScoutCore, not the test target's): add `5C0E00012F9A000000000002 /* TrackWalk */,`.

Use tabs and match the neighbouring lines.

- [ ] **Step 2: Create `TrackWalk/TrackWalkMedia.swift`**

```swift
import AVFoundation
import Foundation
import Photos
import Speech

/// Files, storage, Photos and on-device transcription for Track Walk.
enum TrackWalkMedia {
  /// Application Support/TrackWalks — recordings live here until uploaded (Plan 7).
  static let folder: URL = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let folder = support.appendingPathComponent("TrackWalks", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }()

  static func url(for id: UUID, ext: String) -> URL {
    folder.appendingPathComponent("\(id.uuidString).\(ext)")
  }

  /// Space available for a user-requested save, in bytes.
  static func freeBytes() -> Int64? {
    let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  /// Fragmented .mov → .mp4, no re-encode.
  static func remux(_ mov: URL, to mp4: URL) async throws {
    try? FileManager.default.removeItem(at: mp4)
    let asset = AVURLAsset(url: mov)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
      throw CocoaError(.fileWriteUnknown)
    }
    export.shouldOptimizeForNetworkUse = true
    try await export.export(to: mp4, as: .mp4)
  }

  /// Adds the video to Photos with add-only permission. False on any failure.
  static func saveToPhotos(_ url: URL) async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { return false }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
      }
      return true
    } catch {
      NSLog("[TrackWalk] Photos save failed: %@", error.localizedDescription)
      return false
    }
  }

  /// The narration track as .m4a, for the speech analyzer.
  static func extractAudio(from video: URL, to m4a: URL) async throws {
    try? FileManager.default.removeItem(at: m4a)
    let asset = AVURLAsset(url: video)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try await export.export(to: m4a, as: .m4a)
  }

  private static func transcriber() async -> SpeechTranscriber {
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
      ?? Locale(identifier: "en-US")
    return SpeechTranscriber(locale: locale, preset: .transcription)
  }

  /// Downloads the speech model now if it is missing (preflight, while online).
  static func ensureSpeechModel() async -> Bool {
    let module = await transcriber()
    do {
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        try await request.downloadAndInstall()
      }
      return true
    } catch {
      NSLog("[TrackWalk] Speech model unavailable: %@", error.localizedDescription)
      return false
    }
  }

  /// On-device transcription of a recorded file; one string per finalized phrase.
  static func transcribe(_ audio: URL) async throws -> [String] {
    let module = await transcriber()
    let analyzer = SpeechAnalyzer(modules: [module])
    let collector = Task { () -> [String] in
      var lines: [String] = []
      for try await result in module.results where result.isFinal {
        lines.append(String(result.text.characters))
      }
      return lines
    }
    let file = try AVAudioFile(forReading: audio)
    if let last = try await analyzer.analyzeSequence(from: file) {
      try await analyzer.finalizeAndFinish(through: last)
    } else {
      await analyzer.cancelAndFinishNow()
    }
    return try await collector.value
  }
}
```

**The `SpeechAnalyzer` API is the highest compile risk in this plan.** Before writing `transcribe`, `transcriber()` and `ensureSpeechModel`, confirm each symbol against Apple's documentation using web search or fetch:
- `SpeechTranscriber(locale:preset:)` and the `.transcription` preset
- `SpeechTranscriber.supportedLocale(equivalentTo:)`
- `AssetInventory.assetInstallationRequest(supporting:)` and `downloadAndInstall()`
- `SpeechAnalyzer(modules:)`
- `analyzeSequence(from:)`, `finalizeAndFinish(through:)` and `cancelAndFinishNow()`
- the results sequence and its `isFinal` and `text`

Pages to check: https://developer.apple.com/documentation/speech/speechanalyzer, https://developer.apple.com/documentation/speech/speechtranscriber, https://developer.apple.com/documentation/speech/assetinventory. Adapt the spelling to what the docs say, and list each adaptation in the report.

- [ ] **Step 3: Create `TrackWalk/TrackWalkRecorder.swift`**

```swift
import AVFoundation
import CoreVideo
import Foundation

/// Writes a Track Walk to a fragmented QuickTime .mov (crash-safe: at most
/// the last 2 s is lost). Video frames come from the FrameHub (stamped with
/// host time on arrival); audio comes from its own capture session, which is
/// told not to touch the app's audio session so the glasses route holds.
/// Everything that touches the writer runs on `queue`.
final class TrackWalkRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  private let outputURL: URL
  private let queue = DispatchQueue(label: "trackwalk-writer")
  private let audioSession = AVCaptureSession()
  private let audioOutput = AVCaptureAudioDataOutput()

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var clock = RecordingClock()
  private var lastVideoTime: TimeInterval = -1
  private var lastAudioTime: TimeInterval = -1
  private var finished = false

  init(outputURL: URL) {
    self.outputURL = outputURL
    super.init()
  }

  /// Starts the microphone. The writer is created on the first video frame,
  /// when the frame size is known.
  func start() throws {
    audioSession.automaticallyConfiguresApplicationAudioSession = false
    audioSession.beginConfiguration()
    guard let mic = AVCaptureDevice.default(for: .audio) else {
      audioSession.commitConfiguration()
      throw CocoaError(.featureUnsupported)
    }
    let input = try AVCaptureDeviceInput(device: mic)
    if audioSession.canAddInput(input) { audioSession.addInput(input) }
    audioOutput.setSampleBufferDelegate(self, queue: queue)
    if audioSession.canAddOutput(audioOutput) { audioSession.addOutput(audioOutput) }
    audioSession.commitConfiguration()
    queue.async { [audioSession] in audioSession.startRunning() }
  }

  func appendVideo(_ pixelBuffer: CVPixelBuffer, hostTime: TimeInterval) {
    queue.async { [self] in
      guard !finished else { return }
      if writer == nil { makeWriter(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer), startTime: hostTime) }
      guard let videoInput, let adaptor, videoInput.isReadyForMoreMediaData,
            let media = clock.mediaTime(for: hostTime), media > lastVideoTime
      else { return }
      if adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: media, preferredTimescale: 600)) {
        lastVideoTime = media
      }
    }
  }

  func pause(at hostTime: TimeInterval) {
    queue.async { [self] in clock.pause(at: hostTime) }
  }

  func resume(at hostTime: TimeInterval) {
    queue.async { [self] in clock.resume(at: hostTime) }
  }

  /// Recorded time so far (pauses excluded).
  func elapsed(at hostTime: TimeInterval) -> TimeInterval {
    queue.sync { clock.elapsed(at: hostTime) }
  }

  /// Stops capture and closes the file. True when a playable file was written.
  func finish() async -> Bool {
    audioSession.stopRunning()
    return await withCheckedContinuation { continuation in
      queue.async { [self] in
        finished = true
        guard let writer, writer.status == .writing else {
          continuation.resume(returning: false)
          return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting {
          continuation.resume(returning: writer.status == .completed)
        }
      }
    }
  }

  // MARK: - Audio

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    // Already on `queue`.
    guard !finished, let audioInput, audioInput.isReadyForMoreMediaData else { return }
    let hostTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
    guard let media = clock.mediaTime(for: hostTime), media > lastAudioTime else { return }
    var timing = CMSampleTimingInfo(
      duration: CMSampleBufferGetDuration(sampleBuffer),
      presentationTimeStamp: CMTime(seconds: media, preferredTimescale: 48_000),
      decodeTimeStamp: .invalid)
    var retimed: CMSampleBuffer?
    guard CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleBufferOut: &retimed) == noErr, let retimed
    else { return }
    if audioInput.append(retimed) { lastAudioTime = media }
  }

  // MARK: - Writer

  private func makeWriter(width: Int, height: Int, startTime: TimeInterval) {
    do {
      try? FileManager.default.removeItem(at: outputURL)
      let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
      writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

      let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: TrackWalkLimits.videoBitRate(width: width, height: height),
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
      ])
      video.expectsMediaDataInRealTime = true
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)

      let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 44_100,
        AVEncoderBitRateKey: 64_000,
      ])
      audio.expectsMediaDataInRealTime = true

      if writer.canAdd(video) { writer.add(video) }
      if writer.canAdd(audio) { writer.add(audio) }
      guard writer.startWriting() else {
        NSLog("[TrackWalk] Writer failed to start: %@", writer.error?.localizedDescription ?? "unknown")
        return
      }
      writer.startSession(atSourceTime: .zero)
      clock.start(at: startTime)
      self.writer = writer
      self.videoInput = video
      self.audioInput = audio
      self.adaptor = adaptor
      NSLog("[TrackWalk] Recording %dx%d to %@", width, height, outputURL.lastPathComponent)
    } catch {
      NSLog("[TrackWalk] Writer setup failed: %@", error.localizedDescription)
    }
  }
}
```

Notes for the implementer:
- `RecordingClock` is ScoutCore, used without an import.
- The class is not `@MainActor`. `appendVideo`, `pause`, `resume` and `elapsed` are called from the main actor; `elapsed` does a short `queue.sync`, which is safe because nothing on `queue` waits on main.
- Audio sample timestamps come from the capture session's clock, which is the host clock. Video uses `CACurrentMediaTime()` from the caller, so both are host seconds.

- [ ] **Step 4: Self-check by reading.**
  - Every AVFoundation and Speech symbol exists (docs check).
  - `TrackWalk/` is on disk and registered in three places.
  - No `@MainActor` state is touched from `queue`.

- [ ] **Step 5: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj samples/CameraAccess/CameraAccess/TrackWalk
git commit -m "feat(trackwalk): fragmented .mov recorder and media helpers (remux, Photos, SpeechAnalyzer)"
```

---

### Task 4: After-Stop pipeline and crash recovery

**Files:**
- Create: `samples/CameraAccess/CameraAccess/TrackWalk/TrackWalkFinisher.swift`
- Modify: `samples/CameraAccess/CameraAccess/CameraAccessApp.swift`

**Interfaces (produces):** `@MainActor final class TrackWalkFinisher` with:
- `static let shared`
- `var liveCaptureId: UUID?`, which the controller sets while recording
- `func advance(_ id: UUID) async`
- `func resumeAll()`

- [ ] **Step 1: Create `TrackWalkFinisher.swift`**

```swift
import Foundation

/// Takes a stopped (or crashed) Track Walk from its .mov to a queued report:
/// remux to .mp4 → Photos → transcribe → reportPending. Every step records its
/// result in the Outbox before the next one runs, so it can pick up where it
/// left off after a relaunch.
@MainActor
final class TrackWalkFinisher {
  static let shared = TrackWalkFinisher()

  /// The capture being recorded right now; never finalized from here.
  var liveCaptureId: UUID?
  private var working: Set<UUID> = []

  private init() {}

  /// At launch and on becoming active: finish anything left in progress.
  func resumeAll() {
    for capture in ScoutOutbox.shared.captures where capture.mode == .trackWalk
      && (capture.state == .recording || capture.state == .recorded) {
      Task { await advance(capture.id) }
    }
  }

  func advance(_ id: UUID) async {
    guard !working.contains(id), id != liveCaptureId else { return }
    working.insert(id)
    defer { working.remove(id) }

    if ScoutOutbox.shared.capture(id)?.state == .recording {
      await finalize(id)
    }
    if ScoutOutbox.shared.capture(id)?.state == .recorded {
      await transcribe(id)
    }
    ScoutOutbox.shared.resume()
  }

  /// .mov → .mp4 (a crash-recovered .mov is still readable up to its last fragment),
  /// then Photos. A missing recording still moves on, as a walk without video.
  private func finalize(_ id: UUID) async {
    let mov = TrackWalkMedia.url(for: id, ext: "mov")
    let mp4 = TrackWalkMedia.url(for: id, ext: "mp4")
    var videoName: String?
    if FileManager.default.fileExists(atPath: mp4.path) {
      videoName = mp4.lastPathComponent
    } else if FileManager.default.fileExists(atPath: mov.path) {
      do {
        try await TrackWalkMedia.remux(mov, to: mp4)
        videoName = mp4.lastPathComponent
      } catch {
        NSLog("[TrackWalk] Remux failed for %@: %@", id.uuidString, error.localizedDescription)
        ScoutOutbox.shared.update(id) { $0.lastError = "Video could not be finalized" }
        return  // Try again next launch; the .mov is kept.
      }
    }
    var saved = ScoutOutbox.shared.capture(id)?.savedToPhotos ?? false
    if let videoName, !saved, SettingsManager.shared.trackWalkSaveToPhotos {
      saved = await TrackWalkMedia.saveToPhotos(TrackWalkMedia.folder.appendingPathComponent(videoName))
    }
    ScoutOutbox.shared.update(id) { OutboxRules.markRecorded(&$0, videoFileName: videoName, savedToPhotos: saved) }
    if videoName != nil { try? FileManager.default.removeItem(at: mov) }
  }

  /// On-device transcription. A walk with no audio (or no video) becomes a silent walk.
  private func transcribe(_ id: UUID) async {
    guard let capture = ScoutOutbox.shared.capture(id) else { return }
    var lines: [String] = []
    if let name = capture.videoFileName {
      let video = TrackWalkMedia.folder.appendingPathComponent(name)
      let m4a = TrackWalkMedia.url(for: id, ext: "m4a")
      do {
        try await TrackWalkMedia.extractAudio(from: video, to: m4a)
        _ = await TrackWalkMedia.ensureSpeechModel()
        lines = try await TrackWalkMedia.transcribe(m4a)
      } catch {
        NSLog("[TrackWalk] Transcription failed for %@: %@", id.uuidString, error.localizedDescription)
        ScoutOutbox.shared.update(id) { $0.lastError = "Transcription failed; will retry" }
        try? FileManager.default.removeItem(at: m4a)
        return  // Stays .recorded; retried next launch or activation.
      }
      try? FileManager.default.removeItem(at: m4a)
    }
    ScoutOutbox.shared.update(id) {
      OutboxRules.markTranscribed(&$0, lines: lines)
      $0.lastError = nil
    }
  }
}
```

- [ ] **Step 2: Resume at launch and when active**

In `CameraAccessApp.swift`, inside the existing `.task { ScoutOutbox.shared.start() }`, add `TrackWalkFinisher.shared.resumeAll()` after `start()`. In the existing `.onChange(of: scenePhase)` `.active` branch, add `TrackWalkFinisher.shared.resumeAll()` after `ScoutOutbox.shared.resume()`.

- [ ] **Step 3: Self-check by reading.**
  - A capture in `recording` whose `id == liveCaptureId` is skipped.
  - A failed remux or transcription leaves the state unchanged, so it is retried later without looping on its own.
  - Every state change goes through `ScoutOutbox.update`, which saves.

- [ ] **Step 4: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/TrackWalk/TrackWalkFinisher.swift samples/CameraAccess/CameraAccess/CameraAccessApp.swift
git commit -m "feat(trackwalk): after-stop pipeline with crash recovery"
```

---

### Task 5: `TrackWalkController` and the glasses hooks

**Files:**
- Create: `samples/CameraAccess/CameraAccess/TrackWalk/TrackWalkController.swift`
- Modify: `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift`

**Interfaces (produces):** `@MainActor final class TrackWalkController: ObservableObject` with:
- `enum Phase { idle, preparing, recording, paused, finishing }`
- `@Published private(set) var phase`, `elapsed: TimeInterval`, `sessionTrack: String`, `errorMessage: String?`
- `var isActive: Bool` (any phase except idle)
- `var isPausedByFold: Bool`
- `func begin(session: ScoutSessionSummary, subscribeFrames: (@escaping (VideoFrameSample) -> Void) -> UUID, unsubscribeFrames: @escaping (UUID) -> Void, glassesSource: Bool) async`
- `func pauseByUser()`, `func resumeByUser()`
- `func glassesFolded()`, `func glassesUnfolded()`, `func glassesStreamStopped()`
- `func finish(reason: FinishReason) async`, with `enum FinishReason { user, timeLimit, storageFull, pausedTooLong, glassesStopped, leftScreen }`

- [ ] **Step 1: Create `TrackWalkController.swift`**

```swift
import AVFoundation
import QuartzCore
import SwiftUI

/// Runs one Track Walk: preflight, audio session, recorder, cues, pause/resume,
/// limits and glasses events. After Stop, the finisher takes over.
@MainActor
final class TrackWalkController: ObservableObject {
  enum Phase: Equatable {
    case idle
    case preparing
    case recording
    case paused
    case finishing
  }

  enum FinishReason {
    case user
    case timeLimit
    case storageFull
    case pausedTooLong
    case glassesStopped
    case leftScreen
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var sessionTrack = ""
  @Published var errorMessage: String?

  var isActive: Bool { phase != .idle }
  private(set) var isPausedByFold = false

  private var recorder: TrackWalkRecorder?
  private var captureId: UUID?
  private var frameSubscription: UUID?
  private var unsubscribeFrames: ((UUID) -> Void)?
  private var ticker: Task<Void, Never>?
  private var stopGrace: Task<Void, Never>?
  private var warned = false
  private var pausedSince: TimeInterval?

  // MARK: - Start

  func begin(
    session: ScoutSessionSummary,
    subscribeFrames: (@escaping (VideoFrameSample) -> Void) -> UUID,
    unsubscribeFrames: @escaping (UUID) -> Void,
    glassesSource: Bool
  ) async {
    guard phase == .idle else { return }
    phase = .preparing
    errorMessage = nil
    sessionTrack = session.track

    if let free = TrackWalkMedia.freeBytes(), free < TrackWalkLimits.minFreeBytesToStart {
      fail("A Track Walk needs 3 GB free. Free up space and try again.")
      return
    }
    // Download the speech model now, while online; recording goes ahead either way.
    _ = await TrackWalkMedia.ensureSpeechModel()

    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetooth, .defaultToSpeaker])
      try audio.setActive(true)
      if glassesSource { GlassesAudioRoute.selectGlassesMicIfNeeded() }
    } catch {
      fail("Audio could not start: \(error.localizedDescription)")
      return
    }

    let id = UUID()
    let capture = Capture(
      id: id, mode: .trackWalk, sessionId: session.id, trackName: session.track,
      transcript: [], scoutContext: "Track Walk", vehicleModel: "", durationMin: 0,
      state: .recording, videoFileName: TrackWalkMedia.url(for: id, ext: "mov").lastPathComponent)
    // On disk before recording starts, so a crash from here on is recoverable.
    ScoutOutbox.shared.add(capture)
    TrackWalkFinisher.shared.liveCaptureId = id

    let recorder = TrackWalkRecorder(outputURL: TrackWalkMedia.url(for: id, ext: "mov"))
    do {
      try recorder.start()
    } catch {
      TrackWalkFinisher.shared.liveCaptureId = nil
      fail("The microphone could not start.")
      return
    }
    self.recorder = recorder
    self.captureId = id
    self.unsubscribeFrames = unsubscribeFrames
    frameSubscription = subscribeFrames { [weak recorder] frame in
      recorder?.appendVideo(frame.pixelBuffer, hostTime: CACurrentMediaTime())
    }
    warned = false
    isPausedByFold = false
    pausedSince = nil
    elapsed = 0
    phase = .recording
    SpokenCues.shared.speak("Recording started")
    startTicker()
  }

  // MARK: - Controls

  func pauseByUser() { pause(byFold: false) }

  func resumeByUser() { resume() }

  func glassesFolded() {
    stopGrace?.cancel()
    stopGrace = nil
    guard phase == .recording else { return }
    pause(byFold: true)
  }

  func glassesUnfolded() {
    guard phase == .paused, isPausedByFold else { return }
    resume()
  }

  /// The glasses stream stopped. A fold reports hingesClosed around the same
  /// moment; if none arrives within 1 s, it was a tap-and-hold or a drop, and
  /// the walk finishes (spec §B4: a drop can't be told from a tap-and-hold).
  func glassesStreamStopped() {
    guard phase == .recording, stopGrace == nil else { return }
    stopGrace = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled else { return }
      self.stopGrace = nil
      guard self.phase == .recording else { return }
      await self.finish(reason: .glassesStopped)
    }
  }

  private func pause(byFold: Bool) {
    guard phase == .recording, let recorder else { return }
    recorder.pause(at: CACurrentMediaTime())
    isPausedByFold = byFold
    pausedSince = CACurrentMediaTime()
    phase = .paused
    SpokenCues.shared.speak("Paused")
  }

  private func resume() {
    guard phase == .paused, let recorder else { return }
    recorder.resume(at: CACurrentMediaTime())
    isPausedByFold = false
    pausedSince = nil
    phase = .recording
    SpokenCues.shared.speak("Recording")
  }

  // MARK: - Stop

  func finish(reason: FinishReason) async {
    guard phase == .recording || phase == .paused, let recorder, let id = captureId else { return }
    phase = .finishing
    ticker?.cancel()
    ticker = nil
    stopGrace?.cancel()
    stopGrace = nil
    if let frameSubscription { unsubscribeFrames?(frameSubscription) }
    frameSubscription = nil

    let recorded = recorder.elapsed(at: CACurrentMediaTime())
    let wrote = await recorder.finish()
    ScoutOutbox.shared.update(id) { $0.durationMin = max(1, Int((recorded / 60).rounded())) }
    SpokenCues.shared.speak(reason == .storageFull ? "Storage full, saved" : "Stopped")
    NSLog("[TrackWalk] Finished (%@), %.0f s, file written: %@", String(describing: reason), recorded, wrote ? "yes" : "no")

    self.recorder = nil
    captureId = nil
    isPausedByFold = false
    TrackWalkFinisher.shared.liveCaptureId = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    phase = .idle
    await TrackWalkFinisher.shared.advance(id)
  }

  // MARK: - Limits

  private func startTicker() {
    ticker?.cancel()
    ticker = Task { @MainActor [weak self] in
      var tick = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled, let recorder = self.recorder else { return }
        tick += 1
        let now = CACurrentMediaTime()
        self.elapsed = recorder.elapsed(at: now)
        switch TrackWalkLimits.cue(elapsed: self.elapsed, warned: self.warned) {
        case .none: break
        case .twoMinutesLeft:
          self.warned = true
          SpokenCues.shared.speak("Two minutes left")
        case .stop:
          await self.finish(reason: .timeLimit)
          return
        }
        if let since = self.pausedSince, now - since >= TrackWalkLimits.pausedFinishAfter {
          await self.finish(reason: .pausedTooLong)
          return
        }
        if tick % 30 == 0, let free = TrackWalkMedia.freeBytes(),
           free < TrackWalkLimits.minFreeBytesWhileRecording {
          await self.finish(reason: .storageFull)
          return
        }
      }
    }
  }

  private func fail(_ message: String) {
    errorMessage = message
    phase = .idle
  }
}
```

- [ ] **Step 2: Hooks in `StreamSessionViewModel`**
- Add `let trackWalk = TrackWalkController()` as a property next to `frameHub`. It is `internal`, so `StreamView` can observe it.
- Add these frame-subscription passthroughs:

```swift
  func subscribeFrames(_ subscriber: @escaping (VideoFrameSample) -> Void) -> UUID {
    frameHub.subscribe(subscriber)
  }

  func unsubscribeFrames(_ id: UUID) {
    frameHub.unsubscribe(id)
  }
```

- `keepGlassesAlive`: return `true` also when `trackWalk.isActive`. For example, start the getter with `if trackWalk.isActive { return true }` and keep the Gemini lines. Update its doc comment: "…or while a Track Walk runs (a fold's stream stop must reconnect so unfolding resumes; a bare stop finishes the walk and the link then winds down)".
- In the errorPublisher `if case .hingesClosed = error { … }` block, add `self.trackWalk.glassesFolded()` after `self.startFoldToEndIfRacing()`.
- In `noteDeliveredFrame(_:)`'s first statement block (the `if glassesReportedFolded, foldEndTask != nil { … }` cancel), add a separate check **before** it:

```swift
    if glassesReportedFolded {
      trackWalk.glassesUnfolded()
    }
```

- In `handleGlassesDrop(reason:)`, before `apply(link.handle(…))`, add:

```swift
    if trackWalk.isActive && !glassesReportedFolded {
      trackWalk.glassesStreamStopped()
    }
```

- In `markStopped()`, add `if trackWalk.isActive { Task { await trackWalk.finish(reason: .leftScreen) } }`. Also in `stopIPhoneSession()`, add the same line (Stop streaming in phone mode).

- [ ] **Step 3: Self-check by reading.** Trace each of these through the code:
  - **Glasses fold:** `hingesClosed` → pause, and the stream stop → reconnect (walk active) → unfold → frames → resume.
  - **Glasses tap-and-hold:** stream stop, no `hingesClosed` → grace 1 s → finish → `trackWalk` idle → the next retry has `reconnectAllowed` false → `markStopped`.
  - **Phone Stop streaming:** `stopIPhoneSession` → finish.
  - **Folded 2 minutes:** the ticker → finish.

- [ ] **Step 4: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/TrackWalk/TrackWalkController.swift samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift
git commit -m "feat(trackwalk): controller with cues, limits, pause and glasses controls"
```

---

### Task 6: Track Walk UI

**Files:**
- Create: `samples/CameraAccess/CameraAccess/TrackWalk/TrackWalkViews.swift`
- Modify: `samples/CameraAccess/CameraAccess/Views/StreamView.swift`

**Interfaces (consumes):**
- `TrackWalkController` (Task 5), through `viewModel.trackWalk`
- `SpectreScoutBridge.fetchSessions()` and `ScoutSessionSummary` (Task 2)
- `SettingsManager.shared.scoutTestMode`

- [ ] **Step 1: Create `TrackWalkViews.swift`**

```swift
import SwiftUI

/// Pick the session a walk belongs to, then Record.
struct TrackWalkPickerSheet: View {
  let onRecord: (ScoutSessionSummary) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var sessions: [ScoutSessionSummary] = []
  @State private var selection: String?
  @State private var loading = true
  @State private var loadError: String?

  var body: some View {
    NavigationStack {
      List {
        if loading {
          ProgressView("Loading sessions…")
        } else if let loadError {
          Text(loadError).foregroundStyle(.secondary)
        } else if sessions.isEmpty {
          Text("No planned or active sessions. Create one in SPECTRE first.")
            .foregroundStyle(.secondary)
        }
        ForEach(sessions) { session in
          Button {
            selection = session.id
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(session.track).font(.headline)
                Text(session.status == "active" ? "Active now" : (session.scheduledDate ?? "Planned"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if selection == session.id {
                Image(systemName: "checkmark").foregroundStyle(.tint)
              }
            }
          }
          .accessibilityAddTraits(selection == session.id ? .isSelected : [])
        }
      }
      .navigationTitle("Track Walk")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Record") {
            guard let chosen = sessions.first(where: { $0.id == selection }) else { return }
            dismiss()
            onRecord(chosen)
          }
          .disabled(selection == nil)
        }
      }
      .task { await load() }
    }
  }

  private func load() async {
    loading = true
    defer { loading = false }
    if SettingsManager.shared.scoutTestMode {
      sessions = [ScoutSessionSummary(id: "test-mode", track: "Test Track", status: "active", scheduledDate: nil)]
    } else {
      do {
        sessions = try await SpectreScoutBridge().fetchSessions()
      } catch {
        loadError = "Couldn't load sessions: \(error.localizedDescription)"
      }
    }
    // SPECTRE sorts active first, then nearest planned date.
    selection = sessions.first?.id
  }
}

/// Recording status and controls, shown over the stream while a walk runs.
struct TrackWalkBar: View {
  @ObservedObject var walk: TrackWalkController

  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(walk.phase == .recording ? Color.red : Color.orange)
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(walk.sessionTrack).font(.footnote.weight(.semibold))
        Text("\(Self.clock(walk.elapsed)) · \(Self.label(walk.phase))")
          .font(.caption.monospacedDigit())
      }
      .foregroundStyle(.white)
      Spacer()
      if walk.phase == .recording {
        Button("Pause") { walk.pauseByUser() }
          .buttonStyle(.bordered)
          .tint(.white)
      } else if walk.phase == .paused {
        Button("Resume") { walk.resumeByUser() }
          .buttonStyle(.bordered)
          .tint(.white)
      }
      Button("Stop") { Task { await walk.finish(reason: .user) } }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(walk.phase == .finishing || walk.phase == .preparing)
    }
    .padding(12)
    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .contain)
  }

  private static func clock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  private static func label(_ phase: TrackWalkController.Phase) -> String {
    switch phase {
    case .idle: return "Idle"
    case .preparing: return "Getting ready"
    case .recording: return "Recording"
    case .paused: return "Paused"
    case .finishing: return "Saving"
    }
  }
}
```

- [ ] **Step 2: `StreamView` wiring**
- **Observe the controller.** In `StreamView`, add `@ObservedObject private var walk: TrackWalkController`, initialised in `StreamView`'s memberwise path. Because `StreamView` is created with `viewModel:`, add an explicit `init(viewModel:wearablesVM:geminiVM:webrtcVM:)` that sets `self._walk = ObservedObject(wrappedValue: viewModel.trackWalk)`. Keep the call site in `StreamSessionView` unchanged. If an explicit init conflicts with how the file is structured, instead pass `viewModel.trackWalk` into a small `TrackWalkBar` only and read `phase` there; say which you chose in the report.
- **Recording bar.** In the top-level `ZStack`, after the Gemini overlay block, add:

```swift
      if walk.isActive {
        VStack {
          TrackWalkBar(walk: walk)
            .padding(.horizontal, 16)
            .padding(.top, 12)
          Spacer()
        }
      }
```

- **Error alert.** Add `.alert("Track Walk", isPresented: Binding(get: { walk.errorMessage != nil }, set: { if !$0 { walk.errorMessage = nil } })) { Button("OK") { walk.errorMessage = nil } } message: { Text(walk.errorMessage ?? "") }` next to the other alerts.
- **Leaving the screen.** In `.onDisappear`'s `Task`, first add `if viewModel.trackWalk.isActive { await viewModel.trackWalk.finish(reason: .leftScreen) }`.
- **The Walk button.** In `ControlsView`:
  - Add `@State private var showWalkPicker = false`.
  - After the Race button, add:

```swift
      CircleButton(icon: "figure.walk", text: "Walk") {
        showWalkPicker = true
      }
      .opacity(geminiVM.isGeminiActive || webrtcVM.isActive || viewModel.trackWalk.isActive ? 0.4 : 1.0)
      .disabled(geminiVM.isGeminiActive || webrtcVM.isActive || viewModel.trackWalk.isActive)
      .accessibilityHint("Records a Track Walk video with your narration")
      .sheet(isPresented: $showWalkPicker) {
        TrackWalkPickerSheet { session in
          Task {
            await viewModel.trackWalk.begin(
              session: session,
              subscribeFrames: { viewModel.subscribeFrames($0) },
              unsubscribeFrames: { viewModel.unsubscribeFrames($0) },
              glassesSource: viewModel.streamingMode == .glasses)
          }
        }
      }
```

- **Mutual exclusion.** Add `|| viewModel.trackWalk.isActive` to the Race button's `.disabled(…)` and to the Live button's `.disabled(…)` and `.opacity(…)` conditions.

- [ ] **Step 3: Self-check by reading.**
  - Race, Walk and Live are mutually exclusive.
  - The Walk sheet's Record calls `begin` with the current source.
  - The bar's Stop and Pause buttons work in both modes.
  - Test mode offers "Test Track". In test mode a walk records and queues a report, which is held while reports are off.

- [ ] **Step 4: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/TrackWalk/TrackWalkViews.swift samples/CameraAccess/CameraAccess/Views/StreamView.swift
git commit -m "feat(trackwalk): Walk button, session picker and recording bar"
```

The controller pushes after the final review.

---

## Device checklist (end-of-project device pass; owner)

1. **Phone walk:** Walk → pick a session → Record. You hear "Recording started", then Pause/Resume ("Paused"/"Recording"), then Stop ("Stopped"). The video appears in Photos, plays on a PC as `.mp4`, and has no gap where the pause was.
2. **Glasses walk:**
   - Fold the glasses: "Paused". Unfold: "Recording".
   - Tap-and-hold: the walk stops.
   - Folded for 2 minutes: the walk finishes.
3. **Transcript:** Settings → Scout reports shows the walk as "Held". Turn on "Send Track Walk reports" once SPECTRE is ready and it sends, with the narration visible in SPECTRE.
4. **Silent walk:** record 30 s saying nothing. The report is held with the "Silent walk" line.
5. **Crash recovery:** force-quit the app mid-walk. On relaunch the walk appears, with its video up to about 2 s before the quit.
6. **Limits:** a walk left running says "Two minutes left" at 12:55 and stops at 14:55.

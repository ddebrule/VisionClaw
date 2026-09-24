# Stage 1: Safe Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Stage 1 of the catch-up. It includes:
- a tested logic package
- Gemini 3.8 Live with automatic reconnect across Google's roughly 10-minute connection limit
- no self-hearing
- faster replies
- no preview freezes
- the entitlements and Info.plist keys the glasses SDK needs
- iOS 26 minimum

It goes out as one TestFlight build that the owner verifies.

**Architecture:**
- **Pure, testable logic** (the reconnect backoff policy and the resumption-handle tracking) lives in a local Swift package, `ScoutCore`, at `samples/CameraAccess/ScoutCore/`.
  - The app compiles those same source files directly through an Xcode synchronized folder, so the app does **not** `import ScoutCore`.
  - CI runs `swift test` on the package before archiving.
- **Everything else** is a targeted edit to the existing Gemini, stream and settings files.

**Tech Stack:** Swift / SwiftUI, AVFoundation, URLSessionWebSocketTask, the Gemini Live BidiGenerateContent v1beta WebSocket, XCTest via SwiftPM, and GitHub Actions `macos-26`.

**Spec:** `docs/superpowers/specs/2026-09-23-upstream-catchup-and-scout-modes-design.md` (§A1). Roadmap: `docs/superpowers/plans/2026-09-23-roadmap-catchup-and-scout-modes.md`.

## Global Constraints

- **Before editing any `.swift` file,** read `.claude/skills/swiftui-pro/SKILL.md` (or `.agents/skills/swiftui-pro/SKILL.md`) and follow it. This is a project `CLAUDE.md` rule.
- **iOS only.** Do not touch `samples/CameraAccessAndroid/`.
- **Code style:** 2-space indentation, and match the surrounding comment density.
- **No local builds are possible** (the owner develops on Windows). **The CI run is the build check.** Every push to `main` also uploads a TestFlight build; that's expected.
- **`ScoutCore` sources:** Foundation only (no UIKit, AVFoundation, MWDAT or WebRTC). They must compile both inside the app module and as the SwiftPM package.
- **Model string:** exactly `models/gemini-3.8-live`.
- **Deployment target:** exactly `26.0` for every `IPHONEOS_DEPLOYMENT_TARGET` in `project.pbxproj`.
- **Commits:** end every commit message with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- **No Android ports, no LiveKit code, no OpenClaw code.**

## Review Focus

These are the inputs a person will hit that no unit test covers. Each has a check in the task that owns it.

1. **Google's roughly 10-minute connection limit mid-conversation.** The session keeps going and the transcript keeps growing. *Task 4, device check.*
2. **The network is gone longer than the retry budget** (a phone deep in a pocket at the stand). The app gives up cleanly, End still sends everything captured, and the error says so. *Task 4, device check.*
3. **A resumption handle the server refuses** (stale or invalid). After 2 failed resumes the app starts a fresh Gemini session with the same instruction instead of failing all 5 retries. *Task 1 unit test, Task 4 wiring.*
4. **Pressing Scout while an unsent report exists.** The app refuses with a message instead of silently wiping the transcript. *Task 4, device check.*
5. **A reply interrupted mid-playback in iPhone mode.** The mic reopens afterwards; it doesn't stay muted forever. *Task 5, device check.*

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `samples/CameraAccess/ScoutCore/Package.swift` | Create | SwiftPM manifest for the pure-logic package |
| `samples/CameraAccess/ScoutCore/Sources/ScoutCore/ReconnectPolicy.swift` | Create | Backoff delays and the "drop the handle" threshold |
| `samples/CameraAccess/ScoutCore/Sources/ScoutCore/LiveResumptionState.swift` | Create | Tracks the latest resumable handle and builds the setup field |
| `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/ReconnectPolicyTests.swift` | Create | Unit tests |
| `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/LiveResumptionStateTests.swift` | Create | Unit tests |
| `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj` | Modify | Synchronized ScoutCore folder, the SpectreScoutBridge file entry, deployment target |
| `.github/workflows/build.yml` | Modify | `swift test` step before archive |
| `samples/CameraAccess/CameraAccess/Gemini/SpectreScoutBridge.swift` | Create (moved code) | SPECTRE HTTP client and its data types |
| `samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift` | Modify | Remove the moved code; reconnect loop; unsent-report handling; mute gate |
| `samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift` | Modify | Model string |
| `samples/CameraAccess/CameraAccess/Gemini/GeminiLiveService.swift` | Modify | Turn timing, session resumption, `goAway` callback, connect-timeout generation |
| `samples/CameraAccess/CameraAccess/Gemini/AudioManager.swift` | Modify | `isSpeakerActive` from scheduled-buffer completion |
| `samples/CameraAccess/CameraAccess/Views/StreamView.swift` | Modify | End visible while a report is unsent; Discard option |
| `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift` | Modify | Foreground frame throttle |
| `samples/CameraAccess/CameraAccess/CameraAccess.entitlements` | Modify | Keychain group and Wi-Fi entitlements |
| `samples/CameraAccess/CameraAccess/Info.plist` | Modify | `bluetooth-central`, local network, Bonjour |

---

### Task 1: ScoutCore package, reconnect logic, and the CI test step

**Files:**
- Create: `samples/CameraAccess/ScoutCore/Package.swift`
- Create: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/ReconnectPolicy.swift`
- Create: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/LiveResumptionState.swift`
- Create: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/ReconnectPolicyTests.swift`
- Create: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/LiveResumptionStateTests.swift`
- Modify: `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj` (the `PBXFileSystemSynchronizedRootGroup` section at about line 127, the main group at about line 147, and the app target's `fileSystemSynchronizedGroups` at about line 304)
- Modify: `.github/workflows/build.yml` (after the "Select Xcode" step, line 19)

**Interfaces:**
- Produces:
  - `enum ReconnectPolicy` with
    - `static let delays: [TimeInterval]`
    - `static let dropHandleAfterFailures: Int`
    - `static func delay(afterConsecutiveFailures: Int) -> TimeInterval?`
  - `struct LiveResumptionState` with
    - `private(set) var handle: String?`
    - `mutating func apply(update: [String: Any])`
    - `var setupField: [String: Any]`
    - `mutating func reset()`
  - Both are visible to app code without an import. Tasks 4 and 3 use them.

- [ ] **Step 1: Create the package manifest**

`samples/CameraAccess/ScoutCore/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

// Pure, Foundation-only logic shared by the app and its unit tests.
// The app compiles Sources/ScoutCore directly (Xcode synchronized folder) and
// never imports this package; `swift test` builds it standalone in CI.
let package = Package(
  name: "ScoutCore",
  platforms: [.macOS(.v14), .iOS("26.0")],
  products: [.library(name: "ScoutCore", targets: ["ScoutCore"])],
  targets: [
    .target(name: "ScoutCore"),
    .testTarget(name: "ScoutCoreTests", dependencies: ["ScoutCore"]),
  ]
)
```

- [ ] **Step 2: Write the failing tests**

`samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/ReconnectPolicyTests.swift`:

```swift
import XCTest
@testable import ScoutCore

final class ReconnectPolicyTests: XCTestCase {
  func testFirstAttemptIsImmediate() {
    XCTAssertEqual(ReconnectPolicy.delay(afterConsecutiveFailures: 0), 0)
  }

  func testBackoffDoublesAfterEachFailure() {
    XCTAssertEqual(ReconnectPolicy.delay(afterConsecutiveFailures: 1), 1)
    XCTAssertEqual(ReconnectPolicy.delay(afterConsecutiveFailures: 2), 2)
    XCTAssertEqual(ReconnectPolicy.delay(afterConsecutiveFailures: 3), 4)
    XCTAssertEqual(ReconnectPolicy.delay(afterConsecutiveFailures: 4), 8)
  }

  func testGivesUpAfterFiveFailures() {
    XCTAssertNil(ReconnectPolicy.delay(afterConsecutiveFailures: 5))
    XCTAssertNil(ReconnectPolicy.delay(afterConsecutiveFailures: 50))
  }

  func testNegativeFailureCountGivesUp() {
    XCTAssertNil(ReconnectPolicy.delay(afterConsecutiveFailures: -1))
  }

  func testHandleIsDroppedAfterTwoFailedResumes() {
    XCTAssertEqual(ReconnectPolicy.dropHandleAfterFailures, 2)
  }
}
```

`samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/LiveResumptionStateTests.swift`:

```swift
import XCTest
@testable import ScoutCore

final class LiveResumptionStateTests: XCTestCase {
  func testStartsWithoutHandleAndEmptySetupField() {
    let state = LiveResumptionState()
    XCTAssertNil(state.handle)
    XCTAssertTrue(state.setupField.isEmpty)
  }

  func testResumableUpdateStoresHandle() {
    var state = LiveResumptionState()
    state.apply(update: ["newHandle": "h-1", "resumable": true])
    XCTAssertEqual(state.handle, "h-1")
    XCTAssertEqual(state.setupField as? [String: String], ["handle": "h-1"])
  }

  func testNonResumableUpdateKeepsPreviousHandle() {
    var state = LiveResumptionState()
    state.apply(update: ["newHandle": "h-1", "resumable": true])
    state.apply(update: ["newHandle": "h-2", "resumable": false])
    XCTAssertEqual(state.handle, "h-1")
  }

  func testEmptyOrMissingHandleIsIgnored() {
    var state = LiveResumptionState()
    state.apply(update: ["newHandle": "", "resumable": true])
    state.apply(update: ["resumable": true])
    XCTAssertNil(state.handle)
  }

  func testResetClearsHandle() {
    var state = LiveResumptionState()
    state.apply(update: ["newHandle": "h-1", "resumable": true])
    state.reset()
    XCTAssertNil(state.handle)
    XCTAssertTrue(state.setupField.isEmpty)
  }
}
```

- [ ] **Step 3: Confirm the tests are red**

There is no Swift toolchain on the owner's Windows machine, and pushing a deliberately broken commit to `main` would ship a failed TestFlight run. So the red state is checked by reading, not by running: the tests reference `ReconnectPolicy` and `LiveResumptionState`, and neither exists yet. If a Mac is available, run `swift test --package-path samples/CameraAccess/ScoutCore` now and expect `error: cannot find 'ReconnectPolicy' in scope`. The green run happens in CI at Step 7.

- [ ] **Step 4: Write the implementation**

`samples/CameraAccess/ScoutCore/Sources/ScoutCore/ReconnectPolicy.swift`:

```swift
import Foundation

/// When to retry a dropped Gemini Live connection.
///
/// Google closes every Live connection after ~10 minutes (a `goAway` message),
/// and trackside signal drops often, so a Race session reconnects instead of
/// ending. Five attempts span ~15 s before giving up.
enum ReconnectPolicy {
  static let delays: [TimeInterval] = [0, 1, 2, 4, 8]

  /// A resumption handle the server keeps refusing is stale; after this many
  /// consecutive failures reconnect without it (a fresh Gemini session with the
  /// same instruction — the app's own transcript is unaffected).
  static let dropHandleAfterFailures = 2

  /// Delay before the next attempt, or nil to give up.
  static func delay(afterConsecutiveFailures failures: Int) -> TimeInterval? {
    guard failures >= 0, failures < delays.count else { return nil }
    return delays[failures]
  }
}
```

`samples/CameraAccess/ScoutCore/Sources/ScoutCore/LiveResumptionState.swift`:

```swift
import Foundation

/// The latest Gemini Live session-resumption handle.
///
/// The server sends `sessionResumptionUpdate { newHandle, resumable }` during a
/// session; passing the last resumable handle in the next connection's
/// `setup.sessionResumption.handle` continues the same conversation. Handles
/// stay valid for 2 hours after the connection ends.
struct LiveResumptionState: Equatable {
  private(set) var handle: String?

  mutating func apply(update: [String: Any]) {
    guard update["resumable"] as? Bool == true,
          let newHandle = update["newHandle"] as? String, !newHandle.isEmpty
    else { return }
    handle = newHandle
  }

  /// Value for `setup.sessionResumption`. Empty on a first connection, which
  /// still opts the session into receiving resumption updates.
  var setupField: [String: Any] {
    guard let handle else { return [:] }
    return ["handle": handle]
  }

  mutating func reset() {
    handle = nil
  }
}
```

- [ ] **Step 5: Add the CI test step**

In `.github/workflows/build.yml`, insert directly after the "Select Xcode" step (after line 19):

```yaml
      - name: Test ScoutCore
        run: swift test --package-path samples/CameraAccess/ScoutCore
```

- [ ] **Step 6: Compile the ScoutCore sources into the app**

In `project.pbxproj`, make three edits.

(a) In the `PBXFileSystemSynchronizedRootGroup` section, add this line after the `CameraAccessTests` line (about line 129):

```
		5C0E00012F9A000000000001 /* ScoutCore */ = {isa = PBXFileSystemSynchronizedRootGroup; explicitFileTypes = {}; explicitFolders = (); name = ScoutCore; path = ScoutCore/Sources/ScoutCore; sourceTree = "<group>"; };
```

(b) In the main group `5A5A5A5A5A5A5A5A5A5A5A5A`'s `children`, add after `E699CC962E8150670052C240 /* CameraAccessTests */,`:

```
				5C0E00012F9A000000000001 /* ScoutCore */,
```

(c) In the app target `8A8A8A8A8A8A8A8A8A8A8A8A /* CameraAccess */`, change `fileSystemSynchronizedGroups` to:

```
			fileSystemSynchronizedGroups = (
				9D3C69602F367CF700E641A5 /* iPhone */,
				5C0E00012F9A000000000001 /* ScoutCore */,
			);
```

Before saving, verify that the ID `5C0E00012F9A000000000001` doesn't already appear in the file (`grep -c 5C0E00012F9A000000000001` should print `0`).

- [ ] **Step 7: Commit, push, and verify in CI**

```bash
git add samples/CameraAccess/ScoutCore .github/workflows/build.yml samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj
git commit -m "feat(core): add ScoutCore package with reconnect policy and resumption state

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push origin main
gh run watch --exit-status $(gh run list --workflow build.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected:
- The "Test ScoutCore" step shows `Executed 10 tests, with 0 failures`.
- The Archive step succeeds, which proves the synchronized folder compiles in the app.

If the archive fails with `invalid redeclaration`, a ScoutCore type name collides with an app type: rename the ScoutCore type and rerun.

---

### Task 2: Move `SpectreScoutBridge` into its own file

A pure move with no behaviour change. It shrinks `GeminiSessionViewModel.swift` before Task 4 edits it.

**Files:**
- Create: `samples/CameraAccess/CameraAccess/Gemini/SpectreScoutBridge.swift`
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift:1-89`
- Modify: `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: the same `ScoutTranscriptEntry`, `ActiveSessionInfo` and `SpectreScoutBridge` types, unchanged, in the new file.

- [ ] **Step 1: Create the new file**

Create `samples/CameraAccess/CameraAccess/Gemini/SpectreScoutBridge.swift` containing **exactly** lines 1–87 of the current `GeminiSessionViewModel.swift`: from `import Foundation` through the closing `}` of `class SpectreScoutBridge`. Copy the text verbatim.

- [ ] **Step 2: Remove the moved code from the view model**

Delete lines 1–88 of `GeminiSessionViewModel.swift`, so the file now begins:

```swift
import Foundation
import SwiftUI
import AVFoundation

// MARK: - GeminiSessionViewModel
```

- [ ] **Step 3: Register the new file in the project**

Make four edits to `project.pbxproj`. First check that `A1B2C3D42F0A000100000006` and `A1B2C3D42F0A000200000006` don't exist (`grep -c` prints `0`).

(a) In the `PBXBuildFile` section, after the `GeminiOverlayView.swift in Sources` line:

```
		A1B2C3D42F0A000200000006 /* SpectreScoutBridge.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1B2C3D42F0A000100000006 /* SpectreScoutBridge.swift */; };
```

(b) In the `PBXFileReference` section, after the `GeminiOverlayView.swift` file reference:

```
		A1B2C3D42F0A000100000006 /* SpectreScoutBridge.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SpectreScoutBridge.swift; sourceTree = "<group>"; };
```

(c) In the `Gemini` group `A1B2C3D42F0A000300000001`'s `children`, after `GeminiSessionViewModel.swift`:

```
				A1B2C3D42F0A000100000006 /* SpectreScoutBridge.swift */,
```

(d) In the app's Sources phase `AAAAAAAAAAAAAAAAAAAAAA`'s `files`, after `A1B2C3D42F0A000200000005 /* GeminiOverlayView.swift in Sources */,`:

```
				A1B2C3D42F0A000200000006 /* SpectreScoutBridge.swift in Sources */,
```

- [ ] **Step 4: Commit, push, and verify in CI**

```bash
git add samples/CameraAccess/CameraAccess/Gemini/SpectreScoutBridge.swift samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj
git commit -m "refactor(ios): move SpectreScoutBridge into its own file

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push origin main
gh run watch --exit-status $(gh run list --workflow build.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected: the Archive step succeeds. `cannot find 'SpectreScoutBridge' in scope` means edit (d) is missing.

---

### Task 3: Gemini 3.8 Live, faster turn detection, and resumption in the protocol layer

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift:4-8`
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiLiveService.swift`

**Interfaces:**
- Consumes: `LiveResumptionState` (Task 1).
- Produces, on `GeminiLiveService`:
  - `var onGoAway: ((Int) -> Void)?`
  - `var resumptionHandle: String? { get }`
  - `func resetResumption()`
  - `goAway` **no longer** triggers `onDisconnected`.
  - Task 4 relies on all of these.

- [ ] **Step 1: Switch the model**

In `GeminiConfig.swift`, replace lines 4–8 with:

```swift
  // gemini-3.8-live (stable, 2026-09-15) on the v1beta BidiGenerateContent endpoint.
  // 3.1-flash-live-preview is legacy. Model and endpoint version must move together:
  // a mismatch makes the server accept the socket and then close it ("Failed to connect").
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  static let model = "models/gemini-3.8-live"
```

- [ ] **Step 2: Add the resumption state, the goAway callback, and the connect generation to `GeminiLiveService`**

After `var onOutputTranscription: ((String) -> Void)?` (line 23), add:

```swift
  /// Server announced it will close this connection in N seconds (~10 min limit).
  /// The session is still usable until then; the owner should reconnect.
  var onGoAway: ((Int) -> Void)?

  private var resumption = LiveResumptionState()
  var resumptionHandle: String? { resumption.handle }
  // Invalidates a stale connect-timeout task when a newer connect() starts.
  private var connectGeneration = 0
```

After the `disconnect()` function, add:

```swift
  /// Forget the resumption handle so the next connect() starts a fresh Gemini session.
  func resetResumption() {
    resumption.reset()
  }
```

- [ ] **Step 3: Stop a stale timeout from failing a newer connect**

In `connect(systemInstruction:)`, replace the timeout block (lines 81–89):

```swift
      Task {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await MainActor.run {
          self.resolveConnect(success: false)
          if self.connectionState == .connecting || self.connectionState == .settingUp {
            self.connectionState = .error("Connection timed out")
          }
        }
      }
```

with:

```swift
      self.connectGeneration += 1
      let generation = self.connectGeneration
      Task {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await MainActor.run {
          guard generation == self.connectGeneration else { return }
          self.resolveConnect(success: false)
          if self.connectionState == .connecting || self.connectionState == .settingUp {
            self.connectionState = .error("Connection timed out")
          }
        }
      }
```

- [ ] **Step 4: Set turn timing and opt into resumption in the setup message**

In `sendSetupMessage()`, replace:

```swift
            "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
            "silenceDurationMs": 500,
```

with:

```swift
            // HIGH + 400 ms: LOW + 500 ms was most of the perceived reply lag.
            // If Scout_IQ starts answering mid-sentence pauses, raise silenceDurationMs first.
            "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH",
            "silenceDurationMs": 400,
```

Then, directly after the `"contextWindowCompression": [...]` entry (after its closing `],` at line 165), add:

```swift
        "sessionResumption": resumption.setupField,
```

- [ ] **Step 5: Handle resumption updates and goAway**

In `handleMessage(_:)`, replace the whole `if let goAway = ... { ... }` block (lines 218–225) with:

```swift
    if let update = json["sessionResumptionUpdate"] as? [String: Any] {
      resumption.apply(update: update)
      return
    }

    if let goAway = json["goAway"] as? [String: Any] {
      let timeLeft = goAway["timeLeft"] as? [String: Any]
      let seconds = timeLeft?["seconds"] as? Int ?? 0
      NSLog("[Gemini] goAway: server closes this connection in %ds", seconds)
      onGoAway?(seconds)
      return
    }
```

- [ ] **Step 6: Commit, push, and verify in CI**

```bash
git add samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift samples/CameraAccess/CameraAccess/Gemini/GeminiLiveService.swift
git commit -m "feat(gemini): gemini-3.8-live, faster endpointing, session resumption protocol

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push origin main
gh run watch --exit-status $(gh run list --workflow build.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected: tests and Archive are green.

Note that between Task 3 and Task 4, a `goAway` no longer ends the session, but nothing reconnects yet. **Don't hand out the TestFlight builds from Tasks 3 and 4 separately.** The owner tests only the build from Task 8.

---

### Task 4: Reconnect loop, a transcript that survives, and the unsent-report guard

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift`
- Modify: `samples/CameraAccess/CameraAccess/Views/StreamView.swift:156-176`

**Interfaces:**
- Consumes:
  - `ReconnectPolicy` (Task 1)
  - `GeminiLiveService.onGoAway`, `resumptionHandle`, `resetResumption()` (Task 3)
- Produces, on `GeminiSessionViewModel`:
  - `@Published var isReconnecting: Bool`
  - `var hasUnsentReport: Bool`
  - `func discardReport()`
  - `StreamView` uses these.

- [ ] **Step 1: Add the new state**

In `GeminiSessionViewModel`, change `private var scoutHistory: [ScoutTranscriptEntry] = []` to:

```swift
  @Published private var scoutHistory: [ScoutTranscriptEntry] = []
```

After `@Published var isFetchingSession: Bool = false`, add:

```swift
  @Published var isReconnecting: Bool = false

  /// A transcript exists that has not reached Setup_IQ. End stays available for it
  /// even after the live connection is gone.
  var hasUnsentReport: Bool { !scoutHistory.isEmpty && !scoutReportSent }
```

After `private var sessionVehicles: [String] = []`, add:

```swift
  private var dynamicInstruction: String = ""
  private var reconnectTask: Task<Void, Never>?
```

- [ ] **Step 2: Refuse to wipe an unsent report, and keep the instruction for reconnects**

At the top of `startSession()`, after `guard !isGeminiActive else { return }`, add:

```swift
    guard !hasUnsentReport else {
      errorMessage = "Send or discard the last Scout report first (tap End)."
      return
    }
```

Change `let dynamicInstruction = GeminiConfig.defaultSystemInstruction + """` to `dynamicInstruction = GeminiConfig.defaultSystemInstruction + """`, which assigns the stored property instead of a local.

Directly after `scoutReportSent = false` in `startSession()`, add:

```swift
    geminiService.resetResumption()
```

- [ ] **Step 3: Reconnect instead of ending**

Replace the `geminiService.onDisconnected = { ... }` block with:

```swift
    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        self.reconnect(reason: reason ?? "Unknown error")
      }
    }

    geminiService.onGoAway = { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        self.reconnect(reason: "server connection limit")
      }
    }
```

- [ ] **Step 4: Flush partial speech into the transcript when stopping, and cancel any reconnect**

Replace `stopSession()` with:

```swift
  func stopSession() {
    reconnectTask?.cancel()
    reconnectTask = nil
    isReconnecting = false
    flushPendingTurn()
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
  }

  /// Throw away an unsent transcript (the racer chose Discard).
  func discardReport() {
    scoutHistory = []
    scoutReportSent = false
  }
```

- [ ] **Step 5: Add the reconnect loop and the flush helper**

In the `// MARK: - Private` section, add:

```swift
  /// Keep a Race going across Google's ~10-minute connection limit and signal drops.
  /// Audio capture keeps running; GeminiLiveService drops audio until it is ready again.
  private func reconnect(reason: String) {
    guard isGeminiActive, reconnectTask == nil else { return }
    NSLog("[ScoutVM] Reconnecting Gemini: %@", reason)
    isReconnecting = true
    audioManager.stopPlayback()
    flushPendingTurn()
    reconnectTask = Task { [weak self] in
      guard let self else { return }
      var failures = 0
      while let delay = ReconnectPolicy.delay(afterConsecutiveFailures: failures) {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        guard !Task.isCancelled, self.isGeminiActive else { return }
        if failures == ReconnectPolicy.dropHandleAfterFailures {
          NSLog("[ScoutVM] Resumption handle refused twice; starting a fresh Gemini session")
          self.geminiService.resetResumption()
        }
        self.geminiService.disconnect()
        if await self.geminiService.connect(systemInstruction: self.dynamicInstruction) {
          NSLog("[ScoutVM] Gemini reconnected (resumed: %@)",
                self.geminiService.resumptionHandle == nil ? "no" : "yes")
          self.isReconnecting = false
          self.reconnectTask = nil
          return
        }
        failures += 1
      }
      self.isReconnecting = false
      self.reconnectTask = nil
      guard self.isGeminiActive else { return }
      self.stopSession()
      self.errorMessage = "Connection lost (\(reason)). Tap End to send what was captured."
    }
  }

  /// Move any half-finished turn into the transcript so a drop or stop never loses it.
  private func flushPendingTurn() {
    if !pendingUserText.isEmpty {
      scoutHistory.append(ScoutTranscriptEntry(role: "user", text: pendingUserText))
      extractOpeningSequenceAnswers(from: pendingUserText)
    }
    if !pendingAIText.isEmpty {
      scoutHistory.append(ScoutTranscriptEntry(role: "assistant", text: pendingAIText))
    }
    pendingUserText = ""
    pendingAIText = ""
  }
```

`reconnect` checks `reconnectTask == nil`, but the loop's own `disconnect()`/`connect()` can fire `onDisconnected`. `disconnect()` nils the delegate callbacks first, so a failed `connect()` only reports through its return value. A late `onDisconnected` from a closed socket is ignored because `reconnectTask` is non-nil.

- [ ] **Step 6: Keep End available while a report is unsent, and offer Discard**

In `StreamView.swift` `ControlsView`, change `if geminiVM.isGeminiActive {` (line 156) to:

```swift
      if geminiVM.isGeminiActive || geminiVM.hasUnsentReport {
```

In the same `confirmationDialog`, after the "Send Report to Setup_IQ" button, add:

```swift
          Button("Discard report", role: .destructive) {
            geminiVM.stopSession()
            geminiVM.discardReport()
          }
```

- [ ] **Step 7: Commit, push, and verify in CI**

```bash
git add samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift samples/CameraAccess/CameraAccess/Views/StreamView.swift
git commit -m "feat(scout): reconnect across Gemini connection limit, keep unsent transcript

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push origin main
gh run watch --exit-status $(gh run list --workflow build.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected: tests and Archive are green. The device checks are in Task 8.

---

### Task 5: Keep the mic muted until the speaker has actually finished

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Gemini/AudioManager.swift` (properties at about line 13, `playAudio` at lines 176–179)
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift` (the `onAudioCaptured` closure)

**Interfaces:**
- Produces: `AudioManager.isSpeakerActive: Bool`, which is thread-safe.

- [ ] **Step 1: Track scheduled playback buffers**

In `AudioManager`, after `private var useIPhoneMode = false`, add:

```swift
  // Buffers scheduled on playerNode that have not finished (or been stopped).
  private let playbackCountLock = NSLock()
  private var scheduledPlaybackBuffers = 0

  /// True while audio is still coming out of the speaker, including the buffered
  /// tail that keeps playing after Gemini reports the turn complete. The iPhone-mode
  /// mute follows this so the model never hears the end of its own reply.
  var isSpeakerActive: Bool {
    playbackCountLock.lock()
    defer { playbackCountLock.unlock() }
    return scheduledPlaybackBuffers > 0
  }
```

In `playAudio(data:)`, replace `playerNode.scheduleBuffer(buffer)` with:

```swift
    playbackCountLock.lock()
    scheduledPlaybackBuffers += 1
    playbackCountLock.unlock()
    // The completion handler also fires when playerNode.stop() flushes the buffer
    // (interruption, stopPlayback), so the count always returns to zero.
    playerNode.scheduleBuffer(buffer) { [weak self] in
      guard let self else { return }
      self.playbackCountLock.lock()
      self.scheduledPlaybackBuffers = max(0, self.scheduledPlaybackBuffers - 1)
      self.playbackCountLock.unlock()
    }
```

- [ ] **Step 2: Gate the mic on the speaker, not only on generation**

In `GeminiSessionViewModel.startSession()`, in the `audioManager.onAudioCaptured` closure, replace:

```swift
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
```

with:

```swift
        // isModelSpeaking covers the gap before the first buffer is scheduled;
        // isSpeakerActive covers the tail that plays after generation ends.
        if speakerOnPhone && (self.geminiService.isModelSpeaking || self.audioManager.isSpeakerActive) { return }
```

- [ ] **Step 3: Commit, push, and verify in CI**

```bash
git add samples/CameraAccess/CameraAccess/Gemini/AudioManager.swift samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift
git commit -m "fix(audio): keep mic muted until reply playback finishes (iPhone mode)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push origin main
gh run watch --exit-status $(gh run list --workflow build.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

---

### Task 6: Throttle foreground frame conversion

At 24 fps, `makeUIImage()` runs on the main thread for every frame. Upstream saw that path freeze the app and get it killed by the watchdog. Gemini needs 1 frame per second; only WebRTC wants every frame. Stage 3 replaces this with `FrameHub`, so this is a deliberate stopgap.

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift` (properties at about line 87, the foreground branch at lines 163–173)

- [ ] **Step 1: Add the counter**

After `private var bgDiagLogged = false`, add:

```swift
  // Foreground frames converted to UIImage: every 3rd (8 fps of 24) unless WebRTC
  // is live and needs them all. makeUIImage is a GPU->CPU render on the main
  // thread; doing it 24x/s froze the app. Replaced by FrameHub in Stage 3.
  private var foregroundFrameCount = 0
```

- [ ] **Step 2: Skip the conversion for frames nobody needs**

In the video frame listener's `if !isInBackground {` branch, replace:

```swift
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          if let image = videoFrame.makeUIImage() {
```

with:

```swift
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          self.foregroundFrameCount &+= 1
          let webrtcNeedsEveryFrame = self.webrtcSessionVM?.isActive == true
          guard webrtcNeedsEveryFrame || (self.foregroundFrameCount - 1) % 3 == 0 else { return }
          if let image = videoFrame.makeUIImage() {
```

`(count - 1) % 3 == 0` renders the very first frame, so `hasReceivedFirstFrame` flips immediately.

- [ ] **Step 3: Commit, push, and verify in CI**

```bash
git add samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift
git commit -m "fix(stream): convert only needed foreground frames to stop main-thread stalls

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push origin main
gh run watch --exit-status $(gh run list --workflow build.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

---

### Task 7: Entitlements, Info.plist keys, iOS 26 minimum

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/CameraAccess.entitlements`
- Modify: `samples/CameraAccess/CameraAccess/Info.plist:53-60`
- Modify: `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj` (every `IPHONEOS_DEPLOYMENT_TARGET`)

- [ ] **Step 1: Entitlements (from upstream `53bd4d8`)**

Replace the empty `<dict>\n</dict>` in `CameraAccess.entitlements` with:

```xml
<dict>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)$(CFBundleIdentifier)</string>
	</array>
	<key>com.apple.developer.networking.HotspotConfiguration</key>
	<true/>
	<key>com.apple.developer.networking.wifi-info</key>
	<true/>
</dict>
```

- [ ] **Step 2: Info.plist (from upstream `664f4ac`)**

Replace the `UIBackgroundModes` array and the `NSBluetoothAlwaysUsageDescription` pair (lines 53–60) with:

```xml
	<key>UIBackgroundModes</key>
	<array>
		<string>audio</string>
		<string>bluetooth-central</string>
		<string>bluetooth-peripheral</string>
		<string>external-accessory</string>
	</array>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>Needed to connect to Meta AI Glasses</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>This allows your phone to find and connect to your glasses over Wi-Fi, which carries far more video than Bluetooth.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_bonjour._tcp</string>
	</array>
```

The requested glasses frame rate stays at 24, which is already one of the legal values (2, 7, 15, 24, 30).

- [ ] **Step 3: Deployment target 26.0**

In `project.pbxproj`, replace every `IPHONEOS_DEPLOYMENT_TARGET = 17.0;` and `IPHONEOS_DEPLOYMENT_TARGET = 14.5;` with `IPHONEOS_DEPLOYMENT_TARGET = 26.0;`. Verify:

```bash
grep -c "IPHONEOS_DEPLOYMENT_TARGET = 26.0;" samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj
grep -c "IPHONEOS_DEPLOYMENT_TARGET = 1[47]" samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj
```

Expected: `6`, then `0`.

- [ ] **Step 4: Commit, push, and verify in CI**

```bash
git add samples/CameraAccess/CameraAccess/CameraAccess.entitlements samples/CameraAccess/CameraAccess/Info.plist samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj
git commit -m "chore(ios): DAT entitlements, Wi-Fi transport plist keys, iOS 26 minimum

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push origin main
gh run watch --exit-status $(gh run list --workflow build.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected: green.

**If Archive fails** with a provisioning error that mentions *Hotspot Configuration* or *Access Wi-Fi Information*, that's an **owner action**:
1. Go to developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → `com.xiaoanliu.VisionClaw.VGWD36A4MQ`.
2. Enable **Hotspot** and **Access Wi-Fi Information**, then save.
3. Re-run the workflow with `gh run rerun --failed <id>`.

---

### Task 8: TestFlight device verification (owner)

- [ ] **Step 1: Confirm the build** is the TestFlight build from the last green run (build number = the `github.run_number` of the final push).

- [ ] **Step 2: Owner runs the checklist on the iPhone (iOS 27) with the Vanguards.** Write each result into this plan file.

**Basic checks:**
- [ ] Scout connects on `gemini-3.8-live` and answers out loud in the Charon voice. If it fails with "Connection closed (code …)", note the reason text: it names the rejected setup field.
- [ ] A reply starts noticeably faster after you stop talking. Note whether it ever cuts in during a mid-sentence pause.
- [ ] Glasses registration survives force-quitting and reopening the app, with no bounce back to Meta AI.
- [ ] 10 minutes of glasses streaming with the screen on: no freeze.

**Review Focus checks:**
- [ ] **(1)** Talk to Scout for 12 minutes or more. The session keeps going past about 10 minutes. After the ~10-minute mark (the log shows `goAway`), ask "Which vehicle are we on?": Scout answers from memory and does NOT re-run its opening questions. Also confirm that the reply in progress when `goAway` arrived was not cut off mid-sentence. End sends a report that contains both early and late turns.
- [ ] **(2)** Mid-session, turn on Airplane Mode for 30 s, then turn it off. The app reconnects. Repeat with Airplane Mode on for 90 s or more: you see "Connection lost … Tap End to send what was captured". Turn Airplane Mode off, tap End → Send: the report arrives in SPECTRE.
- [ ] **(3)** No field step. It's covered by the unit test and the log line `Resumption handle refused twice`, if it ever appears.
- [ ] **(4)** Make the last send fail (Airplane Mode at End), then tap Scout. You see "Send or discard the last Scout report first (tap End)." End → Discard clears it, and Scout then starts.
- [ ] **(5)** In iPhone mode, ask a long question and let the reply finish. Talk again: Scout hears you. Then interrupt a reply by toggling Airplane Mode for ~5 s: after reconnect, Scout hears you. Finally, Scout off → End → Discard → Scout on: the mic works and Scout starts.

**Results, 2026-09-23 (owner, run in Scout test mode, commit 6d56f51):**
- Passed: basic checks, check (2) dead zones, check (4), check (5) mic.
- Pending: check (1), the 12+ minute session across `goAway`. Not yet run; do it on the next longer session.
- Pending: the real SPECTRE send (test mode doesn't send). Confirm on the first session that is actually active.

- [ ] **Step 3:** If every box is ticked, Stage 1 is done. Next is writing Plan 2 (Stage 2), whose first task is the Vanguard gate.

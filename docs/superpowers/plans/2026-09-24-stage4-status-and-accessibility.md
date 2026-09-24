# Stage 4: Glasses Status + Accessibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the glasses screen sitting black or on a bare spinner. It shows "Connecting…", "Put on your glasses" or "Glasses folded" as appropriate. VoiceOver names every control and announces session start, end, reconnecting and glasses status.

**Architecture:**
- **Status rule.** A pure `GlassesStatusRule` in `ScoutCore` decides the glasses status from four inputs: time since the user tapped Start, time since the last frame, a hinges-closed flag, and the current time. It is unit-tested in CI.
- **View model.** `StreamSessionViewModel` records when frames arrive and whether the glasses reported a fold, then recomputes the status twice a second while glasses streaming is on.
- **Screen.** `StreamView` shows a centered placeholder for any status other than live, in place of today's bare spinner and the "Reconnecting to glasses…" capsule.
- **Announcements.** These go through `A11y.announce`, taken from upstream `dbd507c`.

**Tech Stack:** SwiftUI, Swift 5 language mode, iOS 26.0, XCTest through `swift test`.

**Spec:** `docs/superpowers/specs/2026-09-23-upstream-catchup-and-scout-modes-design.md` §A4 (roadmap plan 4).

## Global Constraints

- iOS 26.0 minimum. Swift 5 language mode in the app. `ScoutCore` builds with swift-tools 6.0, and its sources compile into the app with **no `import ScoutCore`**.
- **No LiveKit, OpenClaw or Android code.**
- Placeholder timing (spec §A4):
  - A glasses stream counts as stale when **no frame has arrived for 1.5 s**.
  - Right after the user taps Start, the screen shows "Connecting" rather than "Put on your glasses" **for up to 6 s, until the first frame**.
- Placeholder wording (upstream's final wording):
  - `connecting`: "Connecting to your glasses", with a spinner.
  - `putThemOn`: "Put on your glasses" / "Open the hinges and put them on. The camera turns off when they're folded or off your face."
  - `folded`: "Glasses folded" / "Unfold them to start streaming."
  - While a reconnect is running, the placeholder adds the line "Reconnecting automatically…".
- The placeholder is shown in glasses mode only, never in phone mode.
- Announcements:
  - "Scout started" and "Scout ended".
  - "Scout connection lost. Reconnecting." (assertive).
  - The placeholder title and caption when the status becomes `putThemOn` or `folded` (assertive).
  - "Glasses video is back" when the status returns to live after a placeholder.
  - Transitions only. Nothing is announced when a view first appears.
- Stage 2 and 3 behaviour must survive untouched: reconnect, generation guards, `FrameHub` and the event log.
- Before editing any `.swift` file, read `.claude/skills/swiftui-pro/SKILL.md` and follow it.
- **No Swift toolchain on this PC; CI is the compiler.** Push once, after the final review. Before pushing, run `git pull --rebase origin main`.
- Commit to `main`. Commit messages end with exactly: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## Review Focus

1. **The glasses come off mid-Scout.** Frames stop but the stream may stay "streaming". Expected: "Put on your glasses" appears within about 2 s. Pinned by `testStaleFramesAfterStartShowPutThemOn` (Task 1). The 0.5 s ticker is a reviewer check (Task 3).
2. **The first frame is slow over Bluetooth.** Expected: "Connecting" for up to 6 s, with no flash of "Put on your glasses". Pinned by `testConnectingDuringGrace` and `testGraceExpiresWithoutFrames` (Task 1).
3. **The glasses fold and then unfold.** Expected: "Glasses folded", then live again once frames return, even though the fold flag was set. Pinned by `testLiveFramesBeatFoldedFlag` (Task 1), plus the flag clearing on frame arrival (Task 3).
4. **The first status change is swallowed.** Upstream Android bug `9055363`: an announcement tied to "skip the first update" missed the first real change. Expected: announcements use `onChange(of:)` old and new values, which never fires on the first appearance, so the first real change is announced. Reviewer check (Task 3).
5. **Phone mode.** Expected: no glasses placeholder and no glasses announcements. Reviewer check (Task 3).

## Hunk map

| Upstream | Take | Adapt | Never |
|---|---|---|---|
| `0286e73` | Final wording | 1.5 s staleness watchdog → `GlassesStatusRule.staleAfter` plus a 0.5 s ticker in the view model | `LiveKitSession`/`LiveKitStreamView`; Android |
| `2494f43` | none | 6 s "video establishing" grace → `GlassesStatusRule.connectingGrace` | LiveKit and Android files |
| `4b50ee6` (not cited) | none | Rule: the placeholder never competes with the connecting spinner (covered by `.connecting`) | LiveKit file |
| `7adc513` | none | A mid-Scout drop shows "Put on your glasses", not "Reconnecting". Reconnect becomes a secondary line. | none |
| `a6d7356` | `.hingesClosed` wording ("Glasses folded" / "Unfold…", reworded from "Open the hinges…") | none | none |
| `dbd507c` | `Accessibility.swift` (without the pre-iOS-17 fallback); labels in `CircleButton`, `DebugMenuView`, `HomeScreenView`, `NonStreamView`, `PhotoPreviewView`, `StreamView` | Announcement hook: our own `onChange` handlers | `LiveKitStreamView`; the `ConnectedAppsView` hunk (our file has no matching label) |
| `9055363` | none | none | Android only; its lesson is Review Focus 4 |

## File map

| File | Change | Task |
|---|---|---|
| `samples/CameraAccess/ScoutCore/Sources/ScoutCore/GlassesStatusRule.swift` | Create | 1 |
| `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/GlassesStatusRuleTests.swift` | Create | 1 |
| `samples/CameraAccess/CameraAccess/Views/Components/Accessibility.swift` | Create | 2 |
| `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj` | Add `Accessibility.swift` to Components | 2 |
| `Views/Components/CircleButton.swift`, `Views/DebugMenuView.swift`, `Views/HomeScreenView.swift`, `Views/NonStreamView.swift`, `Views/PhotoPreviewView.swift` | Labels and hidden decorations | 2 |
| `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift` | `glassesStatus`, ticker, frame clock, fold flag | 3 |
| `samples/CameraAccess/CameraAccess/Views/StreamView.swift` | Placeholder, capture label, announcements | 3 |

---

### Task 1: `GlassesStatusRule` in ScoutCore

**Files:**
- Create: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/GlassesStatusRule.swift`
- Test: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/GlassesStatusRuleTests.swift`

**Interfaces:**
- Produces:
  - `public enum GlassesStatus: Equatable, Sendable { case live, connecting, putThemOn, folded }`
  - `public enum GlassesStatusRule` with `static let staleAfter: TimeInterval = 1.5`, `static let connectingGrace: TimeInterval = 6`, and `static func status(now: TimeInterval, startedAt: TimeInterval, lastFrameAt: TimeInterval?, hingesClosed: Bool) -> GlassesStatus`

**Rule, in order:**
1. A frame within `staleAfter` → `.live`.
2. Otherwise, the fold flag set → `.folded`.
3. Otherwise, no frame yet since Start and under `connectingGrace` since Start → `.connecting`.
4. Otherwise → `.putThemOn`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ScoutCore

final class GlassesStatusRuleTests: XCTestCase {
  private func status(now: TimeInterval, lastFrameAt: TimeInterval?, hingesClosed: Bool = false) -> GlassesStatus {
    GlassesStatusRule.status(now: now, startedAt: 100, lastFrameAt: lastFrameAt, hingesClosed: hingesClosed)
  }

  func testConnectingDuringGrace() {
    XCTAssertEqual(status(now: 100, lastFrameAt: nil), .connecting)
    XCTAssertEqual(status(now: 105.9, lastFrameAt: nil), .connecting)
  }

  func testGraceExpiresWithoutFrames() {
    XCTAssertEqual(status(now: 106, lastFrameAt: nil), .putThemOn)
    XCTAssertEqual(status(now: 200, lastFrameAt: nil), .putThemOn)
  }

  func testFreshFrameIsLive() {
    XCTAssertEqual(status(now: 102, lastFrameAt: 101.5), .live)
    XCTAssertEqual(status(now: 103, lastFrameAt: 101.5), .live)
  }

  func testStaleFramesAfterStartShowPutThemOn() {
    XCTAssertEqual(status(now: 103.01, lastFrameAt: 101.5), .putThemOn)
  }

  func testStaleFramesInsideGraceStillShowPutThemOn() {
    // Frames started then stopped: the connecting grace only covers the first frame.
    XCTAssertEqual(status(now: 104, lastFrameAt: 101), .putThemOn)
  }

  func testFoldedWhenFlagSetAndNoFreshFrames() {
    XCTAssertEqual(status(now: 103, lastFrameAt: nil, hingesClosed: true), .folded)
    XCTAssertEqual(status(now: 110, lastFrameAt: 101, hingesClosed: true), .folded)
  }

  func testLiveFramesBeatFoldedFlag() {
    XCTAssertEqual(status(now: 110, lastFrameAt: 109.9, hingesClosed: true), .live)
  }

  func testConstants() {
    XCTAssertEqual(GlassesStatusRule.staleAfter, 1.5)
    XCTAssertEqual(GlassesStatusRule.connectingGrace, 6)
  }
}
```

- [ ] **Step 2: Confirm the tests would fail.** A grep finds no `GlassesStatusRule` under `samples/CameraAccess/ScoutCore/Sources`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// What the glasses screen should say.
public enum GlassesStatus: Equatable, Sendable {
  /// Frames are arriving; show the video.
  case live
  /// Just started and no frame yet; show a spinner.
  case connecting
  /// No fresh frames: the glasses are off the face, folded, or out of reach.
  case putThemOn
  /// The glasses reported their hinges closed and frames have stopped.
  case folded
}

/// Decides the glasses status from the frame clock. A stream is stale after
/// `staleAfter` seconds without a frame; right after Start, a missing first
/// frame reads as connecting for up to `connectingGrace` seconds so a slow
/// Bluetooth start never flashes "put them on".
public enum GlassesStatusRule {
  public static let staleAfter: TimeInterval = 1.5
  public static let connectingGrace: TimeInterval = 6

  public static func status(
    now: TimeInterval,
    startedAt: TimeInterval,
    lastFrameAt: TimeInterval?,
    hingesClosed: Bool
  ) -> GlassesStatus {
    if let lastFrameAt, now - lastFrameAt <= staleAfter {
      return .live
    }
    if hingesClosed {
      return .folded
    }
    if lastFrameAt == nil, now - startedAt < connectingGrace {
      return .connecting
    }
    return .putThemOn
  }
}
```

- [ ] **Step 4: Trace each test by hand** and put the traces in the report. For example, `testStaleFramesAfterStartShowPutThemOn` gives 103.01 − 101.5 = 1.51 > 1.5, so the frame is not live; the flag is not set and a frame has been seen, so the result is `.putThemOn`.

- [ ] **Step 5: Commit (do not push)**

```bash
git add samples/CameraAccess/ScoutCore/Sources/ScoutCore/GlassesStatusRule.swift samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/GlassesStatusRuleTests.swift
git commit -m "feat(scoutcore): GlassesStatusRule for the glasses placeholder"
```

---

### Task 2: Accessibility helper and control labels (upstream `dbd507c`)

**Files:**
- Create: `samples/CameraAccess/CameraAccess/Views/Components/Accessibility.swift`
- Modify: `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj`
- Modify: `Views/Components/CircleButton.swift`, `Views/DebugMenuView.swift`, `Views/HomeScreenView.swift`, `Views/NonStreamView.swift`, `Views/PhotoPreviewView.swift` (all under `samples/CameraAccess/CameraAccess/`)

**Interfaces:**
- Produces:
  - `enum A11y { static func announce(_ message: String, assertive: Bool = false) }`
  - `extension View { func a11yLabel(_ label: String?) -> some View }`
  - `CircleButton` gains `var label: String? = nil`. It is declared between `text` and `action`, so the existing trailing-closure call sites keep compiling.

- [ ] **Step 1: Create `Accessibility.swift`**

```swift
/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// Accessibility.swift
//
// Shared helpers for the app's accessibility layer. `A11y.announce` posts the
// state changes VoiceOver would not otherwise speak (session start and end,
// reconnecting, glasses status); `a11yLabel` names icon-only controls that
// would otherwise be read as their SF Symbol.
//

import SwiftUI

enum A11y {
  /// Announces a status change. Use `assertive` for states that should
  /// interrupt -- a dropped connection -- and leave it off for routine
  /// updates so they queue behind whatever VoiceOver is already speaking.
  static func announce(_ message: String, assertive: Bool = false) {
    guard !message.isEmpty else { return }
    var announcement = AttributedString(message)
    announcement.accessibilitySpeechAnnouncementPriority = assertive ? .high : .default
    AccessibilityNotification.Announcement(announcement).post()
  }
}

/// Applies an accessibility label only when one is supplied, so a component
/// that draws a visible `Text` keeps its implicit label while its icon-only
/// variant can still name itself.
struct OptionalAccessibilityLabel: ViewModifier {
  private let label: String?

  init(_ label: String?) {
    self.label = label
  }

  func body(content: Content) -> some View {
    if let label, !label.isEmpty {
      content.accessibilityLabel(Text(label))
    } else {
      content
    }
  }
}

extension View {
  func a11yLabel(_ label: String?) -> some View {
    modifier(OptionalAccessibilityLabel(label))
  }
}
```

- [ ] **Step 2: Add it to the Components group in `project.pbxproj`**

Use the four-place pattern of `GlassesEventLogStore.swift`, with the IDs:
- File reference: `A1B2C3D42F0A00010000000B /* Accessibility.swift */`.
- Build file: `A1B2C3D42F0A00020000000B /* Accessibility.swift in Sources */`.
- Add the file reference as a child of the Components group (`8FFD5FF42E8422580035E446`, the group that lists `CircleButton.swift`).
- Add the build file to the app's `PBXSourcesBuildPhase`, the one that lists `StreamSessionViewModel.swift in Sources`.
- Check that each ID appears where expected.

- [ ] **Step 3: `CircleButton`: a label for the icon-only variant**

Add this after `let text: String?`:

```swift
  /// VoiceOver name for the icon-only variant. Without it the button is read
  /// as its SF Symbol, so callers that pass `text: nil` must pass a label.
  var label: String? = nil
```

Then add `.a11yLabel(label ?? text)` after `.clipShape(Circle())`.

- [ ] **Step 4: Labels and hidden decorations in the other views**
- `DebugMenuView.swift`: change `}.accessibilityIdentifier("debug_menu_button")` to:
  ```swift
          }
          .accessibilityLabel("Debug menu")
          .accessibilityIdentifier("debug_menu_button")
  ```
- `HomeScreenView.swift`:
  - Add `.accessibilityLabel("Settings")` to the settings `Button` (after its `label:` closure).
  - Add `.accessibilityHidden(true)` to the `Image(.cameraAccessIcon)` logo.
  - Add `.accessibilityHidden(true)` to the icon `Image(resource)` in `HomeTipItemView` (after `.padding(.top, 4)`).
- `NonStreamView.swift`:
  - Add `.accessibilityLabel("Settings")` to the gear `Menu` (after its `label:` closure).
  - Add `.accessibilityHidden(true)` to the logo `Image(.cameraAccessIcon)`.
  - Add `.accessibilityHidden(true)` to the `hourglass` image.
  - Add `.accessibilityHidden(true)` to the icon `Image(resource)` in `TipItemView` (after `.padding(.top, 4)`).
- `PhotoPreviewView.swift`: after `.shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)`, add `.accessibilityLabel("Captured photo")`.

- [ ] **Step 5: Self-check by reading.** Every existing `CircleButton(icon:text:) { … }` call site still compiles, because `label` has a default value and sits before the trailing closure. `AccessibilityNotification.Announcement` and `accessibilitySpeechAnnouncementPriority` are iOS 17+ APIs, and our minimum is 26.

- [ ] **Step 6: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/Views/Components/Accessibility.swift samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj samples/CameraAccess/CameraAccess/Views/Components/CircleButton.swift samples/CameraAccess/CameraAccess/Views/DebugMenuView.swift samples/CameraAccess/CameraAccess/Views/HomeScreenView.swift samples/CameraAccess/CameraAccess/Views/NonStreamView.swift samples/CameraAccess/CameraAccess/Views/PhotoPreviewView.swift
git commit -m "feat(a11y): announce helper and labels for icon-only controls"
```

---

### Task 3: Glasses status placeholder and announcements

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift`
- Modify: `samples/CameraAccess/CameraAccess/Views/StreamView.swift`

**Interfaces:**
- Consumes: `GlassesStatus` and `GlassesStatusRule` (Task 1); `A11y.announce` and `CircleButton(label:)` (Task 2).
- Produces: on `StreamSessionViewModel`, `@Published private(set) var glassesStatus: GlassesStatus = .connecting`.

- [ ] **Step 1: View-model state**

After `@Published private(set) var isReconnectingGlasses = false`, add:

```swift
  /// What the glasses screen should say; recomputed twice a second while
  /// glasses streaming is on (see GlassesStatusRule).
  @Published private(set) var glassesStatus: GlassesStatus = .connecting
```

After the `decodeQueue` property, add:

```swift
  // Glasses status inputs: when the user tapped Start, when the last frame
  // arrived, and whether the glasses reported their hinges closed since then.
  private var glassesStartedAt: TimeInterval = 0
  private var lastGlassesFrameAt: TimeInterval?
  private var glassesReportedFolded = false
  private var statusTicker: Task<Void, Never>?
```

- [ ] **Step 2: Start the clock on the user's Start**

In `startSession()`, after the existing `geminiThrottle.reset()` line, add:

```swift
    glassesStartedAt = ProcessInfo.processInfo.systemUptime
    lastGlassesFrameAt = nil
    glassesReportedFolded = false
    glassesStatus = .connecting
    startStatusTicker()
```

Add these methods near `noteDeliveredFrame`:

```swift
  /// Recomputes the glasses status twice a second while glasses streaming is on.
  private func startStatusTicker() {
    statusTicker?.cancel()
    statusTicker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        self?.refreshGlassesStatus()
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  private func refreshGlassesStatus() {
    let status = GlassesStatusRule.status(
      now: ProcessInfo.processInfo.systemUptime,
      startedAt: glassesStartedAt,
      lastFrameAt: lastGlassesFrameAt,
      hingesClosed: glassesReportedFolded)
    if status != glassesStatus {
      logEvent("glasses status: \(status)")
      glassesStatus = status
    }
  }
```

- [ ] **Step 3: Feed the frame clock and the fold flag**

At the top of `noteDeliveredFrame(_:)`, add:

```swift
    lastGlassesFrameAt = ProcessInfo.processInfo.systemUptime
    glassesReportedFolded = false
```

In the `errorPublisher` listener, directly after the `self.logEvent("stream error: …")` line and **before** the `keepGlassesAlive` guard, add:

```swift
        if case .hingesClosed = error {
          self.glassesReportedFolded = true
          self.refreshGlassesStatus()
        }
```

- [ ] **Step 4: Stop the ticker when streaming ends**

In `markStopped()`, add `statusTicker?.cancel()` and `statusTicker = nil` next to the other task cancellations.

- [ ] **Step 5: `StreamView`: the placeholder**

5a. Replace the final `else { ProgressView() … }` branch of the video `if` chain (the one after the `currentVideoFrame` branch) with:

```swift
      } else if viewModel.streamingMode == .iPhone {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.white)
      }
```

(In glasses mode, the status placeholder below covers the empty state.)

5b. Replace the whole `if viewModel.isReconnectingGlasses { VStack { … } }` block with:

```swift
      if viewModel.streamingMode == .glasses, viewModel.glassesStatus != .live {
        GlassesStatusPlaceholder(
          status: viewModel.glassesStatus,
          isReconnecting: viewModel.isReconnectingGlasses)
      }
```

5c. Hide the decorative video from VoiceOver: in the `currentVideoFrame` branch, add `.accessibilityHidden(true)` after `.clipped()`.

5d. In `ControlsView`, change the capture button to:

```swift
        CircleButton(icon: "camera.fill", text: nil, label: "Capture photo") {
          viewModel.capturePhoto()
        }
        .accessibilityHint("Takes a photo through your glasses")
```

5e. Add at the end of `StreamView.swift`:

```swift
/// Centered message for a glasses stream that is not showing live video.
private struct GlassesStatusPlaceholder: View {
  let status: GlassesStatus
  let isReconnecting: Bool

  var body: some View {
    VStack(spacing: 10) {
      if status == .connecting {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.white)
      } else {
        Image(systemName: status == .folded ? "eyeglasses.slash" : "eyeglasses")
          .font(.system(size: 40))
          .foregroundStyle(.white)
          .accessibilityHidden(true)
      }
      Text(GlassesStatusText.title(for: status))
        .font(.headline)
        .foregroundStyle(.white)
      if let caption = GlassesStatusText.caption(for: status) {
        Text(caption)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.8))
          .multilineTextAlignment(.center)
      }
      if isReconnecting, status != .connecting {
        Text("Reconnecting automatically…")
          .font(.footnote)
          .foregroundStyle(.white.opacity(0.6))
      }
    }
    .padding(24)
    .frame(maxWidth: 320)
    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    .accessibilityElement(children: .combine)
  }
}

/// Wording for the glasses placeholder and its announcements.
enum GlassesStatusText {
  static func title(for status: GlassesStatus) -> String {
    switch status {
    case .live: return ""
    case .connecting: return "Connecting to your glasses"
    case .putThemOn: return "Put on your glasses"
    case .folded: return "Glasses folded"
    }
  }

  static func caption(for status: GlassesStatus) -> String? {
    switch status {
    case .live, .connecting: return nil
    case .putThemOn:
      return "Open the hinges and put them on. The camera turns off when they're folded or off your face."
    case .folded: return "Unfold them to start streaming."
    }
  }
}
```

If `eyeglasses.slash` is not a valid SF Symbol name in the iOS 26 SDK's list, use `"eyeglasses"` for both. Say which one was used in the report.

- [ ] **Step 6: `StreamView`: announcements**

Add these to `StreamView`'s body chain, after the existing `.onDisappear { … }`. The two-parameter `onChange` never fires on first appearance, which avoids upstream's `9055363` swallowed-first-transition bug.

```swift
    .onChange(of: viewModel.glassesStatus) { oldStatus, newStatus in
      guard viewModel.streamingMode == .glasses else { return }
      switch newStatus {
      case .putThemOn, .folded:
        let caption = GlassesStatusText.caption(for: newStatus) ?? ""
        A11y.announce("\(GlassesStatusText.title(for: newStatus)). \(caption)", assertive: true)
      case .live where oldStatus == .putThemOn || oldStatus == .folded:
        A11y.announce("Glasses video is back")
      default:
        break
      }
    }
    .onChange(of: geminiVM.isGeminiActive) { _, isActive in
      A11y.announce(isActive ? "Scout started" : "Scout ended")
    }
    .onChange(of: geminiVM.isReconnecting) { _, isReconnecting in
      if isReconnecting {
        A11y.announce("Scout connection lost. Reconnecting.", assertive: true)
      }
    }
```

- [ ] **Step 7: Self-check by reading**
- No remaining UI uses `isReconnectingGlasses` except as the placeholder's `isReconnecting` input. The property itself stays, because the view model uses it for logging.
- Phone mode shows no placeholder and makes no glasses announcements.
- `GlassesStatus` is used without `import ScoutCore`.
- `refreshGlassesStatus` runs on the main actor only.

- [ ] **Step 8: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift samples/CameraAccess/CameraAccess/Views/StreamView.swift
git commit -m "feat(glasses): status placeholder and VoiceOver announcements"
```

The controller pushes after the final review.

---

## Device checklist (end-of-project device pass; owner)

1. Start glasses streaming: "Connecting to your glasses" shows, then video, with no "Put on your glasses" flash.
2. Take the glasses off mid-stream: "Put on your glasses" appears within about 2 s. Put them back on and the video returns.
3. Fold the glasses: "Glasses folded", or "Put on your glasses" if the SDK doesn't report a fold.
4. With VoiceOver on:
   - The capture button reads "Capture photo".
   - Settings reads "Settings".
   - Starting and ending Scout are announced.
   - Taking the glasses off is announced.

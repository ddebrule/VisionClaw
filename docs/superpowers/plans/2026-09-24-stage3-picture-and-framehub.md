# Stage 3: Picture Quality + FrameHub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sharper glasses video (HEVC, 720×1280, 15 fps) that keeps working with the phone locked, a single `FrameHub` that every frame source publishes to once, and a sharper phone mode (1080p, a native preview, and pinch-to-zoom).

**Architecture:** Every source (glasses raw frames, glasses frames decoded from HEVC, the phone camera) publishes a `VideoFrameSample` (a `CVPixelBuffer` plus its timestamp) to a main-actor `FrameHub`. Three consumers subscribe:
- **Preview:** throttled to 8 fps, rendered to a `UIImage` off the main thread.
- **Gemini:** throttled to 1 per second, rendered off the main thread, then sent through the existing gate.
- **WebRTC:** gets the pixel buffer directly, which removes today's UIImage → pixel-buffer round trip.

Throttling is a pure `FrameThrottle` in `ScoutCore`, unit-tested in CI. HEVC samples are decoded on a background queue by `VideoDecoder`, which now rebuilds itself after the phone locks (upstream `f8c353b`).

**Tech Stack:** SwiftUI, Swift 5 language mode, iOS 26.0, MetaWearablesDAT 0.9.0, VideoToolbox, CoreImage, AVFoundation, WebRTC (existing), XCTest through `swift test`.

**Spec:** `docs/superpowers/specs/2026-09-23-upstream-catchup-and-scout-modes-design.md` §A3 (roadmap plan 3).

## Global Constraints

- iOS 26.0 minimum (already set). Swift 5 language mode in the app; `ScoutCore` builds with swift-tools 6.0.
- **No LiveKit, OpenClaw or Android code.** Upstream's `onDecodedFrame` room bridge is not taken.
- Glasses request: `VideoCodec.hvc1`, `.high` by default (the Low/Med/High picker stays as an override), **15 fps**.
- Gemini still gets **one frame per second** (`GeminiConfig.videoFrameInterval`) as a JPEG at `GeminiConfig.videoJPEGQuality`, gated by `SettingsManager.shared.videoStreamingEnabled`, `isGeminiActive` and `connectionState == .ready`.
- Preview frames are at most **8 per second**, and none are rendered while the app is in the background.
- No image conversion on the main thread on the per-frame path.
- Phone camera: `.hd1920x1080` when supported, otherwise `.high`. Zoom is capped at **8×** or the device maximum, whichever is lower.
- Stage 2 behaviour must survive untouched: generation guards, reconnect, event log (`noteDeliveredFrame`), and the glasses-mic selection in `beginStream()`.
- Before editing any `.swift` file, read `.claude/skills/swiftui-pro/SKILL.md` and follow it.
- `ScoutCore` sources compile into the app with **no `import ScoutCore`**.
- **This PC has no Swift toolchain; CI is the compiler.** Push once, at the end of Task 5. Before pushing, run `git pull --rebase origin main`.
- Commit to `main`. Commit messages end with exactly: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## Review Focus

1. **Gemini frames stop arriving at the promised one per second.** Two throttles in series with render latency between them can halve the rate. So Gemini's own time check is removed and `FrameThrottle` is the only throttle (Task 3). Pinned by `testPassesAtExactlyTheInterval` (Task 1), plus a reviewer check that `GeminiSessionViewModel` has no remaining time gate.
2. **The phone locks mid-stream.** Expected: glasses frames keep decoding and reaching Gemini, and the preview stops rendering. Covered by `VideoDecoder`'s rebuild on `kVTInvalidSessionErr` (Task 2), the software-renderer `CIContext` (Task 3), and the background check (Task 3). Confirmed in the end-of-project device pass.
3. **The system clock jumps backwards, or the first frame arrives.** Expected: the frame passes. Pinned by `testFirstFramePasses` and `testClockGoingBackwardsPasses` (Task 1).
4. **HEVC is not decodable on this device or SDK.** Expected: the event log says so once rather than showing a silent black screen. Covered by the first-failure log in Task 3's decode path.
5. **A late render lands after streaming stopped.** Expected: it does not bring back a preview frame. Covered by the `streamingStatus != .stopped` check in the render completion (Task 3).

## Hunk map (spec porting rule)

| Upstream | Take | Adapt | Never |
|---|---|---|---|
| `08312c7` | `videoCodec: .hvc1` (Task 4) | "Compressed sample" handling moved into our `ingestGlassesSample` (Task 3) | `onDecodedFrame` LiveKit bridge |
| `f6880d6` | Decode compressed samples in the foreground too (Task 3) | The decoder callback publishes to `FrameHub` instead of a room | The LiveKit callback |
| `15ade86` | `requestedFrameRate = 15` (Task 4) | none | HFP hunk (already done in Stage 2); Android |
| `f8c353b` | Whole `VideoDecoder` change (Task 2) | none | none |
| `e1d7e2f` | `IPhoneCameraPreviewView`, `session`, 1080p preset, the `StreamView` branch (Task 5) | The per-frame UIImage throttle inside the manager is replaced by `FrameHub` | none |
| `0277421` | Zoom (Task 5) | `MagnifyGesture` instead of the deprecated `MagnificationGesture` | none |
| `6adb111` (not cited) | none | none | Not taken: our event log already records the real first-frame size from the format description |

## File map

| File | Change | Task |
|---|---|---|
| `samples/CameraAccess/ScoutCore/Sources/ScoutCore/FrameThrottle.swift` | Create | 1 |
| `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/FrameThrottleTests.swift` | Create | 1 |
| `samples/CameraAccess/CameraAccess/ViewModels/VideoDecoder.swift` | Rebuild after lock, prefer software decode, failure counter | 2 |
| `samples/CameraAccess/CameraAccess/ViewModels/FrameHub.swift` | Create: `VideoFrameSample`, `FrameHub` | 3 |
| `samples/CameraAccess/CameraAccess/ViewModels/PixelBufferImageRenderer.swift` | Create | 3 |
| `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj` | Add the two new files to the ViewModels group | 3 |
| `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift` | Hub, consumers, glasses ingest (T3); codec, resolution, fps (T4); phone preview and zoom (T5) | 3, 4, 5 |
| `samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift` | `sendVideoFrameIfThrottled` → `sendVideoFrame` (no time gate) | 3 |
| `samples/CameraAccess/CameraAccess/WebRTC/WebRTCSessionViewModel.swift`, `WebRTCClient.swift`, `CustomVideoCapturer.swift` | Take a `CVPixelBuffer` | 3 |
| `samples/CameraAccess/CameraAccess/iPhone/IPhoneCameraManager.swift` | Publish pixel buffers (T3); session, 1080p, zoom (T5) | 3, 5 |
| `samples/CameraAccess/CameraAccess/iPhone/IPhoneCameraPreviewView.swift` | Create (synchronized folder, so no pbxproj edit) | 5 |
| `samples/CameraAccess/CameraAccess/Views/StreamView.swift` | Phone preview branch with zoom | 5 |

---

### Task 1: `FrameThrottle` in ScoutCore

**Files:**
- Create: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/FrameThrottle.swift`
- Test: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/FrameThrottleTests.swift`

**Interfaces:**
- Produces: `public struct FrameThrottle: Equatable, Sendable` with `init(minimumInterval: TimeInterval)`, `let minimumInterval`, `mutating func shouldPass(at now: TimeInterval) -> Bool`, `mutating func reset()`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ScoutCore

final class FrameThrottleTests: XCTestCase {
  func testFirstFramePasses() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 100))
  }

  func testBlocksWithinTheInterval() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 100))
    XCTAssertFalse(throttle.shouldPass(at: 100.5))
    XCTAssertFalse(throttle.shouldPass(at: 100.999))
  }

  func testPassesAtExactlyTheInterval() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 100))
    XCTAssertTrue(throttle.shouldPass(at: 101))
    XCTAssertFalse(throttle.shouldPass(at: 101.5))
    XCTAssertTrue(throttle.shouldPass(at: 102))
  }

  func testBlockedFramesDoNotMoveTheWindow() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 0))
    for step in 1...9 {
      XCTAssertFalse(throttle.shouldPass(at: Double(step) / 10))
    }
    XCTAssertTrue(throttle.shouldPass(at: 1.0))
  }

  func testEightPerSecondFromThirtyFrames() {
    var throttle = FrameThrottle(minimumInterval: 1.0 / 8)
    let passed = (0..<30).filter { throttle.shouldPass(at: Double($0) / 30) }.count
    XCTAssertEqual(passed, 8)
  }

  func testClockGoingBackwardsPasses() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 100))
    XCTAssertTrue(throttle.shouldPass(at: 50))
    XCTAssertFalse(throttle.shouldPass(at: 50.5))
  }

  func testResetLetsTheNextFrameThrough() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 100))
    throttle.reset()
    XCTAssertTrue(throttle.shouldPass(at: 100.1))
  }

  func testZeroIntervalPassesEverything() {
    var throttle = FrameThrottle(minimumInterval: 0)
    XCTAssertTrue(throttle.shouldPass(at: 1))
    XCTAssertTrue(throttle.shouldPass(at: 1))
  }
}
```

- [ ] **Step 2: Confirm the tests would fail**

Grep confirms that `FrameThrottle` is not defined anywhere under `samples/CameraAccess/ScoutCore/Sources`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Lets a frame through when at least `minimumInterval` seconds have passed
/// since the last frame it let through. Blocked frames do not move the window,
/// and a clock that goes backwards restarts it.
public struct FrameThrottle: Equatable, Sendable {
  public let minimumInterval: TimeInterval
  private var lastPassed: TimeInterval?

  public init(minimumInterval: TimeInterval) {
    self.minimumInterval = minimumInterval
  }

  public mutating func shouldPass(at now: TimeInterval) -> Bool {
    if let lastPassed, now >= lastPassed, now - lastPassed < minimumInterval {
      return false
    }
    lastPassed = now
    return true
  }

  public mutating func reset() {
    lastPassed = nil
  }
}
```

`testEightPerSecondFromThirtyFrames` traced: frames pass at indices 0, 4, 8, 12, 16, 20, 24 and 28. After a pass at 4/30, the next frame at or beyond 1/8 later is 8/30, because 7/30 − 4/30 = 0.1 < 0.125 and 8/30 − 4/30 = 0.133. That is 8 frames.

- [ ] **Step 4: Check against the tests by reading.** Trace each test by hand and record the traces in the report.

- [ ] **Step 5: Commit (do not push)**

```bash
git add samples/CameraAccess/ScoutCore/Sources/ScoutCore/FrameThrottle.swift samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/FrameThrottleTests.swift
git commit -m "feat(scoutcore): FrameThrottle for per-consumer frame rates"
```

---

### Task 2: `VideoDecoder` survives the locked screen (upstream `f8c353b`)

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/ViewModels/VideoDecoder.swift`

**Interfaces:**
- Produces: the same public API (`setFrameCallback`, `decode(_:)`, `invalidateSession()`, `DecodedFrame`), plus `private(set) var failureCount: Int`. Task 3 reads `failureCount` on the decode queue.

- [ ] **Step 1: Split `decode` into rebuild-and-retry**

Replace the body of `decode(_:)` from the line `guard let session = decompressionSession else {` to the end of the function with:

```swift
    var result = try decodeOnce(sampleBuffer)

    // Backgrounding invalidates the session (kVTInvalidSessionErr, -12903).
    // Previously decode() just threw, so the session stayed dead for the rest
    // of the call: locking the phone killed the decoder and unlocking never
    // brought it back. Rebuild and retry the frame instead.
    if result == kVTInvalidSessionErr || result == kVTVideoDecoderMalfunctionErr {
      NSLog("[VideoDecoder] session invalid (%d), rebuilding", result)
      try recreateDecompressionSession(formatDescription: formatDescription)
      result = try decodeOnce(sampleBuffer)
    }

    guard result == noErr else {
      failureCount += 1
      throw DecoderError.decodingFailed(result)
    }
  }

  private func decodeOnce(_ sampleBuffer: CMSampleBuffer) throws -> OSStatus {
    guard let session = decompressionSession else {
      throw DecoderError.invalidFormat
    }
    var flagOut = VTDecodeInfoFlags(rawValue: 0)
    let result = VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sampleBuffer,
      flags: [._1xRealTimePlayback],
      frameRefcon: nil,
      infoFlagsOut: &flagOut
    )
    if result == noErr {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
    return result
  }
```

Add `private(set) var failureCount = 0` below `private var onFrameDecoded`. Update the doc comment on the class to: `/// Decodes compressed video frames (H.264/HEVC) into BGRA pixel buffers with VTDecompressionSession. Not thread-safe: call it from one serial queue.`

- [ ] **Step 2: Prefer software decoding**

In `createDecompressionSession`, replace the `var session …` / `let status = VTDecompressionSessionCreate(…)` block with:

```swift
    // Hardware decode runs in a shared out-of-process service, which iOS tears
    // down when the app backgrounds -- that is the -12903 storm on a locked
    // screen. Software decode stays inside this process and keeps working with
    // the screen off. Fall back to the default decoder if software is
    // unavailable for this format, so a foreground stream never breaks over it.
    let softwareSpec: [CFString: Any] = [
      kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false,
    ]

    var session: VTDecompressionSession?
    var usedSoftware = true
    var status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: softwareSpec as CFDictionary,
      imageBufferAttributes: attrs as CFDictionary,
      outputCallback: &outputCallback,
      decompressionSessionOut: &session
    )

    if status != noErr || session == nil {
      usedSoftware = false
      status = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: formatDescription,
        decoderSpecification: nil,
        imageBufferAttributes: attrs as CFDictionary,
        outputCallback: &outputCallback,
        decompressionSessionOut: &session
      )
    }
```

Change the final log line to:

```swift
    NSLog("[VideoDecoder] Created %@ decompression session for codec: %@",
          usedSoftware ? "software" : "hardware", subTypeStr)
```

- [ ] **Step 3: Self-check.** `kVTInvalidSessionErr`, `kVTVideoDecoderMalfunctionErr` and `kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder` are VideoToolbox symbols, and the file already imports VideoToolbox. The result must match upstream's final file: `git show upstream/main:samples/CameraAccess/CameraAccess/ViewModels/VideoDecoder.swift`. The only differences allowed are `failureCount` and the class doc comment.

- [ ] **Step 4: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/ViewModels/VideoDecoder.swift
git commit -m "fix(glasses): rebuild the decoder after lock and prefer software decode"
```

---

### Task 3: `FrameHub` and its consumers

**Files:**
- Create: `samples/CameraAccess/CameraAccess/ViewModels/FrameHub.swift`
- Create: `samples/CameraAccess/CameraAccess/ViewModels/PixelBufferImageRenderer.swift`
- Modify: `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj`
- Modify: `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift`
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift`
- Modify: `samples/CameraAccess/CameraAccess/WebRTC/WebRTCSessionViewModel.swift`, `WebRTC/WebRTCClient.swift`, `WebRTC/CustomVideoCapturer.swift`
- Modify: `samples/CameraAccess/CameraAccess/iPhone/IPhoneCameraManager.swift`

**Interfaces:**
- Consumes: `FrameThrottle` (Task 1); `VideoDecoder.failureCount` (Task 2).
- Produces:
  - `struct VideoFrameSample { let pixelBuffer: CVPixelBuffer; let timestamp: CMTime }`
  - `@MainActor final class FrameHub` with `@discardableResult func subscribe(_:) -> UUID`, `func unsubscribe(_:)`, `func publish(_:)`
  - `final class PixelBufferImageRenderer` with `func render(_:completion:)`
  - `GeminiSessionViewModel.sendVideoFrame(image:)`
  - `WebRTCSessionViewModel.pushVideoFrame(_ pixelBuffer: CVPixelBuffer)`
  - `IPhoneCameraManager.onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?`, which replaces `onFrameCaptured`
  - In `StreamSessionViewModel`: `frameHub`, `ingestGlassesSample(_:)`, `decodeQueue`

Behaviour is unchanged for the user: same codec (raw), resolution and fps until Task 4. Only the plumbing changes.

- [ ] **Step 1: Create `FrameHub.swift`**

```swift
import CoreMedia
import CoreVideo
import Foundation

/// One video frame from any source: the glasses (raw or decoded) or the phone camera.
struct VideoFrameSample {
  let pixelBuffer: CVPixelBuffer
  let timestamp: CMTime
}

/// Fans each frame out to its subscribers. Every source publishes a frame once;
/// each consumer (preview, Gemini, WebRTC, and later the Track Walk recorder)
/// subscribes and applies its own rate. Subscribers run on the main actor and
/// must return quickly: anything expensive goes to a background queue.
@MainActor
final class FrameHub {
  typealias Subscriber = (VideoFrameSample) -> Void

  private var subscribers: [UUID: Subscriber] = [:]

  @discardableResult
  func subscribe(_ subscriber: @escaping Subscriber) -> UUID {
    let id = UUID()
    subscribers[id] = subscriber
    return id
  }

  func unsubscribe(_ id: UUID) {
    subscribers[id] = nil
  }

  func publish(_ frame: VideoFrameSample) {
    for subscriber in subscribers.values {
      subscriber(frame)
    }
  }
}
```

- [ ] **Step 2: Create `PixelBufferImageRenderer.swift`**

```swift
import CoreImage
import CoreVideo
import UIKit

/// Renders pixel buffers to UIImages on a background queue. Uses a CPU
/// CIContext so it keeps working while the phone is locked, when iOS suspends
/// GPU rendering for background apps.
final class PixelBufferImageRenderer {
  private let queue = DispatchQueue(label: "frame-image-render", qos: .userInitiated)
  private let context = CIContext(options: [.useSoftwareRenderer: true])

  func render(_ pixelBuffer: CVPixelBuffer, completion: @escaping @MainActor (UIImage) -> Void) {
    queue.async { [context] in
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
      let image = UIImage(cgImage: cgImage)
      Task { @MainActor in
        completion(image)
      }
    }
  }
}
```

- [ ] **Step 3: Add both files to the ViewModels group in `project.pbxproj`**

Use the same four-place pattern as `GlassesEventLogStore.swift` (IDs `A1B2C3D42F0A000100000007` / `A1B2C3D42F0A000200000007`), with new IDs:
- `A1B2C3D42F0A000100000009 /* FrameHub.swift */` file reference, and `A1B2C3D42F0A000200000009 /* FrameHub.swift in Sources */` build file.
- `A1B2C3D42F0A00010000000A /* PixelBufferImageRenderer.swift */` file reference, and `A1B2C3D42F0A00020000000A /* PixelBufferImageRenderer.swift in Sources */` build file.
- Add both file references as children of the ViewModels group (`8FD96B702E6F0A9800F56AB1`, the group that lists `VideoDecoder.swift`).
- Add both build files to the app target's `PBXSourcesBuildPhase`: the one that lists `StreamSessionViewModel.swift in Sources`.
- Check that each ID appears in the expected places (2 for a file-ref ID, 2 for a build-file ID).

- [ ] **Step 4: Gemini — remove the second throttle**

In `GeminiSessionViewModel.swift`, replace `sendVideoFrameIfThrottled(image:)` with:

```swift
  /// Sends one frame to Gemini. The caller (StreamSessionViewModel's FrameHub
  /// consumer) already limits this to GeminiConfig.videoFrameInterval.
  func sendVideoFrame(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    geminiService.sendVideoFrame(image: image)
  }
```

Delete the `private var lastVideoFrameTime: Date = .distantPast` property (line 31), which is now unused.

- [ ] **Step 5: WebRTC — take pixel buffers**

- `WebRTCSessionViewModel.swift`: change `func pushVideoFrame(_ image: UIImage)` to `func pushVideoFrame(_ pixelBuffer: CVPixelBuffer)` and its body to `webRTCClient?.pushVideoFrame(pixelBuffer)`. Keep the guard. Add `import CoreVideo` if the file lacks it.
- `WebRTCClient.swift`: change `func pushVideoFrame(_ image: UIImage)` to `func pushVideoFrame(_ pixelBuffer: CVPixelBuffer)` and its body to `videoCapturer?.pushFrame(pixelBuffer)`.
- `CustomVideoCapturer.swift`: replace `pushFrame(_ image: UIImage)` with:

```swift
  /// Push one frame into the WebRTC video track. Frames arrive as BGRA pixel
  /// buffers straight from the FrameHub, so there is no UIImage round trip.
  func pushFrame(_ pixelBuffer: CVPixelBuffer) {
    let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
    let timeStampNs = Int64(CACurrentMediaTime() * 1_000_000_000)
    let rtcFrame = RTCVideoFrame(
      buffer: rtcPixelBuffer,
      rotation: ._0,
      timeStampNs: timeStampNs
    )

    self.delegate?.capturer(self, didCapture: rtcFrame)

    frameCount += 1
    if frameCount == 1 || frameCount % 120 == 0 {
      NSLog("[WebRTC] Pushed frame #%lld (%dx%d)", frameCount,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
    }
  }
```

  Update the class doc comment's "UIImage frames" wording to "pixel-buffer frames". Keep `import UIKit`, which is needed for `CACurrentMediaTime` through QuartzCore.

- [ ] **Step 6: Phone camera publishes pixel buffers**

In `IPhoneCameraManager.swift`:
- Replace `var onFrameCaptured: ((UIImage) -> Void)?` with:
  ```swift
  /// Called on the capture queue for every frame; the FrameHub throttles per consumer.
  var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?
  ```
- Delete `private let context = CIContext()`.
- Replace the body of `captureOutput(_:didOutput:from:)` with:
  ```swift
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    onPixelBuffer?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
  ```

- [ ] **Step 7: `StreamSessionViewModel` — the hub and its consumers**

7a. Replace the property block from `// CPU-based CIContext for rendering decoded pixel buffers in background` through `private var foregroundFrameCount = 0` (the `cpuCIContext`, `videoDecoder`, `backgroundFrameCount`, `bgDiagLogged` and `foregroundFrameCount` properties with their comments) with:

```swift
  // Every source publishes each frame here once; the preview, Gemini and
  // WebRTC consumers subscribe and apply their own rates.
  private let frameHub = FrameHub()
  private let imageRenderer = PixelBufferImageRenderer()
  private var previewThrottle = FrameThrottle(minimumInterval: 1.0 / 8)
  private var geminiThrottle = FrameThrottle(minimumInterval: GeminiConfig.videoFrameInterval)
  // Compressed glasses samples (HEVC, or raw once backgrounded) are decoded
  // here, off the main thread. VideoDecoder is used only on this queue.
  private let videoDecoder = VideoDecoder()
  private let decodeQueue = DispatchQueue(label: "glasses-decode", qos: .userInitiated)
```

7b. In `init`, after `setupVideoDecoder()`, add `subscribeFrameConsumers()`.

7c. Replace `setupVideoDecoder()` entirely with:

```swift
  private func setupVideoDecoder() {
    // Runs on the decode queue; hop to the main actor to publish.
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      let frame = VideoFrameSample(
        pixelBuffer: decodedFrame.pixelBuffer,
        timestamp: decodedFrame.presentationTimeStamp)
      Task { @MainActor [weak self] in
        self?.frameHub.publish(frame)
      }
    }
  }

  private func subscribeFrameConsumers() {
    frameHub.subscribe { [weak self] frame in self?.showPreview(frame) }
    frameHub.subscribe { [weak self] frame in self?.sendToGemini(frame) }
    frameHub.subscribe { [weak self] frame in
      self?.webrtcSessionVM?.pushVideoFrame(frame.pixelBuffer)
    }
  }

  /// At most 8 preview images a second, and none while backgrounded.
  private func showPreview(_ frame: VideoFrameSample) {
    guard UIApplication.shared.applicationState != .background,
          previewThrottle.shouldPass(at: ProcessInfo.processInfo.systemUptime)
    else { return }
    imageRenderer.render(frame.pixelBuffer) { [weak self] image in
      // A render that finishes after streaming stopped must not bring a frame back.
      guard let self, self.streamingStatus != .stopped else { return }
      self.currentVideoFrame = image
      if !self.hasReceivedFirstFrame {
        self.hasReceivedFirstFrame = true
      }
    }
  }

  /// One frame a second to Gemini while Scout runs, locked screen included.
  private func sendToGemini(_ frame: VideoFrameSample) {
    guard let gemini = geminiSessionVM, gemini.isGeminiActive,
          geminiThrottle.shouldPass(at: ProcessInfo.processInfo.systemUptime)
    else { return }
    imageRenderer.render(frame.pixelBuffer) { [weak gemini] image in
      gemini?.sendVideoFrame(image: image)
    }
  }

  /// Raw samples carry a pixel buffer and publish directly. Compressed ones
  /// (HEVC, or raw once the app is backgrounded) go to the decoder, whose
  /// callback publishes.
  private func ingestGlassesSample(_ sampleBuffer: CMSampleBuffer) {
    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      frameHub.publish(VideoFrameSample(
        pixelBuffer: pixelBuffer,
        timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
      return
    }
    let decoder = videoDecoder
    decodeQueue.async { [weak self] in
      do {
        try decoder.decode(sampleBuffer)
      } catch {
        let failures = decoder.failureCount
        if failures <= 3 || failures % 120 == 0 {
          NSLog("[Stream] decode failed (#%d): %@", failures, String(describing: error))
        }
        if failures == 1 {
          let text = "decode failed: \(String(describing: error))"
          Task { @MainActor [weak self] in
            self?.logEvent(text)
          }
        }
      }
    }
  }
```

7d. In `attachStreamListeners(to:generation:)`, replace the whole `videoFrameListenerToken = stream.videoFramePublisher.listen { … }` statement (from that line through its closing `}` just before `errorListenerToken =`) with:

```swift
    // Fires in the foreground and the background, so streaming continues
    // with the screen locked.
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
      let sampleBuffer = videoFrame.sampleBuffer
      Task { @MainActor [weak self] in
        guard let self, generation == self.cameraGeneration else { return }
        self.noteDeliveredFrame(sampleBuffer)
        self.ingestGlassesSample(sampleBuffer)
      }
    }
```

(Remove the duplicate "Fires in the foreground…" comment above it if one is left.)

7e. In `startIPhoneSession()`, replace the `camera.onFrameCaptured = { … }` statement with:

```swift
    camera.onPixelBuffer = { [weak self] pixelBuffer, timestamp in
      let frame = VideoFrameSample(pixelBuffer: pixelBuffer, timestamp: timestamp)
      Task { @MainActor [weak self] in
        self?.frameHub.publish(frame)
      }
    }
```

7f. Reset the throttles when a stream starts, so the first frame always shows. In `startSession()` (after `_ = link.handle(.userStarted)`) and at the top of `startIPhoneSession()`, add:

```swift
    previewThrottle.reset()
    geminiThrottle.reset()
```

- [ ] **Step 8: Self-check by reading**

- Grep `sendVideoFrameIfThrottled|onFrameCaptured|makeUIImage|cpuCIContext|backgroundFrameCount|foregroundFrameCount|bgDiagLogged|lastVideoFrameTime` under `samples/CameraAccess/CameraAccess`: no matches.
- Grep `pushVideoFrame(`: only the FrameHub consumer and the WebRTC chain, all taking `CVPixelBuffer`.
- `PiPVideoView` still receives `viewModel.currentVideoFrame` (a `UIImage`), so it needs no change.
- `noteDeliveredFrame`, the generation guard and `beginStream()` are untouched.

- [ ] **Step 9: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj samples/CameraAccess/CameraAccess/ViewModels/FrameHub.swift samples/CameraAccess/CameraAccess/ViewModels/PixelBufferImageRenderer.swift samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift samples/CameraAccess/CameraAccess/WebRTC/WebRTCSessionViewModel.swift samples/CameraAccess/CameraAccess/WebRTC/WebRTCClient.swift samples/CameraAccess/CameraAccess/WebRTC/CustomVideoCapturer.swift samples/CameraAccess/CameraAccess/iPhone/IPhoneCameraManager.swift
git commit -m "feat(frames): FrameHub fans each frame out to preview, Gemini and WebRTC"
```

---

### Task 4: Glasses request HEVC at 720×1280, 15 fps

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift`

**Interfaces:**
- Consumes: `ingestGlassesSample(_:)` (Task 3), which already decodes compressed samples.

- [ ] **Step 1: Default to `.high`**

Change `@Published var selectedResolution: StreamingResolution = .low` to `= .high`.

- [ ] **Step 2: HEVC at 15 fps**

Replace `streamConfig()` with:

```swift
  // 15 fps: Meta's docs say per-frame compression adapts to the Bluetooth
  // budget, so asking for fewer frames leaves more bits per frame. That suits a
  // vision model reading stills, and halves the decode work while locked.
  private let requestedFrameRate: UInt = 15

  private func streamConfig() -> StreamConfiguration {
    // HEVC rather than raw: raw 720x1280 is ~1.4 MB a frame, far more than the
    // glasses link carries, so the SDK laddered down to a lower tier. HEVC is
    // 10-30x smaller, so the top tier fits. Samples arrive compressed and are
    // decoded in ingestGlassesSample.
    StreamConfiguration(
      videoCodec: VideoCodec.hvc1,
      resolution: selectedResolution,
      frameRate: requestedFrameRate)
  }
```

- [ ] **Step 3: Log the request**

In `noteDeliveredFrame`, change the first-frame log text to:
`"first frame \(size.width)x\(size.height) (requested \(resolutionLabel) @ \(requestedFrameRate) fps, HEVC)"`

- [ ] **Step 4: Commit (do not push)**

```bash
git add samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift
git commit -m "feat(glasses): request HEVC 720x1280 at 15 fps"
```

---

### Task 5: Phone mode — native preview, 1080p and pinch-to-zoom (upstream `e1d7e2f`, `0277421`)

**Files:**
- Create: `samples/CameraAccess/CameraAccess/iPhone/IPhoneCameraPreviewView.swift` (synchronized folder, so no pbxproj edit)
- Modify: `samples/CameraAccess/CameraAccess/iPhone/IPhoneCameraManager.swift`
- Modify: `samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift`
- Modify: `samples/CameraAccess/CameraAccess/Views/StreamView.swift`

**Interfaces:**
- Consumes: `IPhoneCameraManager.onPixelBuffer` (Task 3).
- Produces:
  - On `StreamSessionViewModel`: `iPhoneCaptureSession: AVCaptureSession?`, `@Published var iPhoneZoom: CGFloat`, `beginIPhoneZoomGesture()`, `updateIPhoneZoom(scale:)`.
  - On `IPhoneCameraManager`: `session`, `maxAvailableZoom`, `setZoom(_:)`.

- [ ] **Step 1: Create `IPhoneCameraPreviewView.swift`**

```swift
import AVFoundation
import SwiftUI

/// Native preview for iPhone mode.
///
/// The frames sent to the model still go through the FrameHub, but the picture
/// on screen comes straight off the capture session: AVCaptureVideoPreviewLayer
/// composites in hardware at the sensor's own resolution, so there is no
/// UIImage and no upscaling.
struct IPhoneCameraPreviewView: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewUIView {
    let view = PreviewUIView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ view: PreviewUIView, context: Context) {
    if view.previewLayer.session !== session {
      view.previewLayer.session = session
    }
  }

  final class PreviewUIView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }
}
```

- [ ] **Step 2: `IPhoneCameraManager` — session, 1080p, zoom**

- After `private var isRunning = false`, add:

```swift
  /// For AVCaptureVideoPreviewLayer: drawing the preview from the session is
  /// sharper and cheaper than displaying converted frames.
  var session: AVCaptureSession { captureSession }

  // MARK: - Zoom

  private var device: AVCaptureDevice?
  /// Beyond roughly this the wide-angle sensor is just upscaling, which costs
  /// detail rather than adding it.
  private let maxZoom: CGFloat = 8

  var maxAvailableZoom: CGFloat {
    guard let device else { return 1 }
    return min(device.activeFormat.videoMaxZoomFactor, maxZoom)
  }

  /// Zoom applied at the sensor, so it sharpens what is captured rather than
  /// enlarging a finished frame. The preview and the model's frames both follow it.
  func setZoom(_ factor: CGFloat) {
    guard let device else { return }
    let clamped = min(max(factor, 1), maxAvailableZoom)
    sessionQueue.async {
      do {
        try device.lockForConfiguration()
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
      } catch {
        NSLog("[iPhoneCamera] Zoom failed: %@", error.localizedDescription)
      }
    }
  }
```

- In `configureSession()`, replace `captureSession.sessionPreset = .medium` with:

```swift
    // 1920x1080 rather than .medium's 480x360: the preview layer shows it at
    // full quality, and the FrameHub throttles what reaches the CPU path.
    captureSession.sessionPreset =
      captureSession.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
```

- In `configureSession()`, directly after `captureSession.addInput(input)` (inside its `if`), add `device = camera`.

- [ ] **Step 3: `StreamSessionViewModel` — session and zoom API**

Add `import AVFoundation` to the imports. After `private var iPhoneCameraManager: IPhoneCameraManager?`, add:

```swift
  /// Non-nil in iPhone mode: the view draws an AVCaptureVideoPreviewLayer off
  /// the live session instead of showing converted frames.
  var iPhoneCaptureSession: AVCaptureSession? { iPhoneCameraManager?.session }

  /// Shown while pinching, and reset when the camera stops.
  @Published var iPhoneZoom: CGFloat = 1
  /// Zoom when the current pinch began; a magnify gesture reports scale
  /// relative to its own start, not to the last committed value.
  private var zoomAtGestureStart: CGFloat = 1

  func beginIPhoneZoomGesture() {
    zoomAtGestureStart = iPhoneZoom
  }

  func updateIPhoneZoom(scale: CGFloat) {
    guard let camera = iPhoneCameraManager else { return }
    let target = min(max(zoomAtGestureStart * scale, 1), camera.maxAvailableZoom)
    iPhoneZoom = target
    camera.setZoom(target)
  }
```

In `stopIPhoneSession()`, add `iPhoneZoom = 1` and `zoomAtGestureStart = 1` before `streamingMode = .glasses`.

In `showPreview(_:)` (Task 3), add a check as the first `guard` condition. In phone mode the screen uses the preview layer, so a converted image is needed only for WebRTC's picture-in-picture:

```swift
    guard streamingMode == .glasses || webrtcSessionVM?.isActive == true,
```

(This joins the existing `guard` conditions, and the `else { return }` stays.)

- [ ] **Step 4: `StreamView` — the phone preview branch**

In `StreamView`'s body, between the WebRTC `PiPVideoView(…)` branch and the `} else if let videoFrame = viewModel.currentVideoFrame, …` branch, insert:

```swift
      } else if viewModel.streamingMode == .iPhone, let session = viewModel.iPhoneCaptureSession {
        // Straight off the capture session: hardware-composited at sensor
        // resolution, rather than a converted frame stretched to fit.
        IPhoneCameraPreviewView(session: session)
          .ignoresSafeArea()
          .gesture(
            MagnifyGesture()
              .onChanged { value in viewModel.updateIPhoneZoom(scale: value.magnification) }
              .onEnded { _ in viewModel.beginIPhoneZoomGesture() }
          )
          .onAppear { viewModel.beginIPhoneZoomGesture() }
          .overlay(alignment: .topTrailing) {
            // Only while zoomed: at 1x the label is noise on top of the scene.
            if viewModel.iPhoneZoom > 1.05 {
              Text(String(format: "%.1f×", viewModel.iPhoneZoom))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.top, 60)
                .padding(.trailing, 16)
                .accessibilityLabel(String(format: "Zoom %.1f times", viewModel.iPhoneZoom))
            }
          }
          .accessibilityLabel("Camera preview. Pinch to zoom.")
```

- [ ] **Step 5: Self-check by reading**

- `iPhone/` is a synchronized group (`9D3C69602F367CF700E641A5`), so the new file needs no pbxproj entry.
- `MagnifyGesture.Value.magnification` is a `CGFloat` (iOS 17+).
- Zoom resets when the camera stops.

- [ ] **Step 6: Commit, push, and wait for CI**

```bash
git add samples/CameraAccess/CameraAccess/iPhone/IPhoneCameraPreviewView.swift samples/CameraAccess/CameraAccess/iPhone/IPhoneCameraManager.swift samples/CameraAccess/CameraAccess/ViewModels/StreamSessionViewModel.swift samples/CameraAccess/CameraAccess/Views/StreamView.swift
git commit -m "feat(iphone): native preview, 1080p capture and pinch-to-zoom"
```

The controller pushes after this task's review and after the final review: `git pull --rebase origin main`, then `git push origin main`, then watch CI (Test ScoutCore, Archive). If Archive fails with exit 65 right after green runs, suspect the Apple certificate limit first.

---

## Device checklist (end-of-project device pass; owner)

1. The glasses event log shows `first frame 720x1280 (requested 720x1280 @ 15 fps, HEVC)`, or the tier the link actually negotiated.
2. Glasses video survives locking and unlocking the phone three times, and Scout keeps receiving frames while it is locked.
3. Scout still gets about one frame a second. Ask it what it sees and it answers about the current scene.
4. Phone mode: the preview is sharp, pinch zooms up to 8× with a readout, and zoom resets after Stop.
5. **Heat check:** 15 minutes of glasses streaming with the phone locked in a pocket, with no thermal warning.

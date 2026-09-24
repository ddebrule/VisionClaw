# Plan 7: Track Walk Video Upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a Track Walk's text report is accepted, send its `.mp4` to SPECTRE: create the media item, upload the whole file in one background `PUT` that keeps going with the phone locked, then call complete. On Wi-Fi it starts at once. On cellular it asks first, through a notification the owner can answer from the lock screen. The Scout reports list shows progress, a cellular button, Retry and Delete.

**Architecture:**

- Pure rules in `ScoutCore`, tested in CI:
  - the new `uploading` state and optional upload fields on `Capture`;
  - `UploadRules`: route choice, and SPECTRE/storage reply classification;
  - `MediaRequest`: the create body.
- App side, in the existing synchronized folder `CameraAccess/TrackWalk/` (no project-file edits):
  - `SpectreMediaClient`: the three SPECTRE routes.
  - `TrackWalkUploader`: two background `URLSession`s (Wi-Fi only, and cellular allowed) and the upload driver.
  - `UploadPrompt`: the "Upload now on cellular?" notification.
  - `ScoutAppDelegate`: background-session relaunch events and early notification setup.

**Tech Stack:** SwiftUI, Swift 5 language mode, iOS 26.0, Foundation background `URLSession`, `UserNotifications`, `Network` (`NWPathMonitor`), AVFoundation (duration), XCTest through `swift test`.

**Spec:** `docs/superpowers/specs/2026-09-23-upstream-catchup-and-scout-modes-design.md` §B5 (Upload, network rule, clean-up, failures) and §B7. **The upload contract is SPECTRE's `docs/scout-media-contract.md`** (SPECTRE commit 446aa561, amended by 73444a26). Where the two disagree, the contract wins: it is what SPECTRE built. It has no `bucket` or `upload_endpoint` fields, it adds `put_url`, and "any 200 means stop retrying".

**Ruling — transport (spec §B5 spike):** the spec asks for an on-device spike before the uploader. The owner deferred every device check to one end-of-project pass, so this plan picks option **(b)**: one background `PUT` of the whole file to the contract's `put_url`. That is the only option where iOS finishes the upload with the app suspended at the cost of a single relaunch. **Cost if wrong:** a dropped connection restarts the file from zero. If the device pass shows that locked-phone uploads stall, the fallback is a TUS client, replacing only `TrackWalkUploader.advance`'s `PUT` step.

## Global Constraints

- iOS 26.0. Swift 5 mode in the app. `ScoutCore` uses swift-tools 6.0 (Swift 6 mode), is Foundation-only, and compiles into the app **without `import ScoutCore`**.
- **Do not touch the SPECTRE repo.** Read its contract only.
- Order is fixed by state: the text report first (`reportPending → reported`), then the video (`reported → uploading → done`). **Nothing uploads while `SettingsManager.shared.trackWalkReportsEnabled` is false.** Test-mode walks are already `done` and never upload.
- Every SPECTRE request carries `X-Scout-Token` and refuses redirects (`RedirectRefuser`). Success means `2xx` **with** `"ok": true` in JSON.
- Create body (`POST <spectreScoutURL>/media`):
  - `session_id`, `kind: "video"`, `mime_type: "video/mp4"`;
  - `size_bytes` (exact file size), `duration_sec` (> 0, one decimal);
  - `captured_at`: the walk's start in ISO 8601 with offset, e.g. `2023-11-14T15:13:20-07:00`;
  - `captured_tz` (IANA), `scout_context: "Track Walk"`;
  - `capture_id`: the capture's UUID, **lower-case**, the same as the text report's.
  - **No `vehicle_id`.**
- If the capture has no `mediaId`, call create. If it has one, call the token route `POST <spectreScoutURL>/media/<media_id>/token`. Both replies go through `UploadRules.classifyStart`.
- Upload: `PUT` the file to `put_url` with headers `Content-Type: video/mp4` and `x-upsert: true`, as a background `uploadTask(with:fromFile:)`. `taskDescription` = the capture UUID string.
- Complete: `POST <spectreScoutURL>/media/<media_id>/complete`, no body. Classified with `UploadRules.classifyComplete`.
- Background sessions: `<bundle id>.upload.wifi` (`allowsCellularAccess = false`) and `<bundle id>.upload.cellular`. Both have `sessionSendsLaunchEvents = true` and `isDiscretionary = false`.
- Network rule (`UploadRules.route`):
  - On Wi-Fi → Wi-Fi session.
  - Owner chose Wi-Fi only → Wi-Fi session (iOS waits for Wi-Fi).
  - Owner chose cellular → cellular session.
  - No choice yet and cellular available → **ask**, and meanwhile queue on the Wi-Fi session.
  - No network → wait.
- Clean-up: delete the local `.mp4` (and any `.mov`) **only after complete returns `.completed`**. A failed item keeps its file until the owner taps Retry or Delete.
- A storage `400/401/403` means the signature expired or was refused (the exact status is unconfirmed; see the contract). Get a fresh token and upload again, **at most 3 times** (`UploadRules.maxReuploads`), then fail with "Upload refused: storage kept refusing the video".
- New `Capture` fields are **optional**. The manifest stays at version 1.
- Before editing any `.swift` file, read `.claude/skills/swiftui-pro/SKILL.md` and follow it.
- **No Swift toolchain on this PC; CI is the compiler.** Push once, after the final review. Before pushing, run `git pull --rebase origin main`.
- Commit messages end with exactly: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## Review Focus

1. **Retrying a failed upload must not re-send the text report.** Expected: Retry goes back to `reported`, and the Outbox's report sender ignores it. Covered by `testFailedUploadDoesNotNeedSend` and `testRetryAfterUploadFailureReturnsToReported` (Task 1).
2. **A walk with no video** (lost recording) must end `done` after its report, not sit in "video waiting" forever. Covered by `testAcceptedTrackWalkWithoutVideoIsDone` (Task 1).
3. **A token that expires while the upload waits for Wi-Fi.** Expected: re-token and upload again, capped at 3. Covered by `testStorage403IsReupload` and `testReuploadCappedAtThree` (Task 1).
4. **A login-page redirect or an HTML 200** is never success. Covered by `testStartRedirectIsRejected`, `testStartHTML200IsRejected` and `testCompleteNeedsOk` (Task 1).
5. **Switching a waiting Wi-Fi upload to cellular.** Expected: the cancelled Wi-Fi task's completion is ignored, not recorded as a failure. Covered by the `abandoned` task-key check in `TrackWalkUploader.uploadFinished` (Task 3). The reviewer must check this by reading the code.

## File map

| File | Change | Task |
|---|---|---|
| `ScoutCore/Sources/ScoutCore/Capture.swift` | `uploading` state, optional upload fields, rule changes | 1 |
| `ScoutCore/Sources/ScoutCore/Upload.swift` | Create: `UploadNetwork`, `UploadRoute`, `UploadStep`, `UploadRules`, `MediaRequest` | 1 |
| `ScoutCore/Tests/ScoutCoreTests/CaptureTests.swift` | Update one test, add upload-state tests | 1 |
| `ScoutCore/Tests/ScoutCoreTests/UploadTests.swift` | Create | 1 |
| `CameraAccess/Gemini/GeminiConfig.swift` | `spectreMediaURL` | 2 |
| `CameraAccess/Gemini/SpectreScoutBridge.swift` | `RedirectRefuser` no longer `private` | 2 |
| `CameraAccess/TrackWalk/SpectreMediaClient.swift` | Create | 2 |
| `CameraAccess/Gemini/ScoutOutbox.swift` | `remove(_:)` | 2 |
| `CameraAccess/TrackWalk/TrackWalkController.swift` | Store the walk's time zone | 2 |
| `CameraAccess/TrackWalk/TrackWalkUploader.swift` | Create (uploader + session delegate) | 3 |
| `CameraAccess/TrackWalk/UploadPrompt.swift` | Create | 3 |
| `CameraAccess/TrackWalk/ScoutAppDelegate.swift` | Create | 3 |
| `CameraAccess/CameraAccessApp.swift` | Delegate adaptor; resume uploads on becoming active | 3 |
| `CameraAccess/Gemini/ScoutOutbox.swift` | Kick the uploader after a report is accepted and on Retry | 3 |
| `CameraAccess/Settings/SettingsView.swift` | Ask for notification permission when Track Walk reports are turned on | 3 |
| `CameraAccess/Settings/ScoutReportsView.swift` | Upload labels, progress, cellular button, Delete | 4 |

---

### Task 1: Upload rules in ScoutCore

**Files:**
- Modify: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/Capture.swift`
- Create: `samples/CameraAccess/ScoutCore/Sources/ScoutCore/Upload.swift`
- Modify: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/CaptureTests.swift`
- Create: `samples/CameraAccess/ScoutCore/Tests/ScoutCoreTests/UploadTests.swift`

**Interfaces:**
- Produces:
  - `CaptureState.uploading`
  - on `Capture`: `var reportAccepted: Bool?`, `var mediaId: String?`, `var uploadNetwork: UploadNetwork?`, `var uploadAttempts: Int?`, `var timeZone: String?`
  - `OutboxRules.needsUpload(_:trackWalkReportsEnabled:)`, `OutboxRules.beginUpload(_:mediaId:)`, `OutboxRules.applyUpload(_:to:)`
  - `UploadNetwork` (`wifiOnly`, `cellularAllowed`)
  - `UploadRoute` (`wifiSession`, `cellularSession`, `askUser`, `wait`)
  - `UploadStep` (`upload(mediaId:putURL:)`, `complete(mediaId:)`, `completed`, `reupload`, `rejected(String)`, `transient(String)`)
  - `UploadRules.route(for:onWiFi:cellularAvailable:)`, `UploadRules.classifyStart(status:body:)`, `UploadRules.classifyComplete(status:body:)`, `UploadRules.classifyStorage(status:mediaId:networkError:)`, `UploadRules.maxReuploads`
  - `MediaRequest.mimeType`, `MediaRequest.createBody(for:sizeBytes:durationSec:fallbackZone:)`

- [ ] **Step 1: Write the failing tests**

In `CaptureTests.swift`, **replace** `testAcceptedTrackWalkIsReported` with these two tests. A walk without a video now ends `done`.

```swift
  func testAcceptedTrackWalkWithVideoIsReported() {
    var capture = walk(state: .reportPending)
    capture.videoFileName = "22222222-3333-4444-5555-666666666666.mp4"
    OutboxRules.apply(.accepted, to: &capture)
    XCTAssertEqual(capture.state, .reported)
    XCTAssertEqual(capture.reportAccepted, true)
  }

  func testAcceptedTrackWalkWithoutVideoIsDone() {
    var capture = walk(state: .reportPending)
    capture.videoFileName = nil
    OutboxRules.apply(.accepted, to: &capture)
    XCTAssertEqual(capture.state, .done)
    XCTAssertEqual(capture.reportAccepted, true)
  }
```

Then append these tests before the final `}` of `CaptureTests`:

```swift
  private func reportedWalk() -> Capture {
    var capture = walk(state: .reportPending)
    capture.videoFileName = "22222222-3333-4444-5555-666666666666.mp4"
    OutboxRules.apply(.accepted, to: &capture)
    return capture
  }

  func testReportedWalkNeedsUploadOnlyWhenReportsEnabled() {
    let capture = reportedWalk()
    XCTAssertTrue(OutboxRules.needsUpload(capture, trackWalkReportsEnabled: true))
    XCTAssertFalse(OutboxRules.needsUpload(capture, trackWalkReportsEnabled: false))
    XCTAssertFalse(OutboxRules.needsSend(capture))
  }

  func testRaceNeverNeedsUpload() {
    var capture = race()
    OutboxRules.apply(.accepted, to: &capture)
    XCTAssertFalse(OutboxRules.needsUpload(capture))
  }

  func testBeginUploadStoresMediaId() {
    var capture = reportedWalk()
    OutboxRules.beginUpload(&capture, mediaId: "m-1")
    XCTAssertEqual(capture.state, .uploading)
    XCTAssertEqual(capture.mediaId, "m-1")
    XCTAssertTrue(OutboxRules.needsUpload(capture))
  }

  func testCompletedUploadIsDone() {
    var capture = reportedWalk()
    OutboxRules.beginUpload(&capture, mediaId: "m-1")
    OutboxRules.applyUpload(.completed, to: &capture)
    XCTAssertEqual(capture.state, .done)
    XCTAssertNil(capture.lastError)
    XCTAssertFalse(OutboxRules.needsUpload(capture))
  }

  func testInProgressStepsChangeNothing() {
    var capture = reportedWalk()
    OutboxRules.beginUpload(&capture, mediaId: "m-1")
    let before = capture
    OutboxRules.applyUpload(.complete(mediaId: "m-1"), to: &capture)
    OutboxRules.applyUpload(.upload(mediaId: "m-1", putURL: URL(string: "https://x.test/put")!), to: &capture)
    XCTAssertEqual(capture, before)
  }

  func testRejectedUploadIsFinal() {
    var capture = reportedWalk()
    OutboxRules.applyUpload(.rejected("Over 2 GB — record at 1080p or trim it"), to: &capture)
    XCTAssertEqual(capture.state, .failed)
    XCTAssertFalse(capture.retryable)
    XCTAssertEqual(capture.lastError, "Upload refused: Over 2 GB — record at 1080p or trim it")
    XCTAssertFalse(OutboxRules.needsUpload(capture))
  }

  func testTransientUploadFailureIsRetried() {
    var capture = reportedWalk()
    OutboxRules.applyUpload(.transient("offline"), to: &capture)
    XCTAssertEqual(capture.state, .failed)
    XCTAssertTrue(capture.retryable)
    XCTAssertEqual(capture.lastError, "offline")
    XCTAssertTrue(OutboxRules.needsUpload(capture))
  }

  func testFailedUploadDoesNotNeedSend() {
    var capture = reportedWalk()
    OutboxRules.applyUpload(.transient("offline"), to: &capture)
    XCTAssertFalse(OutboxRules.needsSend(capture))
  }

  func testRetryAfterUploadFailureReturnsToReported() {
    var capture = reportedWalk()
    OutboxRules.applyUpload(.rejected("Not found"), to: &capture)
    OutboxRules.retry(&capture)
    XCTAssertEqual(capture.state, .reported)
    XCTAssertTrue(capture.retryable)
    XCTAssertNil(capture.lastError)
    XCTAssertEqual(capture.uploadAttempts, 0)
    XCTAssertFalse(OutboxRules.needsSend(capture))
    XCTAssertTrue(OutboxRules.needsUpload(capture))
  }

  func testReuploadGoesBackToReported() {
    var capture = reportedWalk()
    OutboxRules.beginUpload(&capture, mediaId: "m-1")
    OutboxRules.applyUpload(.reupload, to: &capture)
    XCTAssertEqual(capture.state, .reported)
    XCTAssertEqual(capture.uploadAttempts, 1)
    XCTAssertEqual(capture.mediaId, "m-1")
  }

  func testReuploadCappedAtThree() {
    var capture = reportedWalk()
    for _ in 0..<3 { OutboxRules.applyUpload(.reupload, to: &capture) }
    XCTAssertEqual(capture.state, .failed)
    XCTAssertFalse(capture.retryable)
    XCTAssertEqual(capture.lastError, "Upload refused: storage kept refusing the video")
  }

  func testUploadFieldsRoundTrip() throws {
    var capture = reportedWalk()
    OutboxRules.beginUpload(&capture, mediaId: "m-1")
    capture.uploadNetwork = .wifiOnly
    capture.timeZone = "America/Denver"
    XCTAssertEqual(try OutboxCoding.decode(OutboxCoding.encode([capture])), [capture])
  }
```

Create `UploadTests.swift`:

```swift
import XCTest
@testable import ScoutCore

final class UploadTests: XCTestCase {
  private func walk(network: UploadNetwork? = nil) -> Capture {
    var capture = Capture(
      id: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
      mode: .trackWalk, sessionId: "c0ffee00-0000-4000-8000-000000000002",
      trackName: "Mile High", transcript: [], scoutContext: "Track Walk",
      vehicleModel: "", durationMin: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      state: .reported, videoFileName: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE.mp4")
    capture.uploadNetwork = network
    return capture
  }

  private func json(_ text: String) -> Data { Data(text.utf8) }

  // MARK: route

  func testWiFiAlwaysUsesWiFiSession() {
    XCTAssertEqual(UploadRules.route(for: walk(), onWiFi: true, cellularAvailable: false), .wifiSession)
    XCTAssertEqual(UploadRules.route(for: walk(network: .cellularAllowed), onWiFi: true, cellularAvailable: true), .wifiSession)
  }

  func testCellularWithoutChoiceAsks() {
    XCTAssertEqual(UploadRules.route(for: walk(), onWiFi: false, cellularAvailable: true), .askUser)
  }

  func testNoNetworkWithoutChoiceWaits() {
    XCTAssertEqual(UploadRules.route(for: walk(), onWiFi: false, cellularAvailable: false), .wait)
  }

  func testChosenNetworkIsUsedOffWiFi() {
    XCTAssertEqual(UploadRules.route(for: walk(network: .wifiOnly), onWiFi: false, cellularAvailable: true), .wifiSession)
    XCTAssertEqual(UploadRules.route(for: walk(network: .cellularAllowed), onWiFi: false, cellularAvailable: true), .cellularSession)
  }

  // MARK: create / token replies

  func testStartNewItemUploads() {
    let body = json(#"{"ok":true,"media_id":"m-1","path":"u/s/m-1.mp4","token":"t","upload_url":"https://s.test/tus","put_url":"https://s.test/put?token=t"}"#)
    XCTAssertEqual(UploadRules.classifyStart(status: 200, body: body),
                   .upload(mediaId: "m-1", putURL: URL(string: "https://s.test/put?token=t")!))
  }

  func testStartDuplicateWithTokenUploads() {
    let body = json(#"{"ok":true,"duplicate":true,"media_id":"m-1","path":"p","token":"t2","upload_url":"https://s.test/tus","put_url":"https://s.test/put2"}"#)
    XCTAssertEqual(UploadRules.classifyStart(status: 200, body: body),
                   .upload(mediaId: "m-1", putURL: URL(string: "https://s.test/put2")!))
  }

  func testStartAlreadyUploadedSkipsToComplete() {
    let body = json(#"{"ok":true,"duplicate":true,"already_uploaded":true,"media_id":"m-1","path":"p"}"#)
    XCTAssertEqual(UploadRules.classifyStart(status: 200, body: body), .complete(mediaId: "m-1"))
  }

  func testStartMissingPutURLIsRejected() {
    let body = json(#"{"ok":true,"media_id":"m-1","token":"t"}"#)
    XCTAssertEqual(UploadRules.classifyStart(status: 200, body: body), .rejected("Unexpected reply from SPECTRE"))
  }

  func testStartHTML200IsRejected() {
    XCTAssertEqual(UploadRules.classifyStart(status: 200, body: json("<html>login</html>")),
                   .rejected("Unexpected reply from SPECTRE"))
  }

  func testStartRedirectIsRejected() {
    XCTAssertEqual(UploadRules.classifyStart(status: 307, body: Data()),
                   .rejected("SPECTRE redirected the upload (HTTP 307)"))
  }

  func testStart400UsesSpectreMessage() {
    XCTAssertEqual(UploadRules.classifyStart(status: 400, body: json(#"{"error":"Over 15 min — trim it"}"#)),
                   .rejected("Over 15 min — trim it"))
  }

  func testStart404WithoutBody() {
    XCTAssertEqual(UploadRules.classifyStart(status: 404, body: Data()), .rejected("HTTP 404"))
  }

  func testStart500IsTransient() {
    XCTAssertEqual(UploadRules.classifyStart(status: 500, body: json(#"{"error":"Try again"}"#)),
                   .transient("SPECTRE error (HTTP 500)"))
  }

  func testStart429IsTransient() {
    XCTAssertEqual(UploadRules.classifyStart(status: 429, body: Data()), .transient("SPECTRE error (HTTP 429)"))
  }

  // MARK: complete replies

  func testCompleteOk() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 200, body: json(#"{"ok":true}"#)), .completed)
  }

  func testCompleteNeedsOk() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 200, body: json("<html></html>")),
                   .rejected("Unexpected reply from SPECTRE"))
  }

  func testComplete409IsTransient() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 409, body: json(#"{"error":"Upload not found in storage yet"}"#)),
                   .transient("Upload not found in storage yet"))
  }

  func testCompleteRefusedOrExpiredIsReupload() {
    let body = json(#"{"error":"Upload refused or expired — upload the file again"}"#)
    XCTAssertEqual(UploadRules.classifyComplete(status: 400, body: body), .reupload)
  }

  func testCompleteLimitIsRejected() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 400, body: json(#"{"error":"File type does not match"}"#)),
                   .rejected("File type does not match"))
  }

  func testCompleteRedirectIsRejected() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 302, body: Data()),
                   .rejected("SPECTRE redirected the upload (HTTP 302)"))
  }

  func testComplete500IsTransient() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 503, body: Data()), .transient("SPECTRE error (HTTP 503)"))
  }

  // MARK: storage PUT

  func testStorage200GoesToComplete() {
    XCTAssertEqual(UploadRules.classifyStorage(status: 200, mediaId: "m-1", networkError: nil), .complete(mediaId: "m-1"))
  }

  func testStorage403IsReupload() {
    XCTAssertEqual(UploadRules.classifyStorage(status: 403, mediaId: "m-1", networkError: nil), .reupload)
    XCTAssertEqual(UploadRules.classifyStorage(status: 400, mediaId: "m-1", networkError: nil), .reupload)
    XCTAssertEqual(UploadRules.classifyStorage(status: 401, mediaId: "m-1", networkError: nil), .reupload)
  }

  func testStorage413IsRejected() {
    XCTAssertEqual(UploadRules.classifyStorage(status: 413, mediaId: "m-1", networkError: nil),
                   .rejected("Video too large for storage"))
  }

  func testStorageNetworkErrorIsTransient() {
    XCTAssertEqual(UploadRules.classifyStorage(status: nil, mediaId: "m-1", networkError: "The network connection was lost."),
                   .transient("The network connection was lost."))
  }

  func testStorageNoReplyIsTransient() {
    XCTAssertEqual(UploadRules.classifyStorage(status: nil, mediaId: "m-1", networkError: nil), .transient("No reply from storage"))
  }

  func testStorage500IsTransient() {
    XCTAssertEqual(UploadRules.classifyStorage(status: 502, mediaId: "m-1", networkError: nil), .transient("Storage error (HTTP 502)"))
  }

  func testStorageRedirectIsRejected() {
    XCTAssertEqual(UploadRules.classifyStorage(status: 307, mediaId: "m-1", networkError: nil),
                   .rejected("Storage refused the upload (HTTP 307)"))
  }

  // MARK: create body

  func testCreateBody() throws {
    var capture = walk()
    capture.timeZone = "America/Denver"
    let data = try MediaRequest.createBody(for: capture, sizeBytes: 734_003_200, durationSec: 421.37)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(body["session_id"] as? String, "c0ffee00-0000-4000-8000-000000000002")
    XCTAssertEqual(body["kind"] as? String, "video")
    XCTAssertEqual(body["mime_type"] as? String, "video/mp4")
    XCTAssertEqual(body["size_bytes"] as? Int, 734_003_200)
    XCTAssertEqual(body["duration_sec"] as? Double, 421.4)
    XCTAssertEqual(body["captured_at"] as? String, "2023-11-14T15:13:20-07:00")
    XCTAssertEqual(body["captured_tz"] as? String, "America/Denver")
    XCTAssertEqual(body["scout_context"] as? String, "Track Walk")
    XCTAssertEqual(body["capture_id"] as? String, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
    XCTAssertNil(body["vehicle_id"])
    XCTAssertEqual(body.count, 9)
  }

  func testCreateBodyFallsBackToGivenZone() throws {
    let data = try MediaRequest.createBody(
      for: walk(), sizeBytes: 1, durationSec: 1, fallbackZone: TimeZone(identifier: "Asia/Tokyo")!)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(body["captured_at"] as? String, "2023-11-15T07:13:20+09:00")
    XCTAssertEqual(body["captured_tz"] as? String, "Asia/Tokyo")
  }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

No Swift toolchain on this PC. Confirm that the new names (`needsUpload`, `UploadRules`, `MediaRequest`, `reportAccepted`, `.uploading`) appear nowhere in `ScoutCore/Sources` yet: `grep -rn "needsUpload\|UploadRules\|MediaRequest\|reportAccepted" samples/CameraAccess/ScoutCore/Sources` should print nothing. CI runs `swift test`.

- [ ] **Step 3: Change `Capture.swift`**

Replace the `CaptureState` doc comment and enum with:

```swift
/// Where a capture is in its trip to SPECTRE. Race: reportPending → done.
/// Track Walk: recording → recorded → reportPending → reported → uploading → done.
/// `failed` can follow any network step; `reportAccepted` says which side of the report it is on.
public enum CaptureState: String, Codable, Sendable {
  case recording
  case recorded
  case reportPending
  case reported
  case uploading
  case done
  case failed
}
```

In `Capture`, after `public var savedToPhotos: Bool?`, add:

```swift
  /// Track Walk: SPECTRE accepted the text report, so a failure after this is the video's.
  public var reportAccepted: Bool?
  /// Track Walk: SPECTRE's media item for the video, once created.
  public var mediaId: String?
  /// Track Walk: the owner's answer to "Upload now on cellular?"; nil until asked.
  public var uploadNetwork: UploadNetwork?
  /// Track Walk: uploads storage refused (expired signature) since the last success or Retry.
  public var uploadAttempts: Int?
  /// Track Walk: the IANA time zone the walk was recorded in.
  public var timeZone: String?
```

In `init`, after `self.savedToPhotos = nil`, add:

```swift
    self.reportAccepted = nil
    self.mediaId = nil
    self.uploadNetwork = nil
    self.uploadAttempts = nil
    self.timeZone = nil
```

In `OutboxRules.needsSend`, replace the switch with:

```swift
    switch capture.state {
    case .reportPending: return true
    case .failed: return capture.retryable && capture.reportAccepted != true
    case .recording, .recorded, .reported, .uploading, .done: return false
    }
```

Replace the `.accepted` case in `apply(_:to:)` with:

```swift
    case .accepted:
      if capture.mode == .race {
        capture.state = .done
      } else {
        capture.reportAccepted = true
        capture.state = capture.videoFileName == nil ? .done : .reported
      }
      capture.lastError = nil
      capture.retryable = true
```

Replace `retry(_:)` with:

```swift
  /// The user's Retry: revives any failed capture, including a rejected one.
  /// A walk whose report SPECTRE already has goes back to its upload, never re-sending the report.
  public static func retry(_ capture: inout Capture) {
    guard capture.state == .failed else { return }
    if capture.reportAccepted == true {
      capture.state = .reported
      capture.uploadAttempts = 0
    } else {
      capture.state = .reportPending
    }
    capture.lastError = nil
    capture.retryable = true
  }
```

After `retry(_:)`, add:

```swift
  /// A Track Walk whose video still has to reach SPECTRE. `.uploading` is included:
  /// the app checks separately whether a background task is already carrying it.
  public static func needsUpload(_ capture: Capture, trackWalkReportsEnabled: Bool = true) -> Bool {
    guard capture.mode == .trackWalk, trackWalkReportsEnabled, capture.videoFileName != nil else { return false }
    switch capture.state {
    case .reported, .uploading: return true
    case .failed: return capture.retryable && capture.reportAccepted == true
    case .recording, .recorded, .reportPending, .done: return false
    }
  }

  /// SPECTRE created (or re-issued) the media item; bytes are about to move.
  public static func beginUpload(_ capture: inout Capture, mediaId: String) {
    capture.mediaId = mediaId
    capture.state = .uploading
    capture.lastError = nil
  }

  /// Records a finished upload step. `.upload` and `.complete` are steps still
  /// in progress and change nothing.
  public static func applyUpload(_ step: UploadStep, to capture: inout Capture) {
    switch step {
    case .upload, .complete:
      return
    case .completed:
      capture.state = .done
      capture.lastError = nil
      capture.retryable = true
      capture.uploadAttempts = 0
    case .reupload:
      let attempts = (capture.uploadAttempts ?? 0) + 1
      capture.uploadAttempts = attempts
      if attempts >= UploadRules.maxReuploads {
        capture.state = .failed
        capture.lastError = "Upload refused: storage kept refusing the video"
        capture.retryable = false
      } else {
        capture.state = .reported
      }
    case .rejected(let reason):
      capture.state = .failed
      capture.lastError = "Upload refused: \(reason)"
      capture.retryable = false
    case .transient(let reason):
      capture.state = .failed
      capture.lastError = reason
      capture.retryable = true
    }
  }
```

- [ ] **Step 4: Create `Upload.swift`**

```swift
import Foundation

/// How a Track Walk's video may travel. Asked once per walk, only when on cellular.
public enum UploadNetwork: String, Codable, Sendable {
  case wifiOnly
  case cellularAllowed
}

/// Which background session carries an upload, or why none starts yet.
public enum UploadRoute: Equatable, Sendable {
  case wifiSession
  case cellularSession
  /// Ask "Upload now on cellular?", and meanwhile queue on the Wi-Fi session.
  case askUser
  /// No network at all: try again when the path changes.
  case wait
}

/// One step of a video's trip to SPECTRE, decided from a reply.
public enum UploadStep: Equatable, Sendable {
  /// PUT the file to this URL, then call complete for this item.
  case upload(mediaId: String, putURL: URL)
  /// The file is in storage: call complete.
  case complete(mediaId: String)
  /// SPECTRE has the video. Delete the local copy.
  case completed
  /// Storage refused the signature (probably expired): get a fresh token and upload again.
  case reupload
  /// Final: sending again unchanged would fail the same way.
  case rejected(String)
  /// Worth trying again later.
  case transient(String)
}

/// SPECTRE's Scout media contract (SPECTRE `docs/scout-media-contract.md`), as pure decisions.
public enum UploadRules {
  public static let maxReuploads = 3
  static let refusedOrExpired = "Upload refused or expired — upload the file again"
  static let unexpectedReply = "Unexpected reply from SPECTRE"

  public static func route(for capture: Capture, onWiFi: Bool, cellularAvailable: Bool) -> UploadRoute {
    if onWiFi { return .wifiSession }
    switch capture.uploadNetwork {
    case .wifiOnly: return .wifiSession
    case .cellularAllowed: return .cellularSession
    case nil: return cellularAvailable ? .askUser : .wait
    }
  }

  /// The reply to `POST /api/scout/media` or `POST /api/scout/media/<id>/token`.
  public static func classifyStart(status: Int, body: Data) -> UploadStep {
    switch status {
    case 200...299:
      guard let json = object(body), json["ok"] as? Bool == true,
            let mediaId = json["media_id"] as? String
      else { return .rejected(unexpectedReply) }
      if json["already_uploaded"] as? Bool == true { return .complete(mediaId: mediaId) }
      guard json["token"] is String,
            let put = json["put_url"] as? String, let putURL = URL(string: put)
      else { return .rejected(unexpectedReply) }
      return .upload(mediaId: mediaId, putURL: putURL)
    case 300...399:
      return .rejected("SPECTRE redirected the upload (HTTP \(status))")
    case 400, 401, 403, 404:
      return .rejected(errorText(body) ?? "HTTP \(status)")
    default:
      return .transient("SPECTRE error (HTTP \(status))")
    }
  }

  /// The reply to `POST /api/scout/media/<id>/complete`.
  public static func classifyComplete(status: Int, body: Data) -> UploadStep {
    switch status {
    case 200...299:
      guard let json = object(body), json["ok"] as? Bool == true else { return .rejected(unexpectedReply) }
      return .completed
    case 300...399:
      return .rejected("SPECTRE redirected the upload (HTTP \(status))")
    case 409:
      return .transient("Upload not found in storage yet")
    case 400:
      let text = errorText(body)
      return text == refusedOrExpired ? .reupload : .rejected(text ?? "HTTP 400")
    case 401, 403, 404:
      return .rejected(errorText(body) ?? "HTTP \(status)")
    default:
      return .transient("SPECTRE error (HTTP \(status))")
    }
  }

  /// The whole-file PUT to storage. `status` is nil when no reply arrived.
  /// Storage reports an expired signature as a 4xx; the exact code is unconfirmed,
  /// so 400, 401 and 403 all mean "get a fresh token and upload again".
  public static func classifyStorage(status: Int?, mediaId: String, networkError: String?) -> UploadStep {
    if let networkError { return .transient(networkError) }
    guard let status else { return .transient("No reply from storage") }
    switch status {
    case 200...299: return .complete(mediaId: mediaId)
    case 400, 401, 403: return .reupload
    case 413: return .rejected("Video too large for storage")
    case 408, 429, 500...599: return .transient("Storage error (HTTP \(status))")
    default: return .rejected("Storage refused the upload (HTTP \(status))")
    }
  }

  private static func object(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func errorText(_ data: Data) -> String? {
    object(data)?["error"] as? String
  }
}

/// The body of `POST /api/scout/media` for a Track Walk video.
public enum MediaRequest {
  public static let mimeType = "video/mp4"

  private struct CreateBody: Encodable {
    let sessionId: String
    let kind: String
    let mimeType: String
    let sizeBytes: Int64
    let durationSec: Double
    let capturedAt: String
    let capturedTz: String
    let scoutContext: String
    let captureId: String

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case kind
      case mimeType = "mime_type"
      case sizeBytes = "size_bytes"
      case durationSec = "duration_sec"
      case capturedAt = "captured_at"
      case capturedTz = "captured_tz"
      case scoutContext = "scout_context"
      case captureId = "capture_id"
    }
  }

  /// `captured_at` is the walk's start, written in the zone it was recorded in
  /// (or `fallbackZone` for a walk saved before zones were stored), with its offset.
  public static func createBody(
    for capture: Capture, sizeBytes: Int64, durationSec: Double, fallbackZone: TimeZone = .current
  ) throws -> Data {
    let zone = capture.timeZone.flatMap { TimeZone(identifier: $0) } ?? fallbackZone
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = zone
    let body = CreateBody(
      sessionId: capture.sessionId,
      kind: "video",
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      durationSec: (durationSec * 10).rounded() / 10,
      capturedAt: formatter.string(from: capture.createdAt),
      capturedTz: zone.identifier,
      scoutContext: String(capture.scoutContext.prefix(100)),
      captureId: capture.id.uuidString.lowercased())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(body)
  }
}
```

- [ ] **Step 5: Check every `switch` over `CaptureState` in the app handles `.uploading`**

Run: `grep -rn "case .reported" samples/CameraAccess/CameraAccess`. Every exhaustive `switch capture.state` must now list `.uploading`. `ScoutReportsView` is rewritten in Task 4. For any other switch, add `.uploading` beside `.reported`, and list each one in the report.

- [ ] **Step 6: Commit**

```bash
git add samples/CameraAccess/ScoutCore
git commit -m "feat(upload): upload states, reply rules and create body in ScoutCore"
```

---

### Task 2: SPECTRE media client and small plumbing

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift`
- Modify: `samples/CameraAccess/CameraAccess/Gemini/SpectreScoutBridge.swift` (the `RedirectRefuser` declaration only)
- Create: `samples/CameraAccess/CameraAccess/TrackWalk/SpectreMediaClient.swift`
- Modify: `samples/CameraAccess/CameraAccess/Gemini/ScoutOutbox.swift`
- Modify: `samples/CameraAccess/CameraAccess/TrackWalk/TrackWalkController.swift`

**Interfaces:**
- Consumes: `UploadStep`, `UploadRules.classifyStart/classifyComplete`, `MediaRequest.createBody` (Task 1).
- Produces:
  - `GeminiConfig.spectreMediaURL: String`
  - internal `RedirectRefuser`
  - `SpectreMediaClient` with `create(_:sizeBytes:durationSec:) async -> UploadStep`, `token(mediaId:) async -> UploadStep` and `complete(mediaId:) async -> UploadStep`
  - `ScoutOutbox.remove(_ id: UUID)`

- [ ] **Step 1: `GeminiConfig.swift`**

After `static var spectreSessionsURL`, add:

```swift
  static var spectreMediaURL: String { spectreScoutURL + "/media" }
```

- [ ] **Step 2: `SpectreScoutBridge.swift`**

Change `private final class RedirectRefuser` to `final class RedirectRefuser`, and change its doc comment to:

```swift
/// Refuses HTTP redirects so a report or upload can never be "delivered" to a login page.
```

- [ ] **Step 3: Create `SpectreMediaClient.swift`**

```swift
import Foundation

/// SPECTRE's Scout media routes: create, token and complete. Never throws;
/// every reply becomes an `UploadStep` (see `UploadRules`).
@MainActor
final class SpectreMediaClient {
  private let session: URLSession

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    session = URLSession(configuration: config)
  }

  /// `POST /api/scout/media`. Safe to repeat: the capture_id makes SPECTRE return the same item.
  func create(_ capture: Capture, sizeBytes: Int64, durationSec: Double) async -> UploadStep {
    guard let body = try? MediaRequest.createBody(for: capture, sizeBytes: sizeBytes, durationSec: durationSec) else {
      return .rejected("Could not build the upload request")
    }
    return await post(GeminiConfig.spectreMediaURL, body: body, classify: UploadRules.classifyStart)
  }

  /// A fresh upload token for an item that already exists, fetched just before uploading.
  func token(mediaId: String) async -> UploadStep {
    await post(GeminiConfig.spectreMediaURL + "/\(mediaId)/token", body: nil, classify: UploadRules.classifyStart)
  }

  func complete(mediaId: String) async -> UploadStep {
    await post(GeminiConfig.spectreMediaURL + "/\(mediaId)/complete", body: nil, classify: UploadRules.classifyComplete)
  }

  private func post(_ address: String, body: Data?, classify: (Int, Data) -> UploadStep) async -> UploadStep {
    guard let url = URL(string: address) else { return .rejected("SPECTRE URL not configured") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(GeminiConfig.spectreUserToken, forHTTPHeaderField: "X-Scout-Token")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    do {
      let (data, response) = try await session.data(for: request, delegate: RedirectRefuser())
      guard let http = response as? HTTPURLResponse else { return .transient("No HTTP response") }
      return classify(http.statusCode, data)
    } catch {
      return .transient(error.localizedDescription)
    }
  }
}
```

- [ ] **Step 4: `ScoutOutbox.swift` — add `remove`**

After `retry(_:)`, add:

```swift
  /// Drops a capture for good (the owner's Delete). Files are the caller's to remove.
  func remove(_ id: UUID) {
    captures.removeAll { $0.id == id }
    save()
  }
```

- [ ] **Step 5: `TrackWalkController.swift` — store the walk's time zone**

Where the walk's `Capture` is created (`let capture = Capture(id: id, mode: .trackWalk, …)`), change `let` to `var`. Then add this line right after the initializer, before `ScoutOutbox.shared.add(capture)`:

```swift
    capture.timeZone = TimeZone.current.identifier
```

- [ ] **Step 6: Commit**

```bash
git add samples/CameraAccess/CameraAccess
git commit -m "feat(upload): SPECTRE media client, Outbox remove, walk time zone"
```

---

### Task 3: Background uploader, cellular prompt and app wiring

**Files:**
- Create: `samples/CameraAccess/CameraAccess/TrackWalk/TrackWalkUploader.swift`
- Create: `samples/CameraAccess/CameraAccess/TrackWalk/UploadPrompt.swift`
- Create: `samples/CameraAccess/CameraAccess/TrackWalk/ScoutAppDelegate.swift`
- Modify: `samples/CameraAccess/CameraAccess/CameraAccessApp.swift`
- Modify: `samples/CameraAccess/CameraAccess/Gemini/ScoutOutbox.swift`
- Modify: `samples/CameraAccess/CameraAccess/Settings/SettingsView.swift`

**Interfaces:**
- Consumes:
  - from Task 1: `OutboxRules.needsUpload/beginUpload/applyUpload`, `UploadRules`, `UploadRoute`, `UploadStep`, `UploadNetwork`, `MediaRequest.mimeType`;
  - from Task 2: `SpectreMediaClient`, `ScoutOutbox.remove`;
  - existing: `TrackWalkMedia.folder`, `TrackWalkMedia.url(for:ext:)`.
- Produces (used by Task 4):
  - `TrackWalkUploader.shared` (`ObservableObject`) with `progress: [UUID: Double]`, `onWiFi: Bool` and `cellularAvailable: Bool`
  - on `TrackWalkUploader`: `start()`, `resumeAll()`, `choose(_:for:)`, `delete(_:) async`
  - `UploadPrompt.shared.requestPermission()`

- [ ] **Step 1: Create `TrackWalkUploader.swift`**

```swift
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
```

- [ ] **Step 2: Create `UploadPrompt.swift`**

```swift
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
    let action = response.actionIdentifier
    await MainActor.run {
      switch action {
      case Self.uploadNow: TrackWalkUploader.shared.choose(.cellularAllowed, for: id)
      case Self.later: TrackWalkUploader.shared.choose(.wifiOnly, for: id)
      default: break  // Tapped to open the app: Scout reports offers the same choice.
      }
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }
}
```

- [ ] **Step 3: Create `ScoutAppDelegate.swift`**

```swift
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
```

- [ ] **Step 4: `CameraAccessApp.swift`**

After `@Environment(\.scenePhase) private var scenePhase`, add:

```swift
  @UIApplicationDelegateAdaptor(ScoutAppDelegate.self) private var appDelegate
```

In the `.onChange(of: scenePhase)` block, after `TrackWalkFinisher.shared.resumeAll()`, add:

```swift
            TrackWalkUploader.shared.resumeAll()
```

- [ ] **Step 5: `ScoutOutbox.swift` — hand accepted walks to the uploader**

In `send(_:)`, after the `save()` that follows `captures = OutboxRules.pruned(...)`, add:

```swift
    if captures.first(where: { $0.id == id })?.state == .reported {
      TrackWalkUploader.shared.resumeAll()
    }
```

In `retry(_:)`, after `reconcile()`, add:

```swift
    TrackWalkUploader.shared.resumeAll()  // A failed upload's Retry goes back to `reported`.
```

- [ ] **Step 6: `SettingsView.swift`**

In the save code (around line 134), `if trackWalkReportsEnabled { … }` already calls `ScoutOutbox.shared.resume()`. Add these two lines inside the same `if`:

```swift
      UploadPrompt.shared.requestPermission()
      TrackWalkUploader.shared.resumeAll()
```

- [ ] **Step 7: Self-check and commit**

Check each item by reading the code, and list the results in the report:
- (a) Every path in `advance` that inserts into `working` removes it again, through `defer`.
- (b) `uploadFinished` ignores abandoned keys and stale keys.
- (c) Nothing deletes the `.mp4` except `finish(.completed)` and `delete`.
- (d) No upload starts while `trackWalkReportsEnabled` is false.

```bash
git add samples/CameraAccess/CameraAccess
git commit -m "feat(upload): background uploader, cellular prompt, relaunch handling"
```

---

### Task 4: Scout reports list — upload status and controls

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Settings/ScoutReportsView.swift`

**Interfaces:**
- Consumes: `TrackWalkUploader.shared` (`progress`, `onWiFi`, `cellularAvailable`, `choose(_:for:)` and `delete(_:)`), `OutboxRules.needsUpload`, and `Capture.reportAccepted/uploadNetwork/savedToPhotos` (Tasks 1 and 3).

- [ ] **Step 1: Replace `ScoutReportsView.swift`**

```swift
import SwiftUI

/// The Outbox as a list: every Scout report, where it is, its upload, and Retry,
/// "Upload now on cellular" and Delete where they apply.
struct ScoutReportsView: View {
  @ObservedObject private var outbox = ScoutOutbox.shared
  @ObservedObject private var uploader = TrackWalkUploader.shared
  @State private var pendingDelete: Capture?
  @State private var confirmingDelete = false

  var body: some View {
    List {
      if outbox.captures.isEmpty {
        Text("No Scout reports yet.")
          .foregroundStyle(.secondary)
      }
      ForEach(outbox.captures.sorted { $0.createdAt > $1.createdAt }) { capture in
        row(capture)
      }
    }
    .navigationTitle("Scout reports")
    .confirmationDialog("Delete this report?", isPresented: $confirmingDelete, titleVisibility: .visible, presenting: pendingDelete) { capture in
      Button("Delete", role: .destructive) {
        Task { await uploader.delete(capture.id) }
      }
    } message: { capture in
      Text(deleteMessage(capture))
    }
  }

  private func row(_ capture: Capture) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(capture.trackName.isEmpty ? "Session" : capture.trackName)
          .font(.headline)
        Spacer()
        Text(stateLabel(capture))
          .font(.subheadline)
          .foregroundStyle(capture.state == .failed ? .red : .secondary)
      }
      Text("\(capture.mode == .trackWalk ? "Track Walk" : capture.vehicleModel) · \(capture.durationMin) min · \(capture.createdAt.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption)
        .foregroundStyle(.secondary)
      if capture.state == .uploading, let fraction = uploader.progress[capture.id] {
        ProgressView(value: fraction)
          .accessibilityLabel("Upload progress")
      }
      if let error = capture.lastError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        if capture.state == .failed {
          Button("Retry") {
            outbox.retry(capture.id)
          }
        }
        if canUploadOnCellular(capture) {
          Button("Upload now on cellular") {
            uploader.choose(.cellularAllowed, for: capture.id)
          }
        }
        if capture.state == .failed {
          Button("Delete", role: .destructive) {
            pendingDelete = capture
            confirmingDelete = true
          }
        }
      }
      .buttonStyle(.bordered)
    }
    .accessibilityElement(children: .contain)
  }

  private func canUploadOnCellular(_ capture: Capture) -> Bool {
    OutboxRules.needsUpload(capture, trackWalkReportsEnabled: SettingsManager.shared.trackWalkReportsEnabled)
      && capture.state != .failed
      && capture.uploadNetwork != .cellularAllowed
      && !uploader.onWiFi
      && uploader.cellularAvailable
  }

  /// True when the upload can run now, rather than waiting for Wi-Fi.
  private func canMove(_ capture: Capture) -> Bool {
    uploader.onWiFi || capture.uploadNetwork == .cellularAllowed
  }

  private func stateLabel(_ capture: Capture) -> String {
    switch capture.state {
    case .recording: return "Recording…"
    case .recorded: return "Processing…"
    case .reportPending:
      if capture.mode == .trackWalk && !SettingsManager.shared.trackWalkReportsEnabled {
        return "Held"
      }
      return "Sending…"
    case .reported:
      guard capture.mode == .trackWalk else { return "Sent" }
      return canMove(capture) ? "Report sent · starting upload" : "Report sent · waiting for Wi-Fi"
    case .uploading:
      if let fraction = uploader.progress[capture.id] {
        return "Uploading \(Int(fraction * 100))%"
      }
      return canMove(capture) ? "Uploading…" : "Waiting for Wi-Fi"
    case .done: return "Sent"
    case .failed:
      if capture.reportAccepted == true {
        return capture.retryable ? "Upload waiting for signal" : "Upload failed"
      }
      return capture.retryable ? "Waiting for signal" : "Failed"
    }
  }

  private func deleteMessage(_ capture: Capture) -> String {
    guard capture.mode == .trackWalk, capture.videoFileName != nil else {
      return "The report will not be sent."
    }
    if capture.savedToPhotos == true {
      return "The app's copy of the video is removed. It is still in Photos."
    }
    return "This is the only copy of the video. It will be gone for good."
  }
}
```

- [ ] **Step 2: Self-check and commit**

Read `.claude/skills/swiftui-pro/SKILL.md` and check the view against it. Accessibility: every button has a text label, and the progress bar has a label. List anything the skill flags, and what you changed, in the report.

```bash
git add samples/CameraAccess/CameraAccess/Settings/ScoutReportsView.swift
git commit -m "feat(upload): Scout reports shows upload progress, cellular choice, Delete"
```

---

## After the tasks

- Final whole-branch review (most capable model), one fix wave, one scoped re-review.
- `git pull --rebase origin main`, push once, wait for CI.
- **Carry to the device pass (owner):**
  - Lock the phone mid-upload: it completes.
  - Cellular → notification → "Later" → uploads on Starlink/Wi-Fi.
  - Kill the app mid-upload: it recovers on the next launch.
  - The SPECTRE Media tab shows the video.
- **Carry to SPECTRE (for the owner to pass along; do not edit SPECTRE):**
  - VisionClaw uses `put_url` (a whole-file `PUT`) for video, not TUS.
  - Supabase's standard upload must accept files up to 2 GB. Check the project's global upload size limit and the `session-media` bucket's limit.

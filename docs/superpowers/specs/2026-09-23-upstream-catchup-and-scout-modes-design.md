# Upstream Catch-up + Race / Track Walk Modes — Design Spec

- **Date:** 2026-09-23
- **Status:** Draft — awaiting owner review
- **Platform:** iOS only (`samples/CameraAccess/`). The owner does not use Android; Android is untouched.
- **Build order:** Part A (catch-up, Stages 1–4) ships first, stage by stage. Part B (modes) is built after Part A.
- **Companion spec (SPECTRE repo):** `SPECTRE/docs/superpowers/specs/2026-09-23-track-vision-design.md`. Its §8 is the upload contract this spec implements.

## 1. Summary

Two things, one spec:

- **Part A: upstream catch-up.** Upstream (Intent-Lab/VisionClaw) is 194 commits ahead. On 2026-07-30 (`ad462d4`) it replaced the direct Gemini client with LiveKit and a cloud gateway. We do not adopt that architecture. About 20 client-side changes are portable and worth having. The most important is the Meta DAT SDK moving from 0.4 to 0.9, because a 0.4 app gets no frames from glasses on 0.9 firmware.
- **Part B: two Scout modes.**
  - **Race:** the glasses are live with Scout_IQ, hands-free, with the phone locked in a pocket. This is today's Scout flow, hardened.
  - **Track Walk:** new. It records a real `.mp4` video with narration from the phone camera or the glasses. There is no live AI during the walk. The app posts the text report first, then uploads the video to SPECTRE for a Gemini reading.

### Background facts (verified 2026-09-23)

- **VisionClaw has never recorded video.** It sends Gemini Live one JPEG still per second at quality 0.5 (`GeminiConfig.swift:15-16`, `GeminiSessionViewModel.swift:321-328`), and nothing is saved.
- The glasses stream is requested at `.low` (360×640), raw, 24 fps (`StreamSessionViewModel.swift:92-96`).
- **Gemini Live only ever takes stills.** Full video understanding comes from the non-Live Gemini reading a recorded file, which is SPECTRE's job.
- **The model has to move off `gemini-3.1-flash-live-preview`.** Google now lists it as legacy. Gemini 3.7 Flash has no Live API support. The upgrade target is `gemini-3.8-live`, a stable release from 2026-09-15 that uses the same v1beta WebSocket endpoint.

## 2. Owner rulings (brainstorm, 2026-09-23)

1. Order: upgrades first, then the new modes. One spec covers both.
2. iOS only.
3. Track Walk has **no live AI**. It gives spoken cues only.
4. Race mode keeps **one spoken question, the vehicle**. There is no practice/qualifying distinction: Race always reports as `Driver Stand`, and SPECTRE's live session already knows the round.
5. Track Walk uses either the phone camera or the glasses. Phone Record/Stop buttons work in both cases. With the glasses, the glasses controls also work: the temple touch, and the capture button if the SDK exposes it.
6. Track Walk videos are saved to the Photos library, on by default with a Settings switch.
7. Upload rule: on Wi-Fi, upload immediately. On cellular only, **ask each time** through a lock-screen notification. "Later" waits for Wi-Fi. (The owner sometimes has Starlink.)
8. Walks normally run about 7 minutes. The hard cap is 15 minutes (SPECTRE's cap).
9. Video format: **H.264 + AAC in `.mp4`**, so the file plays on non-Apple devices.
10. Architecture: **one recorder** for both sources, and **our own small resumable (TUS) uploader** on background URLSession. No TUSKit.

---

# Part A: Upstream catch-up

Each stage is its own TestFlight build. The owner runs that stage's device checklist before the next stage starts. Commit SHAs refer to `upstream/main`.

## A1. Stage 1: Safe fixes

| Change | Upstream | Notes |
|---|---|---|
| Video decoder rebuilds after the phone locks, and prefers software decode | `f8c353b` | Without this, glasses video dies when the phone locks and never recovers. Required for Race mode. `VideoDecoder.swift` is otherwise identical to upstream. |
| Live model → `gemini-3.8-live` | none (ours) | `GeminiConfig.swift:8`. Before switching, confirm the setup message fields still match: `realtimeInputConfig`, context-window compression, output transcription, and the voice name. Also record the documented maximum session length (it feeds §B3). |
| Keychain and Wi-Fi entitlements | `53bd4d8` | Our entitlements file is empty. Upstream saw "not entitled" registration failures. **Owner action:** the provisioning profile / App ID must have the matching capabilities. |
| Info.plist: Bluetooth background mode, local-network usage string, Bonjour services | `664f4ac` (plist part only) | Enables the Wi-Fi transport on 0.9 and is harmless on 0.4. Also restrict requested frame rates to the legal set: 2, 7, 15, 24, 30. |
| Throttle preview image creation | `6d02f6a` (preview part only) | We build a UIImage on the main thread at 24 fps. Upstream saw freezes and watchdog kills from the same thing. |
| Keep the mic muted until playback has actually finished | `1a293fd` (mute part only) | Keeps Gemini from hearing the tail of its own answer. |
| Faster end-of-speech detection | `671f282` | High end-of-speech sensitivity, 400 ms silence. Trackside noise needs checking in the field. |

**Device checklist:**
- Glasses video survives locking and unlocking the phone three times.
- A Scout session connects on `gemini-3.8-live` and gets a spoken reply.
- No freeze after 10 minutes of streaming.
- The mic stays muted until the reply audio stops.

## A2. Stage 2: DAT SDK 0.4 → 0.9, auto-reconnect

- **SDK move.** Take upstream's 0.9 integration (`6d02f6a`, `9125d68`): a two-step setup (connect the device, then add the camera), with a minimum iOS of 17.2. Keep **our** frame hand-off (`sendVideoFrameIfThrottled` to Gemini, and the WebRTC capturer). Do not take any LiveKit publishing code. `StreamSessionViewModel.swift` is the conflict hot spot.
- **HFP before camera** (`15ade86`, `8a02162`). Select the glasses Bluetooth HFP input and let the route settle (~1.5 s) before starting the camera stream. This goes in `AudioManager.setupAudioSession` and the start sequence.
- **Auto-reconnect** (`650ad13`, adapted). If the glasses stream drops mid-session, keep the Gemini call alive and retry the glasses every 1.5 s until frames return or the user stops.
- **Verification gate: this is the first task of the stage, before any other Stage 2 work.** On the owner's **Oakley Meta Vanguard**:
  1. 0.9 streams video.
  2. The stream state publisher reports **temple tap (pause/resume)** and **tap-and-hold (stop)**.
  3. Find out whether the **capture button** reaches the app in any form.
  4. Donning and doffing are reported.
  Record the results in the plan. If gesture events do not reach the app, §B4's glasses controls fall back to the phone buttons only. Tell the owner before proceeding.

**Device checklist:**
- Register and stream from the Vanguards.
- Audio routes through the glasses.
- Turn the glasses off mid-session: the Gemini call survives and video returns within about 5 s of the glasses coming back.

## A3. Stage 3: Picture

- **Glasses:** HEVC stream decoded on the phone (`08312c7`, `f6880d6`), requesting `.high` at **15 fps** (the final state after upstream's tuning: `15ade86`, `c2ab295`). The frame fed to Gemini is still throttled to 1/s.
- **Phone camera:** preview drawn from the capture session, and capture at **1080p** (`e1d7e2f`). Today it is `.medium`, about 480×360. Convert a frame only when one is actually sent. Track Walk (§B4) needs this.
- **Pinch to zoom in phone mode, up to 8×** (`0277421`).

**Device checklist:**
- The log shows the negotiated glasses resolution.
- The phone preview is sharp.
- Zoom works.
- A Gemini frame is still sent once per second.

## A4. Stage 4: Glasses status and accessibility

- **"Put your glasses on" placeholder** (`0286e73`, `7adc513`, `2494f43`, `a6d7356`, adapted). Shown when no frame has arrived for about 1.5 s. Suppressed while the first frame is still loading.
- **Accessibility** (`dbd507c`, `9055363`, adapted). Labels on the `StreamView`, `NonStreamView` and `HomeScreen` controls. VoiceOver announcements for session start, session end and glasses reconnecting.

## A5. Explicitly not taken

| Category | Upstream commits / examples |
|---|---|
| LiveKit, cloud gateway, accounts, OAuth, browse, study logs, notes cards, alternative engines | `ad462d4` and descendants |
| OpenClaw | we removed it |
| Glasses/phone source-swipe UI | |
| Full-duplex echo cancellation | upstream abandoned it |
| CJK transcript fix | its commit also deletes our WebRTC folder |
| All Android commits | |
| "look_closely" sharp-still tool (`677afe8`) | Deferred. It needs a Gemini tool-call path, and could be paired later with voice "end session". |

---

# Part B: Race and Track Walk modes

## B1. Start screen

- Camera selection is unchanged: glasses or iPhone, on the existing `HomeScreenView` and `NonStreamView`.
- In `StreamView`'s `ControlsView`, the single **Scout** button becomes two: **Race** and **Track Walk**. The **Live** (WebRTC) button is unchanged, and it and the two mode buttons stay mutually exclusive, as today.
- **Race** uses the active SPECTRE session (`GET /api/scout/active-session`). If there is none: "No live session — activate one in SPECTRE first."
- **Track Walk** opens a session picker from `GET /api/scout/sessions` (§B6):
  - It lists planned and active sessions, showing track name and date.
  - The active session is pre-selected; otherwise the nearest upcoming planned session is.
  - There is no vehicle selection.

## B2. Race mode flow

1. Press **Race**. The app fetches the active session, injects the vehicle list into the system prompt, and connects.
2. **The opening sequence shrinks to one question.** Scout_IQ asks "Which vehicle — [list]?" and confirms "Locked in, <vehicle>. Go ahead." The context question is removed from `GeminiConfig.defaultSystemInstruction`.
3. **Vehicle ID.** Stop discarding vehicle IDs (`GeminiSessionViewModel.swift:50`). Match the spoken or confirmed vehicle to a garage entry. The report sends `vehicle_id` (already accepted by SPECTRE's schema) as well as `vehicle_model`.
4. **Context is fixed.** `scout_context = "Driver Stand"`, replacing keyword guessing for context.
5. **Ending.**
   - The glasses **tap-and-hold (stream stop)** ends the session and sends the report, with a spoken "Report sent to Setup_IQ".
   - Or tap **End** on the phone, as today.
   - Voice "end session" is out of scope (§A5).

## B3. Race mode resilience

- **Glasses drop:** Stage 2 auto-reconnect.
- **Gemini socket drops or hits its session limit:** reconnect with the Live API's session-resumption handle, so the conversation continues. The plan must verify that `gemini-3.8-live` supports resumption and confirm its fields.
- **The transcript is never lost.** If reconnecting fails, keep the accumulated transcript. End still sends everything captured so far. Today, a disconnect calls `stopSession()` (`GeminiSessionViewModel.swift:229`) and the transcript is lost.
- **Idle guard:**
  - After 30 minutes of silence, say "Scout still running".
  - After 45 minutes of silence, end the session and send the report.

## B4. Track Walk recording

### Start

1. Pick the source (phone or glasses), then press **Track Walk**, then confirm the session, then press **Record**.
2. **Preflight:** at least 3 GB free, or refuse with a message.
3. Spoken "Recording started". Cues play through the active output route, which is the glasses speakers when they are worn.

### Recorder

One component, `TrackWalkRecorder`, built on `AVAssetWriter`, fed by either source.

| | Phone | Glasses |
|---|---|---|
| Video input | Phone camera sample buffers | Decoded glasses frames |
| Resolution / frame rate | 1080p @ 30 fps | Glasses stream resolution @ 15 fps |
| Audio input | Phone mic | Glasses HFP mic |

- **Format:** **H.264 (AVC), about 10 Mbps, with AAC mono audio, in `.mp4`.** That is about 0.5 GB for 7 minutes and about 1.1 GB for 15 minutes.
- **Audio source:** the recorder owns its own audio capture, because no Gemini session runs during a walk, so there is no contention with `AudioManager`'s tap.
- **Crash safety:** a **fragmented MP4** (`movieFragmentInterval` of a few seconds). If the app crashes or the battery dies, everything except the last few seconds stays playable and uploadable.
- **Pausing:** paused time is removed from the file by timestamp offsetting, so there are no dead gaps.

### Controls

| Action | Phone | Glasses (subject to the §A2 gate) |
|---|---|---|
| Pause / resume | Pause button | Temple tap |
| Finish | Stop button | Temple tap-and-hold; capture button if exposed |

- **Doff:** taking the glasses off pauses the recording. If they stay off for 2 minutes, the recording finishes.
- **Cues:**
  - "Paused" and "Recording" on pause and resume.
  - "Two minutes left" at 13:00.
  - Automatic stop at 15:00 with "Stopped".
- **Storage full mid-recording:** stop, finalize, and say "Storage full, saved".

### After Stop

1. **Save to Photos** (add-only permission) when the Settings switch is on. It is on by default.
2. **Transcribe on the device.** Run on-device speech-to-text over the recorded audio. SPECTRE's `POST /api/scout` requires at least one transcript entry, and its Track Walk layout extraction reads the narration. The plan chooses the API: `SpeechAnalyzer` on iOS 26+, with `SFSpeechRecognizer` in on-device mode as the fallback. Transcription must work offline.
   - If the walk was silent or recognition fails, send a single entry: "(no narration captured)". The text-first order is kept either way.
3. **Text report first:** `POST /api/scout` with `scout_context = "Track Walk"`, the selected `session_id`, and `duration_min`.
4. **Queue the video for upload (§B5).**

## B5. Upload

### Contract

This follows SPECTRE track-vision spec §8.

1. `POST /api/scout/media` (with `X-Scout-Token`) and body `{session_id, kind:"video", mime_type:"video/mp4", size_bytes, duration_sec, captured_at, scout_context:"Track Walk"}`. The response is `{media_id, bucket, path, token, upload_endpoint}`.
2. TUS upload to `upload_endpoint` with `x-signature: <token>`, in **6 MB** chunks.
3. `POST /api/scout/media/<media_id>/complete` (with `X-Scout-Token`).

### Uploader

`ScoutUploader`, our own minimal TUS client:

- **Persistence:** jobs are stored on disk (a JSON manifest in Application Support) and survive app kill and reboot.
- **Chunks:** each chunk is written to a temporary file and sent as a **background `URLSession` upload task**. iOS keeps sending while the phone is locked or the app is suspended.
- **Resume:** after any interruption, send `HEAD` to read `Upload-Offset` and resume from there.
- **Expired token** (24 h): request a new token for the same `media_id` and continue.
- **Complete:** retried until it succeeds. SPECTRE's complete is idempotent.
- **Order:** a video job does not start until its text report has succeeded.

### Network rule

- **On Wi-Fi:** start immediately.
- **On cellular only:** post a local notification, "Upload now on cellular?", with **Yes** and **Later** actions that can be answered from the lock screen.
  - **Yes:** upload with `allowsCellularAccess = true`.
  - **Later:** restrict to Wi-Fi. The job starts automatically when Wi-Fi appears.

### UI

An **Uploads** list shows each walk as one of:
- waiting for Wi-Fi
- uploading (with a percentage)
- done
- failed, with **Retry**

### Clean-up

Delete the app's working copy only after `complete` succeeds. The Photos copy is untouched.

### Failures

| Situation | Result |
|---|---|
| Text report fails | Retried automatically. The video waits behind it. |
| Signal drops mid-upload | Resume from the server offset. |
| App killed or phone rebooted | Resumes on the next launch from the manifest. |
| SPECTRE rejects the request (4xx other than an expired token) | "Upload refused: <reason>". The video stays in Photos, and the job is marked failed. |
| `complete` fails | Retried. |

## B6. SPECTRE-side contract (implemented in the SPECTRE repo, not here)

1. **New `GET /api/scout/sessions`:**
   - Auth: `X-Scout-Token`, with the same lookup as `/api/scout/active-session`.
   - Returns the owner's sessions with `status in ('planned','active')`: `[{session_id, track, status, date}]`. Here `date` is the session's event date, from whichever column SPECTRE's `sessions` schema actually uses, as an ISO date. No vehicles, because Track Walk does not ask for one.
   - Sorted with active first, then planned by date ascending.
   - Must be added to the token-route allowlist in `SPECTRE/src/middleware.ts:39-41`.
2. **Fix `GET /api/scout/active-session`.** Today it uses `.single()`, which fails when two sessions are active. Return the most recently activated one instead.
3. **Track-vision spec §8 routes** (`/api/scout/media`, `/complete`) ship with that spec.
   - **Heads-up for its Task 0 gate:** through OpenRouter, Google AI Studio only accepts **YouTube** video URLs. Other video must go inline as base64. That is not practical at 0.5–1 GB, so the direct Google Files API fallback (`GEMINI_API_KEY`) is likely needed.

**Dependency:** Part B's Track Walk cannot ship until items 1 and 3 are live on SPECTRE. Race mode needs only item 2, and even that is optional.

## B7. Testing

- **Automated (XCTest, run in CI).** Add a simulator test step to `.github/workflows/build.yml`; today it only builds and ships. Tests cover pure logic, with literal expected values:
  - Vehicle matching: spoken text maps to a garage entry, including partial and fuzzy names, and no match.
  - Upload job state machine: order enforcement (the video waits for the text report), offset resume, token-expiry refresh, and the Wi-Fi/cellular rule.
  - The TUS request builder: headers and chunk boundaries at 6 MB.
  - The recorder timing math: pause offsetting, the 13:00 warning, the 15:00 stop, and the 2-minute doff finish.
  - Session-picker default selection: active, else the nearest planned session.
- **Device checklist (owner, per build).**
  - Race:
    - A pocketed, locked 10-minute Race session.
    - A glasses tap-and-hold ends it and sends the report.
    - A forced Wi-Fi drop mid-Race reconnects without losing the transcript.
  - Track Walk:
    - A phone walk (7 minutes) and a glasses walk.
    - Pause and resume, from both the phone and the glasses.
    - The video appears in Photos and plays on a Windows PC.
    - A cellular prompt answered "Later", then an auto-upload on Starlink Wi-Fi.
    - Lock the phone mid-upload: it completes.
    - Kill the app mid-upload: it resumes on the next open.
    - The SPECTRE Media tab shows the video and its description.

## 3. Risks

| Risk | Mitigation |
|---|---|
| Vanguards may not stream on 0.9, or gestures may not reach the app | The Stage 2 gate runs first, and the fallbacks are defined. |
| The `gemini-3.8-live` setup schema may differ from 3.1 preview | Verified in Stage 1 before switching. |
| Upload shipping ahead of SPECTRE's routes | Part B Track Walk ships only after SPECTRE §B6 items 1 and 3. |
| On-device transcription quality in wind and engine noise | The transcript is a supplement. Gemini hears the narration in the video itself. |

## 4. Noticed, not changed

- The project `CLAUDE.md` says the scout endpoint is rate-limited (10 requests per 60 s). SPECTRE's scout routes have **no** rate limit. Fix the doc separately if wanted.

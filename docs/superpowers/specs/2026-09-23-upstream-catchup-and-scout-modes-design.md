# Upstream Catch-up + Race / Track Walk Modes — Design Spec

- **Date:** 2026-09-23 (rev 2, after a three-model adversarial review the same day)
- **Status:** Draft — awaiting owner review
- **Platform:** iOS only (`samples/CameraAccess/`). The owner does not use Android; Android is untouched.
- **Build order:** Part A (catch-up, Stages 1–4) ships first, stage by stage. Part B (modes) is built after Part A.
- **Companion spec (SPECTRE repo):** `SPECTRE/docs/superpowers/specs/2026-09-23-track-vision-design.md`. Its §8 is the upload contract; §B6 below lists the additions and corrections SPECTRE needs.

## 0. Open questions for the owner

1. **Race ending is phone-only (§B2).** The glasses cannot tell the app that a tap-and-hold happened (§A2). Confirm this is acceptable.
2. **iPhone iOS version.** If the owner's phone is on iOS 26 or later, raise the minimum to iOS 26 and drop the `SFSpeechRecognizer` fallback (§B4). Until answered, keep the fallback.

## 1. Summary

Two things, one spec:

- **Part A: upstream catch-up.** Upstream (Intent-Lab/VisionClaw) is 194 non-merge commits ahead (201 including merges). On 2026-07-30 (`ad462d4`) it replaced the direct Gemini client with LiveKit and a cloud gateway. We do not adopt that.
  - About 20 client-side changes are worth having. Most were written *after* that rewrite, against LiveKit-era code, so each is a **re-implementation informed by the upstream diff**, not a cherry-pick. The plan must size them that way.
  - The most important is the Meta DAT SDK 0.4 → 0.9: a 0.4 app gets no frames from glasses on 0.9 firmware.
- **Part B: two Scout modes.**
  - **Race:** hands-free live Scout_IQ with the phone locked in a pocket. This is today's Scout flow, hardened.
  - **Track Walk:** new. It records a real `.mp4` with narration from the phone camera or the glasses, with no live AI. The text report is sent first, then the video goes to SPECTRE for a Gemini reading.

**Background facts (verified 2026-09-23):**

- VisionClaw has never recorded video. It sends Gemini Live one JPEG still per second at quality 0.5 (`GeminiConfig.swift:15-16`, `GeminiSessionViewModel.swift:321-328`) and saves nothing.
- The glasses stream is `.low` (360×640), raw, 24 fps (`StreamSessionViewModel.swift:92-96`).
- Gemini Live only ever takes stills. Full video understanding comes from SPECTRE's non-Live Gemini reading of the recorded file.
- `gemini-3.1-flash-live-preview` is now listed as legacy, and Gemini 3.7 Flash has no Live API. The target is `gemini-3.8-live` (stable, 2026-09-15), on the same v1beta WebSocket endpoint.

## 2. Owner rulings (brainstorm, 2026-09-23)

1. Order: upgrades first, then the new modes. One spec covers both.
2. iOS only.
3. Track Walk has **no live AI**, only spoken cues.
4. Race keeps **one spoken question, the vehicle**. There is no practice/qualifying distinction: Race always reports `scout_context = "Driver Stand"`.
5. Track Walk works from the phone camera or the glasses. Phone buttons always work.
   - Glasses controls: the owner asked for side touch and the capture button.
   - *Revised after review:* the DAT SDK does not report *why* the stream stopped, so glasses controls are limited to what the SDK can actually tell apart (§A2, §B4).
6. Track Walk videos are saved to the Photos library. This is on by default, with a Settings switch.
7. Uploads:
   - On Wi-Fi, upload immediately.
   - On cellular only, **ask each time** through a lock-screen notification.
   - "Later" waits for Wi-Fi. The owner sometimes has Starlink.
8. Walks run about 7 minutes. The hard cap is SPECTRE's 15 minutes.
9. Video format: **H.264 + AAC in `.mp4`**, playable on non-Apple devices.
10. Architecture:
    - One recorder for both sources.
    - Our own small uploader, not TUSKit.

---

# Part A: Upstream catch-up

Each stage is its own TestFlight build. The owner runs that stage's device checklist before the next stage starts. SHAs refer to `upstream/main`.

**Porting rule.** Upstream commits after `ad462d4` mix our-relevant code with LiveKit/OpenClaw code in the same hunks. Take `6d02f6a` for example: its 280 lines in `StreamSessionViewModel.swift` contain the SDK migration, the preview throttle, LiveKit frame bridging and publish tuning. **Before each stage's implementation, the plan writes a hunk map** for every cited commit: which hunks we take, which we adapt, and which we never take.

## A1. Stage 1: Safe fixes

| Change | Upstream | Notes |
|---|---|---|
| Live model → `gemini-3.8-live` | none (ours) | `GeminiConfig.swift:8`. Before switching, confirm that the setup fields still match (`realtimeInputConfig`, context-window compression, output transcription, voice name). Also confirm session resumption support and the documented maximum session length; both feed §B3. |
| Keychain and Wi-Fi entitlements | `53bd4d8` | Our entitlements file is empty. **Owner action:** enable the matching capabilities on the App ID / provisioning profile. |
| Info.plist: local-network usage string, Bonjour services, frame-rate legality | `664f4ac` (plist part) | Name the exact `UIBackgroundModes` value added. Ours already has `bluetooth-peripheral`; check whether upstream's is `bluetooth-central`. Restrict requested frame rates to 2, 7, 15, 24 or 30. |
| Throttle preview image creation | `6d02f6a` (preview hunk only, per the hunk map) | We build a UIImage on the main thread at 24 fps. Upstream saw freezes and watchdog kills from the same thing. |
| Keep the mic muted until playback has actually finished | `1a293fd` (mute part) | Stops Gemini hearing the tail of its own reply. |
| Faster end-of-speech detection | `671f282` | High end-of-speech sensitivity, 400 ms silence. Needs a trackside noise check. |
| Split `SpectreScoutBridge` into its own file | none (ours) | It currently shares `GeminiSessionViewModel.swift` (lines 1–87). This is a pure move, which prepares for §B2/§B3/§B5. |

**Device checklist:**

- A Scout session connects on `gemini-3.8-live` and gets a spoken reply.
- No freeze after 10 minutes of streaming.
- The mic stays muted until the reply audio stops.
- Glasses registration persists across an app relaunch.

## A2. Stage 2: DAT SDK 0.4 → 0.9, and reconnect

**Verification gate (task 1, before any other Stage 2 work).** On the owner's **Oakley Meta Vanguard**, with a throwaway 0.9 build, log every state and error event and record the results in the plan:

1. Does 0.9 stream video?
2. What events does each action produce?
   - Temple tap
   - Tap-and-hold
   - Capture button
   - Folding or doffing the glasses
   - Walking out of Bluetooth range

**What the docs already say:**

- `DeviceSessionState` does not expose the reason for a transition.
- No touchpad or capture-button events exist.
- The only distinguishable signal is `StreamError.hingesClosed`, which arrives on the error publisher.

**Design assumption.** The design below assumes the documented behaviour. If the gate shows more, features are added back with the owner's agreement. If it shows less (for example, no `hingesClosed` on the Vanguard), stop and tell the owner.

**The Stage 2 changes:**

- **SDK move.** Re-implement upstream's 0.9 integration (`6d02f6a`, `9125d68`) per the hunk map: the two-step device/camera setup and minimum iOS 17.2. Keep **our** frame consumers (Gemini, WebRTC). Take no LiveKit code.
- **Glasses audio route.** Port only the `prepareGlassesAudioRoute` idea (`15ade86`, `8a02162`): select the glasses HFP input and let the route settle (~1.5 s) before the camera starts. It runs *inside* our `AudioManager`'s `.playAndRecord` session. Upstream's version lives in `LiveKitSession.swift`, which we don't have.
- **Reconnect policy, per mode.** Reconnect has to be a per-mode decision, because a stop looks the same whatever caused it:
  - **Race:** any stream stop → keep the Gemini call alive, and retry the glasses every 1.5 s until frames return or the user presses End (`650ad13`, adapted).
  - **Track Walk:** see §B4. It never auto-reconnects.
  - **Idle:** no reconnect.
- **Existing tests.** `CameraAccessTests` uses 0.4 MockDevice APIs. Migrate it to 0.9 or delete it in this stage. It is not run in CI (§B7).

**Device checklist:**

- Register and stream from the Vanguards.
- Audio routes through the glasses.
- Turn the glasses off mid-Race: the call survives, and video returns within about 5 s of them coming back.

## A3. Stage 3: Picture and frame pipeline

- **One frame hub.** Replace today's four direct UIImage fan-out sites (`StreamSessionViewModel.swift:121,171,201,297`, `IPhoneCameraManager.swift:91-93`) with a small `FrameHub`.
  - Every source (glasses, decoded or raw, and the phone camera) publishes a `CVPixelBuffer` with its presentation timestamp once.
  - Consumers subscribe:
    - The preview, throttled.
    - The Gemini sender: 1/s, JPEG conversion off the main thread.
    - The WebRTC capturer.
    - In Part B, the recorder.
  - This keeps the view model out of recording, and keeps it from growing toward 1k lines.
- **Glasses:** HEVC decoded on the phone (`08312c7`, `f6880d6`), requesting `.high` at **15 fps** (`15ade86`; `c2ab295` is Android and was not taken).
- **Decoder recovery after lock** (`f8c353b`, moved here from Stage 1). The decoder rebuilds after `kVTInvalidSessionErr` and prefers software decoding. This only matters once frames are HEVC; with the raw stream it has nothing to decode. `VideoDecoder.swift` is otherwise identical to upstream.
- **Phone camera:** 1080p capture, with the preview drawn from the capture session (`e1d7e2f`).
- **Pinch to zoom in phone mode, up to 8×** (`0277421`).

**Device checklist:**

- The negotiated glasses resolution appears in the log.
- Glasses video survives locking and unlocking the phone three times.
- A Gemini frame is still sent once per second.
- Zoom works.
- **Heat check:** 15 minutes of glasses streaming with the phone locked in a pocket, with no thermal warning or throttling message.

## A4. Stage 4: Status and accessibility

- **"Put your glasses on" placeholder.** Shown after about 1.5 s with no frames, and not while the first frame is still loading (`0286e73`, `7adc513`, `2494f43`, `a6d7356`, adapted). Use `hingesClosed` where available for the "unfold your glasses" wording.
- **Accessibility labels** on the `StreamView`, `NonStreamView` and `HomeScreen` controls.
- **VoiceOver announcements** for session start, end and reconnecting (`dbd507c`, `9055363`, adapted).

## A5. Explicitly not taken

- LiveKit, the cloud gateway, accounts/OAuth, browse, study logs, notes cards, and alternative engines (`ad462d4` and everything built on it).
- OpenClaw.
- The source-swipe UI.
- Full-duplex echo cancellation (upstream abandoned it).
- The CJK transcript fix: its commit also deletes our WebRTC folder.
- All Android commits.
- The "look_closely" tool (`677afe8`). Deferred: it needs a Gemini tool-call path, and could arrive together with voice "end session" later.

---

# Part B: Race and Track Walk modes

## B1. Start screen

- Camera choice is unchanged: glasses or iPhone, on the existing `HomeScreenView` and `NonStreamView`.
- The single **Scout** button in `StreamView`'s `ControlsView` becomes **Race** and **Track Walk**. **Live** (WebRTC) is unchanged. All three stay mutually exclusive.
- **Race** uses `GET /api/scout/active-session`. If there is none: "No live session — activate one in SPECTRE first." (SPECTRE's unique index `sessions_one_active_per_profile` guarantees at most one.)
- **Track Walk** opens a session picker from `GET /api/scout/sessions` (§B6):
  - It lists planned and active sessions, with track name and date.
  - The active session is pre-selected; otherwise the planned session with the nearest `scheduled_date`.
  - There is no vehicle choice.

## B2. Race mode flow

1. Press **Race**. The app fetches the active session, injects the vehicle list into the system prompt, and connects.
2. **One opening question.** "Which vehicle — [list]?", answered with "Locked in, <vehicle>. Go ahead." Remove the context question from `GeminiConfig.defaultSystemInstruction`.
3. **The vehicle is sent as `vehicle_model`**, extracted from the conversation as today. SPECTRE already fuzzy-matches it server-side (`route.ts:91-104`). No client-side matching.
4. `scout_context = "Driver Stand"`. This replaces keyword guessing for context.
5. **Ending:** tap **End** on the phone (open question 0.1). The glasses cannot signal "end" (§A2). A stream stop in Race triggers a reconnect, never an end.

## B3. Race mode resilience

- **Glasses drop:** reconnect per §A2.
- **Gemini socket drops or hits its session limit:** reconnect using the Live API's session-resumption handle, if Stage 1 confirmed it; otherwise use a fresh connection with the transcript so far re-sent as context.
- **The transcript survives:**
  - Today, the End button hides when `isGeminiActive` goes false (`StreamView.swift:156`).
  - `scoutHistory` is wiped by the next `startSession()` (`GeminiSessionViewModel.swift:165`).
  - Fix this in state and UI: End stays available after a disconnect and sends the accumulated history. Only a successful report clears it.
- **Idle guard:**
  - After 30 minutes of silence: say "Scout still running".
  - After 45 minutes of silence: end the session and send the report.
- **The report goes through the Outbox (§B5),** so a failed send on a weak signal is saved and retried, never discarded. Today's failure path at `GeminiSessionViewModel.swift:300-317` drops it.

## B4. Track Walk

### Start

1. Pick the source, press **Track Walk**, confirm the session, then press **Record**.
2. **Preflight:**
   - At least 3 GB free.
   - The speech model is present. On iOS 26, download the `SpeechAnalyzer` locale asset now while online if it's missing.
3. The Outbox creates the walk's **Capture record** (§B5) *before* recording starts, so a crash from this point on is recoverable.
4. Spoken "Recording started".

### Audio ownership

- For the length of a walk, `TrackWalkSession` owns `AVAudioSession`: `.playAndRecord`, `allowBluetooth` for the glasses HFP mic, with the glasses route selected per §A2.
- The capture session is set to `automaticallyConfiguresApplicationAudioSession = false`, so it cannot undo the route.
- Spoken cues are played with `AVSpeechSynthesizer`. They will be audible in the recording. That's accepted: they are short, and they mark events usefully.
- Gemini is not running during a walk, so there is no conflict with `AudioManager`.

### Recorder: `TrackWalkRecorder`

- Built on `AVAssetWriter` and subscribed to `FrameHub` (§A3) for pixel buffers with timestamps.
- Audio comes from the session's mic.

| Source | Video |
|---|---|
| Phone | 1080p @ 30 fps |
| Glasses | Stream resolution @ 15 fps |

- **Format:** H.264 at about 10 Mbps for phone 1080p, scaled down by pixel count for the glasses stream, with AAC mono audio. About 0.5 GB for 7 minutes and about 1.1 GB for 15.
- **Crash safety:**
  - Write a **fragmented QuickTime `.mov`** (`movieFragmentInterval` ≈ 2 s; fragmenting is QuickTime-only).
  - On Stop, **remux with passthrough to `.mp4`**. There is no re-encode, so it is fast and lossless.
  - After a crash, the partial `.mov` is still readable and is remuxed on recovery.
- **Pausing:** paused time is removed by offsetting timestamps.
- **Phone-camera walks keep the screen awake** (`isIdleTimerDisabled`), because locking interrupts the camera. If an interruption happens anyway, the recorder treats it as a pause.

### Controls

| Action | Phone | Glasses |
|---|---|---|
| Pause / resume | Pause button | Fold or doff (`hingesClosed`) pauses. Unfold or don resumes. |
| Finish | Stop button | Any stream stop *without* `hingesClosed`: a tap-and-hold, or a drop. |

- **Doff:** if the glasses stay folded or off for 2 minutes, the walk finishes.
- **Capture button:** used only if the §A2 gate shows the app can see it.
- **Cues:** "Paused", "Recording", "Two minutes left" at 12:55, auto-stop at **14:55** with "Stopped". SPECTRE refuses anything over 15:00.
- **A Bluetooth drop finishes the walk.** There's no way to tell a drop from a tap-and-hold. The file keeps everything up to that point, and a second walk can be started.
- **Storage full:** stop, finalize, and say "Storage full, saved".

### After Stop

The Outbox advances the Capture record (§B5):

1. **Finalize:** remux to `.mp4`.
2. **Save to Photos** if the switch is on. Uses add-only permission.
3. **Transcribe on the device:** `SpeechAnalyzer` on iOS 26 or later, otherwise `SFSpeechRecognizer` with `requiresOnDeviceRecognition` (open question 0.2). Transcript entries are sent as `role: "user"`.
4. **Text report:** `POST /api/scout` with `scout_context = "Track Walk"`, the session, `duration_min`, and the capture's `capture_id`.
   - **Silent walk** (no speech recognized): send `no_narration: true` with a single placeholder entry. SPECTRE skips the layout extraction, so it doesn't overwrite earlier notes (§B6).
5. **Upload the video** (§B5).

## B5. Outbox and upload

### Outbox

One persisted queue for both modes.

- **Storage:** a JSON manifest in Application Support.
- **Each item is a `Capture`:**
  - `capture_id` (a UUID generated on the device)
  - mode
  - session
  - transcript
  - an optional video, plus its upload sub-state
  - `state`
- **States:**
  - Race: `reportPending → reported → done`.
  - Track Walk: `recording → recorded → transcribed → reportPending → reported → uploading → done`, with `failed(reason)` possible from any network step.
- **Every transition is written to disk before the step it leads to runs.** Each step is idempotent.
- **One reconciler** runs at app launch and on network change:
  - A `recording` item with no live recorder is a crash, so the reconciler recovers the partial `.mov`.
  - The reconciler then drives each item forward.
- Text-before-video order follows from the state order itself; nothing else enforces it.
- **UI:** an **Outbox / Uploads** list shows each capture's state, the upload percentage, and a **Retry** button on failures.

### Report idempotency

`POST /api/scout` carries `capture_id`. SPECTRE returns success for a `capture_id` it has already stored and does not insert again (§B6). Retries and client timeouts (60 s client vs. up to about 45 s server extraction) can then never duplicate a report, a brain turn or a follow-up.

### Upload (SPECTRE §8, as corrected in §B6)

1. `POST /api/scout/media`, returning `{media_id, bucket, path, upload_endpoint}`.
2. Get a token just in time with `POST /api/scout/media/<id>/token` (new, §B6). Tokens last **2 hours**. Never cache one across a Wi-Fi wait.
3. Create the TUS upload:
   - `POST upload_endpoint` with:
     - `Upload-Length`
     - `Upload-Metadata`: bucketName, objectName, contentType
     - `x-signature`
   - **Store the returned `Location` in the Capture before sending any bytes.**
4. Send the bytes; the method is decided by the §B5 spike below.
5. `POST /api/scout/media/<id>/complete`.

**Resume and error rules:**

- **Resume:** `HEAD Location` for `Upload-Offset`, then continue.
- **409:** re-`HEAD` and continue from the server's offset.
- **Token expired (2 h):** re-token, same `Location`, same offset.
- **`Location` expired (24 h) or 404:** create a new upload from offset 0.

**Transport spike (the first Part B task, on the device, before building the uploader).** A background `URLSession` only runs upload and download tasks from files, and every task that completes while the app is suspended costs a relaunch that iOS rations. A 1.1 GB file in 6 MB chunks is about 190 relaunches, which is likely to stall with the phone locked. Measure these options with a 500 MB file on a locked phone and pick the one that finishes:

- **(a)** Supabase TUS accepts **one `PATCH` carrying the whole remaining file** as a single background upload task.
- **(b)** A SPECTRE route issues a **standard signed upload URL** for one background `PUT` of the whole file. Resume is lost; a drop restarts the file.
- **(c)** 6 MB chunks, in the foreground while the app is active, with background tasks as a slow catch-up.

The chosen option is written into the plan. `HEAD` requests run on a separate foreground session.

**Network rule:**

- Two background session identifiers: one Wi-Fi-only (`allowsCellularAccess = false`) and one cellular-allowed. That setting is fixed per session.
- On Wi-Fi: use the Wi-Fi session immediately.
- On cellular only: post a local notification, "Upload now on cellular?", with actions:
  - **Yes:** use the cellular-allowed session.
  - **Later:** use the Wi-Fi-only session; iOS starts it when Wi-Fi appears.

**Success means a real SPECTRE response:**

- The client refuses HTTP redirects (via the `URLSession` redirect delegate).
- It treats a response as success only if it is `2xx` **with** the expected JSON fields.
- This guards against a missing middleware allowlist entry turning into a 307 to `/login` plus an HTML 200.

**Clean-up:**

- Delete the working `.mp4` only after `complete` returns a valid response.
- **If the Photos switch is off,** the working copy is the only copy. It is kept until `complete` succeeds, and if the item ends `failed` it stays until the owner taps Retry or Delete.

**Failures:**

| Situation | Result |
|---|---|
| Report send fails | Stays in `reportPending`, retried by the reconciler. The video waits. |
| Signal drops mid-upload | Resume from the server offset. |
| App killed or phone rebooted | The reconciler resumes on the next launch. |
| Crash during recording | The partial `.mov` is recovered, then the normal pipeline runs. |
| SPECTRE 4xx (other than token or URL expiry) | `failed(reason)`, shown as "Upload refused: <reason>". The local or Photos copy is kept. |

## B6. SPECTRE-side contract (implemented in the SPECTRE repo)

**1. `GET /api/scout/sessions`**

- Auth: `X-Scout-Token`, same lookup as `active-session`.
- Returns the owner's sessions with `status in ('planned','active')` as `[{session_id, track, status, scheduled_date}]`.
- Sorted active first, then planned by `scheduled_date` ascending (nulls last).

**2. Middleware**

- Cover every scout route with a prefix match: `pathname.startsWith('/api/scout/')` plus `/api/scout`.
- Today's exact-match list (`src/middleware.ts:39-42`) would redirect `/api/scout/media/<id>/complete` to `/login`.

**3. `POST /api/scout` additions**

- `capture_id` (uuid, optional): add a unique column on `scout_sessions`. On a duplicate, return `{ok:true}` without re-running anything.
- `no_narration` (boolean): skip the Track Walk layout extraction, so `sessions.track_walk_notes` is not overwritten.
- **Track Walk has no vehicle:** when `scout_context = 'Track Walk'` and no vehicle is given, store `vehicle_id = null`. Do not fall back to `vehicle_ids[0]` (`route.ts:107-109`).

**4. Track-vision §8 routes, plus:**

- `POST /api/scout/media/<id>/token`: a fresh signed upload token for the same row and path.
- Token lifetime is **2 hours** (Supabase `createSignedUploadUrl`), not 24. The 24 hours is the TUS upload URL's life. Correct track-vision §5.5 and §9 too.
- If the transport spike (§B5) picks (b), add the standard signed-upload variant.
- *Recommended, not required:* a per-token cap on open media rows. The scout token ships inside the app binary.

**5. Heads-up for track-vision Task 0**

Through OpenRouter, Google AI Studio accepts only YouTube video URLs. A 0.5–1 GB file inline as base64 is impractical, so the direct Google Files API route (`GEMINI_API_KEY`) is likely needed.

**Dependencies:**

- Track Walk ships only after items 1–4 are live.
- Race needs no SPECTRE changes. It sends `capture_id` from the start. Until item 3 ships, SPECTRE ignores the field, and retries can still duplicate.

## B7. Testing

**Automated.**

- Pure logic lives in a local Swift package, `ScoutCore`, with no UIKit, DAT or WebRTC dependencies, run with `swift test` on the macOS CI runner **before** archive.
  - A failure blocks the TestFlight upload.
  - The existing app-hosted `CameraAccessTests` is not part of this step.
- Tests use literal expected values:
  - **Outbox state machine:** every transition, idempotent re-entry at every state, and crash recovery from `recording` / `uploading`.
  - **Upload decisions:**
    - Token expiry → re-token at the same offset.
    - `Location` expiry → re-create at offset 0.
    - 409 → re-`HEAD`.
    - A redirect or non-JSON 200 is treated as failure.
  - **TUS request builder:** headers and metadata encoding.
  - **Recorder timing:** pause offsets, the 12:55 warning, the 14:55 stop, and the 2-minute doff finish.
  - **Glasses event → Track Walk action mapping:** `hingesClosed` → pause, a bare stop → finish.
  - **Session-picker default:** active first; otherwise the nearest `scheduled_date`.

**Device checklist (owner, per build).**

- Race:
  - A 10-minute session, pocketed and locked.
  - End from the phone sends the report.
  - A forced Wi-Fi drop mid-Race reconnects without losing the transcript.
  - Airplane mode at End: the report sends once signal returns.
- Track Walk:
  - A phone walk (7 minutes) and a glasses walk.
  - Fold/unfold pauses and resumes.
  - Tap-and-hold finishes.
  - The video is in Photos and plays on a Windows PC.
  - Cellular prompt → "Later" → auto-upload on Starlink.
  - Lock the phone mid-upload: it completes.
  - Kill the app mid-recording and mid-upload: both recover.
  - The SPECTRE Media tab shows the video and its description.

## 3. Risks

| Risk | Mitigation |
|---|---|
| The Vanguard on 0.9 may not stream, or may not emit `hingesClosed` | The §A2 gate runs first. Stop and tell the owner. |
| No background upload transport finishes on a locked phone | The §B5 spike runs first and picks between three options. |
| `gemini-3.8-live` schema or resumption may differ | Verified in Stage 1 before switching. §B3 has a fallback. |
| SPECTRE's cap drops below 15 minutes after its Task 0 | The recorder's stop time is a single constant. Update it if SPECTRE changes its cap. |
| On-device transcription quality in wind and engine noise | The transcript is a supplement; Gemini hears the narration in the video. |
| Software HEVC decode running alongside H.264 encode heats the phone | Stage 3 heat check. Fall back to hardware decode if it passes lock testing. |

## 4. Noticed, not changed

- The project `CLAUDE.md` says the scout endpoint is rate-limited. SPECTRE's scout routes have no rate limit.

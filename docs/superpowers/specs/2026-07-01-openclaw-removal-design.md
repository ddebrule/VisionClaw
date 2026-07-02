# OpenClaw Removal — Design Spec

- **Date:** 2026-07-01
- **Status:** Approved for planning
- **Scope:** Phase 1 of a larger program (see "Roadmap context")
- **Platform:** iOS (`samples/CameraAccess/`) **and** Android (`samples/CameraAccessAndroid/`) — removed in parity

## Summary

Remove the OpenClaw tool-calling subsystem from **both** the iOS and Android apps
in the VisionClaw fork, leaving a clean SPECTRE-focused app whose only job is:

> glasses camera + mic → Gemini Live (voice + vision) → conversation transcript → `POST /api/scout` (SPECTRE)

This is a **deletion-only refactor**. No scout behavior changes on either platform.
The result is a smaller, clearer codebase to build future features on.

## Motivation

- OpenClaw is a bridge that let Gemini call an `execute` tool routed to a local
  OpenClaw gateway. It is **not part of the SPECTRE integration** and is being
  handled in a separate repo, so it is dead weight here.
- Its `execute` tool declaration previously caused failed/wasted tool calls at
  runtime. It is currently gated behind `isOpenClawConfigured`, but the unused
  subsystem still clutters the code the user will be editing with Claude Code.
- **Both platforms are cleaned in parity** because it is unknown who runs which
  build — neither the iOS nor the Android app should ship OpenClaw.
- Removing it yields a lean base for the upcoming (future) Live Scout Feed and
  Facebook work.

## Roadmap context (NOT in this spec)

This is Phase 1 of three. Phases 2–3 are **future** and explicitly untouched here:

- **Phase 2 — Live Scout Feed:** deploy the existing WebRTC signaling server
  (`samples/CameraAccess/server/`, already Docker/Fly-ready) and wire the browser
  viewer into the SPECTRE web app. **Therefore WebRTC is PRESERVED, not removed** —
  on both platforms.
- **Phase 3 — Facebook (live broadcast + clips):** shares a video pipeline with
  Phase 2; requires Meta app review (start that registration in parallel, early).

Two architectural truths captured during design, for the future phases:
1. Today, Gemini Live and WebRTC **cannot run simultaneously** (audio-device
   conflict; the UI disables one when the other is active). Resolving this is the
   keystone of Phase 2 if scouting + streaming must happen at once.
2. The current feed is peer-to-peer **WebRTC**; Facebook Live ingests **RTMP**.
   "Both, eventually" points toward a cloud **media server** that fans one glasses
   stream out to both the SPECTRE viewers and Facebook.

## In scope — REMOVE the OpenClaw subsystem

### iOS (`samples/CameraAccess/`)

1. **`OpenClaw/` folder** — `OpenClawBridge.swift`, `ToolCallModels.swift`,
   `ToolCallRouter.swift` (includes `ToolDeclarations`, the `execute` tool, and the
   `ToolCallStatus` / `OpenClawConnectionState` types).
2. **`Gemini/GeminiConfig.swift`** — `openClawHost`/`openClawPort`/
   `openClawHookToken`/`openClawGatewayToken` accessors and `isOpenClawConfigured`.
3. **`Gemini/GeminiLiveService.swift`** — the tool advertisement in
   `sendSetupMessage()` (the `tools` array + `ToolDeclarations` reference), plus the
   now-orphaned tool-call machinery: `onToolCall`, `onToolCallCancellation`,
   `GeminiToolCall` / `GeminiToolCallCancellation` parsing, and `sendToolResponse()`.
4. **`Gemini/GeminiSessionViewModel.swift`** — `openClawBridge`, `toolCallRouter`,
   the `onToolCall` / `onToolCallCancellation` wiring, and the
   `openClawConnectionState` + `toolCallStatus` published properties + their resets.
5. **`Settings/SettingsManager.swift` + `Settings/SettingsView.swift`** — OpenClaw
   configuration fields and their Settings UI section.
6. **`Views/Components/GeminiOverlayView.swift`** — the OpenClaw connection-state /
   tool-call-status display.
7. **`Secrets.swift.example`** — OpenClaw placeholder constants.
8. **`CameraAccess.xcodeproj/project.pbxproj`** — file references and build-phase
   entries for the removed OpenClaw files.

### Android (`samples/CameraAccessAndroid/`)

Mirrors iOS. Package root:
`app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/`

1. **`openclaw/` package** — `OpenClawBridge.kt`, `ToolCallModels.kt`,
   `ToolCallRouter.kt` (includes `ToolDeclarations`, `GeminiToolCall`,
   `GeminiToolCallCancellation`).
2. **`gemini/GeminiConfig.kt`** — `openClawHost`/`openClawPort`/`openClawHookToken`/
   `openClawGatewayToken` and `isOpenClawConfigured`.
3. **`gemini/GeminiLiveService.kt`** — the `openclaw.*` imports, the tool
   advertisement in the setup message, `onToolCall` / `onToolCallCancellation`, the
   tool-call parsing, and `sendToolResponse()`.
   ⚠️ **Preserve `sendExecutor.execute { }`** — that is a Java `Executor`, unrelated
   to OpenClaw. Do not remove it.
4. **`gemini/GeminiSessionViewModel.kt`** — OpenClaw bridge/router wiring and the
   tool-call-status / connection-state exposure.
5. **`settings/SettingsManager.kt` + `ui/SettingsScreen.kt`** — OpenClaw fields and
   their Settings UI.
6. **`ui/GeminiOverlayView.kt`** — the OpenClaw status display.
7. **`Secrets.kt.example`** — OpenClaw placeholder constants.
8. **No Gradle project-file edit needed** — Android globs its source dirs, so
   deleting the `.kt` files + fixing references is sufficient (simpler than iOS).

> The implementation plan will enumerate exact symbols and line ranges per platform.
> Any Gemini tool-call *types* referenced only by the above are removed with them.

## Out of scope — KEEP untouched (both platforms)

- **DAT glasses pipeline** — stream/session view models, video decoder, and the
  registration / device / stream UI.
- **Gemini Live core** — connection/audio/video, session lifecycle, audio manager,
  `GeminiConfig` (minus OpenClaw bits).
- **SPECTRE integration** — active-session fetch + `/api/scout` POST.
- **WebRTC live-streaming subsystem** — iOS `WebRTC/` folder + `server/`, and the
  Android `webrtc/` package, plus their Settings fields. **Preserved for Phase 2.**
- **Test / dev tooling** — MockDeviceKit + DebugMenu (iOS) and any Android equivalent.
- **iPhone camera fallback.**
- **Recent scout features** — audio-only mode, proactive notifications.

## Approach (safe, staged, verifiable)

1. Work on a dedicated branch off `main` (`chore/remove-openclaw`, already created).
   Never on `main`.
2. One coherent change covering both platforms: delete the OpenClaw subsystem and
   all references. Because WebRTC stays, there are **no dependency / Swift Package /
   Gradle dependency edits** — lower risk.
3. **iOS** requires editing `project.pbxproj`; **Android** does not (Gradle globs
   sources). The plan sequences iOS and Android as two independently-verifiable
   sub-steps so a break is isolated to one platform.
4. The user builds via Xcode/TestFlight and Claude cannot run Xcode/Gradle here, so
   **verification is performed by the user at a checkpoint**, with Claude giving
   precise steps and reading any build errors pasted back.

## Verification (removal → "nothing that worked broke")

**iOS:**
- App compiles in Xcode with zero errors/warnings tied to removed symbols.
- MockDeviceKit pairs a mock glasses device.
- A mock scout session streams audio + video to Gemini and returns a spoken response.
- Ending the session POSTs a report to SPECTRE `/api/scout` successfully (HTTP 200).
- Settings renders without the OpenClaw section; the WebRTC section still present.

**Android:**
- `./gradlew assembleDebug` (or Android Studio build) succeeds with no unresolved
  references.
- Settings screen renders without the OpenClaw section; WebRTC section still present.
- ⚠️ **Known verification gap:** a full runtime scout-session test on Android needs
  an Android device + glasses paired to Android, which the user may not have. If so,
  Android verification is **compile-only** for now, and a runtime pass is deferred to
  whoever runs the Android build. This gap is accepted, not hidden.

**Both:**
- Repo-wide grep for OpenClaw / tool-call symbols comes back clean (excluding the
  unrelated Android `sendExecutor.execute`).

## Risks & mitigations

- **iOS Xcode project-file breakage** (editing `project.pbxproj`): make one clean,
  consistent edit and build immediately; the branch makes it trivially revertible.
- **Hidden coupling** (a kept file referencing an OpenClaw symbol): final grep for
  OpenClaw symbols before "done"; the Swift/Kotlin compilers also flag dangling refs.
- **Android runtime untested** (see verification gap): mitigated by a clean Gradle
  compile + symmetric parity with the verified iOS change; flagged for follow-up.
- **Accidentally removing `sendExecutor.execute`** on Android: explicitly called out
  above and in the plan; it is a thread Executor, not the OpenClaw tool.
- **Losing tool-calling we may later want:** acceptable — Phases 2–3 use the video
  pipeline, not Gemini tool calls. Re-added deliberately if a future feature needs it.

## Success criteria

Both apps build and run with **identical scout behavior**, containing **no OpenClaw
code**, ready to merge and build the next phases on. (Android runtime pass may be
deferred per the verification gap above.)

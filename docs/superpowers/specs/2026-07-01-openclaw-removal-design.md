# OpenClaw Removal — Design Spec

- **Date:** 2026-07-01
- **Status:** Approved for planning
- **Scope:** Phase 1 of a larger program (see "Roadmap context")
- **Platform:** iOS app only (`samples/CameraAccess/`)

## Summary

Remove the OpenClaw tool-calling subsystem from the VisionClaw fork, leaving a
clean SPECTRE-focused iOS app whose only job is:

> glasses camera + mic → Gemini Live (voice + vision) → conversation transcript → `POST /api/scout` (SPECTRE)

This is a **deletion-only refactor**. No scout behavior changes. The result is a
smaller, clearer codebase to build future features on.

## Motivation

- OpenClaw is a bridge that let Gemini call an `execute` tool routed to a local
  OpenClaw gateway. It is **not part of the SPECTRE integration** and is being
  handled in a separate repo, so it is dead weight here.
- Its `execute` tool declaration previously caused failed/wasted tool calls at
  runtime. It is currently gated behind `isOpenClawConfigured`, but the unused
  subsystem still clutters the code the user will be editing with Claude Code.
- Removing it yields a lean base for the upcoming (future) Live Scout Feed and
  Facebook work.

## Roadmap context (NOT in this spec)

This is Phase 1 of three. Phases 2–3 are **future** and explicitly untouched here:

- **Phase 2 — Live Scout Feed:** deploy the existing WebRTC signaling server
  (`samples/CameraAccess/server/`, already Docker/Fly-ready) and wire the browser
  viewer into the SPECTRE web app. **Therefore WebRTC is PRESERVED, not removed.**
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

1. **`OpenClaw/` folder** — `OpenClawBridge.swift`, `ToolCallModels.swift`,
   `ToolCallRouter.swift` (includes `ToolDeclarations`, the `execute` tool, and the
   `ToolCallStatus` / `OpenClawConnectionState` types).
2. **`Gemini/GeminiConfig.swift`** — `openClawHost`/`openClawPort`/
   `openClawHookToken`/`openClawGatewayToken` accessors and `isOpenClawConfigured`.
3. **`Gemini/GeminiLiveService.swift`** — the tool advertisement in
   `sendSetupMessage()` (the `tools` array + `ToolDeclarations` reference), plus the
   now-orphaned tool-call machinery: `onToolCall`, `onToolCallCancellation`,
   `GeminiToolCall` / `GeminiToolCallCancellation` parsing, and `sendToolResponse()`.
   (OpenClaw was the only tool backend, so no tool-calling remains.)
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

> The implementation plan will enumerate exact symbols and line ranges. Any Gemini
> tool-call *types* referenced only by the above are removed with them.

## Out of scope — KEEP untouched

- **DAT glasses pipeline** — `WearablesViewModel`, `StreamSessionViewModel`,
  `VideoDecoder`, and the Registration/Home/Main/Stream/NonStream views.
- **Gemini Live core** — connection/audio/video, session lifecycle, `AudioManager`,
  `GeminiConfig` (minus OpenClaw bits).
- **SPECTRE bridge** — `SpectreScoutBridge` (active-session fetch + `/api/scout` POST).
- **WebRTC live-streaming subsystem** — `WebRTC/` folder, `server/`, and its Settings
  fields. **Preserved for Phase 2.**
- **MockDeviceKit + DebugMenu** — hardware-free testing tools.
- **iPhone camera fallback.**
- **Recent scout features** — audio-only mode, proactive notifications.
- **Android app** (`CameraAccessAndroid/`) — this is an iOS-only change.

## Approach (safe, staged, verifiable)

1. Work on a dedicated branch off `main` (`chore/remove-openclaw`). Never on `main`.
2. One coherent change: delete the OpenClaw subsystem and all references. Because
   WebRTC stays, there are **no Swift Package / dependency edits** — lower risk than
   the originally-considered broader cleanup.
3. The user builds via Xcode/TestFlight and Claude cannot run Xcode here, so
   **verification is performed by the user at a checkpoint**, with Claude giving
   precise steps and reading any build errors pasted back.

## Verification (removal → "nothing that worked broke")

- App compiles in Xcode with zero errors/warnings tied to removed symbols.
- MockDeviceKit pairs a mock glasses device.
- A mock scout session streams audio + video to Gemini and returns a spoken response.
- Ending the session POSTs a report to SPECTRE `/api/scout` successfully (HTTP 200).
- Settings renders without the OpenClaw section; the WebRTC section still present.
- Repo-wide grep for OpenClaw / `execute` / tool-call symbols comes back clean.

## Risks & mitigations

- **Xcode project-file breakage** (editing `project.pbxproj`): make one clean,
  consistent edit and build immediately; the branch makes it trivially revertible.
- **Hidden coupling** (a kept file referencing an OpenClaw symbol): final grep for
  OpenClaw symbols before "done"; the Swift compiler also flags dangling references.
- **Losing tool-calling we may later want:** acceptable — Phases 2–3 use the video
  pipeline, not Gemini tool calls. If a future feature needs Gemini tools, that
  plumbing is re-added deliberately at that time.

## Success criteria

A branch that builds and runs with **identical scout behavior**, containing **no
OpenClaw code**, ready to merge and build the next phases on.

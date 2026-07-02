# VisionClaw

SwiftUI + Gemini Live app — the glasses-side of Scout_IQ in the Spectre RC racing system.

## Stack
- SwiftUI (iOS/visionOS)
- Gemini Live API (real-time audio + camera)
- Posts results to Spectre `/api/scout` endpoint via `X-Scout-Token` auth

## Auto-trigger Rules

**Before editing any `.swift` file**, invoke the `swiftui-pro` skill:
```
When about to edit or write any Swift file, read .claude/skills/swiftui-pro/SKILL.md and follow it before making changes.
```

This catches deprecated APIs, accessibility issues, and SwiftUI state management mistakes before they happen.

## Architecture
- `samples/CameraAccess/` — main project
- `Gemini/` — Gemini Live service, session view model, audio manager
- `iPhone/` — iPhone camera manager
- `Settings/` — settings manager

## Integration with Spectre
- VisionClaw → POST `/api/scout` (Spectre) with `X-Scout-Token` header
- Spectre synthesizes scout context into Setup_IQ chat
- Rate limited: 10 requests per token per 60 seconds
- Scout_IQ and Setup_IQ use separate ElevenLabs voices

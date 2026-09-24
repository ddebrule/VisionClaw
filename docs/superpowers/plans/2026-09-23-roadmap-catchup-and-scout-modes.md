# Roadmap: Upstream Catch-up + Race / Track Walk Modes

**Spec:** `docs/superpowers/specs/2026-09-23-upstream-catchup-and-scout-modes-design.md`

The spec is delivered as **seven plans**, one per verifiable stage. Each plan is written *after* the plan before it has shipped, because the later plans depend on facts that only real hardware can give: how the Vanguard glasses behave on the 0.9 SDK, and which upload method survives a locked phone. Writing their code now would mean guessing at those facts.

| # | Plan | Spec | Entry gate | Produces |
|---|---|---|---|---|
| 1 | **Stage 1: Safe fixes** (written: `2026-09-23-stage1-safe-fixes.md`) | §A1 | none | `ScoutCore` test package plus the CI test step; `gemini-3.8-live` with session resumption; mute fix; faster turn detection; preview throttle; entitlements and Info.plist; iOS 26 minimum; `SpectreScoutBridge` split out |
| 2 | Stage 2: DAT SDK 0.9 + reconnect | §A2 | Plan 1 on TestFlight and its checklist passed | **Task 1 is the Vanguard gate** (a throwaway 0.9 build that logs every event). Then the 0.9 migration, the HFP route, Race-mode glasses reconnect, and the `CameraAccessTests` migration or removal |
| 3 | Stage 3: Picture + FrameHub | §A3 | Plan 2 checklist passed | `FrameHub` (pixel buffer + timestamp); HEVC at `.high` @ 15 fps; decoder lock recovery; phone 1080p; pinch zoom; heat check |
| 4 | Stage 4: Status + accessibility | §A4 | Plan 3 checklist passed | Glasses placeholder, labels, VoiceOver announcements |
| 5 | Part B-1: Race mode + Outbox | §B1–B3, §B5 Outbox | Plan 4 shipped | Race/Track Walk buttons, one-question Race, fold-to-end, idle guard, and the persisted `Outbox` with `capture_id` (Race reports only) |
| 6 | Part B-2: Track Walk recording | §B4 | Plan 5 shipped | Session picker, `TrackWalkRecorder` (fragmented `.mov` remuxed to `.mp4`), controls, cues, Photos, `SpeechAnalyzer` transcription, the text report through the Outbox |
| 7 | Part B-3: Upload | §B5 upload | Plan 6 shipped **and** SPECTRE §B6 items 1–4 live | **Task 1 is the transport spike** on a locked phone. Then `ScoutUploader`, the network rule, the Uploads UI, and clean-up |

**SPECTRE work (a separate repo)** can proceed in parallel at any time. Hand SPECTRE §B6 of the spec, together with its own track-vision spec. Plans 5 and 6 only need SPECTRE's `capture_id` and `no_narration` fields to avoid duplicate reports; both fields are optional on the wire.

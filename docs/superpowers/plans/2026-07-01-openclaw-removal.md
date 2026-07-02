# OpenClaw Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the OpenClaw tool-calling subsystem from both the iOS and Android apps, leaving a clean SPECTRE-focused codebase (glasses → Gemini Live → `POST /api/scout`), with WebRTC live-streaming fully preserved.

**Architecture:** Deletion-only refactor. Delete the OpenClaw source folder/package on each platform, then remove every reference (config accessors, tool-call callbacks/parsing, tool advertisement, view-model wiring, settings fields, overlay UI). Sequenced iOS-first then Android so a break is isolated to one platform. No dependency, Swift Package, or Gradle changes.

**Tech Stack:** Swift/SwiftUI (iOS, Xcode 16 `objectVersion = 70`), Kotlin/Jetpack Compose (Android, Gradle).

## Global Constraints

- **Branch:** `chore/remove-openclaw` (already created off `main`). All commits land here.
- **Match by verbatim string, not line number.** Deletions shift subsequent line numbers within a file. The line numbers below are orientation only.
- **Source files are CRLF on disk; this plan's snippets are LF.** Do NOT paste an `old_string` verbatim from this plan into an Edit — a byte-exact Edit tool would fail to match every multi-line deletion. For each edit, **Read the target region first and build the `old_string` from the actual file bytes** (preserving CRLF and exact indentation). The plan's snippets are the identification guide. (Verified: all iOS/Android source and `project.pbxproj` are CRLF.)
- **swiftui-pro:** Before editing ANY `.swift` file, invoke the `swiftui-pro` skill (project convention in `CLAUDE.md`). This does not apply to `.pbxproj`, `.kt`, or `Secrets*.example` files.
- **WebRTC is PRESERVED on both platforms.** Never touch `WebRTC/` (iOS) / `webrtc/` (Android), `server/`, or any `webrtcSignalingURL` settings/secret. Each task's KEEP list calls out the WebRTC lines that sit next to removed code.
- **Android executor trap:** In `gemini/GeminiLiveService.kt`, `sendExecutor.execute { }` is a `java.util.concurrent.Executor` (thread pool), NOT the OpenClaw `execute` tool. Never remove `sendExecutor` or its `.execute` calls except as a side effect of deleting the whole `sendToolResponse` function.
- **Scope includes non-source cruft.** A "clean codebase" also means removing OpenClaw from CI (`.github/workflows/build.yml`) and docs (`README.md`, `CLAUDE.md`) — handled in Phase 3. None of these break the build, but they contradict the goal and are invisible to source-only greps.
- **Verification is performed by the user** (Claude cannot run Xcode/Gradle here). iOS = full build + runtime. Android = compile-only (accepted gap).
- **Types removed with the folder/package** (do not redeclare): iOS — `GeminiToolCall`, `GeminiToolCallCancellation`, `ToolCallStatus`, `ToolDeclarations`, `ToolCallRouter`, `OpenClawConnectionState`, `OpenClawBridge`. Android — same set. `GeminiConnectionState` (iOS) and `StreamingMode` (Android) are NOT tool types — keep them.

---

# PHASE 1 — iOS (`samples/CameraAccess/`)

> The iOS app is expected to compile only after **all** of Tasks 1–7 are complete (deletions create dangling references mid-phase). Commit per file for reviewability; run the Xcode build at the Task 8 checkpoint.

### Task 1: Delete the iOS OpenClaw folder + prune the Xcode project node

**Files:**
- Delete: `samples/CameraAccess/CameraAccess/OpenClaw/OpenClawBridge.swift`
- Delete: `samples/CameraAccess/CameraAccess/OpenClaw/ToolCallModels.swift`
- Delete: `samples/CameraAccess/CameraAccess/OpenClaw/ToolCallRouter.swift`
- Modify: `samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: removes all OpenClaw types listed in Global Constraints. Tasks 2–7 remove the now-dangling references.

**Context:** The `OpenClaw` folder is an Xcode 16 `PBXFileSystemSynchronizedRootGroup` (auto-includes files on disk), so the three `.swift` files have NO individual `PBXBuildFile`/`PBXFileReference`/build-phase entries — deleting them from disk is sufficient. Only the folder *node* (GUID `9D85EB992F35EC46006C44D1`) is referenced, in exactly 3 places.

- [ ] **Step 1: Delete the three OpenClaw source files from disk**

Remove the entire `samples/CameraAccess/CameraAccess/OpenClaw/` directory (all three files).

- [ ] **Step 2: Remove the synchronized-group node (project.pbxproj)**

Delete this line (the group definition, ~line 129):

```
		9D85EB992F35EC46006C44D1 /* OpenClaw */ = {isa = PBXFileSystemSynchronizedRootGroup; explicitFileTypes = {}; explicitFolders = (); name = OpenClaw; path = CameraAccess/OpenClaw; sourceTree = SOURCE_ROOT; };
```

- [ ] **Step 3: Remove the node from its parent group's `children` (project.pbxproj)**

The reference appears twice identically; disambiguate by context. Replace this block (~lines 217–219):

```
				8FD96B7B2E6F0A9800F56AB1 /* Info.plist */,
				9D85EB992F35EC46006C44D1 /* OpenClaw */,
			);
```

with:

```
				8FD96B7B2E6F0A9800F56AB1 /* Info.plist */,
			);
```

- [ ] **Step 4: Remove the node from the target's `fileSystemSynchronizedGroups` (project.pbxproj)**

Replace this block (~lines 307–309):

```
				9D3C69602F367CF700E641A5 /* iPhone */,
				9D85EB992F35EC46006C44D1 /* OpenClaw */,
			);
```

with:

```
				9D3C69602F367CF700E641A5 /* iPhone */,
			);
```

- [ ] **Step 5: Sanity grep**

Run: `grep -rn "9D85EB99\|OpenClawBridge\|ToolCallModels\|ToolCallRouter" "samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj"`
Expected: no matches.

- [ ] **Step 6: Commit**

```bash
git add -A "samples/CameraAccess/CameraAccess/OpenClaw" "samples/CameraAccess/CameraAccess.xcodeproj/project.pbxproj"
git commit -m "refactor(ios): delete OpenClaw folder and prune Xcode project node"
```

---

### Task 2: iOS — GeminiConfig.swift

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift`

**Interfaces:**
- Produces: removes `openClawHost/Port/HookToken/GatewayToken` and `isOpenClawConfigured`. Consumed only by the deleted folder and by Task 3's removed `sendSetupMessage` tools line.

- [ ] **Step 1: Invoke swiftui-pro** (per Global Constraints), then apply Steps 2–3.

- [ ] **Step 2: Delete the OpenClaw config accessors**

Delete (verbatim):

```swift
  static var openClawHost: String { SettingsManager.shared.openClawHost }
  static var openClawPort: Int { SettingsManager.shared.openClawPort }
  static var openClawHookToken: String { SettingsManager.shared.openClawHookToken }
  static var openClawGatewayToken: String { SettingsManager.shared.openClawGatewayToken }
```

Keep the preceding `// User-configurable values` comment and `static var apiKey...` (Gemini, not OpenClaw).

- [ ] **Step 3: Delete `isOpenClawConfigured`**

Delete (verbatim), collapsing any resulting double blank line to a single blank between `isConfigured` and `isSpectreConfigured`:

```swift
  static var isOpenClawConfigured: Bool {
    return openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
      && !openClawGatewayToken.isEmpty
      && openClawHost != "http://YOUR_MAC_HOSTNAME.local"
  }
```

- [ ] **Step 4: Commit**

```bash
git add "samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift"
git commit -m "refactor(ios): remove OpenClaw config accessors from GeminiConfig"
```

---

### Task 3: iOS — GeminiLiveService.swift

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiLiveService.swift`

**Interfaces:**
- Produces: removes `onToolCall`, `onToolCallCancellation`, `sendToolResponse`, tool advertisement, and tool-call parsing. Keeps all audio/video/transcription/connection handling and `GeminiConnectionState`.

- [ ] **Step 1: Invoke swiftui-pro**, then apply Steps 2–7.

- [ ] **Step 2: Delete the two callback properties**

```swift
  var onToolCall: ((GeminiToolCall) -> Void)?
  var onToolCallCancellation: ((GeminiToolCallCancellation) -> Void)?
```

- [ ] **Step 3: Delete the `= nil` resets in `disconnect()`**

```swift
    onToolCall = nil
    onToolCallCancellation = nil
```

- [ ] **Step 4: Delete `sendToolResponse(...)`** (collapse the resulting extra blank line before `// MARK: - Private`)

```swift
  func sendToolResponse(_ response: [String: Any]) {
    sendQueue.async { [weak self] in self?.sendJSON(response) }
  }
```

- [ ] **Step 5: Delete the tools-array construction in `sendSetupMessage()`**

```swift
    // The `execute` tool routes through the OpenClaw gateway. Only advertise it to
    // Gemini when OpenClaw is actually configured — otherwise the model is nudged to
    // call a tool that can't reach a backend, producing failed tool calls.
    let tools: [[String: Any]] = GeminiConfig.isOpenClawConfigured
      ? [["functionDeclarations": ToolDeclarations.allDeclarations()]]
      : []
```

- [ ] **Step 6: Delete the now-dangling `"tools"` dictionary entry**

```swift
        "tools": tools,
```

(The preceding `"systemInstruction": ...,` line ends with a comma and `"realtimeInputConfig"` follows, so the dictionary stays valid.)

- [ ] **Step 7: Delete the tool-call parsing in `handleMessage(...)`**

```swift
    if let toolCall = GeminiToolCall(json: json) {
      onToolCall?(toolCall)
      return
    }

    if let cancellation = GeminiToolCallCancellation(json: json) {
      onToolCallCancellation?(cancellation)
      return
    }
```

Keep `setupComplete`, `goAway`, and all `serverContent` (audio/text/turnComplete/transcription) handling.

- [ ] **Step 8: Commit**

```bash
git add "samples/CameraAccess/CameraAccess/Gemini/GeminiLiveService.swift"
git commit -m "refactor(ios): strip tool-call machinery from GeminiLiveService"
```

---

### Task 4: iOS — GeminiSessionViewModel.swift

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift`

**Interfaces:**
- Consumes: none (all removed symbols are gone by Task 1).
- Produces: removes `@Published toolCallStatus`, `@Published openClawConnectionState`, `openClawBridge`, `toolCallRouter`. Task 6 removes their UI readers. Keeps `SpectreScoutBridge` and all audio/video/transcription code.

- [ ] **Step 1: Invoke swiftui-pro**, then apply Steps 2–7.

- [ ] **Step 2: Delete the two `@Published` tool/OpenClaw state properties**

```swift
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
```

- [ ] **Step 3: Delete the bridge/router stored properties**

```swift
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
```

- [ ] **Step 4: Delete the OpenClaw check + tool-call wiring in `startSession()`**

```swift
    await openClawBridge.checkConnection()
    openClawBridge.resetSession()

    toolCallRouter = ToolCallRouter(bridge: openClawBridge)

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            self?.geminiService.sendToolResponse(response)
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }
```

- [ ] **Step 5: Delete the assignments in the `stateObservation` loop**

```swift
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        self.openClawConnectionState = self.openClawBridge.connectionState
```

Keep the two lines above them (`self.connectionState = ...`, `self.isModelSpeaking = ...`).

- [ ] **Step 6: Delete the router teardown in `stopSession()`**

```swift
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
```

- [ ] **Step 7: Delete the `toolCallStatus` reset in `stopSession()`**

```swift
    toolCallStatus = .idle
```

- [ ] **Step 8: Commit**

```bash
git add "samples/CameraAccess/CameraAccess/Gemini/GeminiSessionViewModel.swift"
git commit -m "refactor(ios): remove OpenClaw wiring from GeminiSessionViewModel"
```

---

### Task 5: iOS — Settings (SettingsManager.swift + SettingsView.swift)

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Settings/SettingsManager.swift`
- Modify: `samples/CameraAccess/CameraAccess/Settings/SettingsView.swift`

**Interfaces:**
- Produces: removes OpenClaw storage + Settings UI. Keeps all `webrtcSignalingURL` storage/UI.

- [ ] **Step 1: Invoke swiftui-pro**, then apply Steps 2–8.

- [ ] **Step 2: SettingsManager — delete the OpenClaw `Key` enum cases**

```swift
    case openClawHost
    case openClawPort
    case openClawHookToken
    case openClawGatewayToken
```

Keep `case webrtcSignalingURL`.

- [ ] **Step 3: SettingsManager — delete the OpenClaw MARK + 4 computed properties**

```swift
  // MARK: - OpenClaw

  var openClawHost: String {
    get { defaults.string(forKey: Key.openClawHost.rawValue) ?? Secrets.openClawHost }
    set { defaults.set(newValue, forKey: Key.openClawHost.rawValue) }
  }

  var openClawPort: Int {
    get {
      let stored = defaults.integer(forKey: Key.openClawPort.rawValue)
      return stored != 0 ? stored : Secrets.openClawPort
    }
    set { defaults.set(newValue, forKey: Key.openClawPort.rawValue) }
  }

  var openClawHookToken: String {
    get { defaults.string(forKey: Key.openClawHookToken.rawValue) ?? Secrets.openClawHookToken }
    set { defaults.set(newValue, forKey: Key.openClawHookToken.rawValue) }
  }

  var openClawGatewayToken: String {
    get { defaults.string(forKey: Key.openClawGatewayToken.rawValue) ?? Secrets.openClawGatewayToken }
    set { defaults.set(newValue, forKey: Key.openClawGatewayToken.rawValue) }
  }
```

Keep the `// MARK: - WebRTC` block that follows.

- [ ] **Step 4: SettingsManager — remove the OpenClaw keys from `resetAll()`**

Replace:

```swift
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .openClawHost, .openClawPort,
                .openClawHookToken, .openClawGatewayToken, .webrtcSignalingURL,
                .speakerOutputEnabled, .videoStreamingEnabled] {
```

with:

```swift
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .webrtcSignalingURL,
                .speakerOutputEnabled, .videoStreamingEnabled] {
```

- [ ] **Step 5: SettingsView — delete the OpenClaw `@State` properties**

```swift
  @State private var openClawHost: String = ""
  @State private var openClawPort: String = ""
  @State private var openClawHookToken: String = ""
  @State private var openClawGatewayToken: String = ""
```

Keep `@State private var webrtcSignalingURL`.

- [ ] **Step 6: SettingsView — delete the entire OpenClaw `Section`**

```swift
        Section(header: Text("OpenClaw"), footer: Text("Connect to an OpenClaw gateway running on your Mac for agentic tool-calling.")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Host")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("http://your-mac.local", text: $openClawHost)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Port")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("18789", text: $openClawPort)
              .keyboardType(.numberPad)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Hook Token")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Hook token", text: $openClawHookToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Gateway Token")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Gateway auth token", text: $openClawGatewayToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }
```

Keep the WebRTC `Section` that follows.

- [ ] **Step 7: SettingsView — delete the OpenClaw assignments in `loadCurrentValues()`**

```swift
    openClawHost = settings.openClawHost
    openClawPort = String(settings.openClawPort)
    openClawHookToken = settings.openClawHookToken
    openClawGatewayToken = settings.openClawGatewayToken
```

Keep `webrtcSignalingURL = settings.webrtcSignalingURL`.

- [ ] **Step 8: SettingsView — delete the OpenClaw writes in `save()`**

```swift
    settings.openClawHost = openClawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    if let port = Int(openClawPort.trimmingCharacters(in: .whitespacesAndNewlines)) {
      settings.openClawPort = port
    }
    settings.openClawHookToken = openClawHookToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.openClawGatewayToken = openClawGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
```

Keep `settings.webrtcSignalingURL = ...`.

- [ ] **Step 9: Commit**

```bash
git add "samples/CameraAccess/CameraAccess/Settings/SettingsManager.swift" "samples/CameraAccess/CameraAccess/Settings/SettingsView.swift"
git commit -m "refactor(ios): remove OpenClaw settings storage and UI"
```

---

### Task 6: iOS — Overlay UI (GeminiOverlayView.swift + StreamView.swift)

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Views/Components/GeminiOverlayView.swift`
- Modify: `samples/CameraAccess/CameraAccess/Views/StreamView.swift`

**Interfaces:**
- Consumes: `geminiVM.toolCallStatus` / `geminiVM.openClawConnectionState` (removed in Task 4) — this task removes their last readers.
- Produces: removes `ToolCallStatusView` and the OpenClaw status pill. Keeps the Gemini pill, `StatusPill`, `TranscriptView`, `SpeakingIndicator`.

- [ ] **Step 1: Invoke swiftui-pro**, then apply Steps 2–5.

- [ ] **Step 2: GeminiOverlayView — delete the OpenClaw pill in `GeminiStatusBar.body`**

```swift

      // OpenClaw connection pill
      StatusPill(color: openClawStatusColor, text: openClawStatusText)
```

Keep the Gemini pill above it.

- [ ] **Step 3: GeminiOverlayView — delete the `openClawStatusColor` / `openClawStatusText` vars**

```swift
  private var openClawStatusColor: Color {
    switch geminiVM.openClawConnectionState {
    case .connected: return .green
    case .checking: return .yellow
    case .unreachable: return .red
    case .notConfigured: return .gray
    }
  }

  private var openClawStatusText: String {
    switch geminiVM.openClawConnectionState {
    case .connected: return "OpenClaw"
    case .checking: return "OpenClaw..."
    case .unreachable: return "OpenClaw Off"
    case .notConfigured: return "No OpenClaw"
    }
  }
```

- [ ] **Step 4: GeminiOverlayView — delete the entire `ToolCallStatusView` struct**

```swift
struct ToolCallStatusView: View {
  let status: ToolCallStatus

  var body: some View {
    if status != .idle {
      HStack(spacing: 8) {
        statusIcon
        Text(status.displayText)
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(.white)
          .lineLimit(1)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(statusBackground)
      .cornerRadius(16)
    }
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch status {
    case .executing:
      ProgressView()
        .scaleEffect(0.7)
        .tint(.white)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.green)
        .font(.system(size: 14))
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundColor(.red)
        .font(.system(size: 14))
    case .cancelled:
      Image(systemName: "xmark.circle.fill")
        .foregroundColor(.yellow)
        .font(.system(size: 14))
    case .idle:
      EmptyView()
    }
  }

  private var statusBackground: Color {
    switch status {
    case .executing: return Color.black.opacity(0.7)
    case .completed: return Color.black.opacity(0.6)
    case .failed: return Color.red.opacity(0.3)
    case .cancelled: return Color.black.opacity(0.6)
    case .idle: return Color.clear
    }
  }
}
```

- [ ] **Step 5: StreamView — delete the `ToolCallStatusView` call site (~line 51)**

The line is indented **12 spaces** (it sits inside `ZStack > if isGeminiActive > VStack > VStack(spacing: 8)`). Delete exactly this one line, at 12-space indent:

```swift
            ToolCallStatusView(status: geminiVM.toolCallStatus)
```

The enclosing `VStack(spacing: 8)` keeps its other children (the transcript `if`, the `isModelSpeaking` `if`, and the `isSendingScoutReport` scout-report `if`), so it is NOT left empty — delete only this line and change nothing else. (Verified: the file uses 12 spaces here, not 8.)

- [ ] **Step 6: Commit**

```bash
git add "samples/CameraAccess/CameraAccess/Views/Components/GeminiOverlayView.swift" "samples/CameraAccess/CameraAccess/Views/StreamView.swift"
git commit -m "refactor(ios): remove OpenClaw/tool-call status UI"
```

---

### Task 7: iOS — Secrets.swift.example

**Files:**
- Modify: `samples/CameraAccess/CameraAccess/Secrets.swift.example`

**Interfaces:**
- Produces: removes OpenClaw placeholder constants. Keeps Gemini key, SPECTRE, WebRTC.

- [ ] **Step 1: Delete the OpenClaw placeholder constants** (not a `.swift` source file — no swiftui-pro needed)

```swift
  // OPTIONAL: OpenClaw gateway config (for agentic tool-calling)
  static let openClawHost = "http://YOUR_MAC_HOSTNAME.local"
  static let openClawPort = 18789
  static let openClawHookToken = "YOUR_OPENCLAW_HOOK_TOKEN"
  static let openClawGatewayToken = "YOUR_OPENCLAW_GATEWAY_TOKEN"
```

Keep `geminiAPIKey`, the three `spectre*` constants, and `webrtcSignalingURL`.

- [ ] **Step 2: Commit**

```bash
git add "samples/CameraAccess/CameraAccess/Secrets.swift.example"
git commit -m "refactor(ios): drop OpenClaw placeholders from Secrets example"
```

---

### Task 8: iOS — BUILD + RUNTIME VERIFICATION (user checkpoint)

**Files:** none (verification only).

- [ ] **Step 1: Build in Xcode**

Open `samples/CameraAccess/CameraAccess.xcodeproj` and build (⌘B).
Expected: build succeeds with **zero** errors. No "cannot find 'OpenClaw…' / 'ToolCall…' in scope".

- [ ] **Step 2: Repo grep for stragglers (iOS)**

Run (case-insensitive superset of removed symbols): `grep -rniE "openclaw|tool[-_ ]?call|sendtoolresponse|tooldeclarations|ontoolcall" "samples/CameraAccess/CameraAccess"`
Expected: no matches. This pattern catches lowercase `openClaw*`, `toolCallStatus`, `onToolCall`, `sendToolResponse`, `ToolDeclarations`, etc. — the earlier narrower/case-sensitive pattern reported false "clean."

- [ ] **Step 3: Runtime smoke test (MockDeviceKit)**

Run the app, pair a MockDeviceKit device, start a scout session. Confirm: audio+video stream to Gemini, a spoken response is heard, and ending the session POSTs to SPECTRE `/api/scout` (HTTP 200). Confirm Settings shows **no** OpenClaw section and **still shows** the WebRTC section.

- [ ] **Step 4: Report result.** If the build fails, paste the exact Xcode error; do not proceed to Phase 2 until iOS is green.

---

# PHASE 2 — Android (`samples/CameraAccessAndroid/`)

Base package dir: `app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/`
No Gradle project-file edits are needed (sources are globbed). The app is expected to compile only after **all** of Tasks 9–14 are complete.

### Task 9: Delete the Android `openclaw/` package

**Files:**
- Delete: `.../openclaw/OpenClawBridge.kt`
- Delete: `.../openclaw/ToolCallModels.kt`
- Delete: `.../openclaw/ToolCallRouter.kt`

- [ ] **Step 1: Delete the entire `openclaw/` directory** (all three files).

- [ ] **Step 2: Commit**

```bash
git add -A "samples/CameraAccessAndroid/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/openclaw"
git commit -m "refactor(android): delete openclaw package"
```

---

### Task 10: Android — GeminiConfig.kt + GeminiLiveService.kt

**Files:**
- Modify: `.../gemini/GeminiConfig.kt`
- Modify: `.../gemini/GeminiLiveService.kt`

**Interfaces:**
- Produces: removes OpenClaw config accessors + all tool-call machinery. Keeps `sendExecutor` and its `.execute` calls in `sendAudio`/`sendVideoFrame`.

- [ ] **Step 1: GeminiConfig — delete the four `openClaw*` accessors**

```kotlin
    val openClawHost: String
        get() = SettingsManager.openClawHost

    val openClawPort: Int
        get() = SettingsManager.openClawPort

    val openClawHookToken: String
        get() = SettingsManager.openClawHookToken

    val openClawGatewayToken: String
        get() = SettingsManager.openClawGatewayToken
```

Keep `import ...settings.SettingsManager` (still used by `systemInstruction`/`apiKey`).

- [ ] **Step 2: GeminiConfig — delete `isOpenClawConfigured`** (keep the object's closing `}`)

```kotlin
    val isOpenClawConfigured: Boolean
        get() = openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
                && openClawGatewayToken.isNotEmpty()
                && openClawHost != "http://YOUR_MAC_HOSTNAME.local"
```

- [ ] **Step 3: GeminiLiveService — delete the openclaw imports**

```kotlin
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiToolCall
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.GeminiToolCallCancellation
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolDeclarations
```

- [ ] **Step 4: GeminiLiveService — delete the callback fields**

```kotlin
    var onToolCall: ((GeminiToolCall) -> Unit)? = null
    var onToolCallCancellation: ((GeminiToolCallCancellation) -> Unit)? = null
```

- [ ] **Step 5: GeminiLiveService — delete the callback nulling in `disconnect()`**

```kotlin
        onToolCall = null
        onToolCallCancellation = null
```

- [ ] **Step 6: GeminiLiveService — delete the tool advertisement in the setup message**

```kotlin
                put("tools", JSONArray().put(JSONObject().apply {
                    put("functionDeclarations", ToolDeclarations.allDeclarationsJSON())
                }))
```

- [ ] **Step 7: GeminiLiveService — delete `sendToolResponse` (whole function)**

```kotlin
    fun sendToolResponse(response: JSONObject) {
        sendExecutor.execute {
            webSocket?.send(response.toString())
        }
    }
```

⚠️ This is the ONLY place `sendExecutor.execute` is removed, and only because the whole function goes. Do NOT touch `sendExecutor` (line 59) or the `.execute` calls in `sendAudio`/`sendVideoFrame`.

- [ ] **Step 8: GeminiLiveService — delete the tool-call + cancellation parsing in `handleMessage`**

```kotlin
            // Tool call
            val toolCall = GeminiToolCall.fromJSON(json)
            if (toolCall != null) {
                Log.d(TAG, "Tool call received: ${toolCall.functionCalls.size} function(s)")
                onToolCall?.invoke(toolCall)
                return
            }

            // Tool call cancellation
            val cancellation = GeminiToolCallCancellation.fromJSON(json)
            if (cancellation != null) {
                Log.d(TAG, "Tool call cancellation: ${cancellation.ids.joinToString()}")
                onToolCallCancellation?.invoke(cancellation)
                return
            }
```

- [ ] **Step 9: Commit**

```bash
git add "samples/CameraAccessAndroid/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/gemini/GeminiConfig.kt" "samples/CameraAccessAndroid/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/gemini/GeminiLiveService.kt"
git commit -m "refactor(android): remove OpenClaw config and tool-call machinery"
```

---

### Task 11: Android — GeminiSessionViewModel.kt

**Files:**
- Modify: `.../gemini/GeminiSessionViewModel.kt`

- [ ] **Step 1: Delete the openclaw imports**

```kotlin
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawBridge
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawConnectionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallRouter
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallStatus
```

Keep `import ...stream.StreamingMode`.

- [ ] **Step 2: Delete the `GeminiUiState` tool/connection fields**

```kotlin
    val toolCallStatus: ToolCallStatus = ToolCallStatus.Idle,
    val openClawConnectionState: OpenClawConnectionState = OpenClawConnectionState.NotConfigured,
```

(The field above, `val aiTranscript: String = "",`, keeps its trailing comma; the data class closes cleanly.)

- [ ] **Step 3: Delete the bridge/router fields**

```kotlin
    private val openClawBridge = OpenClawBridge()
    private var toolCallRouter: ToolCallRouter? = null
```

- [ ] **Step 4: Replace the OpenClaw check + wiring block in `startSession()`**

Replace:

```kotlin
        // Check OpenClaw and start session
        viewModelScope.launch {
            openClawBridge.checkConnection()
            openClawBridge.resetSession()

            // Wire tool call handling
            toolCallRouter = ToolCallRouter(openClawBridge, viewModelScope)

            geminiService.onToolCall = { toolCall ->
                for (call in toolCall.functionCalls) {
                    toolCallRouter?.handleToolCall(call) { response ->
                        geminiService.sendToolResponse(response)
                    }
                }
            }

            geminiService.onToolCallCancellation = { cancellation ->
                toolCallRouter?.cancelToolCalls(cancellation.ids)
            }
```

with:

```kotlin
        // Start session
        viewModelScope.launch {
```

(The `launch` block now has no suspend calls — that still compiles and runs fine. Do not collapse it; it preserves `stateObservationJob`/`connect` ordering.)

- [ ] **Step 5: Delete the OpenClaw fields in the state-observation `copy(...)`**

```kotlin
                        toolCallStatus = openClawBridge.lastToolCallStatus.value,
                        openClawConnectionState = openClawBridge.connectionState.value,
```

Keep `connectionState = ...` and `isModelSpeaking = ...`.

- [ ] **Step 6: Delete the router teardown in `stopSession()`**

```kotlin
        toolCallRouter?.cancelAll()
        toolCallRouter = null
```

- [ ] **Step 7: Commit**

```bash
git add "samples/CameraAccessAndroid/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/gemini/GeminiSessionViewModel.kt"
git commit -m "refactor(android): remove OpenClaw wiring from GeminiSessionViewModel"
```

---

### Task 12: Android — Settings (SettingsManager.kt incl. prompt rewrite + SettingsScreen.kt)

**Files:**
- Modify: `.../settings/SettingsManager.kt`
- Modify: `.../ui/SettingsScreen.kt`

> **⚠️ DEVIATION FROM SPEC — requires user sign-off before executing this task.** The spec said "no prompt changes," but Android's `DEFAULT_SYSTEM_PROMPT` instructs the model to *"ALWAYS use execute"*. Once the tool is gone that prompt is false and will cause the model to attempt a non-existent tool. Step 3 rewrites it to a neutral voice+vision prompt. iOS is unaffected (its default prompt is already the tool-free Scout_IQ prompt). The replacement text below is a proposed default — confirm or customize it with the user first.

- [ ] **Step 1: SettingsManager — delete the four `openClaw*` accessors**

```kotlin
    var openClawHost: String
        get() = prefs.getString("openClawHost", null) ?: Secrets.openClawHost
        set(value) = prefs.edit().putString("openClawHost", value).apply()

    var openClawPort: Int
        get() {
            val stored = prefs.getInt("openClawPort", 0)
            return if (stored != 0) stored else Secrets.openClawPort
        }
        set(value) = prefs.edit().putInt("openClawPort", value).apply()

    var openClawHookToken: String
        get() = prefs.getString("openClawHookToken", null) ?: Secrets.openClawHookToken
        set(value) = prefs.edit().putString("openClawHookToken", value).apply()

    var openClawGatewayToken: String
        get() = prefs.getString("openClawGatewayToken", null) ?: Secrets.openClawGatewayToken
        set(value) = prefs.edit().putString("openClawGatewayToken", value).apply()
```

Keep the `webrtcSignalingURL` accessor immediately after. Keep `import ...Secrets`.

- [ ] **Step 2: Confirm the prompt rewrite with the user** (per the deviation note above). Proceed only once approved.

- [ ] **Step 3: SettingsManager — rewrite `DEFAULT_SYSTEM_PROMPT`**

Replace the entire existing constant:

```kotlin
    const val DEFAULT_SYSTEM_PROMPT = """You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a voice conversation. Keep responses concise and natural.

CRITICAL: You have NO memory, NO storage, and NO ability to take actions on your own. You cannot remember things, keep lists, set reminders, search the web, send messages, or do anything persistent. You are ONLY a voice interface.

You have exactly ONE tool: execute. This connects you to a powerful personal assistant that can do anything -- send messages, search the web, manage lists, set reminders, create notes, research topics, control smart home devices, interact with apps, and much more.

ALWAYS use execute when the user asks you to:
- Send a message to someone (any platform: WhatsApp, Telegram, iMessage, Slack, etc.)
- Search or look up anything (web, local info, facts, news)
- Add, create, or modify anything (shopping lists, reminders, notes, todos, events)
- Research, analyze, or draft anything
- Control or interact with apps, devices, or services
- Remember or store any information for later

Be detailed in your task description. Include all relevant context: names, content, platforms, quantities, etc. The assistant works better with complete information.

NEVER pretend to do these things yourself.

IMPORTANT: Before calling execute, ALWAYS speak a brief acknowledgment first. For example:
- "Sure, let me add that to your shopping list." then call execute.
- "Got it, searching for that now." then call execute.
- "On it, sending that message." then call execute.
Never call execute silently -- the user needs verbal confirmation that you heard them and are working on it. The tool may take several seconds to complete, so the acknowledgment lets them know something is happening.

For messages, confirm recipient and content before delegating unless clearly urgent."""
```

with (proposed neutral default — customize per Step 2):

```kotlin
    const val DEFAULT_SYSTEM_PROMPT = """You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a natural voice conversation about what they are looking at. Keep responses concise and conversational.

You can describe what you see, answer questions, read text aloud, identify objects, and talk through what is in view. You do not have the ability to take actions in the outside world -- you cannot send messages, search the web, set reminders, control devices, or store information for later. If asked to do one of those things, briefly say you can't do that directly and offer to help by talking it through instead.

Keep responses short and natural, as if speaking to someone hands-free."""
```

- [ ] **Step 4: SettingsScreen — delete the remembered state vars**

```kotlin
    var openClawHost by remember { mutableStateOf(SettingsManager.openClawHost) }
    var openClawPort by remember { mutableStateOf(SettingsManager.openClawPort.toString()) }
    var openClawHookToken by remember { mutableStateOf(SettingsManager.openClawHookToken) }
    var openClawGatewayToken by remember { mutableStateOf(SettingsManager.openClawGatewayToken) }
```

Keep the `webrtcSignalingURL` state var.

- [ ] **Step 5: SettingsScreen — delete the OpenClaw writes in `save()`**

```kotlin
        SettingsManager.openClawHost = openClawHost.trim()
        openClawPort.trim().toIntOrNull()?.let { SettingsManager.openClawPort = it }
        SettingsManager.openClawHookToken = openClawHookToken.trim()
        SettingsManager.openClawGatewayToken = openClawGatewayToken.trim()
```

Keep the WebRTC save line.

- [ ] **Step 6: SettingsScreen — delete the OpenClaw reads in `reload()`**

```kotlin
        openClawHost = SettingsManager.openClawHost
        openClawPort = SettingsManager.openClawPort.toString()
        openClawHookToken = SettingsManager.openClawHookToken
        openClawGatewayToken = SettingsManager.openClawGatewayToken
```

Keep the WebRTC reload line.

- [ ] **Step 7: SettingsScreen — delete the entire OpenClaw UI section**

```kotlin
            // OpenClaw section
            SectionHeader("OpenClaw")
            MonoTextField(
                value = openClawHost,
                onValueChange = { openClawHost = it },
                label = "Host",
                placeholder = "http://your-mac.local",
                keyboardType = KeyboardType.Uri,
            )
            MonoTextField(
                value = openClawPort,
                onValueChange = { openClawPort = it },
                label = "Port",
                placeholder = "18789",
                keyboardType = KeyboardType.Number,
            )
            MonoTextField(
                value = openClawHookToken,
                onValueChange = { openClawHookToken = it },
                label = "Hook Token",
                placeholder = "Hook token",
            )
            MonoTextField(
                value = openClawGatewayToken,
                onValueChange = { openClawGatewayToken = it },
                label = "Gateway Token",
                placeholder = "Gateway auth token",
            )
```

Keep the WebRTC section that follows (`SectionHeader("WebRTC")` …).

- [ ] **Step 8: Commit**

```bash
git add "samples/CameraAccessAndroid/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/settings/SettingsManager.kt" "samples/CameraAccessAndroid/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/ui/SettingsScreen.kt"
git commit -m "refactor(android): remove OpenClaw settings + neutralize system prompt"
```

---

### Task 13: Android — GeminiOverlayView.kt

**Files:**
- Modify: `.../ui/GeminiOverlayView.kt`

- [ ] **Step 1: Delete the openclaw imports**

```kotlin
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.OpenClawConnectionState
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolCallStatus
```

- [ ] **Step 2: Delete the `openClawState` argument in the `GeminiStatusBar(...)` call**

```kotlin
            openClawState = uiState.openClawConnectionState,
```

(Leaves `GeminiStatusBar(connectionState = uiState.connectionState,)`.)

- [ ] **Step 3: Delete the tool-call status block in `GeminiOverlay`**

```kotlin
        // Tool call status
        val toolStatus = uiState.toolCallStatus
        if (toolStatus !is ToolCallStatus.Idle) {
            Spacer(modifier = Modifier.height(4.dp))
            ToolCallStatusView(status = toolStatus)
        }
```

- [ ] **Step 4: Delete the `openClawState` parameter of `GeminiStatusBar`**

```kotlin
    openClawState: OpenClawConnectionState,
```

(Signature becomes `connectionState` + `modifier`.)

- [ ] **Step 5: Delete the OpenClaw `StatusPill` inside `GeminiStatusBar`**

```kotlin
        if (openClawState !is OpenClawConnectionState.NotConfigured) {
            StatusPill(
                label = "OpenClaw",
                color = when (openClawState) {
                    is OpenClawConnectionState.Connected -> Color(0xFF4CAF50)
                    is OpenClawConnectionState.Checking -> Color(0xFFFF9800)
                    is OpenClawConnectionState.Unreachable -> Color(0xFFF44336)
                    is OpenClawConnectionState.NotConfigured -> Color(0xFF9E9E9E)
                },
            )
        }
```

Keep the `"AI"` `StatusPill` and the generic `StatusPill` composable.

- [ ] **Step 6: Delete the entire `ToolCallStatusView` composable**

```kotlin
@Composable
fun ToolCallStatusView(
    status: ToolCallStatus,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when (status) {
            is ToolCallStatus.Executing -> {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    color = Color.White,
                    strokeWidth = 2.dp,
                )
            }
            is ToolCallStatus.Completed -> {
                Text(text = "[OK]", color = Color(0xFF4CAF50), fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
            is ToolCallStatus.Failed -> {
                Text(text = "[X]", color = Color(0xFFF44336), fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
            is ToolCallStatus.Cancelled -> {
                Text(text = "[--]", color = Color(0xFFFF9800), fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
            else -> {}
        }
        Text(
            text = status.displayText,
            color = Color.White.copy(alpha = 0.8f),
            fontSize = 12.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
```

- [ ] **Step 7: Prune now-unused imports** (only if no other use remains in the file — verify each with a quick in-file search):

```kotlin
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.ui.text.font.FontFamily
```

- [ ] **Step 8: Commit**

```bash
git add "samples/CameraAccessAndroid/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/ui/GeminiOverlayView.kt"
git commit -m "refactor(android): remove OpenClaw/tool-call status UI"
```

---

### Task 14: Android — Secrets.kt.example

**Files:**
- Modify: `.../Secrets.kt.example`

- [ ] **Step 1: Delete the OpenClaw placeholders**

```kotlin
    // OPTIONAL: OpenClaw gateway config (for agentic tool-calling)
    // Use your Mac's Bonjour hostname (run: scutil --get LocalHostName)
    const val openClawHost = "http://YOUR_MAC_HOSTNAME.local"
    const val openClawPort = 18789
    const val openClawHookToken = "YOUR_OPENCLAW_HOOK_TOKEN"
    const val openClawGatewayToken = "YOUR_OPENCLAW_GATEWAY_TOKEN"
```

Keep `geminiAPIKey` and the `webrtcSignalingURL` block.

- [ ] **Step 2: Commit**

```bash
git add "samples/CameraAccessAndroid/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/Secrets.kt.example"
git commit -m "refactor(android): drop OpenClaw placeholders from Secrets example"
```

---

### Task 15: Android — COMPILE VERIFICATION (user checkpoint, compile-only)

**Files:** none (verification only).

- [ ] **Step 1: Gradle build**

Run: `cd samples/CameraAccessAndroid && ./gradlew assembleDebug`
Expected: `BUILD SUCCESSFUL`, no unresolved references.

- [ ] **Step 2: Repo grep for stragglers (Android)**

Run (case-insensitive superset): `grep -rniE "openclaw|tool[-_ ]?call|sendtoolresponse|tooldeclarations|ontoolcall" "samples/CameraAccessAndroid/app/src"`
Expected: no matches. This adds `onToolCall` and lowercase `toolCallStatus`/`toolCallRouter`, which the earlier pattern missed. Note: `sendExecutor.execute` must STILL be present in `GeminiLiveService.kt` — it does not match this pattern (no "toolcall" substring), which is correct and expected.

- [ ] **Step 3: (Optional) UI check** if an emulator/device is available: Settings screen renders with no OpenClaw section, WebRTC section present. Runtime scout test is not applicable (Android has no SPECTRE scout). Per the spec, full Android runtime verification is deferred.

- [ ] **Step 4: Report result.** If the build fails, paste the exact Gradle error.

---

# PHASE 3 — Docs, CI cleanup & finish

> Non-source cleanup surfaced by the adversarial plan review. The CI workflow still injects OpenClaw secrets, and README/CLAUDE.md still document it. None break the build, but they contradict the "clean codebase" goal and are invisible to source-only greps. Platform-independent, low-risk.

### Task 16: CI — remove OpenClaw from the TestFlight secrets injection

**Files:**
- Modify: `.github/workflows/build.yml`

**Context:** The `Inject Secrets.swift` step writes the gitignored `Secrets.swift` used by the Release/TestFlight archive. It still declares four `openClaw*` constants. After the removal nothing references them (so it does not break the build), but it leaves the generated `Secrets.swift` inconsistent with the trimmed `Secrets.swift.example`.

- [ ] **Step 1: Delete the four OpenClaw lines from the heredoc** (`.yml` file — no swiftui-pro). Read the region first (CRLF caveat), then remove:

```
            static let openClawHost = "http://localhost"
            static let openClawPort = 18789
            static let openClawHookToken = ""
            static let openClawGatewayToken = ""
```

Keep `geminiAPIKey`, the three `spectre*` lines, and `static let webrtcSignalingURL = "ws://localhost:8080"`.

- [ ] **Step 2: Commit**

```bash
git add ".github/workflows/build.yml"
git commit -m "ci: drop OpenClaw constants from Secrets injection"
```

---

### Task 17: Docs — README.md

**Files:**
- Modify: `README.md`

**Context:** README still documents OpenClaw as a live feature and lists now-deleted files.

- [ ] **Step 1: Locate every reference**

Run: `grep -niE "openclaw|tool[-_ ]?call|execute tool|gateway" README.md`

- [ ] **Step 2: Remove OpenClaw content.** For the hits above:
  - Delete the OpenClaw setup section (its config instructions and `openClaw*`/`openClawGatewayToken` snippets).
  - In the architecture diagram, remove the OpenClaw / "Tool calls (execute) → OpenClaw Gateway" path so the documented flow is glasses → Gemini Live → SPECTRE.
  - In the file-map table, delete the rows for the deleted files: `OpenClaw/ToolCallModels.swift`, `OpenClaw/OpenClawBridge.swift`, `OpenClaw/ToolCallRouter.swift`, `openclaw/OpenClawBridge.kt`, `openclaw/ToolCallRouter.kt`, and any `ToolCallModels.kt` row.
  - Remove any remaining prose mentions of OpenClaw / agentic tool-calling.
  - Leave ALL WebRTC and SPECTRE documentation intact.

- [ ] **Step 3: Verify**

Run: `grep -niE "openclaw" README.md`
Expected: no matches.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: remove OpenClaw from README"
```

---

### Task 18: Docs — project CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (repo root)

- [ ] **Step 1: Remove the OpenClaw line from the Stack section**

Delete:

```
- OpenClaw bridge for tool call routing
```

- [ ] **Step 2: Remove the OpenClaw line from the Architecture section**

Delete:

```
- `OpenClaw/` — tool call bridge to Spectre
```

- [ ] **Step 3: Verify**

Run: `grep -ni "openclaw" CLAUDE.md`
Expected: no matches.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: remove OpenClaw from project CLAUDE.md"
```

---

### Task 19: Cross-platform final verification + branch readiness

**Files:** none.

- [ ] **Step 1: Repo-wide grep** (excludes only the design/plan docs, which legitimately still mention OpenClaw)

Run: `grep -rniE "openclaw|tool[-_ ]?call|sendtoolresponse|tooldeclarations|ontoolcall" . --exclude-dir=.git --exclude-dir=docs`
Expected: no matches. (README.md and CLAUDE.md are at repo root and MUST be clean; the `docs/superpowers/` spec+plan are intentionally excluded.)

- [ ] **Step 2: Confirm `sendExecutor` intact** (Android) — `grep -n "sendExecutor" samples/CameraAccessAndroid/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/gemini/GeminiLiveService.kt` should still show the declaration + the two streaming-path `.execute` calls.

- [ ] **Step 3: Confirm WebRTC intact** on both platforms (spot-check the WebRTC Settings section and that `webrtcSignalingURL` secret/config remain).

- [ ] **Step 4: Review the full branch diff**

Run: `git log --oneline main..chore/remove-openclaw` and `git diff --stat main..chore/remove-openclaw`
Expected: only OpenClaw removals + the Android prompt rewrite + CI/docs cleanup; no WebRTC/SPECTRE/DAT source touched beyond the documented references.

- [ ] **Step 5: Hand back to the user** for the merge decision (per superpowers:finishing-a-development-branch): merge to `main`, open a PR, or continue.

---

## Notes carried forward (not part of this plan)

- **Android is not a SPECTRE scout.** It has no `/api/scout`, active-session, or vehicle-list code — it is the generic glasses assistant. Removing OpenClaw leaves it as a voice+vision assistant with no outward actions. Making Android a real scout (or achieving true feature parity with iOS) is a separate, future effort.
- **Future phases** (Live Scout Feed, Facebook) are untouched; WebRTC is preserved for them.

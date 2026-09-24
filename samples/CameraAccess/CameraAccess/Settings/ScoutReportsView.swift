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
        ContentUnavailableView("No Scout reports yet.", systemImage: "tray")
      }
      ForEach(outbox.captures.sorted { $0.createdAt > $1.createdAt }) { capture in
        ReportRow(
          capture: capture,
          outbox: outbox,
          uploader: uploader,
          pendingDelete: $pendingDelete,
          confirmingDelete: $confirmingDelete
        )
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

/// One report row: its state, upload progress if any, and the actions that apply.
private struct ReportRow: View {
  let capture: Capture
  let outbox: ScoutOutbox
  let uploader: TrackWalkUploader
  @Binding var pendingDelete: Capture?
  @Binding var confirmingDelete: Bool

  var body: some View {
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
}

import SwiftUI

/// Pick the session a walk belongs to, then Record.
struct TrackWalkPickerSheet: View {
  let onRecord: (ScoutSessionSummary) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var sessions: [ScoutSessionSummary] = []
  @State private var selection: String?
  @State private var loading = true
  @State private var loadError: String?

  var body: some View {
    NavigationStack {
      List {
        if loading {
          ProgressView("Loading sessions…")
        } else if let loadError {
          Text(loadError).foregroundStyle(.secondary)
        } else if sessions.isEmpty {
          Text("No planned or active sessions. Create one in SPECTRE first.")
            .foregroundStyle(.secondary)
        }
        ForEach(sessions) { session in
          Button {
            selection = session.id
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(session.track).font(.headline)
                Text(session.status == "active" ? "Active now" : (session.scheduledDate ?? "Planned"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if selection == session.id {
                Image(systemName: "checkmark").foregroundStyle(.tint)
              }
            }
          }
          .accessibilityAddTraits(selection == session.id ? .isSelected : [])
        }
      }
      .navigationTitle("Track Walk")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Record") {
            guard let chosen = sessions.first(where: { $0.id == selection }) else { return }
            dismiss()
            onRecord(chosen)
          }
          .disabled(selection == nil)
        }
      }
      .task { await load() }
    }
  }

  private func load() async {
    loading = true
    defer { loading = false }
    if SettingsManager.shared.scoutTestMode {
      sessions = [ScoutSessionSummary(id: "test-mode", track: "Test Track", status: "active", scheduledDate: nil)]
    } else {
      do {
        sessions = try await SpectreScoutBridge().fetchSessions()
      } catch {
        loadError = "Couldn't load sessions: \(error.localizedDescription)"
      }
    }
    // SPECTRE sorts active first, then nearest planned date.
    selection = sessions.first?.id
  }
}

/// Recording status and controls, shown over the stream while a walk runs.
struct TrackWalkBar: View {
  @ObservedObject var walk: TrackWalkController

  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(walk.phase == .recording ? Color.red : Color.orange)
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(walk.sessionTrack).font(.footnote.weight(.semibold))
        Text("\(Self.clock(walk.elapsed)) · \(Self.label(walk.phase))")
          .font(.caption.monospacedDigit())
      }
      .foregroundStyle(.white)
      Spacer()
      if walk.phase == .recording {
        Button("Pause") { walk.pauseByUser() }
          .buttonStyle(.bordered)
          .tint(.white)
      } else if walk.phase == .paused {
        Button("Resume") { walk.resumeByUser() }
          .buttonStyle(.bordered)
          .tint(.white)
      }
      Button("Stop") { Task { await walk.finish(reason: .user) } }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(walk.phase == .finishing || walk.phase == .preparing)
    }
    .padding(12)
    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .contain)
  }

  private static func clock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  private static func label(_ phase: TrackWalkController.Phase) -> String {
    switch phase {
    case .idle: return "Idle"
    case .preparing: return "Getting ready"
    case .recording: return "Recording"
    case .paused: return "Paused"
    case .finishing: return "Saving"
    }
  }
}

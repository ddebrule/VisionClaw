import SwiftUI

/// The Outbox as a list: every Scout report, where it is, and Retry for failures.
struct ScoutReportsView: View {
  @ObservedObject private var outbox = ScoutOutbox.shared

  var body: some View {
    List {
      if outbox.captures.isEmpty {
        Text("No Scout reports yet.")
          .foregroundStyle(.secondary)
      }
      ForEach(outbox.captures.sorted { $0.createdAt > $1.createdAt }) { capture in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(capture.trackName.isEmpty ? "Session" : capture.trackName)
              .font(.headline)
            Spacer()
            Text(Self.stateLabel(capture))
              .font(.subheadline)
              .foregroundStyle(capture.state == .failed ? .red : .secondary)
          }
          Text("\(capture.vehicleModel) · \(capture.durationMin) min · \(capture.createdAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption)
            .foregroundStyle(.secondary)
          if let error = capture.lastError {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
          }
          if capture.state == .failed {
            Button("Retry") {
              outbox.retry(capture.id)
            }
            .buttonStyle(.bordered)
          }
        }
        .accessibilityElement(children: .contain)
      }
    }
    .navigationTitle("Scout reports")
  }

  private static func stateLabel(_ capture: Capture) -> String {
    switch capture.state {
    case .reportPending: return "Sending…"
    case .reported, .done: return "Sent"
    case .failed: return capture.retryable ? "Waiting for signal" : "Failed"
    }
  }
}

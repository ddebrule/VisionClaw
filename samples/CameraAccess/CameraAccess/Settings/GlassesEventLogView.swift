import SwiftUI

struct GlassesEventLogView: View {
  @ObservedObject private var store = GlassesEventLogStore.shared

  var body: some View {
    List {
      if store.log.entries.isEmpty {
        Text("No glasses events yet. Start streaming to record some.")
          .foregroundStyle(.secondary)
      }
      ForEach(store.log.entries.reversed()) { entry in
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.date, format: .dateTime.hour().minute().second())
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          Text(entry.text)
            .font(.footnote.monospaced())
        }
        .accessibilityElement(children: .combine)
      }
    }
    .navigationTitle("Glasses event log")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        ShareLink(item: store.log.exportText()) {
          Label("Share log", systemImage: "square.and.arrow.up")
        }
        Button("Clear", role: .destructive) {
          store.clear()
        }
      }
    }
  }
}

import SwiftUI
import BituahCore

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore

    var body: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView("אין פוליסות עדיין", systemImage: "clock",
                                       description: Text("פוליסות שצולמו או יובאו יופיעו כאן. הכל נשמר על המכשיר בלבד."))
            } else {
                List {
                    ForEach(history.entries) { e in
                        NavigationLink(value: e) { HistoryRow(entry: e) }
                    }
                    .onDelete { history.delete(at: $0) }
                }
            }
        }
        .navigationTitle("היסטוריה")
        .navigationDestination(for: HistoryEntry.self) { ResultView(entry: $0) }
        .toolbar {
            if !history.entries.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("נקה", role: .destructive) { history.clear() }
                }
            }
        }
    }
}

extension HistoryEntry: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.companyName).font(.headline).lineLimit(1)
                Spacer()
                Text(entry.premium).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(entry.insuranceType).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.12)).clipShape(Capsule())
                Text(entry.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(entry.date.formatted(date: .numeric, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text("\(entry.filledCount)/8 שדות · \(entry.source == "tesseract_ocr" ? "OCR" : "שכבת טקסט") · \(entry.totalMs) ms")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

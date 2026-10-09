import SwiftUI

/// A compact contextual record with locally owned disclosure state. Results
/// remain selectable in place, without creating another navigation destination.
struct SessionContextTimelineRow: View {
    let entry: SessionContextEntry
    @State private var isExpanded = false

    init(entry: SessionContextEntry, initiallyExpanded: Bool = false) {
        self.entry = entry
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.details.isEmpty {
                label
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    Text(entry.details)
                        .font(.callout)
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    label
                }
                .tint(Color.primary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("context-\(entry.id)")
    }

    private var label: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.primary.opacity(0.65))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.65))
                        .lineLimit(isExpanded ? nil : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .model: "cpu"
        case .agent: "person.crop.circle"
        case .location: "folder"
        case .system: "info.circle"
        case .skill: "sparkles"
        case .shell: "terminal"
        case .compaction: "archivebox"
        case .idle: "flag.checkered"
        }
    }
}

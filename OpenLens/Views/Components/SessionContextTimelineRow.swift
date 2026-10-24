import SwiftUI
import UIKit

/// A compact contextual record with locally owned disclosure state. Results
/// remain selectable in place, without creating another navigation destination.
struct SessionContextTimelineRow: View {
    let entry: SessionContextEntry
    @Environment(\.chatEasterEgg) private var chatEasterEgg
    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded = false
    @State private var selectableDetails: SelectableDetails?

    private struct SelectableDetails: Identifiable {
        let id = UUID()
        let text: String
    }

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
                    // Same rule as message bubbles: per-Text selection fights
                    // scrolling, so copying goes through a menu and a sheet.
                    LinkedPlainText(text: entry.details, tint: isRetroChat ? RetroChatStyle.blueAccent : Color.appAccent)
                        .font(isRetroChat ? RetroChatStyle.bodyFont : .callout)
                        .foregroundStyle(ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = entry.details
                            } label: {
                                Label(AppText.copyMessage, systemImage: "doc.on.doc")
                            }
                            Button {
                                selectableDetails = SelectableDetails(text: entry.details)
                            } label: {
                                Label("Select Text", systemImage: "text.cursor")
                            }
                        }
                        .sheet(item: $selectableDetails) { item in
                            SelectableTextSheet(text: item.text)
                        }
                } label: {
                    label
                }
                .foregroundStyle(ink)
                .tint(ink)
                // The native disclosure arrow also needs light-control
                // contrast on retro's fixed pale paper in dark appearance.
                .environment(\.colorScheme, isRetroChat ? .light : colorScheme)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !isRetroChat {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.45))
            }
        }
        .ifRetroPanel(isRetroChat)
        .accessibilityIdentifier("context-\(entry.id)")
    }

    private var label: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(secondaryInk)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(isRetroChat ? RetroChatStyle.headerFont : .subheadline.weight(.medium))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.leading)
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(isRetroChat ? RetroChatStyle.smallFont : .caption)
                        .foregroundStyle(secondaryInk)
                        .multilineTextAlignment(.leading)
                        .lineLimit(isExpanded ? nil : 2)
                }
                if entry.kind == .synthetic, !isExpanded, !entry.resultPreview.isEmpty {
                    Text(entry.resultPreview)
                        .font(isRetroChat ? RetroChatStyle.bodyFont : .callout)
                        .foregroundStyle(ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isRetroChat: Bool { chatEasterEgg.visualMode.isRetro }
    private var ink: Color { isRetroChat ? RetroChatStyle.ink : .primary }
    private var secondaryInk: Color { isRetroChat ? RetroChatStyle.secondaryInk : .primary.opacity(0.65) }

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
        case .synthetic:
            switch entry.subagentResult?.state {
            case .completed: "checkmark.circle"
            case .error: "exclamationmark.circle"
            case .cancelled: "xmark.circle"
            case nil: "info.circle"
            }
        }
    }
}

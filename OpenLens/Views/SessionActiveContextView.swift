import SwiftUI

/// Approximate context usage and compaction controls, without transcript content.
struct SessionActiveContextView: View {
    @Bindable var chatClient: ChatClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatEasterEgg) private var chatEasterEgg
    @Environment(\.colorScheme) private var colorScheme

    private var isRetro: Bool { chatEasterEgg.visualMode.isRetro }
    private var ink: Color { isRetro ? RetroChatStyle.ink : .primary }
    private var secondaryInk: Color { isRetro ? RetroChatStyle.secondaryInk : .secondary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let title = chatClient.currentSession?.title, !title.isEmpty {
                            Text(title)
                                .font(isRetro ? RetroChatStyle.headerFont : .headline)
                                .foregroundStyle(ink)
                        }
                        contextUsage
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isRetro ? RetroChatStyle.paper : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                    SessionCompactionControls()
                        .environment(chatClient)
                }
                .font(isRetro ? RetroChatStyle.bodyFont : .subheadline)
                .padding(16)
            }
            .background(isRetro ? RetroChatStyle.screenBottom : Color(.systemGroupedBackground))
            .refreshable { await refreshContext() }
            .navigationTitle("Active Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshContext() } }
                        .accessibilityIdentifier("active-context-refresh")
                }
            }
        }
        .tint(isRetro ? RetroChatStyle.ink : Color.accentColor)
        .environment(\.colorScheme, isRetro ? .light : colorScheme)
    }

    @ViewBuilder
    private var contextUsage: some View {
        if let usage = chatClient.contextUsageSummary {
            Text("Approximate context usage")
                .font(isRetro ? RetroChatStyle.bodyFont : .subheadline.weight(.medium))
                .foregroundStyle(ink)
            if let percent = usage.usagePercent, let limit = usage.limitTokens {
                Text("About \(percent)% · \(usage.usedTokens.formatted()) of \(limit.formatted()) tokens")
                    .font(isRetro ? RetroChatStyle.bodyFont : .headline)
                    .foregroundStyle(ink)
                ProgressView(value: min(max(Double(percent) / 100, 0), 1))
                    .tint(isRetro ? RetroChatStyle.magentaAccent : .accentColor)
                    .accessibilityLabel("Approximate context usage")
                    .accessibilityValue("\(percent) percent")
            } else {
                Text("About \(usage.usedTokens.formatted()) tokens · model limit unavailable")
                    .foregroundStyle(ink)
            }
            if let model = usage.modelLabel {
                Text(model)
                    .font(isRetro ? RetroChatStyle.smallFont : .caption)
                    .foregroundStyle(secondaryInk)
            }
            Text("Based on token usage reported for the last request, including cached tokens and the response. New messages and tool results may increase usage before the next update. After compaction, an estimate appears with the next response.")
                .font(isRetro ? RetroChatStyle.smallFont : .caption)
                .foregroundStyle(secondaryInk)
        } else {
            Label("Estimate unavailable", systemImage: "questionmark.circle")
                .font(isRetro ? RetroChatStyle.bodyFont : .subheadline.weight(.medium))
                .foregroundStyle(ink)
            Text("An estimate appears after a response with token usage. After compaction, wait for the next response. The server does not report live context occupancy.")
                .font(isRetro ? RetroChatStyle.smallFont : .caption)
                .foregroundStyle(secondaryInk)
        }
    }

    private func refreshContext() async {
        if !ScreenshotFixtures.showsActiveContextButton {
            await chatClient.refreshCompactionState()
        }
    }
}

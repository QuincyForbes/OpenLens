import SwiftUI

/// Approximate context usage and compaction controls, without transcript content.
struct SessionActiveContextView: View {
    @Bindable var chatClient: ChatClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatEasterEgg) private var chatEasterEgg
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isRetro: Bool { chatEasterEgg.visualMode.isRetro }
    private var ink: Color { isRetro ? RetroChatStyle.ink : .primary }
    private var secondaryInk: Color { isRetro ? RetroChatStyle.secondaryInk : .secondary }

    var body: some View {
        NavigationStack {
            ScrollView {
                contextUsage
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SessionCompactionControls()
                    .environment(chatClient)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(isRetro ? RetroChatStyle.paper : Color.appBackground)
            }
            .background(isRetro ? RetroChatStyle.paper : Color.appBackground)
            .navigationTitle("Active Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(340), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(isRetro ? RetroChatStyle.paper : Color.appBackground)
        .tint(isRetro ? RetroChatStyle.ink : Color.appPrimary)
        .environment(\.colorScheme, isRetro ? .light : colorScheme)
    }

    private var usagePercent: Int? { chatClient.contextUsageSummary?.usagePercent }

    private var contextUsage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Estimated usage")
                    .font(isRetro ? RetroChatStyle.bodyFont : .subheadline)
                    .foregroundStyle(secondaryInk)
                Spacer(minLength: 12)
                Text(usagePercent.map { "≈\($0)%" } ?? "—")
                    .font(isRetro ? RetroChatStyle.headerFont : .title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ink)
            }
            if let percent = usagePercent {
                ProgressView(value: min(max(Double(percent) / 100, 0), 1))
                    .tint(isRetro ? RetroChatStyle.magentaAccent : Color.appPrimary)
                    .accessibilityHidden(true)
            }
            Text(tokensText)
                .font(isRetro ? RetroChatStyle.smallFont : .subheadline)
                .monospacedDigit()
                .foregroundStyle(ink)
            Text(chatClient.contextUsageSummary == nil
                 ? "An estimate appears after the next response with token usage."
                 : "Based on the last response. Current usage may differ.")
                .font(isRetro ? RetroChatStyle.smallFont : .footnote)
                .foregroundStyle(secondaryInk)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("active-context-usage-summary")
    }

    private var tokensText: String {
        guard let usage = chatClient.contextUsageSummary else { return "Usage unavailable" }
        if let limit = usage.limitTokens {
            return "\(usage.usedTokens.formatted()) of \(limit.formatted()) tokens"
        }
        return "\(usage.usedTokens.formatted()) tokens · model limit unavailable"
    }
}

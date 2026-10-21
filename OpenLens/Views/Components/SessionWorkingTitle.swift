import SwiftUI

/// Keeps session activity animations local to the title rather than the list.
struct SessionWorkingTitle: View {
    let title: String
    let isWorking: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var indicatorSize: CGFloat = 14

    private var animates: Bool { isWorking && !reduceMotion && scenePhase == .active }
    private var titleFont: Font { .system(size: titleSize, weight: .regular, design: .rounded) }

    var body: some View {
        HStack(spacing: 8) {
            if isWorking {
                Group {
                    if animates {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Color.appSecondary)
                    } else {
                        Image(systemName: "circle.dotted")
                            .font(.system(size: indicatorSize, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                    }
                }
                .frame(width: indicatorSize, height: indicatorSize)
                .accessibilityHidden(true)
            }

            titleText
                .foregroundStyle(Color.appPrimary)
                .overlay {
                    if animates {
                        GeometryReader { proxy in
                            LinearGradient(
                                colors: [.clear, Color.appSecondary.opacity(0.9), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: proxy.size.width * 0.65)
                            .phaseAnimator([false, true]) { content, phase in
                                content.offset(x: proxy.size.width * (phase ? 1 : -0.65))
                            } animation: { phase in
                                .linear(duration: phase ? 1.6 : 0.01)
                            }
                        }
                        .mask(titleText)
                        .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isWorking ? AppText.working : "")
    }

    private var titleText: some View {
        Text(title)
            .font(titleFont)
            .lineLimit(1)
    }
}

#Preview("Working and idle") {
    VStack(alignment: .leading, spacing: 24) {
        SessionWorkingTitle(title: "Improve session recovery", isWorking: true)
        SessionWorkingTitle(title: "Run integration tests", isWorking: false)
    }
    .padding()
}


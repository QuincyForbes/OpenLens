import SwiftUI

/// Consistent, lightweight loading placeholder used across tabs and sheets so initial
/// loads never flash empty states or jump abruptly from a bare spinner.
struct AppLoadingStateView: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .tint(Color.appSecondary)

            VStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appSecondary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.appSecondary.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// Lightweight skeleton rows shown while the session list hydrates from a cold server
/// or freshly switched OpenCode instance, preventing layout jump when rows arrive.
struct SessionListSkeletonView: View {
    let isSidebar: Bool

    @State private var isPulsing = false

    private var rowCount: Int { isSidebar ? 6 : 5 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isSidebar ? 8 : 12) {
                ForEach(0..<rowCount, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.appTertiary)
                            .frame(width: titleWidth(for: index), height: isSidebar ? 13 : 15)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.appTertiary.opacity(0.7))
                            .frame(width: subtitleWidth(for: index), height: isSidebar ? 10 : 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, isSidebar ? 12 : 16)
                    .padding(.vertical, isSidebar ? 11 : 14)
                    .background(
                        RoundedRectangle(cornerRadius: isSidebar ? 10 : 14, style: .continuous)
                            .fill(Color.appSurface)
                    )
                }
            }
            .padding(.horizontal, isSidebar ? 10 : 20)
            .padding(.top, isSidebar ? 12 : 16)
            .opacity(isPulsing ? 0.52 : 0.92)
            .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: isPulsing)
        }
        .scrollDisabled(true)
        .onAppear {
            isPulsing = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading sessions")
    }

    private func titleWidth(for index: Int) -> CGFloat {
        let widths: [CGFloat] = isSidebar ? [168, 134, 192, 148, 176, 126] : [220, 175, 250, 195, 210]
        return widths[index % widths.count]
    }

    private func subtitleWidth(for index: Int) -> CGFloat {
        let widths: [CGFloat] = isSidebar ? [108, 92, 128, 86, 114, 98] : [140, 115, 165, 125, 130]
        return widths[index % widths.count]
    }
}

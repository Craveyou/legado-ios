import SwiftUI

/// 浏览器页：内嵌浏览器与油猴脚本的入口（b86 起发现 Tab 更名为「浏览器」，
/// 网络书源链路已整体移除，书源搜索/换源/缓存/RSS 不再存在）。
struct ExploreView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                features
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(ReadingTheme.canvas.ignoresSafeArea())
        .navigationBarHidden(true)
        .accessibilityIdentifier("explore.scroll")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("浏览器")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("网页浏览与油猴脚本")
                .font(.subheadline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.55))
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 26)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                LNBrowserView()
            } label: {
                featureCard(symbol: "safari",
                            title: "网页浏览器",
                            subtitle: "输入网址或搜索词，直接浏览网页")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("网页浏览器，输入网址或搜索词直接浏览")
            .accessibilityIdentifier("explore.browser")

            NavigationLink {
                LNUserscriptListView()
            } label: {
                featureCard(symbol: "app.badge.checkmark",
                            title: "油猴脚本",
                            subtitle: "管理已导入的用户脚本")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("油猴脚本管理")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
    }

    private func featureCard(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(ReadingTheme.accent)
                .frame(width: 44, height: 44)
                .background(ReadingTheme.canvas,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(ReadingTheme.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(ReadingTheme.ink.opacity(0.25))
                .accessibilityHidden(true)
        }
        .padding(16)
        .background(ReadingTheme.groupedCanvas,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ReadingTheme.separator.opacity(0.4), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
    }
}

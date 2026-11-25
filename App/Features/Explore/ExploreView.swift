import SwiftUI

/// 发现页占位骨架。原书源发现功能已移除，此处保留 tab 与基础版式，
/// 后续可直接在此文件中替换为新的功能页面。
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
            HStack {
                Text("发现")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                NavigationLink { SearchView() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 44, height: 44)
                        .background {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(ReadingTheme.groupedCanvas.opacity(0.75))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
                .accessibilityIdentifier("explore.search")
            }
            Text("下一本好书，在这里遇见")
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

            Text("更多功能陆续加入")
                .font(.caption)
                .foregroundStyle(ReadingTheme.ink.opacity(0.35))
                .padding(.top, 6)
                .padding(.leading, 4)
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

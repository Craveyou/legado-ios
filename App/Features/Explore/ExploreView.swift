import SwiftUI

/// 发现页占位骨架。原书源发现功能已移除，此处保留 tab 与基础版式，
/// 后续可直接在此文件中替换为新的功能页面。
struct ExploreView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                placeholder
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

    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(ReadingTheme.ink.opacity(0.35))
                .accessibilityHidden(true)
            Text("敬请期待")
                .font(.headline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.75))
            Text("这里即将呈现全新的发现体验")
                .font(.subheadline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .accessibilityElement(children: .combine)
    }
}

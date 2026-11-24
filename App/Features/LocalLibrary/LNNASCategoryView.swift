import SwiftUI

/// NAS 连接下的三类入口（漫画 / 整理 / 短剧），显示与本地 tab 完全一致。
/// 数据源走 LNNASSource → FeiniuNASService（双地址 + TCP 预检逻辑不动）。
struct LNNASCategoryView: View {
    let connection: FeiniuConnection

    var body: some View {
        LNCategoryView(source: LNNASSource(connection: connection, rootPath: "/"),
                       title: connection.name,
                       subtitle: "漫画 · 整理 · 短剧 — 飞牛上的三个分类目录",
                       showsCounts: false,
                       extraContent: AnyView(browseAll))
    }

    /// 不按分类浏览时，仍可进原来的目录浏览器
    private var browseAll: some View {
        NavigationLink {
            FeiniuBrowserView(connection: connection)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                Text("浏览全部文件")
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .font(.subheadline)
            .foregroundStyle(ReadingTheme.accent)
            .padding(14)
            .background(ReadingTheme.groupedCanvas,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ln.nas.browseAll")
    }
}

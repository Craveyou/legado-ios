import SwiftUI

/// NAS 连接下的四类入口（漫画 / 整理 / 短剧 / 电影），显示与本地 tab 一致。
/// 数据源走 LNNASSource → FeiniuNASService（双地址 + TCP 预检逻辑不动）。
///
/// 说明：NAS 是「就地阅读 / 就地播放」，不是「导入书架」——
/// 原「浏览全部文件」入口和「点文件下载后导入书架」的整套逻辑已移除（b65）。
/// 各分类目录可以在 NAS 编辑页逐个改路径，不再需要靠目录浏览器去翻文件。
struct LNNASCategoryView: View {
    let connection: FeiniuConnection

    var body: some View {
        LNCategoryView(source: LNNASSource(connection: connection, rootPath: "/"),
                       title: connection.name,
                       // 电影是 NAS 专属分类（本地只有漫画/整理/短剧）
                       categories: LNCategory.allCases,
                       showsCounts: false)
    }
}

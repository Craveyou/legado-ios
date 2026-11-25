import Foundation

// MARK: - 本地/NAS 共用的三类书库模型
// 参照 LocalNovel 的 LibraryModels / BookSections，按 iOS 15 + Swift 6 重写。
// 小说分区不在此列（仍走小浣熊自己的书架）。

enum LNCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case comic
    case organized
    case shortDrama
    case movie

    var id: String { rawValue }

    /// 本地 tab 的分类入口。电影是 NAS 专属（本地放电影没有意义），
    /// 所以本地只用前三类，飞牛 NAS 分类页用 allCases。
    static let localCases: [LNCategory] = [.comic, .organized, .shortDrama]

    var label: String {
        switch self {
        case .comic: return "漫画"
        case .organized: return "整理"
        case .shortDrama: return "短剧"
        case .movie: return "电影"
        }
    }

    var folderName: String { label }

    var symbol: String {
        switch self {
        case .comic: return "photo.on.rectangle.angled"
        case .organized: return "folder"
        case .shortDrama: return "play.rectangle.on.rectangle"
        case .movie: return "film"
        }
    }

    var hint: String {
        switch self {
        case .comic: return "每部一个文件夹，按「部 → 话」分层，图片或 PDF"
        case .organized: return "作者文件夹 → 章节文件夹 → 正文 + 插图 + 音视频"
        case .shortDrama: return "剧名文件夹：剧照包 + 视频包"
        case .movie: return "目录下直接放视频文件，点击即播放"
        }
    }

    var structureExample: String {
        switch self {
        case .comic: return "漫画/漫画名/第1部/第1话/001.jpg\n漫画/漫画名/第5话.pdf"
        case .organized: return "整理/作者名/第01章/正文.txt + 1.jpg + [图1] 标记"
        case .shortDrama: return "短剧/剧名/剧照/001.jpg\n短剧/剧名/视频/第01集.mp4"
        case .movie: return "电影/片名.mp4\n电影/片名.mkv"
        }
    }
}

/// 统一条目：本地 FileManager 与 NAS FeiniuNASService 都归一成这个结构。
struct LNNode: Identifiable, Hashable, Sendable {
    var id: String { path }
    /// 相对根的路径（"/" 分隔），本地与 NAS 都用它做导航
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
}

/// 章节类型
enum LNChapterKind: String, Hashable, Sendable {
    case folder      // 目录章：正文 + 图片 + 音视频
    case images      // 图片话（漫画 / 剧照包）
    case pdf         // PDF 单话
    case text        // 单文件正文
    case video       // 单集视频
    case audio
}

/// 章节引用（本地与 NAS 共用）
struct LNChapter: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let kind: LNChapterKind
    let groupName: String?

    var displayName: String {
        guard let groupName, !groupName.isEmpty, groupName != name else { return name }
        return "\(groupName) · \(name)"
    }
}

/// 一本书（本地与 NAS 共用）
struct LNBook: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let title: String
    let category: LNCategory
    let chapters: [LNChapter]
}

/// 媒体类型
enum LNMediaKind: String, Hashable, Sendable {
    case text, image, animatedImage, video, audio
}

/// 章节内媒体文件
struct LNMediaItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let fileName: String
    let kind: LNMediaKind
    let sequence: Int?
    let isAnimated: Bool

    init(path: String, fileName: String, kind: LNMediaKind,
         sequence: Int? = nil, isAnimated: Bool = false) {
        self.path = path
        self.fileName = fileName
        self.kind = kind
        self.sequence = sequence
        self.isAnimated = isAnimated
    }
}

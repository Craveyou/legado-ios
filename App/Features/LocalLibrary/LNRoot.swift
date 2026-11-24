import Foundation

/// 三类书库的本地根目录与首次启动初始化。
/// 根 = App Documents/本地小说/，通过「文件」App → 我的 iPhone → 小浣熊阅读 可见。
/// 小说目录不建、不扫，小说仍走小浣熊自己的书架。
enum LNRoot {
    static let folderName = "本地小说"

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var libraryURL: URL {
        documentsURL.appendingPathComponent(folderName, isDirectory: true)
    }

    static func localSource() -> LNLocalSource {
        ensureFolders()
        return LNLocalSource(rootURL: libraryURL)
    }

    /// 首次启动建三个分类目录（不建"小说"）。已存在则不动用户文件。
    static func ensureFolders() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: libraryURL.path) else { return }
        try? fm.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        for cat in LNCategory.allCases {
            let dir = libraryURL.appendingPathComponent(cat.folderName, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}

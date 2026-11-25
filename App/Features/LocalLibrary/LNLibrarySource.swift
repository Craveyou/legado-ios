import Foundation

/// 本地 / NAS 共用的数据源协议。UI 只依赖它，因此两类页面显示效果天然一致。
protocol LNLibrarySource: Sendable {
    /// 根路径标识：本地为文档目录绝对路径，NAS 为连接 UUID 前缀
    var rootID: String { get }
    /// 某分类的扫描起点（本地 = "漫画"/"整理"/"短剧"；NAS = 该分类根，通常 "/"）
    func categoryRoot(_ category: LNCategory) -> String
    /// 列出某目录下的条目（path 为相对根路径，""/"/" 表示根）
    func list(at path: String) async throws -> [LNNode]
    /// 取文件本地 URL；本地直接返回磁盘 URL，NAS 下载到缓存后返回
    func localURL(for path: String) async throws -> URL
    /// 判断文件是否存在（用于媒体渲染前的检查）
    func exists(at path: String) -> Bool
    /// 删除一个条目（文件或目录，目录递归删除）。path 语义与 list/localURL 一致。
    func remove(at path: String) async throws
    /// 视频/音频流式播放：返回可直接交给 AVURLAsset 的远端 URL + HTTP 认证头（AVPlayer 按 Range 按需拉取，
    /// 不用先把几百 MB 的文件下载完才开始播）。本地源返回 file URL + 空 headers；
    /// 链路不支持流式（如纯 SMB）返回 nil，调用方回退 localURL 整文件下载。
    func streamingVideo(for path: String) async throws -> (URL, [String: String])?
}

// MARK: - 本地文件源

struct LNLocalSource: LNLibrarySource {
    let rootURL: URL
    var rootID: String { rootURL.path }

    func categoryRoot(_ category: LNCategory) -> String { category.folderName }

    func list(at path: String) async throws -> [LNNode] {
        let dir = url(for: path)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var result: [LNNode] = []
        for name in names where !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let rel = path.isEmpty || path == "/"
                ? name
                : path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + name
            result.append(LNNode(path: rel, name: name,
                                  isDirectory: isDir.boolValue, size: Int64(size)))
        }
        return LNNaturalSort.sorted(result) { $0.name }
    }

    func localURL(for path: String) async throws -> URL {
        let url = url(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LNError.notFound(path)
        }
        return url
    }

    func exists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }

    func streamingVideo(for path: String) async throws -> (URL, [String: String])? {
        // 本地文件没有认证头，AVPlayer 直接读磁盘
        (try await localURL(for: path), [:])
    }

    func remove(at path: String) async throws {
        let target = url(for: path)
        // 只允许删本地书库根目录之内的条目，防路径穿越
        let root = rootURL.standardizedFileURL.path
        guard target.standardizedFileURL.path.hasPrefix(root + "/") else {
            throw LNError.outsideLibrary(path)
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw LNError.notFound(path)
        }
        try FileManager.default.removeItem(at: target)
    }

    private func url(for path: String) -> URL {
        let rel = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel.isEmpty ? rootURL : rootURL.appendingPathComponent(rel)
    }
}

// MARK: - NAS 源（复用小浣熊 FeiniuNASService，不动链路层）

struct LNNASSource: LNLibrarySource {
    let connection: FeiniuConnection
    /// 分类根（相对 NAS 共享根），如 "/漫画"
    let rootPath: String
    var rootID: String { "nas." + connection.id.uuidString + rootPath }

    /// 共享根 + 分类目录名，例如 rootPath="/" → "/漫画"
    func categoryRoot(_ category: LNCategory) -> String {
        // 编辑页里单独配了该分类的目录就用它（可指向 NAS 上任意目录，
        // 比如本地文件夹叫 comics 而默认约定是「漫画」）
        if let custom = connection.categoryPath(category) { return custom }
        let root = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return root.isEmpty ? "/" + category.folderName : "/" + root + "/" + category.folderName
    }

    func list(at path: String) async throws -> [LNNode] {
        let full = fullPath(path)
        let entries = try await FeiniuNASService.list(connection, path: full)
        return entries.map { e in
            LNNode(path: join(path, e.name), name: e.name,
                   isDirectory: e.isDirectory, size: e.size)
        }
    }

    func localURL(for path: String) async throws -> URL {
        let full = fullPath(path)
        let parent = (full as NSString).deletingLastPathComponent
        let name = (full as NSString).lastPathComponent
        let entries = try await FeiniuNASService.list(connection, path: parent)
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw LNError.notFound(path)
        }
        return try await FeiniuNASService.download(connection, entry: entry)
    }

    func exists(at path: String) -> Bool {
        // NAS 远端存在性需异步列目录，这里保守返回 true，由 list/localURL 报错
        true
    }

    func streamingVideo(for path: String) async throws -> (URL, [String: String])? {
        // WebDAV 链路直接给远端 URL 流式播放（秒开）；SMB-only / WebDAV 未配置返回 nil
        // 回退整文件下载。之前 NAS 视频每次播放都先把整个文件下载到临时目录
        //（且每次新建 UUID 目录不缓存），几百 MB 的视频在外网要等好几分钟才能开播。
        await FeiniuNASService.streamingVideo(connection, path: fullPath(path))
    }

    func remove(at path: String) async throws {
        let full = fullPath(path)
        let parent = (full as NSString).deletingLastPathComponent
        let name = (full as NSString).lastPathComponent
        // 先查是文件还是目录（命中缓存则零成本）
        let entries = try await FeiniuNASService.list(connection, path: parent)
        let entry = entries.first(where: { $0.name == name })
        try await FeiniuNASService.remove(connection, path: full, isDirectory: entry?.isDirectory ?? false)
    }

    private func fullPath(_ path: String) -> String {
        let rel = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rel.isEmpty { return root.isEmpty ? "/" : "/" + root }
        return root.isEmpty ? "/" + rel : "/" + root + "/" + rel
    }

    private func join(_ base: String, _ name: String) -> String {
        let b = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return b.isEmpty ? name : b + "/" + name
    }
}

enum LNError: LocalizedError {
    case notFound(String)
    case unsupported(String)
    case outsideLibrary(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "找不到文件：\(p)"
        case .unsupported(let e): return "不支持的格式：\(e)"
        case .outsideLibrary(let p): return "不能删除书库之外的文件：\(p)"
        }
    }
}

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

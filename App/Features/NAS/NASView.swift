import SwiftUI
import Network
import Security
#if canImport(FoundationXML)
import FoundationXML
#endif
import AMSMB2

// MARK: - 飞牛 NAS 连接模型

/// NAS 访问协议。App 自动探测：内网走 SMB，外网走 WebDAV。
enum NASProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case smb = "smb"
    case webdav = "webdav"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smb: "SMB（内网）"
        case .webdav: "WebDAV（外网）"
        }
    }

    var other: NASProtocol { self == .smb ? .webdav : .smb }
}

/// 一条飞牛 NAS 的连接配置（内外网共用一个入口，但两条链路各有各的地址），持久化在 UserDefaults。
/// - smbHost：局域网 IP，内网走 SMB2/3 直连
/// - webdavHost：外网域名（或公网 IP），外网走 WebDAV
/// App 自动探测当前可用链路并记住结果；两套账号可不同，WebDAV 留空时复用主账号。
struct FeiniuConnection: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "飞牛 NAS"
    var smbHost: String = ""              // 局域网 IP（SMB）
    var webdavHost: String = ""           // 外网域名（WebDAV）
    var username: String = ""             // SMB 账号（主账号）
    var password: String = ""
    var share: String = ""                // SMB 共享名
    var smbPort: Int = 445
    var webdavScheme: String = "http"     // http / https
    var webdavPort: Int = 5005
    var webdavRootPath: String = "/"
    var webdavUsername: String = ""       // 留空复用主账号
    var webdavPassword: String = ""
    var createdAt: Date = Date()

    init() {}

    var smbAddress: String {
        guard !smbHost.isEmpty else { return "未配置地址" }
        return "smb://\(smbHost):\(smbPort)/\(share)"
    }

    var webdavAddress: String {
        guard !webdavHost.isEmpty else { return "未配置地址" }
        return "\(webdavScheme)://\(webdavHost):\(webdavPort)\(webdavRootPath)"
    }

    /// 连接列表上的两行地址摘要：内网 IP / 外网域名。
    var lanAddressText: String { smbHost.isEmpty ? "内网：未配置" : "内网：\(smbHost)" }
    var wanAddressText: String { webdavHost.isEmpty ? "外网：未配置" : "外网：\(webdavHost)" }

    var effectiveWebDAVUsername: String { webdavUsername.isEmpty ? username : webdavUsername }
    var effectiveWebDAVPassword: String { webdavPassword.isEmpty ? password : webdavPassword }

    /// 去掉用户可能一并粘贴的 scheme 与端口，只保留主机部分。
    static func cleanedHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), url.scheme != nil, let host = url.host { value = host }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        return value
    }
}

/// 旧版 v3（单地址，SMB 与 WebDAV 共用一个 host）数据结构，仅用于迁移。
private struct FeiniuConnectionV3: Decodable {
    var id: UUID?
    var name: String?
    var host: String?
    var username: String?
    var password: String?
    var share: String?
    var smbPort: Int?
    var webdavScheme: String?
    var webdavPort: Int?
    var webdavRootPath: String?
    var webdavUsername: String?
    var webdavPassword: String?
    var createdAt: Date?
}

/// 旧版 v1/v2（单协议）数据结构，仅用于迁移。
private struct FeiniuConnectionV2: Decodable {
    var id: UUID?
    var name: String?
    var proto: String?
    var scheme: String?
    var host: String?
    var port: Int?
    var username: String?
    var password: String?
    var rootPath: String?
    var share: String?
    var createdAt: Date?
}

@MainActor
final class FeiniuConnectionStore: ObservableObject {
    @Published private(set) var connections: [FeiniuConnection] = []
    private let defaults: UserDefaults
    private let key = "nas.feiniu.connections.v4"
    private let legacyKeys = ["nas.feiniu.connections.v3", "nas.feiniu.connections.v2", "nas.feiniu.connections.v1"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([FeiniuConnection].self, from: data) {
            connections = decoded
            return
        }
        // v3：单地址。旧地址先同时填入内网/外网，用户可在编辑页改成各自的 IP / 域名。
        if let data = defaults.data(forKey: "nas.feiniu.connections.v3"),
           let old = try? JSONDecoder().decode([FeiniuConnectionV3].self, from: data) {
            connections = old.map { item in
                var value = FeiniuConnection()
                value.id = item.id ?? UUID()
                value.name = item.name ?? "飞牛 NAS"
                let legacy = item.host ?? ""
                value.smbHost = legacy
                value.webdavHost = legacy
                value.username = item.username ?? ""
                value.password = item.password ?? ""
                value.share = item.share ?? ""
                value.smbPort = item.smbPort ?? 445
                value.webdavScheme = item.webdavScheme ?? "http"
                value.webdavPort = item.webdavPort ?? 5005
                value.webdavRootPath = item.webdavRootPath ?? "/"
                value.webdavUsername = item.webdavUsername ?? ""
                value.webdavPassword = item.webdavPassword ?? ""
                value.createdAt = item.createdAt ?? Date()
                return value
            }
            persist()
            return
        }
        for legacy in ["nas.feiniu.connections.v2", "nas.feiniu.connections.v1"] {
            guard let data = defaults.data(forKey: legacy),
                  let old = try? JSONDecoder().decode([FeiniuConnectionV2].self, from: data) else { continue }
            connections = old.map { item in
                var value = FeiniuConnection()
                value.id = item.id ?? UUID()
                value.name = item.name ?? "飞牛 NAS"
                let host = item.host ?? ""
                value.smbHost = host
                value.webdavHost = host
                value.username = item.username ?? ""
                value.password = item.password ?? ""
                value.share = item.share ?? ""
                value.webdavScheme = item.scheme ?? "http"
                value.webdavPort = item.proto == "smb" ? 5005 : (item.port ?? 5005)
                value.webdavRootPath = item.rootPath ?? "/"
                value.createdAt = item.createdAt ?? Date()
                return value
            }
            persist()
            return
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: key)
    }

    func upsert(_ connection: FeiniuConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        persist()
    }

    func delete(_ connection: FeiniuConnection) {
        connections.removeAll { $0.id == connection.id }
        persist()
        UserDefaults.standard.removeObject(forKey: FeiniuNASService.cacheKey(connection.id))
    }
}

// MARK: - WebDAV 客户端

struct NASEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String          // 服务器路径（WebDAV 解码后的路径 / SMB share 内相对路径）
    let name: String
    let isDirectory: Bool
    let size: Int64
}

/// WebDAV 实际命中的接入点。
/// 飞牛默认 5005(HTTP) / 5006(HTTPS)，但常见环境只映射了其中一个端口，
/// 或者只在路由器/反代上放了 443。探测成功后记住命中的组合，后续直接用。
struct FeiniuWebDAVEndpoint: Hashable, Sendable {
    var scheme: String
    var port: Int

    var label: String { "\(scheme)://…:\(port)" }

    /// 标准端口不写进 URL：部分反向代理对带端口的 Host 头不认
    var usesStandardPort: Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }
}

enum FeiniuEndpointStore {
    private static func key(_ id: UUID) -> String { "nas.feiniu.webdav.endpoint." + id.uuidString }

    static func endpoint(for connection: FeiniuConnection) -> FeiniuWebDAVEndpoint? {
        guard let raw = UserDefaults.standard.string(forKey: key(connection.id)) else { return nil }
        let parts = raw.split(separator: "|")
        guard parts.count == 2, let port = Int(parts[1]) else { return nil }
        return FeiniuWebDAVEndpoint(scheme: String(parts[0]), port: port)
    }

    static func store(_ endpoint: FeiniuWebDAVEndpoint, for connection: FeiniuConnection) {
        UserDefaults.standard.set("\(endpoint.scheme)|\(endpoint.port)", forKey: key(connection.id))
    }

    static func clear(for connection: FeiniuConnection) {
        UserDefaults.standard.removeObject(forKey: key(connection.id))
    }
}

/// 域名在本机实际解析出的 IP。用于区分「域名被别人解析到别处（WiFi 劫持 / 陈旧 DDNS）」与「服务没开」。
enum NASDNSLookup {
    static func addresses(of host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [] }
        defer { freeaddrinfo(result) }
        var output: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let current = cursor {
            if let address = current.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: 128)
                if getnameinfo(address, current.pointee.ai_addrlen,
                               &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: buffer)
                    if !ip.isEmpty, !output.contains(ip) { output.append(ip) }
                }
            }
            cursor = current.pointee.ai_next
        }
        return output
    }
}

/// 把网络错误翻译成「该去检查哪里」，而不是甩一句 The request timed out。
enum NASDiagnostics {
    static func short(_ error: Error) -> String {
        if let feiniu = error as? FeiniuError {
            switch feiniu {
            case .http(let code):
                return code == 400 || code == 405
                    ? "HTTP \(code)（该端口不是 WebDAV 服务）"
                    : feiniu.errorDescription ?? "HTTP \(code)"
            case .webdav(let detail):
                return detail
            default:
                return feiniu.errorDescription ?? "未知错误"
            }
        }
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "域名解析失败（DNS 劫持/DDNS 未更新？）"
        case .cannotConnectToHost:
            return "端口未开放（连接被拒绝：服务未启用或未做端口映射）"
        case .timedOut:
            return "连接超时（端口被防火墙拦、映射错误，或 IPv6 不可达）"
        case .secureConnectionFailed:
            return "TLS 握手失败（-1200，网络中断或代理/门户干扰）"
        case .serverCertificateUntrusted:
            return "TLS 证书不可信（-1202）"
        case .serverCertificateHasBadDate:
            return "TLS 证书过期（-1201）"
        case .serverCertificateNotYetValid:
            return "TLS 证书未生效（-1204）"
        case .serverCertificateHasUnknownRoot:
            return "TLS 证书根不受信任（-1203）"
        case .notConnectedToInternet:
            return "设备当前没有网络"
        case .networkConnectionLost:
            return "连接被中断（切换网络或服务器断开）"
        case .badURL, .unsupportedURL:
            return "地址格式不对"
        default:
            return "网络错误（\(urlError.code.rawValue)）"
        }
    }
}

private enum FeiniuError: LocalizedError {
    case invalidAddress
    case missingShare
    case http(Int)
    case nonHTTP
    case invalidXML
    case smb(String)
    case webdav(String)
    case noLink(smbHost: String, smbError: String, webdavHost: String, webdavError: String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "地址或端口无效：内网填局域网 IP、外网填域名（均不含协议和端口）"
        case .missingShare: "SMB 需要填写共享名（飞牛「文件服务 → SMB」里共享文件夹的名称）"
        case .http(let code):
            switch code {
            case 401: "账号或密码错误，或该账号没有 WebDAV 权限（飞牛需使用独立 WebDAV 账号）"
            case 403: "账号没有该目录的访问权限"
            case 404: "路径不存在，请检查初始路径（飞牛根目录一般填 /）"
            default: "服务器返回 HTTP \(code)"
            }
        case .nonHTTP: "服务器返回的不是 HTTP 响应"
        case .invalidXML: "WebDAV 返回的目录数据无法解析"
        case .smb(let detail): "SMB 连接失败：\(detail)"
        case .webdav(let detail): "外网 WebDAV 连不上：\(detail)"
        case .noLink(let smbHost, let smbError, let webdavHost, let webdavError):
            "两条链路都不可用。内网 SMB（\(smbHost)）：\(smbError)；外网 WebDAV（\(webdavHost)）：\(webdavError)。请检查：① 飞牛「文件服务」里 SMB / WebDAV 是否已启用；② 路由器是否把外部 5005、5006 映射到 NAS；③ 域名若同时有 IPv6 记录而 IPv6 不通，蜂窝网络会先试 IPv6 导致超时。"
        }
    }
}

/// 飞牛自签证书信任：行为与项目整体设置一致（忽略证书错误）。
/// 单独实现以免 NAS 页依赖额外模块，保持本文件自包含。
private final class FeiniuTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = FeiniuTrustDelegate()

    private let lock = NSLock()
    private var certificateNote: String?

    /// 最近一次 TLS 挑战里看到的服务器证书主体。
    /// 如果 App 报证书错误但这里记的是别人的域名，基本就是 WiFi 门户/抓包代理在换证。
    static func lastCertificateNote() -> String? {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.certificateNote
    }

    static func resetNote() {
        shared.lock.lock(); shared.certificateNote = nil; shared.lock.unlock()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            let note = Self.subject(of: trust)
            lock.lock(); certificateNote = note; lock.unlock()
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private static func subject(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }
}

/// 网络环境探测：判断设备当前是否具备访问内网 SMB 的条件。
/// 用 NWPathMonitor 读取系统网络路径，比"IP 是不是私有段"更可靠：
/// - Wi-Fi / 以太网且已连通：尝试内网 SMB；
/// - 蜂窝 / 未连通：跳过 SMB，直接走外网 WebDAV，避免拿内网 IP 空等超时。
private enum NASNetwork {
    /// 逃逸闭包里的一次性标志，避免重复 resume continuation。
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// 旧判断：只看"有没有 Wi-Fi/以太网"，无法区分家里的 WiFi 和外面的 WiFi，已不再作为链路依据。
    /// 保留仅为诊断参考，实际选路一律以 canReachSMB 的 TCP 预检结果为准。
    static func hasLocalInterface() async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once()
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "nas.network.probe")
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                let usable = path.status == .satisfied &&
                    (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
                continuation.resume(returning: usable)
                monitor.cancel()
            }
            monitor.start(queue: queue)
        }
    }

    /// 方案1：对 smbHost:smbPort 做一次带硬超时的 TCP 连接预检。
    /// 只有 445 端口真的能握手，才判定"当前可达 NAS 内网"，进而允许尝试 SMB。
    /// - 外面 WiFi / 蜂窝：445 不通 → 1.5s 内失败，直接跳过 SMB，绝不进入 AMSMB2 的不可取消 connect。
    /// - 人在内网：445 通 → 强制 SMB 优先，即使上次缓存的是 WebDAV 也不会继续走外网。
    /// NWConnection 的 connect 可被 cancel，配合 DispatchSourceTimer 实现真正的硬超时。
    /// 承载不可 Sendable 的 NWConnection / Timer，供 @Sendable 回调安全捕获。
    /// finish 做成方法而非闭包，避免"非 Sendable 闭包被 @Sendable 回调捕获"的编译错误。
    private final class TCPProbeBox: @unchecked Sendable {
        let once = Once()
        var connection: NWConnection?
        var timer: DispatchSourceTimer?
        var continuation: CheckedContinuation<Bool, Never>?

        func finish(_ reachable: Bool) {
            guard once.claim() else { return }
            timer?.cancel()
            connection?.cancel()
            continuation?.resume(returning: reachable)
        }
    }

    /// 预检结果缓存：外网每次列目录都会先问"445 通不通"，不通要白等满 1.5s。
    /// 同一网络下这个结果短时间内不会变，缓存 5 秒能把连续浏览的延迟直接砍掉。
    private static let probeCache = NASTimedCache<Bool>()

    static func invalidateProbeCache() {
        probeCache.clear()
    }

    static func canReachSMB(host: String, port: Int, timeout: TimeInterval = 1.5) async -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (1...65535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }

        let cacheKey = "\(trimmed):\(port)"
        if let hit = probeCache.value(for: cacheKey, ttl: 5) { return hit }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(trimmed), port: nwPort)
        let reachable = await withCheckedContinuation { continuation in
            let box = TCPProbeBox()
            box.continuation = continuation
            let queue = DispatchQueue(label: "nas.smb.tcp.probe")
            let connection = NWConnection(to: endpoint, using: .tcp)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            box.connection = connection
            box.timer = timer
            // 回调只捕获 box（@unchecked Sendable），并通过它的方法收尾，
            // 不捕获任何非 Sendable 闭包或对象，满足 Swift 6 严格并发检查。
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.finish(true)
                case .failed, .cancelled: box.finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { box.finish(false) }
            timer.resume()
        }
        probeCache.set(reachable, for: cacheKey)
        return reachable
    }
}

/// SMB2/3 客户端（内网直连）：基于 AMSMB2/libsmb2。
/// 每条连接独立创建 SMB2Manager，Swift 对象释放时库会自动断开共享。
private enum FeiniuSMB {
    /// 探测用短超时，避免公网环境连 445 端口长时间阻塞。
    static func probe(_ connection: FeiniuConnection, timeout: TimeInterval = 4) async throws {
        let manager = try makeManager(connection, timeout: timeout)
        try await connect(manager, connection)
    }

    static func list(_ connection: FeiniuConnection, path: String) async throws -> [NASEntry] {
        let manager = try makeManager(connection, timeout: 8)
        try await connect(manager, connection)
        let items = try await manager.contentsOfDirectory(atPath: path, recursive: false)
        return items.compactMap { entry in
            guard let name = entry[.nameKey] as? String, !name.isEmpty else { return nil }
            let resolvedPath = smbPath(entry[.pathKey] as? String, parent: path, name: name)
            let isDirectory = (entry[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            let size = (entry[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
            return NASEntry(path: resolvedPath, name: name, isDirectory: isDirectory, size: size)
        }
    }

    /// SMB 删除：AMSMB2 的 removeItem 递归删目录
    static func remove(_ connection: FeiniuConnection, path: String) async throws {
        let manager = try makeManager(connection, timeout: 8)
        try await connect(manager, connection)
        try await manager.removeItem(atPath: path)
        FeiniuNASService.invalidateListCache(prefix: connection.id.uuidString)
    }

    static func download(_ connection: FeiniuConnection, entry: NASEntry) async throws -> URL {
        let manager = try makeManager(connection, timeout: 20)
        try await connect(manager, connection)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("feiniu-smb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = entry.name.isEmpty ? "download" : entry.name
        let target = folder.appendingPathComponent(filename)
        try await manager.downloadItem(atPath: entry.path, to: target, progress: nil)
        return target
    }

    private static func makeManager(_ connection: FeiniuConnection, timeout: TimeInterval) throws -> SMB2Manager {
        guard !connection.smbHost.isEmpty, (1...65535).contains(connection.smbPort),
              let url = URL(string: "smb://\(connection.smbHost):\(connection.smbPort)") else {
            throw FeiniuError.invalidAddress
        }
        guard !connection.share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FeiniuError.missingShare
        }
        let credential = URLCredential(user: connection.username, password: connection.password, persistence: .forSession)
        guard let manager = SMB2Manager(url: url, domain: "", credential: credential) else {
            throw FeiniuError.smb("无法初始化 SMB 客户端")
        }
        manager.timeout = timeout
        return manager
    }

    /// 底层 connectShare 是同步阻塞调用且不响应 Swift 取消，无法在 Swift 层硬超时。
    /// 真正的防护在上层 NASNetwork：无内网接口时根本不会调用到这里。
    private static func connect(_ manager: SMB2Manager, _ connection: FeiniuConnection) async throws {
        try await manager.connectShare(name: connection.share)
    }

    /// libsmb2 的 pathKey 一般是 share 内完整路径；缺失时用父路径 + 文件名兜底。
    private static func smbPath(_ raw: String?, parent: String, name: String) -> String {
        if var value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            if !value.hasPrefix("/") { value = "/" + value }
            return value
        }
        let base = parent.isEmpty ? "/" : parent
        return (base as NSString).appendingPathComponent(name)
    }
}

/// 飞牛 WebDAV 最小实现：PROPFIND 探测与列目录、GET 下载。
private enum FeiniuWebDAV {
    /// 候选端点：用户配置的排第一，再补飞牛常见的 5005/5006/443。
    /// 很多失败不是账号问题，而是公网只映射了其中一个端口。
    static func candidates(for connection: FeiniuConnection) -> [FeiniuWebDAVEndpoint] {
        var list = [FeiniuWebDAVEndpoint(scheme: connection.webdavScheme,
                                         port: connection.webdavPort)]
        let common = [
            FeiniuWebDAVEndpoint(scheme: "http", port: 5005),
            FeiniuWebDAVEndpoint(scheme: "https", port: 5006),
            FeiniuWebDAVEndpoint(scheme: "https", port: 443),
            FeiniuWebDAVEndpoint(scheme: "http", port: 5006),
            FeiniuWebDAVEndpoint(scheme: "https", port: 5005)
        ]
        for item in common where !list.contains(item) { list.append(item) }
        // 上次命中的端点排最前，避免每次进来都从错端口试起
        if let stored = FeiniuEndpointStore.endpoint(for: connection),
           let index = list.firstIndex(of: stored) {
            list.remove(at: index)
            list.insert(stored, at: 0)
        }
        return list
    }

    /// 逐个候选端点试 PROPFIND；成功即记住该端点。
    /// 全部失败时把每个端点的失败原因（含错误码与服务器证书 CN）汇总抛出，
    /// 这样截图就能分辨是「端口没开」「证书被换（被抓包/门户认证）」还是「账号不对」。
    static func probe(_ connection: FeiniuConnection, timeout: TimeInterval = 12) async throws {
        var notes: [String] = []
        var isFirst = true
        for endpoint in candidates(for: connection) {
            // 用户配置的那个给足超时，其余快速试错
            let budget = isFirst ? timeout : 5
            isFirst = false
            FeiniuTrustDelegate.resetNote()
            do {
                let hit = try await verify(connection, endpoint: endpoint, timeout: budget)
                FeiniuEndpointStore.store(hit, for: connection)
                return
            } catch {
                var note = "\(endpoint.label) \(NASDiagnostics.short(error))"
                if let cert = FeiniuTrustDelegate.lastCertificateNote() {
                    note += "［证书 \(cert)］"
                }
                notes.append(note)
            }
        }
        FeiniuEndpointStore.clear(for: connection)
        var summary = notes.joined(separator: "；")
        let host = connection.webdavHost
        let ips = await Task.detached(priority: .userInitiated) { NASDNSLookup.addresses(of: host) }.value
        if !ips.isEmpty {
            summary += "（本机解析 \(host) → \(ips.joined(separator: ", "))）"
        }
        throw FeiniuError.webdav(summary)
    }

    /// 验证单个端点；明文端点遇到 3xx 会自动升级到 HTTPS 再试一次
    /// （飞牛 / nginx 默认把 http 重定向到 https，旧逻辑会把它当失败）。
    /// 返回实际生效的端点（可能是升级后的 https）。
    private static func verify(_ connection: FeiniuConnection,
                               endpoint: FeiniuWebDAVEndpoint,
                               timeout: TimeInterval) async throws -> FeiniuWebDAVEndpoint {
        let (_, response) = try await request(connection, method: "PROPFIND", path: connection.webdavRootPath,
                                              depth: "0", timeout: timeout, endpoint: endpoint)
        if endpoint.scheme == "http", (300...399).contains(response.statusCode) {
            let upgraded = FeiniuWebDAVEndpoint(scheme: "https", port: endpoint.port)
            let (_, again) = try await request(connection, method: "PROPFIND", path: connection.webdavRootPath,
                                               depth: "0", timeout: timeout, endpoint: upgraded)
            guard again.statusCode == 200 || again.statusCode == 207 else {
                throw FeiniuError.http(again.statusCode)
            }
            return upgraded
        }
        guard response.statusCode == 200 || response.statusCode == 207 else {
            throw FeiniuError.http(response.statusCode)
        }
        return endpoint
    }

    static func list(_ connection: FeiniuConnection, path: String) async throws -> [NASEntry] {
        let (data, response) = try await request(connection, method: "PROPFIND", path: path, depth: "1")
        guard response.statusCode == 200 || response.statusCode == 207 else {
            throw FeiniuError.http(response.statusCode)
        }
        let parser = PropfindParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = false
        xml.delegate = parser
        guard xml.parse() else { throw xml.parserError ?? FeiniuError.invalidXML }

        let root = normalized(path)
        return parser.items.compactMap { item in
            let itemPath = normalized(item.path)
            guard !itemPath.isEmpty, itemPath != root else { return nil }  // 过滤目录自身
            let name = item.name.isEmpty ? (item.path as NSString).lastPathComponent : item.name
            return NASEntry(path: item.path, name: name, isDirectory: item.isDirectory, size: item.size)
        }
    }

    static func download(_ connection: FeiniuConnection, entry: NASEntry) async throws -> URL {
        var urlRequest = try makeRequest(connection, method: "GET", path: entry.path)
        let session = makeSession()
        let (tempURL, response) = try await session.download(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw FeiniuError.nonHTTP }
        guard (200...299).contains(http.statusCode) else { throw FeiniuError.http(http.statusCode) }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("feiniu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = entry.name.isEmpty ? "download" : entry.name
        let target = folder.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: tempURL, to: target)
        return target
    }

    /// WebDAV DELETE：删文件；删目录时带 Depth: infinity，服务端递归删除
    static func remove(_ connection: FeiniuConnection, path: String, isDirectory: Bool) async throws {
        var urlRequest = try makeRequest(connection, method: "DELETE", path: path)
        if isDirectory { urlRequest.setValue("infinity", forHTTPHeaderField: "Depth") }
        let session = makeSession()
        let (_, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw FeiniuError.nonHTTP }
        guard (200...299).contains(http.statusCode) else { throw FeiniuError.http(http.statusCode) }
        // 目录列表缓存失效，否则删完还能看到
        FeiniuNASService.invalidateListCache(prefix: connection.id.uuidString)
    }

    private static func request(_ connection: FeiniuConnection, method: String, path: String, depth: String?, timeout: TimeInterval = 25, endpoint: FeiniuWebDAVEndpoint? = nil) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = try makeRequest(connection, method: method, path: path, timeout: timeout, endpoint: endpoint)
        if let depth { urlRequest.setValue(depth, forHTTPHeaderField: "Depth") }
        if method == "PROPFIND" { urlRequest.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        let session = makeSession()
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw FeiniuError.nonHTTP }
        return (data, http)
    }

    private static func makeRequest(_ connection: FeiniuConnection, method: String, path: String, timeout: TimeInterval = 25, endpoint: FeiniuWebDAVEndpoint? = nil) throws -> URLRequest {
        guard !connection.webdavHost.isEmpty else { throw FeiniuError.invalidAddress }
        // 优先用探测命中的端点（可能是 5006 或 443），否则回到用户配置
        let resolved = endpoint
            ?? FeiniuEndpointStore.endpoint(for: connection)
            ?? FeiniuWebDAVEndpoint(scheme: connection.webdavScheme, port: connection.webdavPort)
        guard (1...65535).contains(resolved.port) else { throw FeiniuError.invalidAddress }
        var components = URLComponents()
        components.scheme = resolved.scheme
        components.host = connection.webdavHost
        components.port = resolved.usesStandardPort ? nil : resolved.port
        let target = path.isEmpty ? "/" : path
        components.path = target.hasPrefix("/") ? target : "/" + target
        guard let url = components.url else { throw FeiniuError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        let basic = Data("\(connection.effectiveWebDAVUsername):\(connection.effectiveWebDAVPassword)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("小浣熊阅读/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 复用同一个 session：TLS 会话恢复 + 连接复用，外网每次列目录能省一次完整握手。
    /// 之前每次 request 都新建 ephemeral session，等于每次都重做 TCP+TLS 握手，
    /// 高 RTT 的外网每次点目录都要多等一个 RTT 以上。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: FeiniuTrustDelegate.shared, delegateQueue: nil)
    }()

    private static func makeSession() -> URLSession { session }

    private static func normalized(_ path: String) -> String {
        var value = path.removingPercentEncoding ?? path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

/// 线程安全的小缓存（Swift 6 下 async 上下文不能直接用 NSLock，
/// 所以把锁和可变字典封装进 @unchecked Sendable 类，方法都是同步的）。
private final class NASTimedCache<V: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: (value: V, at: Date)] = [:]

    func value(for key: String, ttl: TimeInterval) -> V? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = storage[key], Date().timeIntervalSince(hit.at) < ttl else { return nil }
        return hit.value
    }

    func set(_ value: V, for key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = (value, Date())
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }

    /// 删除 key 含指定前缀的缓存项（例如某条 NAS 连接下的所有目录）
    func removeAll(containing prefix: String) {
        lock.lock(); defer { lock.unlock() }
        for key in storage.keys where key.contains(prefix) {
            storage[key] = nil
        }
    }
}

/// 自动探测结果缓存：key 为连接 id，value 为上次成功的协议。
/// 网络切换后缓存可能失效，list 失败时会自动重新探测并切换。
enum FeiniuNASService {
    private static let cachePrefix = "nas.feiniu.link."

    static func cacheKey(_ id: UUID) -> String { cachePrefix + id.uuidString }

    private static func cached(_ connection: FeiniuConnection) -> NASProtocol? {
        guard let raw = UserDefaults.standard.string(forKey: cacheKey(connection.id)) else { return nil }
        return NASProtocol(rawValue: raw)
    }

    private static func store(_ proto: NASProtocol, for connection: FeiniuConnection) {
        UserDefaults.standard.set(proto.rawValue, forKey: cacheKey(connection.id))
    }

    /// 网络变化后清掉旧链路缓存，避免"人在内网却沿用上次 WebDAV 缓存"。
    static func clearCache(for connection: FeiniuConnection) {
        UserDefaults.standard.removeObject(forKey: cacheKey(connection.id))
    }

    /// 上次探测到的链路，仅用于 UI 展示；nil 表示还没探测过。
    static func activeProtocol(_ connection: FeiniuConnection) -> NASProtocol? {
        cached(connection)
    }

    /// 当前网络下这条链路是否"可用到值得尝试"。
    /// smbReachable 来自 canReachSMB 的真实 TCP 探测（445 握手成功），不是"是否连着 WiFi"。
    /// - WiFi 但不在 NAS 内网（外面 WiFi）：445 不通 → 排除 SMB，直接走 WebDAV，不卡死。
    /// - 在内网：445 通 → SMB 可用。
    private static func isViable(_ proto: NASProtocol, _ connection: FeiniuConnection, smbReachable: Bool) -> Bool {
        let configured = proto == .smb
            ? !connection.smbHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !connection.webdavHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !configured { return false }
        if proto == .smb && !smbReachable { return false }
        return true
    }

    /// 探测两条链路：smbHost 是内网 IP、webdavHost 是外网域名，各走各的地址。
    /// 先用 TCP 预检判定内网是否真的可达：
    /// - 445 通 → SMB 强制排第一（忽略旧缓存，修复"在内网却因缓存走外网"）。
    /// - 445 不通 → 只走 WebDAV，绝不调用 AMSMB2 那个不可取消的 connect。
    @discardableResult
    static func resolve(_ connection: FeiniuConnection) async throws -> NASProtocol {
        let smbReachable = await NASNetwork.canReachSMB(host: connection.smbHost, port: connection.smbPort)
        let preferred: NASProtocol = smbReachable ? .smb : .webdav
        let order: [NASProtocol] = smbReachable ? [.smb, .webdav] : [.webdav]
        var failures: [NASProtocol: String] = [:]
        for proto in order {
            guard isViable(proto, connection, smbReachable: smbReachable) else {
                failures[proto] = proto == .smb
                    ? (connection.smbHost.isEmpty ? "未配置内网 IP" : "当前网络无法连接内网 445，已跳过 SMB")
                    : "未配置外网域名"
                continue
            }
            do {
                switch proto {
                case .smb: try await FeiniuSMB.probe(connection)
                case .webdav: try await FeiniuWebDAV.probe(connection)
                }
                store(proto, for: connection)
                return proto
            } catch {
                failures[proto] = NASDiagnostics.short(error)
            }
        }
        throw FeiniuError.noLink(
            smbHost: connection.smbHost.isEmpty ? "未配置" : connection.smbHost,
            smbError: failures[.smb] ?? "未测试",
            webdavHost: connection.webdavHost.isEmpty ? "未配置" : connection.webdavHost,
            webdavError: failures[.webdav] ?? "未测试"
        )
    }

    static func probe(_ connection: FeiniuConnection) async throws -> NASProtocol {
        try await resolve(connection)
    }

    /// 列目录：先用 TCP 预检判定当前网络期望的链路（445 通=内网 SMB，否则外网 WebDAV）。
    /// 缓存链路与期望一致才直接用；不一致（如人在内网但缓存是 WebDAV）则重新探测，避免继续走外网。
    /// 这样断开 WiFi / 换到外面 WiFi 后，即便缓存是 SMB，也不会拿内网 IP 去连导致卡死。
    /// 目录列表缓存：外网上一张图片就要列一次父目录（LNNASSource.localURL），
    /// 没有缓存的话预取 8 张图就是 8 次 PROPFIND。缓存 30 秒，覆盖一次章节阅读。
    private static let listCache = NASTimedCache<[NASEntry]>()

    static func invalidateListCache() {
        listCache.clear()
    }

    /// 只清某条连接的目录缓存（删除文件后调用）
    static func invalidateListCache(prefix: String) {
        listCache.removeAll(containing: prefix)
    }

    private static func listCacheKey(_ connection: FeiniuConnection, _ path: String) -> String {
        "\(connection.id.uuidString)|\(path)"
    }

    static func list(_ connection: FeiniuConnection, path: String) async throws -> [NASEntry] {
        // 先查缓存（刷新/下拉时会主动清）
        let key = listCacheKey(connection, path)
        if let hit = listCache.value(for: key, ttl: 30) {
            return hit.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        let smbReachable = await NASNetwork.canReachSMB(host: connection.smbHost, port: connection.smbPort)
        let expected: NASProtocol = smbReachable ? .smb : .webdav
        let entries: [NASEntry]
        if let proto = cached(connection), proto == expected, isViable(proto, connection, smbReachable: smbReachable) {
            do { entries = try await fetch(connection, proto: proto, path: path) }
            catch {
                let refreshed = try await resolve(connection)
                if refreshed == proto { throw error }
                entries = try await fetch(connection, proto: refreshed, path: path)
            }
        } else {
            let proto = try await resolve(connection)
            entries = try await fetch(connection, proto: proto, path: path)
        }
        // 统一按名称自然排序（数字序号 2 排在 10 前），目录在前。
        // 放在数据源层：FeiniuBrowserView、LNNASSource 三类书库等所有调用点都受益。
        let sorted = entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        listCache.set(sorted, for: key)
        return sorted
    }

    /// 删除远端条目：按当前链路分发到 SMB/WebDAV
    static func remove(_ connection: FeiniuConnection, path: String, isDirectory: Bool) async throws {
        let smbReachable = await NASNetwork.canReachSMB(host: connection.smbHost, port: connection.smbPort)
        if smbReachable, !connection.smbHost.isEmpty {
            do {
                try await FeiniuSMB.remove(connection, path: path)
                return
            } catch {
                // SMB 删除失败则尝试 WebDAV（某些共享只读）
            }
        }
        try await FeiniuWebDAV.remove(connection, path: path, isDirectory: isDirectory)
    }

    static func download(_ connection: FeiniuConnection, entry: NASEntry) async throws -> URL {
        let smbReachable = await NASNetwork.canReachSMB(host: connection.smbHost, port: connection.smbPort)
        let expected: NASProtocol = smbReachable ? .smb : .webdav
        let proto: NASProtocol
        if let cachedProto = cached(connection), cachedProto == expected,
           isViable(cachedProto, connection, smbReachable: smbReachable) {
            proto = cachedProto
        } else {
            proto = try await resolve(connection)
        }
        switch proto {
        case .smb: return try await FeiniuSMB.download(connection, entry: entry)
        case .webdav: return try await FeiniuWebDAV.download(connection, entry: entry)
        }
    }

    private static func fetch(_ connection: FeiniuConnection, proto: NASProtocol, path: String) async throws -> [NASEntry] {
        switch proto {
        case .smb: return try await FeiniuSMB.list(connection, path: path)
        case .webdav: return try await FeiniuWebDAV.list(connection, path: path)
        }
    }

    static func initialPath(_ connection: FeiniuConnection) -> String {
        cached(connection) == .smb ? "/" : connection.webdavRootPath
    }
}

/// 解析 WebDAV multistatus：response / href / displayname / collection / getcontentlength。
private final class PropfindParser: NSObject, XMLParserDelegate {
    struct Item {
        var path = ""
        var name = ""
        var isDirectory = false
        var size: Int64 = 0
    }

    var items: [Item] = []
    private var current: Item?
    private var activeField: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch local(elementName) {
        case "response":
            current = Item()
        case "href", "displayname", "getcontentlength":
            activeField = local(elementName)
            text = ""
        case "collection":
            current?.isDirectory = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeField != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch local(elementName) {
        case "href":
            current?.path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            activeField = nil
        case "displayname":
            current?.name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            activeField = nil
        case "getcontentlength":
            current?.size = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            activeField = nil
        case "response":
            if let item = current { items.append(item) }
            current = nil
        default:
            break
        }
    }

    private func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }
}

// MARK: - NAS 主页面

struct NASView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @StateObject private var store = FeiniuConnectionStore()
    @State private var showingAdd = false
    @State private var editing: FeiniuConnection?
    /// 当前网络下每条连接实际可用的链路（实时 TCP 预检得出），不用旧缓存误导用户。
    @State private var liveLinks: [UUID: NASProtocol] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if store.connections.isEmpty {
                    emptyState
                } else {
                    connectionList
                }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(ReadingTheme.canvas.ignoresSafeArea())
        .navigationBarHidden(true)
        .task(id: store.connections.map(\.id)) {
            await refreshLinks()
        }
        .sheet(isPresented: $showingAdd) {
            FeiniuConnectionFormView(store: store)
        }
        .sheet(item: $editing) { connection in
            FeiniuConnectionFormView(store: store, connection: connection)
        }
        .accessibilityIdentifier("nas.scroll")
    }

    /// 进入页面 / 连接变化时，对每条连接做一次真实 TCP 预检，更新"当前链路"标签。
    /// 只判 445 是否可达，不建立 SMB 会话，开销很小；不依赖上次缓存。
    private func refreshLinks() async {
        var result: [UUID: NASProtocol] = [:]
        for connection in store.connections {
            let reachable = await NASNetwork.canReachSMB(host: connection.smbHost, port: connection.smbPort)
            result[connection.id] = reachable ? .smb : .webdav
            if reachable { FeiniuNASService.clearCache(for: connection) }
        }
        liveLinks = result
    }

    private var header: some View {
        ReadingPageHeader(title: "NAS", subtitle: "网络存储，随处阅读") {
            Button {
                showingAdd = true
            } label: {
                ReadingToolbarIcon(systemName: "plus")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nas.add.connection")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(ReadingTheme.ink.opacity(0.35))
                .accessibilityHidden(true)
            Text("连接你的飞牛 NAS")
                .font(.headline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.75))
            Text("填内网 IP 与外网域名，App 自动识别网络：内网走 SMB、外网走 WebDAV，直接导入书架阅读。")
                .font(.subheadline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                .multilineTextAlignment(.center)
            Button {
                showingAdd = true
            } label: {
                Label("添加飞牛 NAS", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(ReadingTheme.accentFill)
            .padding(.top, 6)
            .accessibilityIdentifier("nas.add.first")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 90)
    }

    private var connectionList: some View {
        VStack(spacing: 12) {
            ForEach(store.connections) { connection in
                NavigationLink {
                    LNNASCategoryView(connection: connection)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 22))
                            .foregroundStyle(ReadingTheme.accent)
                            .frame(width: 42, height: 42)
                            .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.name).font(.headline).foregroundStyle(ReadingTheme.ink)
                            Text(connection.lanAddressText)
                                .font(.caption)
                                .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                                .lineLimit(1)
                            Text(connection.wanAddressText)
                                .font(.caption)
                                .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                                .lineLimit(1)
                            if let active = liveLinks[connection.id] ?? FeiniuNASService.activeProtocol(connection) {
                                Label(active == .smb ? "当前：内网 SMB" : "当前：外网 WebDAV",
                                      systemImage: active == .smb ? "wifi" : "globe")
                                    .font(.caption2)
                                    .foregroundStyle(ReadingTheme.accent)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ReadingTheme.ink.opacity(0.3))
                    }
                    .padding(14)
                    .background(ReadingTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("nas.connection.\(connection.id.uuidString)")
                .contextMenu {
                    Button("编辑") { editing = connection }
                    Button("删除", role: .destructive) { store.delete(connection) }
                }
            }
        }
        .padding(.horizontal, 26)
    }
}

// MARK: - 连接表单

struct FeiniuConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FeiniuConnectionStore

    let connection: FeiniuConnection?
    @State private var name: String
    @State private var smbHost: String
    @State private var webdavHost: String
    @State private var username: String
    @State private var password: String
    @State private var share: String
    @State private var smbPort: String
    @State private var webdavScheme: String
    @State private var webdavPort: String
    @State private var webdavRootPath: String
    @State private var webdavUsername: String
    @State private var webdavPassword: String
    @State private var testing = false
    @State private var testResult: String?
    @State private var errorMessage: String?

    init(store: FeiniuConnectionStore, connection: FeiniuConnection? = nil) {
        self.store = store
        self.connection = connection
        _name = State(initialValue: connection?.name ?? "飞牛 NAS")
        _smbHost = State(initialValue: connection?.smbHost ?? "")
        _webdavHost = State(initialValue: connection?.webdavHost ?? "")
        _username = State(initialValue: connection?.username ?? "")
        _password = State(initialValue: connection?.password ?? "")
        _share = State(initialValue: connection?.share ?? "")
        _smbPort = State(initialValue: String(connection?.smbPort ?? 445))
        _webdavScheme = State(initialValue: connection?.webdavScheme ?? "http")
        _webdavPort = State(initialValue: String(connection?.webdavPort ?? 5005))
        _webdavRootPath = State(initialValue: connection?.webdavRootPath ?? "/")
        _webdavUsername = State(initialValue: connection?.webdavUsername ?? "")
        _webdavPassword = State(initialValue: connection?.webdavPassword ?? "")
    }

    private var draft: FeiniuConnection {
        var value = connection ?? FeiniuConnection()
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "飞牛 NAS" : name
        value.smbHost = FeiniuConnection.cleanedHost(smbHost)
        value.webdavHost = FeiniuConnection.cleanedHost(webdavHost)
        value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        value.password = password
        value.share = share.trimmingCharacters(in: .whitespacesAndNewlines)
        value.smbPort = Int(smbPort) ?? 445
        value.webdavScheme = webdavScheme
        value.webdavPort = Int(webdavPort) ?? (webdavScheme == "https" ? 5006 : 5005)
        let path = webdavRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        value.webdavRootPath = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/" + path)
        value.webdavUsername = webdavUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        value.webdavPassword = webdavPassword
        return value
    }

    /// 至少要配置一条链路：内网 IP + 共享名，或外网域名 + 账号。
    private var canSave: Bool {
        let hasSMB = !draft.smbHost.isEmpty && !draft.share.isEmpty && !draft.username.isEmpty && !draft.password.isEmpty
        let hasWebDAV = !draft.webdavHost.isEmpty && !draft.username.isEmpty && !draft.password.isEmpty
        return hasSMB || hasWebDAV
    }

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                } header: {
                    Text("服务器")
                }

                Section {
                    TextField("局域网 IP（如 192.168.1.10）", text: $smbHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("nas.form.smbHost")
                    TextField("共享名", text: $share)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("nas.form.share")
                    TextField("端口（默认 445）", text: $smbPort)
                        .keyboardType(.numberPad)
                } header: {
                    Text("内网 SMB 地址")
                } footer: {
                    Text("填飞牛在局域网里的 IP，以及「文件服务 → SMB」启用的共享文件夹名；仅在家/Wi-Fi 下可达。")
                }

                Section {
                    TextField("外网域名（如 nas.example.com）", text: $webdavHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("nas.form.webdavHost")
                    Picker("协议", selection: $webdavScheme) {
                        Text("HTTP（默认 5005）").tag("http")
                        Text("HTTPS（默认 5006）").tag("https")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: webdavScheme) { newValue in
                        // 只在端口还是默认值时跟着换，别把用户填的 12300 这类自定义端口冲掉
                        let isDefaultPort = webdavPort.isEmpty || webdavPort == "5005" || webdavPort == "5006"
                        if isDefaultPort {
                            webdavPort = newValue == "https" ? "5006" : "5005"
                        }
                    }
                    TextField("端口", text: $webdavPort)
                        .keyboardType(.numberPad)
                    TextField("初始路径（默认 /）", text: $webdavRootPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("外网 WebDAV 地址")
                } footer: {
                    Text("填外网可访问的域名；需在飞牛「文件服务 → WebDAV」启用，并配置端口转发或反代。")
                }

                Section("账号") {
                    TextField("用户名（SMB）", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码（SMB）", text: $password)
                    TextField("WebDAV 账号（可选，留空复用上方）", text: $webdavUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("WebDAV 密码（可选）", text: $webdavPassword)
                    Text("飞牛 WebDAV 通常需要独立账号；若与 SMB 不同请单独填写。密码仅保存在本机。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Label("测试连接（自动探测）", systemImage: "waveform.path.ecg")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || !canSave)
                    if let testResult {
                        Label(testResult, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("会依次测试内网 SMB 与外网 WebDAV，显示当前可用的链路。连接参数仅保存在本机。")
                }
            }
            .navigationTitle(connection == nil ? "添加飞牛 NAS" : "编辑连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.upsert(draft)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        errorMessage = nil
        defer { testing = false }
        do {
            let proto = try await FeiniuNASService.probe(draft)
            testResult = proto == .smb
                ? "内网 SMB 可用，当前设备走内网链路"
                : "外网 WebDAV 可用，当前设备走外网链路"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 目录浏览与导入

struct FeiniuBrowserView: View {
    @EnvironmentObject private var library: BookLibraryModel
    let connection: FeiniuConnection

    @State private var path: String
    @State private var entries: [NASEntry] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var downloading: String?
    @State private var toast: String?
    @State private var linkLabel: String?
    @State private var isRoot = false
    @State private var editMode: EditMode = .inactive
    @State private var selected: Set<NASEntry.ID> = []
    @State private var confirmDelete = false

    init(connection: FeiniuConnection, path: String? = nil) {
        self.connection = connection
        let root = path == nil
        _isRoot = State(initialValue: root)
        _path = State(initialValue: path ?? FeiniuNASService.initialPath(connection))
    }

    var body: some View {
        Group {
            if loading && entries.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取目录…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if let errorMessage, entries.isEmpty {
                ReadingUnavailableView("无法连接飞牛 NAS", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
            } else {
                List(selection: $selected) {
                    if !entries.isEmpty {
                        Section {
                            ForEach(entries, id: \.path) { entry in
                                entryListRow(entry)
                            }
                        } header: {
                            HStack {
                                Text("\(entries.count) 项 · 点击文件导入书架")
                                Spacer()
                                if let linkLabel { Text(linkLabel).font(.caption2) }
                            }
                        }
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).font(.caption).foregroundStyle(.orange) }
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, $editMode)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if editMode == .active {
                            Button { cancelSelection() } label: {
                                Text("取消").accessibilityLabel("取消多选")
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if editMode == .active {
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Image(systemName: "trash").accessibilityLabel("删除选中")
                            }
                            .disabled(selected.isEmpty)
                        } else {
                            Button { editMode = .active } label: {
                                Text("选择").accessibilityLabel("进入多选模式")
                            }
                        }
                    }
                }
                .alert("删除选中项？", isPresented: $confirmDelete) {
                    Button("取消", role: .cancel) {}
                    Button("删除", role: .destructive) { Task { await deleteSelected() } }
                } message: {
                    Text("将删除 NAS 上选中的文件/目录，不可恢复。")
                }
            }
        }
        .navigationTitle(isRoot ? connection.name : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) { await load(forceRefresh: false) }
        .refreshable {
            FeiniuNASService.invalidateListCache()
            await load(forceRefresh: true)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(ReadingTheme.emphasisSurface, in: Capsule())
                    .foregroundStyle(ReadingTheme.onAccent)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut, value: toast)
        .accessibilityIdentifier("nas.browser.list")
    }

    private func entryRow(_ entry: NASEntry, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(entry.isDirectory ? ReadingTheme.coral : ReadingTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.body).foregroundStyle(ReadingTheme.ink).lineLimit(1)
                if !entry.isDirectory {
                    Text(entry.size > 0 ? formattedSize(entry.size) : "文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func load(forceRefresh: Bool = false) async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            if forceRefresh {
                // 手动下拉才强制重新探测链路
                let proto = try await FeiniuNASService.probe(connection)
                linkLabel = proto == .smb ? "内网 SMB" : "外网 WebDAV"
            } else if let proto = FeiniuNASService.activeProtocol(connection) {
                // 平时直接用上次成功的链路标签，不重复探测（list 内部会按需重探）
                linkLabel = proto == .smb ? "内网 SMB" : "外网 WebDAV"
            }
            // 根目录按实测链路选初始路径：SMB 从 share 根 "/" 开始，WebDAV 用配置的初始路径。
            // 关键：只用于本次取目录，不写回 @State path —— 写回会改变 .task(id: path) 的 id，
            // 触发第二次 load，并让 navigationTitle 从连接名跳成路径末段，落在 push 动画里就是"过渡抖一下"。
            let pathToLoad = isRoot ? FeiniuNASService.initialPath(connection) : path
            // 按名称自然排序（数字章节 2/10 顺序正确），目录在前、文件在后
            let listed = try await FeiniuNASService.list(connection, path: pathToLoad)
            entries = listed.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func entryListRow(_ entry: NASEntry) -> some View {
        Group {
            if entry.isDirectory {
                NavigationLink {
                    FeiniuBrowserView(connection: connection, path: entry.path)
                } label: {
                    entryRow(entry, systemImage: "folder")
                }
            } else {
                Button {
                    Task { await importEntry(entry) }
                } label: {
                    HStack {
                        entryRow(entry, systemImage: "doc.text")
                        if downloading == entry.path {
                            ProgressView().padding(.leading, 6)
                        }
                    }
                }
                .disabled(downloading != nil)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await deleteEntry(entry) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func cancelSelection() {
        selected.removeAll()
        editMode = .inactive
    }

    private func deleteEntry(_ entry: NASEntry) async {
        do {
            try await FeiniuNASService.remove(connection, path: entry.path, isDirectory: entry.isDirectory)
            entries.removeAll { $0.path == entry.path }
            toast = "已删除 \(entry.name)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected() async {
        let targets = entries.filter { selected.contains($0.path) }
        var failed = 0
        for entry in targets {
            do {
                try await FeiniuNASService.remove(connection, path: entry.path, isDirectory: entry.isDirectory)
            } catch {
                failed += 1
            }
        }
        entries.removeAll { selected.contains($0.path) }
        toast = failed == 0 ? "已删除 \(targets.count) 项" : "已删除 \(targets.count - failed) 项，失败 \(failed) 项"
        selected.removeAll()
        editMode = .inactive
    }

    private func importEntry(_ entry: NASEntry) async {
        guard downloading == nil else { return }
        downloading = entry.path
        defer { downloading = nil }
        do {
            let localURL = try await FeiniuNASService.download(connection, entry: entry)
            await library.importLocalFiles([localURL])
            try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
            let message = library.errorMessage ?? "已导入《\(entry.name)》"
            toast = message
            library.clearError()
        } catch {
            toast = "导入失败：\(error.localizedDescription)"
        }
    }
}

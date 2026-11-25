import Foundation

// MARK: - 运行时机

/// 对应油猴的 `@run-at`
enum LNUserscriptRunAt: String, Codable, CaseIterable, Sendable {
    case documentStart = "document-start"
    case documentEnd = "document-end"
    case documentIdle = "document-idle"
    var label: String {
        switch self {
        case .documentStart: return "document-start（DOM 之前）"
        case .documentEnd: return "document-end（DOM 就绪）"
        case .documentIdle: return "document-idle（空闲）"
        }
    }
}

// MARK: - 脚本模型

struct LNUserscript: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var namespace: String = ""
    var version: String = ""
    /// @description
    var summary: String = ""
    /// @match（Chrome match pattern）
    var matchPatterns: [String] = []
    /// @include（通配符语义，兼容老脚本）
    var includePatterns: [String] = []
    /// @exclude
    var excludePatterns: [String] = []
    var runAt: LNUserscriptRunAt = .documentEnd
    var grants: [String] = []
    /// @require：P2 只保存不加载（P3 再做预取拼接）
    var requires: [String] = []
    var code: String = ""
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// 从网址导入时记录来源
    var sourceURL: String? = nil

    /// 列表里展示"作用于哪些站点"：把 match/include 里的域名抽出来
    var displayHosts: [String] {
        var hosts: [String] = []
        for pattern in matchPatterns + includePatterns {
            guard let host = Self.extractHost(from: pattern), !hosts.contains(host) else { continue }
            hosts.append(host)
        }
        return hosts
    }

    var hostSummary: String {
        let hosts = displayHosts
        guard !hosts.isEmpty else { return "未声明匹配范围" }
        if hosts.count <= 2 { return hosts.joined(separator: "、") }
        return "\(hosts.prefix(2).joined(separator: "、")) 等 \(hosts.count) 个站点"
    }

    static func extractHost(from pattern: String) -> String? {
        // pattern 形如 *://*.example.com/path 或 https://a.com/*
        guard let schemeEnd = pattern.range(of: "://") else {
            // @include 可能直接给域名通配
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        var rest = String(pattern[schemeEnd.upperBound...])
        if let slash = rest.firstIndex(of: "/") {
            rest = String(rest[..<slash])
        }
        return rest.isEmpty ? nil : rest
    }
}

// MARK: - 元数据解析

enum LNUserscriptParser {
    /// 解析 `==UserScript==` 头部。没有合法头部时返回 nil。
    static func parse(_ text: String, sourceURL: String? = nil) -> LNUserscript? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let headerStart = normalized.range(of: "==UserScript=="),
              let headerEnd = normalized.range(of: "==/UserScript==", range: headerStart.upperBound..<normalized.endIndex)
        else { return nil }

        let header = normalized[headerStart.upperBound..<headerEnd.lowerBound]
        var script = LNUserscript()
        var name = ""
        var match: [String] = []
        var include: [String] = []
        var exclude: [String] = []
        var grants: [String] = []
        var requires: [String] = []
        var runAt: LNUserscriptRunAt = .documentEnd

        for rawLine in header.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("//") else { continue }
            let content = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard content.hasPrefix("@") else { continue }

            // @key  value（值可能为空，也可能含空格）
            let withoutAt = content.dropFirst()
            let key: String
            let value: String
            if let space = withoutAt.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                key = String(withoutAt[..<space]).lowercased()
                value = String(withoutAt[space...]).trimmingCharacters(in: .whitespaces)
            } else {
                key = String(withoutAt).lowercased()
                value = ""
            }

            switch key {
            case "name": name = value
            case "namespace": script.namespace = value
            case "version": script.version = value
            case "description": script.summary = value
            case "match": if !value.isEmpty { match.append(value) }
            case "include": if !value.isEmpty { include.append(value) }
            case "exclude": if !value.isEmpty { exclude.append(value) }
            case "grant": if !value.isEmpty { grants.append(value) }
            case "require": if !value.isEmpty { requires.append(value) }
            case "run-at":
                if let parsed = LNUserscriptRunAt(rawValue: value.lowercased()) { runAt = parsed }
            case "updateurl", "downloadurl":
                if script.sourceURL == nil, !value.isEmpty { script.sourceURL = value }
            default:
                break
            }
        }

        // 脚本正文 = 头部之后的所有内容
        let body = String(normalized[headerEnd.upperBound...])
        script.code = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.code.isEmpty else { return nil }

        script.name = name.isEmpty ? "未命名脚本" : name
        script.matchPatterns = match
        script.includePatterns = include
        script.excludePatterns = exclude
        script.grants = grants
        script.requires = requires
        script.runAt = runAt
        if let sourceURL, !sourceURL.isEmpty { script.sourceURL = sourceURL }
        return script
    }

    /// 判断一段文本看起来是不是油猴脚本（导入时先校验）
    static func looksLikeUserscript(_ text: String) -> Bool {
        text.contains("==UserScript==") && text.contains("==/UserScript==")
    }
}

// MARK: - URL 匹配

enum LNUserscriptMatcher {
    /// 某个脚本是否应该注入到该 URL
    static func shouldInject(_ script: LNUserscript, into url: URL) -> Bool {
        guard script.isEnabled else { return false }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }

        for pattern in script.excludePatterns where matchesInclude(pattern, url: url) {
            return false
        }

        var hit = false
        if script.matchPatterns.isEmpty && script.includePatterns.isEmpty {
            // 没声明范围：不注入（避免影响所有网站）
            return false
        }
        for pattern in script.matchPatterns where matchesMatchPattern(pattern, url: url) {
            hit = true
            break
        }
        if !hit {
            for pattern in script.includePatterns where matchesInclude(pattern, url: url) {
                hit = true
                break
            }
        }
        return hit
    }

    /// Chrome match pattern：`<scheme>://<host><path>`
    /// - scheme：`*`（仅 http/https）、http、https
    /// - host：`*`、`*.example.com`（含 example.com 本身）、精确域名
    /// - path：必须以 `/` 开头，可含 `*`；匹配 path + query
    static func matchesMatchPattern(_ pattern: String, url: URL) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard let schemeRange = trimmed.range(of: "://") else { return false }
        let schemePart = String(trimmed[..<schemeRange.lowerBound]).lowercased()
        var rest = String(trimmed[schemeRange.upperBound...])

        // path 部分（第一个 / 起）
        var pathPart = "/"
        if let slash = rest.firstIndex(of: "/") {
            pathPart = String(rest[slash...])
            rest = String(rest[..<slash])
        }
        let hostPart = rest.lowercased()

        // scheme
        let urlScheme = (url.scheme ?? "").lowercased()
        if schemePart == "*" {
            guard urlScheme == "http" || urlScheme == "https" else { return false }
        } else if schemePart != urlScheme {
            return false
        }

        // host
        let urlHost = (url.host ?? "").lowercased()
        if hostPart != "*" {
            if hostPart.hasPrefix("*.") {
                let base = String(hostPart.dropFirst(2))
                guard urlHost == base || urlHost.hasSuffix("." + base) else { return false }
            } else if hostPart != urlHost {
                return false
            }
        }

        // path + query
        var target = url.path
        if let query = url.query, !query.isEmpty {
            target += "?" + query
        }
        if target.isEmpty { target = "/" }
        return wildcard(pathPart, target)
    }

    /// @include 语义更宽松：`*` 可出现在任意位置，直接对整串做通配
    static func matchesInclude(_ pattern: String, url: URL) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        var absolute = url.absoluteString
        // 去掉 fragment，避免锚点影响匹配（Tampermonkey 也是忽略 fragment）
        if let hash = absolute.firstIndex(of: "#") {
            absolute = String(absolute[..<hash])
        }
        return wildcard(trimmed, absolute)
    }

    /// 通配匹配：`*` 匹配任意长度（含空）。用回溯法而不是正则，省掉转义问题。
    static func wildcard(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0, ti = 0
        var starIndex = -1
        var matchIndex = 0

        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                starIndex = pi
                matchIndex = ti
                pi += 1
            } else if pi < p.count, p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if starIndex != -1 {
                pi = starIndex + 1
                matchIndex += 1
                ti = matchIndex
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

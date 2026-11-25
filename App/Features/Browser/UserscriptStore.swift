import Foundation
import Combine

/// 油猴脚本仓库：脚本本体存 JSON 文件，GM_* 的键值存 UserDefaults。
///
/// 为什么 GM 值不跟脚本存一起：写入很频繁（脚本可能每次滚动都 set），
/// 而脚本文件是整份重写的。分开存可以做到「写值不重写脚本文件」。
@MainActor
final class LNUserscriptStore: ObservableObject {
    static let shared = LNUserscriptStore()

    @Published private(set) var scripts: [LNUserscript] = []

    private let fileURL: URL
    private let defaults: UserDefaults

    private static let gmKeyPrefix = "ln.userscript.gm."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Userscripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("scripts.json")
        load()
    }

    // MARK: 读写脚本

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        scripts = (try? decoder.decode([LNUserscript].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(scripts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 导入结果
    enum ImportOutcome {
        case added(name: String)
        case updated(name: String)
        case invalid
    }

    /// 导入一个脚本：同 id 更新；同 name + namespace 视为版本更新（覆盖代码与元数据，保留启用状态）
    @discardableResult
    func add(_ script: LNUserscript) -> ImportOutcome {
        var incoming = script
        incoming.updatedAt = Date()

        if let index = scripts.firstIndex(where: { $0.id == incoming.id }) {
            incoming.isEnabled = scripts[index].isEnabled
            scripts[index] = incoming
            persist()
            return .updated(name: incoming.name)
        }
        if !incoming.namespace.isEmpty,
           let index = scripts.firstIndex(where: { $0.name == incoming.name && $0.namespace == incoming.namespace }) {
            incoming.id = scripts[index].id
            incoming.isEnabled = scripts[index].isEnabled
            incoming.createdAt = scripts[index].createdAt
            scripts[index] = incoming
            persist()
            return .updated(name: incoming.name)
        }
        // 连 namespace 都没有的同名脚本也当作更新，避免重复导入堆一堆
        if incoming.namespace.isEmpty,
           let index = scripts.firstIndex(where: { $0.name == incoming.name && $0.namespace.isEmpty }) {
            incoming.id = scripts[index].id
            incoming.isEnabled = scripts[index].isEnabled
            incoming.createdAt = scripts[index].createdAt
            scripts[index] = incoming
            persist()
            return .updated(name: incoming.name)
        }

        scripts.append(incoming)
        scripts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
        return .added(name: incoming.name)
    }

    func update(_ script: LNUserscript) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        var value = script
        value.updatedAt = Date()
        scripts[index] = value
        persist()
    }

    func remove(id: UUID) {
        scripts.removeAll { $0.id == id }
        persist()
        clearGMValues(scriptID: id)
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].isEnabled = enabled
        persist()
    }

    /// 当前 URL 需要注入的脚本（按 run-at 分组由调用方处理）
    func scripts(for url: URL) -> [LNUserscript] {
        scripts.filter { LNUserscriptMatcher.shouldInject($0, into: url) }
    }

    // MARK: GM 值

    private func gmDefaultsKey(_ scriptID: UUID) -> String {
        Self.gmKeyPrefix + scriptID.uuidString
    }

    /// 某个脚本的全部键值（key → JSON 文本）
    func gmValues(scriptID: UUID) -> [String: String] {
        defaults.dictionary(forKey: gmDefaultsKey(scriptID)) as? [String: String] ?? [:]
    }

    /// 写入一个值。json 是 JS 侧 `JSON.stringify(value)` 的结果。
    func setGMValue(scriptID: UUID, key: String, json: String) {
        var values = gmValues(scriptID: scriptID)
        values[key] = json
        defaults.set(values, forKey: gmDefaultsKey(scriptID))
    }

    func deleteGMValue(scriptID: UUID, key: String) {
        var values = gmValues(scriptID: scriptID)
        values.removeValue(forKey: key)
        defaults.set(values, forKey: gmDefaultsKey(scriptID))
    }

    func clearGMValues(scriptID: UUID) {
        defaults.removeObject(forKey: gmDefaultsKey(scriptID))
    }

    /// 注入用的 JSON 对象字面量：`{"k1":<json1>,"k2":<json2>}`
    /// 直接拼 JSON 文本，避免把 [String: Any] 再序列化一次出错。
    func gmStoreLiteral(scriptID: UUID) -> String {
        let values = gmValues(scriptID: scriptID)
        guard !values.isEmpty else { return "{}" }
        let pairs = values.map { key, json -> String in
            let safeKey = Self.jsonString(key)
            let safeValue = json.isEmpty ? "null" : json
            return "\(safeKey):\(safeValue)"
        }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    /// 把 Swift 字符串转成 JS/JSON 字面量（含引号）
    nonisolated static func jsonString(_ value: String) -> String {
        var result = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{2028}": result += "\\u2028"
            case "\u{2029}": result += "\\u2029"
            default:
                if character.value < 0x20 {
                    result += String(format: "\\u%04x", character.value)
                } else {
                    result.unicodeScalars.append(character)
                }
            }
        }
        result += "\""
        return result
    }
}

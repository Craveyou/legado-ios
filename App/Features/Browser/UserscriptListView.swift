import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 脚本列表

struct LNUserscriptListView: View {
    @ObservedObject private var store = LNUserscriptStore.shared

    @State private var showsImportSheet = false
    @State private var showsLog = false
    @State private var detailScript: LNUserscript?
    @State private var pendingDelete: LNUserscript?
    @State private var toast: String?

    var body: some View {
        // 用 ZStack 而不是 Group：Group 内部 if/else 分支切换会重建子树。
        ZStack {
            if store.scripts.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(ReadingTheme.canvas.ignoresSafeArea())
        .navigationTitle("油猴脚本")
        .navigationBarTitleDisplayMode(.inline)
        .lnShowsTabBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        presentFilePicker()
                    } label: {
                        Label("从文件导入", systemImage: "doc.badge.plus")
                    }
                    Button {
                        importFromClipboard()
                    } label: {
                        Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        importFromAppFolder()
                    } label: {
                        Label("扫描 App 文件夹", systemImage: "folder.badge.gearshape")
                    }
                    Button {
                        showsImportSheet = true
                    } label: {
                        Label("粘贴文本 / 从网址导入", systemImage: "square.and.pencil")
                    }
                    Divider()
                    Button {
                        showsLog = true
                    } label: {
                        Label("运行日志", systemImage: "text.alignleft")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("导入脚本")
            }
        }
        .sheet(isPresented: $showsImportSheet) {
            LNUserscriptImportSheet { message in
                showToast(message)
            }
        }
        .sheet(isPresented: $showsLog) {
            LNUserscriptLogView()
        }
        .sheet(item: $detailScript) { script in
            LNUserscriptDetailView(script: script, store: store)
        }
        .alert("删除脚本？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let script = pendingDelete {
                    store.remove(id: script.id)
                    showToast("已删除《\(script.name)》")
                }
                pendingDelete = nil
            }
        } message: {
            Text("脚本以及它保存的数据都会被删除，不可恢复。")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(ReadingTheme.emphasisSurface,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(ReadingTheme.onAccent)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
        .accessibilityIdentifier("ln.userscript.list")
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.scripts) { script in
                    row(script)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = script
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } footer: {
                Text("脚本会在匹配的网页加载时自动执行。导入的脚本仅保存在本机。")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ script: LNUserscript) -> some View {
        HStack(spacing: 12) {
            Button {
                detailScript = script
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(script.name)
                            .font(.body)
                            .foregroundStyle(ReadingTheme.ink)
                            .lineLimit(1)
                        if !script.version.isEmpty {
                            Text("v\(script.version)")
                                .font(.caption2)
                                .foregroundStyle(ReadingTheme.ink.opacity(0.4))
                        }
                    }
                    Text(script.hostSummary)
                        .font(.caption)
                        .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { script.isEnabled },
                set: { store.setEnabled($0, id: script.id) }
            ))
            .labelsHidden()
            .accessibilityLabel("\(script.name) 启用开关")
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "curlybraces.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(ReadingTheme.ink.opacity(0.35))
                .accessibilityHidden(true)
            Text("还没有油猴脚本")
                .font(.headline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.75))
            Text("把 .user.js 脚本文件导入，脚本会在匹配的网页加载时自动执行。")
                .font(.subheadline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 10) {
                Button {
                    presentFilePicker()
                } label: {
                    Label("从文件导入", systemImage: "doc.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(ReadingTheme.accentFill)

                Button {
                    showsImportSheet = true
                } label: {
                    Label("粘贴文本导入", systemImage: "square.and.pencil")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 文件导入

    /// 用 UIKit 的文档选择器（见文件末尾 LNUserscriptFilePicker）。
    /// SwiftUI 的 .fileImporter 在 iOS 18/26 多选模式下有「选完点打开、回调不触发」的回归，
    /// 表现就是点了完全没反应，所以这里绕开它。
    private func presentFilePicker() {
        Task { @MainActor in
            // 等「+」菜单收起，避免和 menu 的 presentation 撞车
            try? await Task.sleep(nanoseconds: 350_000_000)
            LNUserscriptFilePicker.shared.present { urls in
                Task { @MainActor in
                    if urls.isEmpty {
                        showToast("没有选中文件", duration: 2)
                    } else {
                        await importFiles(urls)
                    }
                }
            }
        }
    }

    private func importFiles(_ urls: [URL]) async {
        var added = 0
        var updated = 0
        var failures: [String] = []

        for url in urls {
            let outcome = await store.importFile(at: url)
            switch outcome {
            case .success(.added):
                added += 1
            case .success(.updated):
                updated += 1
            case .success(.invalid):
                failures.append("\(url.lastPathComponent)：内容无效")
            case .failure(let error):
                failures.append("\(url.lastPathComponent)：\(error.reason)")
            }
            // asCopy 复制进 tmp 的副本，导入完就删，别占空间
            if url.path.contains("/tmp/") {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var parts: [String] = []
        if added > 0 { parts.append("新增 \(added) 个") }
        if updated > 0 { parts.append("更新 \(updated) 个") }
        if !failures.isEmpty { parts.append("失败 \(failures.count) 个") }
        let summary = parts.isEmpty ? "没有可导入的脚本" : parts.joined(separator: "，")
        let detail = failures.isEmpty ? summary : summary + "\n" + failures.prefix(3).joined(separator: "\n")
        showToast(detail, duration: failures.isEmpty ? 2 : 5)
    }

    /// 兜底通道：文件选择器万一还是不给回调，用户可以用「文件」App 把脚本拖进
    /// 「我的 iPhone → 小浣熊阅读」目录，这里直接扫本机文档目录导入。
    private func importFromAppFolder() {
        Task { @MainActor in
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            // 注意：DirectoryEnumerator 的 makeIterator 在 async 上下文不可用，这里用 allObjects 一次取回
            let contents = fm.enumerator(at: docs,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []
            let found = contents.filter {
                ["js", "mjs", "txt", "text"].contains($0.pathExtension.lowercased())
            }
            guard !found.isEmpty else {
                showToast("「小浣熊阅读」文件夹里没有 .js 文件\n用「文件」App 把脚本拖进去再试一次", duration: 6)
                return
            }
            await importFiles(found)
        }
    }

    /// iOS 上从粘贴板拿脚本比翻文件快得多，做成一键
    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("剪贴板里没有文字", duration: 2)
            return
        }
        guard LNUserscriptParser.looksLikeUserscript(text) else {
            showToast("剪贴板内容没有 ==UserScript== 头部", duration: 4)
            return
        }
        guard let script = LNUserscriptParser.parse(text) else {
            showToast("不是有效的油猴脚本", duration: 4)
            return
        }
        switch store.add(script) {
        case .added(let name): showToast("已导入《\(name)》")
        case .updated(let name): showToast("已更新《\(name)》")
        case .invalid: showToast("脚本内容无效", duration: 4)
        }
    }

    private func showToast(_ message: String, duration: TimeInterval = 2.2) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if toast == message { toast = nil }
        }
    }
}

// MARK: - 粘贴 / 网址导入

private struct LNUserscriptImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LNUserscriptStore.shared

    let onFinished: (String) -> Void

    @State private var mode: Mode = .paste
    @State private var text = ""
    @State private var urlString = ""
    @State private var isDownloading = false
    @State private var errorMessage: String?

    private enum Mode: String, CaseIterable {
        case paste = "粘贴文本"
        case url = "从网址"
    }

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    Picker("导入方式", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .paste {
                    Section {
                        TextEditor(text: $text)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 220)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("脚本内容")
                    } header: {
                        Text("脚本内容")
                    } footer: {
                        Text("粘贴完整的 UserScript（包含 ==UserScript== 头部）。")
                    }
                } else {
                    Section {
                        TextField("https://example.com/script.user.js", text: $urlString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityLabel("脚本网址")
                        Button {
                            Task { await download() }
                        } label: {
                            HStack {
                                Label("下载并导入", systemImage: "arrow.down.circle")
                                Spacer()
                                if isDownloading { ProgressView() }
                            }
                        }
                        .disabled(isDownloading || resolvedURL == nil)
                    } footer: {
                        Text("只下载纯文本脚本，不会执行远程代码。")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("导入脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importPasted() }
                        .disabled(mode != .paste || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var resolvedURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return url
        }
        return nil
    }

    private func importPasted() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let script = LNUserscriptParser.parse(trimmed) else {
            errorMessage = "没有找到 ==UserScript== 头部，无法识别为油猴脚本"
            return
        }
        finish(script: script)
    }

    private func download() async {
        guard let url = resolvedURL else { return }
        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let content = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                errorMessage = "返回内容不是文本"
                return
            }
            guard let script = LNUserscriptParser.parse(content, sourceURL: url.absoluteString) else {
                errorMessage = "该地址不是有效的 UserScript"
                return
            }
            finish(script: script)
        } catch {
            errorMessage = "下载失败：\(error.localizedDescription)"
        }
    }

    private func finish(script: LNUserscript) {
        switch store.add(script) {
        case .added(let name):
            onFinished("已导入《\(name)》")
            dismiss()
        case .updated(let name):
            onFinished("已更新《\(name)》")
            dismiss()
        case .invalid:
            errorMessage = "脚本内容无效"
        }
    }
}

// MARK: - 详情

private struct LNUserscriptDetailView: View {
    let script: LNUserscript
    @ObservedObject var store: LNUserscriptStore
    @ObservedObject private var log = LNUserscriptLog.shared

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var current: LNUserscript {
        store.scripts.first(where: { $0.id == script.id }) ?? script
    }

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    metaSection
                    runLogSection
                    codeSection
                }
                .padding(20)
            }
            .background(ReadingTheme.canvas.ignoresSafeArea())
            .navigationTitle("脚本详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("删除脚本")
                }
            }
            .alert("删除脚本？", isPresented: $confirmDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    store.remove(id: script.id)
                    dismiss()
                }
            } message: {
                Text("脚本以及它保存的数据都会被删除。")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(current.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ReadingTheme.ink)
            HStack(spacing: 8) {
                if !current.version.isEmpty {
                    Text("v\(current.version)")
                        .font(.caption)
                        .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                }
                Text(current.runAt.rawValue)
                    .font(.caption)
                    .foregroundStyle(ReadingTheme.ink.opacity(0.5))
            }
            if !current.summary.isEmpty {
                Text(current.summary)
                    .font(.subheadline)
                    .foregroundStyle(ReadingTheme.ink.opacity(0.6))
                    .padding(.top, 2)
            }
        }
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("匹配范围")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ReadingTheme.ink.opacity(0.7))
            ForEach((current.matchPatterns + current.includePatterns).prefix(8), id: \.self) { pattern in
                Text(pattern)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ReadingTheme.ink.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(ReadingTheme.groupedCanvas,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if current.matchPatterns.isEmpty && current.includePatterns.isEmpty {
                Text("未声明 @match / @include，脚本不会被执行")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 这台设备上该脚本最近的运行记录（注入成功 / 顶层抛错都能看到）
    private var runLogSection: some View {
        let entries = log.entries(for: current.id)
        return VStack(alignment: .leading, spacing: 8) {
            Text("运行日志")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ReadingTheme.ink.opacity(0.7))
            if entries.isEmpty {
                Text("还没有记录。打开一个匹配的网页后，这里会显示脚本是否注入成功。")
                    .font(.caption)
                    .foregroundStyle(ReadingTheme.ink.opacity(0.5))
            } else {
                ForEach(entries.prefix(6)) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(entry.isError ? .orange : .green)
                            Text(entry.date, style: .time)
                                .font(.caption2)
                                .foregroundStyle(ReadingTheme.ink.opacity(0.4))
                        }
                        Text(entry.message)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ReadingTheme.ink.opacity(entry.isError ? 0.85 : 0.65))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(ReadingTheme.groupedCanvas,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    /// 大脚本（几百 KB）整段丢给 Text 会把主线程按住，所以只渲染前 2 万字符
    private var codePreview: String {
        let limit = 20_000
        guard current.code.count > limit else { return current.code }
        return String(current.code.prefix(limit)) + "\n\n… 已省略 \(current.code.count - limit) 个字符（脚本共 \(current.code.count) 字符）"
    }

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("脚本代码")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ReadingTheme.ink.opacity(0.7))
            Text(codePreview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ReadingTheme.ink.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(ReadingTheme.groupedCanvas,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .textSelection(.enabled)
        }
    }
}

// MARK: - 文件选择器（UIKit 直连）

/// 直接用 UIDocumentPickerViewController，不走 SwiftUI 的 .fileImporter。
///
/// 为什么：iOS 18/26 上 `.fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:)`
/// 存在「文件已选中、点打开后 completion 不触发」的回归，表现为点了完全没反应。
/// UIKit 的 delegate 是基础契约，不会丢回调。
///
/// asCopy: true 让系统把文件复制进 App 沙盒，返回的 URL 不需要 security scope 就能读，
/// 也避免 iCloud / 其他 App 容器文件读到一半权限失效。
@MainActor
final class LNUserscriptFilePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = LNUserscriptFilePicker()

    private var completion: (([URL]) -> Void)?

    private static var contentTypes: [UTType] {
        var types: [UTType] = []
        if let js = UTType(filenameExtension: "js") { types.append(js) }
        types.append(contentsOf: [.plainText, .text, .sourceCode, .data, .item])
        return types
    }

    func present(completion: @escaping ([URL]) -> Void) {
        guard let presenter = Self.topViewController() else {
            completion([])
            return
        }
        // 已经有一个文档选择器在显示时不要重复 present
        if presenter is UIDocumentPickerViewController || presenter.presentedViewController is UIDocumentPickerViewController {
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.contentTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        self.completion = completion
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let callback = completion
        completion = nil
        callback?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
              let root = window.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

// MARK: - 运行日志

struct LNUserscriptLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let scriptID: UUID
    let scriptName: String
    let message: String
    let isError: Bool
}

/// 脚本注入与报错的运行日志（内存里最多留 100 条，不落盘）。
/// 用途：脚本「注入了但控件没出来」时，这里能直接看到是顶层代码抛错还是压根没跑。
@MainActor
final class LNUserscriptLog: ObservableObject {
    static let shared = LNUserscriptLog()

    @Published private(set) var entries: [LNUserscriptLogEntry] = []
    private let limit = 100

    func record(scriptID: UUID, name: String, message: String, isError: Bool) {
        let trimmed = message.count > 1500 ? String(message.prefix(1500)) + "…" : message
        entries.insert(LNUserscriptLogEntry(date: Date(),
                                            scriptID: scriptID,
                                            scriptName: name,
                                            message: trimmed,
                                            isError: isError),
                       at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    func entries(for scriptID: UUID) -> [LNUserscriptLogEntry] {
        entries.filter { $0.scriptID == scriptID }
    }

    func clear() { entries.removeAll() }
}

struct LNUserscriptLogView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var log = LNUserscriptLog.shared

    var body: some View {
        ReadingNavigationStack {
            Group {
                if log.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(ReadingTheme.ink.opacity(0.3))
                            .accessibilityHidden(true)
                        Text("还没有运行记录")
                            .font(.headline)
                            .foregroundStyle(ReadingTheme.ink.opacity(0.7))
                        Text("打开一个匹配脚本的网页后，这里会显示脚本是否注入成功、以及抛了什么错。")
                            .font(.footnote)
                            .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(log.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(entry.isError ? .orange : .green)
                                Text(entry.scriptName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(ReadingTheme.ink.opacity(0.8))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(entry.date, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(ReadingTheme.ink.opacity(0.4))
                            }
                            Text(entry.message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ReadingTheme.ink.opacity(entry.isError ? 0.85 : 0.6))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                }
            }
            .background(ReadingTheme.canvas.ignoresSafeArea())
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { log.clear() }
                        .disabled(log.entries.isEmpty)
                }
            }
        }
    }
}

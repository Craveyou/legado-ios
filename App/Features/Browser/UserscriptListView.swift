import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 脚本列表

struct LNUserscriptListView: View {
    @ObservedObject private var store = LNUserscriptStore.shared

    @State private var showsFileImporter = false
    @State private var showsImportSheet = false
    @State private var detailScript: LNUserscript?
    @State private var pendingDelete: LNUserscript?
    @State private var toast: String?

    var body: some View {
        // 用 ZStack 而不是 Group：Group 内部 if/else 分支切换会重建子树，
        // 挂在它上面的 fileImporter 可能中途丢掉 presentation 回调。
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
                        showsFileImporter = true
                    } label: {
                        Label("从文件导入", systemImage: "doc.badge.plus")
                    }
                    Button {
                        importFromClipboard()
                    } label: {
                        Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        showsImportSheet = true
                    } label: {
                        Label("粘贴文本 / 从网址导入", systemImage: "square.and.pencil")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("导入脚本")
            }
        }
        .fileImporter(isPresented: $showsFileImporter,
                      allowedContentTypes: scriptFileTypes,
                      allowsMultipleSelection: true) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showsImportSheet) {
            LNUserscriptImportSheet { message in
                showToast(message)
            }
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
                    showsFileImporter = true
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

    /// 文件选择器允许的类型：`public.item` 兜底，保证 .user.js / 无扩展名文件都不会被灰掉
    private var scriptFileTypes: [UTType] {
        var types: [UTType] = []
        if let js = UTType(filenameExtension: "js") { types.append(js) }
        if let userJS = UTType(filenameExtension: "user.js") { types.append(userJS) }
        types.append(contentsOf: [.plainText, .text, .sourceCode, .data, .item])
        return types
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            showToast("打开文件选择器失败：\(error.localizedDescription)", duration: 4)
        case .success(let urls):
            guard !urls.isEmpty else {
                showToast("没有选中文件", duration: 2)
                return
            }
            Task { @MainActor in
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
                }

                var parts: [String] = []
                if added > 0 { parts.append("新增 \(added) 个") }
                if updated > 0 { parts.append("更新 \(updated) 个") }
                if !failures.isEmpty { parts.append("失败 \(failures.count) 个") }
                let summary = parts.isEmpty ? "没有可导入的脚本" : parts.joined(separator: "，")
                let detail = failures.isEmpty ? summary : summary + "\n" + failures.prefix(3).joined(separator: "\n")
                showToast(detail, duration: failures.isEmpty ? 2 : 5)
            }
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

import SwiftUI

/// 「当前正在读的章」唯一事实源。
/// 章节列表点章 → 写 current 并 push；阅读页章末「下一章」→ 直接改 current，
/// 阅读页观察它原地换内容，**不退栈**。这样：
/// - 换章无「回目录再进下一章」的过渡动画；
/// - 导航栈里始终只有一层阅读页，系统返回直接回目录，不会退到上一章。
@MainActor
final class LNReaderNavigation: ObservableObject {
    static let shared = LNReaderNavigation()
    @Published var current: LNChapter?
    private init() {}
}

/// 三类共用阅读页（正文 + 插图 + [图NN] 混排 + 章末音视频）。
struct LNReaderView: View {
    static let topAnchorID = "ln-reader-top-anchor"

    let book: LNBook
    let chapter: LNChapter
    let source: any LNLibrarySource
    /// 完整章节列表（用于末尾「下一章」跳转）；不传则无跳转
    var chapters: [LNChapter] = []

    /// 实际显示的章：优先取共享 current（章末「下一章」原地换章就靠它），
    /// 兜底用构造参数（阅读页尚未被 current 覆盖时）。
    @ObservedObject private var nav = LNReaderNavigation.shared
    private var displayChapter: LNChapter { nav.current ?? chapter }

    @State private var content: LNChapterContent?
    @State private var errorMessage: String?
    /// 阅读页弹层：大图预览 / 排版设置（单 sheet 枚举，避免多 sheet 冲突）
    @State private var activeSheet: LNReaderSheet?
    /// 图文混排结果只算一次：放在 body 里的话，每次状态变化都要重跑一遍正则解析
    @State private var flow: [LNInlineFlow.Block] = []

    // 排版偏好（持久化，正文与图文章共用）
    @AppStorage("ln.reader.fontSize") private var fontSize: Double = 17
    @AppStorage("ln.reader.lineSpacing") private var lineSpacing: Double = 6

    var body: some View {
        Group {
            if let content {
                readerBody(content)
            } else if let errorMessage {
                ReadingUnavailableView("读取失败", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else {
                ProgressView("正在读取…")
            }
        }
        .background(ReadingTheme.canvas.ignoresSafeArea())
        .navigationTitle(displayChapter.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .lnHidesTabBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    activeSheet = .typoSettings
                } label: {
                    Image(systemName: "textformat.size")
                }
                .accessibilityLabel("阅读排版：字号与行距")
            }
        }
        // 章变化（含原地换章）时重新加载；flow 清空交给 load() 开头处理
        .task(id: displayChapter.id) { await load() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .typoSettings:
                LNReaderTypoSettings(fontSize: $fontSize, lineSpacing: $lineSpacing)
            case .preview(let request):
                LNImagePreview(images: request.images, startIndex: request.startIndex, source: source)
            }
        }
    }

    @ViewBuilder
    private func readerBody(_ content: LNChapterContent) -> some View {
        if let pdfPath = content.pdfPath {
            LNPDFView(path: pdfPath, source: source)
        } else if content.isEmpty {
            ReadingUnavailableView("这一章没有可显示的内容", systemImage: "doc.questionmark",
                                   description: Text("检查目录里是否有正文 txt / 图片 / 音视频。"))
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // 换章后滚动回顶部的锚点
                    Color.clear.frame(height: 0).id(LNReaderView.topAnchorID)
                    if flow.isEmpty {
                        // 原排布：正文逐段 → 插图 → 章末媒体
                        ForEach(content.paragraphs.indices, id: \.self) { i in
                            paragraphText(content.paragraphs[i])
                        }
                        if !content.images.isEmpty {
                            sectionLabel("插图 · \(content.images.count)")
                            ForEach(content.images) { item in
                                LNImageView(item: item, source: source) {
                                    openPreview(item, in: content.images)
                                }
                            }
                        }
                    } else {
                        // [图NN] 混排：正文片段与图片交错
                        ForEach(flow.indices, id: \.self) { i in
                            switch flow[i] {
                            case .paragraph(let text, _, _):
                                paragraphText(text)
                            case .inlineImage(let index):
                                if content.images.indices.contains(index) {
                                    let item = content.images[index]
                                    LNImageView(item: item, source: source) {
                                        openPreview(item, in: content.images)
                                    }
                                }
                            }
                        }
                        // 未被任何标记引用的图片：章末兜底
                        let matched = LNInlineFlow.matchedIndexes(flow)
                        let residual = content.images.indices.filter { !matched.contains($0) }
                        if !residual.isEmpty {
                            sectionLabel("插图 · \(residual.count)")
                            ForEach(residual, id: \.self) { index in
                                let item = content.images[index]
                                LNImageView(item: item, source: source) {
                                    openPreview(item, in: content.images)
                                }
                            }
                        }
                    }
                    if !content.avMedia.isEmpty {
                        sectionLabel("章末媒体 · \(content.avMedia.count)")
                        ForEach(content.avMedia) { item in
                            if item.kind == .video {
                                LNVideoView(item: item, source: source) {
                                    // 全屏播放结束回章内：把滚动位置拉回该视频（章尾），
                                    // 否则 SwiftUI 在视图被移出层级后会复位到章首
                                    withAnimation(nil) {
                                        proxy.scrollTo(avAnchor(item), anchor: .bottom)
                                    }
                                }
                                .id(avAnchor(item))
                            } else {
                                Label(item.fileName, systemImage: "waveform")
                                    .font(.subheadline)
                                    .foregroundStyle(ReadingTheme.ink.opacity(0.7))
                            }
                        }
                    }
                    if content.ignoredCount > 0 {
                        Text("另有 \(content.ignoredCount) 个文件未显示")
                            .font(.caption)
                            .foregroundStyle(ReadingTheme.ink.opacity(0.4))
                    }
                    if let next = nextChapter {
                        // 章末跳转：直接原地换章（共享 current），不退栈、无过渡动画；
                        // 返回键依旧回目录，因为栈里始终只有这一层阅读页。
                        Button {
                            LNReaderNavigation.shared.current = next
                        } label: {
                            HStack(spacing: 8) {
                                Text("下一章：\(next.displayName)")
                                    .font(.subheadline.weight(.semibold))
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(ReadingTheme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(ReadingTheme.groupedCanvas,
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 12)
                        .accessibilityLabel("下一章：\(next.displayName)")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            // 原地换章后把滚动位置拉回顶部（内容替换不会自动复位）
            .onChange(of: displayChapter.id) { _ in
                proxy.scrollTo(LNReaderView.topAnchorID, anchor: .top)
            }
            }
            // 逐段开启 textSelection 会为每个 Text 建一套选择层，滚动很吃亏；
            // 挂在 ScrollView 上效果一样，开销只算一次。
            .textSelection(.enabled)
        }
    }

    /// 正文段落：字号与行距跟随阅读排版设置（默认 17pt / 6pt）
    private func paragraphText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: fontSize))
            .lineSpacing(lineSpacing)
            .foregroundStyle(ReadingTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ReadingTheme.ink.opacity(0.45))
            .padding(.top, 8)
    }

    /// 章末视频的滚动锚点 id（全屏退出后定位回章尾用）
    private func avAnchor(_ item: LNMediaItem) -> String { "ln-av-\(item.path)" }

    /// 打开大图预览：带上整章图片列表与当前页索引，支持左右滑动翻前后图
    private func openPreview(_ item: LNMediaItem, in images: [LNMediaItem]) {
        let index = images.firstIndex(where: { $0.path == item.path }) ?? 0
        activeSheet = .preview(LNImagePreviewRequest(images: images, startIndex: index))
    }

    /// 当前章的下一章（按章节列表顺序）
    private var nextChapter: LNChapter? {
        guard let index = chapters.firstIndex(where: { $0.path == displayChapter.path }),
              chapters.indices.contains(index + 1) else { return nil }
        return chapters[index + 1]
    }

    private func load() async {
        // 换章先清旧内容：避免原地换章时短暂停留在上一章的正文上
        flow = []
        content = nil
        errorMessage = nil
        do {
            let loaded = try await LNContentLoader.load(displayChapter, source: source)
            flow = LNInlineFlow.blocks(paragraphs: loaded.paragraphs,
                                       images: loaded.images,
                                       category: book.category)
            content = loaded
            errorMessage = nil
            await prefetchImages(loaded)
        } catch {
            errorMessage = error.localizedDescription
            content = nil
            flow = []
        }
    }

    /// 预取前几张图：等滚动到图片位置时解码已经在后台完成，不会有白块和卡顿
    private func prefetchImages(_ content: LNChapterContent) async {
        guard !content.images.isEmpty else { return }
        // 与 LNImageView 的解码边长保持一致，才能命中同一份缓存
        let maxPixel: CGFloat = 1440
        var urls: [URL] = []
        for item in content.images.prefix(8) {
            if let url = try? await source.localURL(for: item.path) { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        LNImageLoader.shared.prefetch(urls, maxPixel: maxPixel)
    }
}

// MARK: - 阅读排版设置

/// 字号 + 行距设置面板：改动即时生效（@AppStorage 双向绑定），带预览。
private struct LNReaderTypoSettings: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("夜色温柔，纸页微凉。调整到眼睛最舒服的尺寸。")
                            .font(.system(size: fontSize))
                            .lineSpacing(lineSpacing)
                            .foregroundStyle(ReadingTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("预览")
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(ReadingTheme.ink.opacity(0.6))
                        Slider(value: $fontSize, in: 13...26, step: 1)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(ReadingTheme.ink.opacity(0.6))
                        Text("\(Int(fontSize))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(ReadingTheme.ink)
                            .frame(width: 28, alignment: .trailing)
                    }
                } header: {
                    Text("字号")
                } footer: {
                    Text("默认 17，范围 13–26")
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "text.alignleft")
                            .foregroundStyle(ReadingTheme.ink.opacity(0.6))
                        Slider(value: $lineSpacing, in: 0...16, step: 1)
                        Text("\(Int(lineSpacing))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(ReadingTheme.ink)
                            .frame(width: 28, alignment: .trailing)
                    }
                } header: {
                    Text("行距")
                } footer: {
                    Text("默认 6，范围 0–16")
                }
            }
            .navigationTitle("阅读排版")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 图片大图预览（左右滑动切换）

/// 阅读页弹层类型：排版设置 / 大图预览
private enum LNReaderSheet: Identifiable {
    case typoSettings
    case preview(LNImagePreviewRequest)

    var id: String {
        switch self {
        case .typoSettings: "typo"
        case .preview(let request): "preview-\(request.id.uuidString)"
        }
    }
}

private struct LNImagePreviewRequest: Identifiable {
    let id = UUID()
    let images: [LNMediaItem]
    let startIndex: Int
}

/// 全屏图片预览：整章图片可左右滑动切换，顶部显示页码。
/// 漫画/整理类书库的图片也走这里，用户点开任意一张后可连续翻看前后图。
private struct LNImagePreview: View {
    let images: [LNMediaItem]
    let source: any LNLibrarySource
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(images: [LNMediaItem], startIndex: Int, source: any LNLibrarySource) {
        self.images = images
        self.source = source
        let clamped = min(max(startIndex, 0), max(images.count - 1, 0))
        _index = State(initialValue: clamped)
    }

    var body: some View {
        ReadingNavigationStack {
            TabView(selection: $index) {
                ForEach(images.indices, id: \.self) { i in
                    LNPreviewPage(item: images[i], source: source)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .bottom)
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("\(index + 1) / \(images.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct LNPreviewPage: View {
    let item: LNMediaItem
    let source: any LNLibrarySource
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.path) {
            guard image == nil else { return }
            guard let url = try? await source.localURL(for: item.path) else { return }
            // 复用带「后台降采样 + NSCache」的加载器：
            // 直接 Data(contentsOf:) + UIImage(data:) 会在主线程全量解码，
            // 翻几百张漫画时每次卡几十毫秒、内存还可能飙到几百 MB；
            // 2400 像素足够大图清晰看，同时在缓存里与正文图共用内存上限。
            if let loaded = await LNImageLoader.shared.load(url, maxPixel: 2400) {
                image = loaded.image
            }
        }
    }
}

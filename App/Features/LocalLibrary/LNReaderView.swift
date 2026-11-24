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

/// 三类共用阅读页（阶段 2：正文 + 插图；阶段 3 起加 [图NN] 混排；阶段 4-6 加媒体）。
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
    @State private var showingImage: LNMediaItem?
    /// 图文混排结果只算一次：放在 body 里的话，每次状态变化都要重跑一遍正则解析
    @State private var flow: [LNInlineFlow.Block] = []

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
        // 章变化（含原地换章）时重新加载；flow 清空交给 load() 开头处理
        .task(id: displayChapter.id) { await load() }
        .sheet(item: $showingImage) { item in
            LNImagePreview(item: item, source: source)
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
                                    showingImage = item
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
                                        showingImage = item
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
                                    showingImage = item
                                }
                            }
                        }
                    }
                    if !content.avMedia.isEmpty {
                        sectionLabel("章末媒体 · \(content.avMedia.count)")
                        ForEach(content.avMedia) { item in
                            if item.kind == .video {
                                LNVideoView(item: item, source: source)
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

    private func paragraphText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(ReadingTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ReadingTheme.ink.opacity(0.45))
            .padding(.top, 8)
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

/// 全屏图片预览（阶段 2 占位：可双指缩放由系统 Image 提供基础能力）
private struct LNImagePreview: View {
    let item: LNMediaItem
    let source: any LNLibrarySource
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ReadingNavigationStack {
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
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            if let url = try? await source.localURL(for: item.path),
               let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                image = UIImage(data: data)
            }
        }
    }
}

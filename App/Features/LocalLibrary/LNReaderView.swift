import SwiftUI
import UIKit

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
    /// 排版设置面板（sheet）
    @State private var showsTypoSettings = false
    /// 大图预览（全屏 cover——图片浏览是沉浸场景，卡片式 sheet 上下留白会挤压画面）
    @State private var previewRequest: LNImagePreviewRequest?
    /// 大图退出时的图片锚点：预览关掉后把正文滚动定位到那张图（退出在哪张就到哪张）
    @State private var previewExitAnchor: String?
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
                    showsTypoSettings = true
                } label: {
                    Image(systemName: "textformat.size")
                }
                .accessibilityLabel("阅读排版：字号与行距")
            }
        }
        // 章变化（含原地换章）时重新加载；flow 清空交给 load() 开头处理
        .task(id: displayChapter.id) { await load() }
        .sheet(isPresented: $showsTypoSettings) {
            LNReaderTypoSettings(fontSize: $fontSize, lineSpacing: $lineSpacing)
        }
        .fullScreenCover(item: $previewRequest) { request in
            LNImagePreview(images: request.images, startIndex: request.startIndex, source: source) { exitIndex in
                // 退出大图时记住当时那张图；关闭动画期间把正文滚过去，露出即是目标位置
                if request.images.indices.contains(exitIndex) {
                    previewExitAnchor = imageAnchor(request.images[exitIndex])
                }
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
                                .id(imageAnchor(item))
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
                                    .id(imageAnchor(item))
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
                                .id(imageAnchor(item))
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
            // 大图退出（X / 上滑 / 末页再滑）：定位到退出时的那张图
            .onChange(of: previewExitAnchor) { anchor in
                guard let anchor else { return }
                withAnimation(nil) {
                    proxy.scrollTo(anchor, anchor: .center)
                }
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
        // 清掉上次的退出锚点：同一张图反复开/关也要能再次触发 onChange 定位
        previewExitAnchor = nil
        let index = images.firstIndex(where: { $0.path == item.path }) ?? 0
        previewRequest = LNImagePreviewRequest(images: images, startIndex: index)
    }

    /// 大图退出后定位回章内图片的滚动锚点
    private func imageAnchor(_ item: LNMediaItem) -> String { "ln-img-\(item.path)" }

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

private struct LNImagePreviewRequest: Identifiable {
    let id = UUID()
    let images: [LNMediaItem]
    let startIndex: Int
}

/// 全屏图片预览：整章图片可左右滑动切换，顶部显示页码。
/// 漫画/整理类书库的图片也走这里，用户点开任意一张后可连续翻看前后图。
/// 交互（b83）：双指捏合缩放、双击在「适应屏幕 ↔ 2.5x」间切换、上滑关闭、
/// 在最后一张继续左滑退出；关闭时回传当前页码给调用方做定位。
private struct LNImagePreview: View {
    let images: [LNMediaItem]
    let source: any LNLibrarySource
    /// 关闭时回传当前页 index（阅读页据此滚动定位到那张图）
    let onExit: (Int) -> Void
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(images: [LNMediaItem], startIndex: Int, source: any LNLibrarySource,
         onExit: @escaping (Int) -> Void = { _ in }) {
        self.images = images
        self.source = source
        self.onExit = onExit
        let clamped = min(max(startIndex, 0), max(images.count - 1, 0))
        _index = State(initialValue: clamped)
    }

    /// 所有退出路径（关闭键 / 上滑 / 末页越界）都走这里，保证 onExit 一定带上当前页
    private func close() {
        onExit(index)
        dismiss()
    }

    var body: some View {
        // 分页不用 TabView(.page)：它底层是 UIPageViewController，页面宽度在布局
        // 阶段被缓存，modal 呈现时容器宽度会经历「小 → 最终」的过渡，它会拿过渡中
        // 的宽度当页宽 → 滑动吸附在两张图中间（b62 去掉导航栈后依旧复现）。
        // 改用 UIScrollView + isPagingEnabled（系统相册同款），页宽始终跟随实时
        // 容器宽度，并在减速结束时按整页修正落点，吸附 100% 落在整页。
        ZStack {
            Color.black.ignoresSafeArea()

            LNPagingView(count: images.count, startIndex: index, index: $index,
                         onDismissRequest: { close() }) { pageIndex, isActive in
                LNPreviewPage(item: images[pageIndex], source: source, isActive: isActive)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        // 顶部栏只占一行（overlay + alignment: .top），不要用 VStack + Spacer 铺满：
        // 那会在画面上盖一层全屏透明层，滑动/点击要先被它吞掉一次。
        .overlay(alignment: .top) {
            HStack(spacing: 12) {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel("关闭大图")

                Spacer()

                Text("\(index + 1) / \(images.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .accessibilityLabel("第 \(index + 1) 张，共 \(images.count) 张")

                Spacer()

                // 占位：让页码真正居中（与左侧关闭键等宽）
                Color.clear.frame(width: 38, height: 38)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
    }
}

private struct LNPreviewPage: View {
    let item: LNMediaItem
    let source: any LNLibrarySource
    /// 是否落在「当前页 ±1」的预加载窗口内。
    /// 整章几十上百张图若一次性全部解码，内存会直接打满、首帧也被拖慢，
    /// 所以窗口外的页面只占位不加载，滑到邻近时再取。
    let isActive: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                // 缩放走 UIKit 的 UIScrollView（捏合 + 双击），
                // 1x 时禁掉内部滚动，横滑手势落回外层分页容器
                LNZoomablePageView(image: image)
            } else if isActive {
                ProgressView().tint(.white)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 已加载的页不再参与重算；isActive 变化时重新评估是否需要加载
        .task(id: "\(item.path)#\(isActive)") {
            guard isActive, image == nil else { return }
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

// MARK: - 单页缩放容器（捏合放大缩小 + 双击切换）

/// 单页图片的缩放滚动容器（系统相册同款交互）：
/// - 双指捏合在 1x ~ 4x 之间缩放；1x 即「适应屏幕」（aspectFit）；
/// - 双击：放大态回 1x（适应屏幕），1x 态放大到 2.5x（以点击点为中心）；
/// - 1x 时 `isScrollEnabled = false`，横滑手势穿透给外层分页容器翻页；
///   放大后内部可自由平移，翻页手势自然被它接管。
private struct LNZoomablePageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> LNZoomScrollView {
        LNZoomScrollView()
    }

    func updateUIView(_ scrollView: LNZoomScrollView, context: Context) {
        if scrollView.image !== image {
            scrollView.setImage(image)
        }
    }
}

/// 用 frame 布局而不是 Auto Layout：UIScrollView 缩放靠改 zoomable view 的
/// frame/transform，约束钉死宽高会和缩放打架（经典坑）。
final class LNZoomScrollView: UIScrollView {
    private let imageView = UIImageView()

    init() {
        super.init(frame: .zero)
        delegate = self as UIScrollViewDelegate
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        minimumZoomScale = 1
        maximumZoomScale = 4
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var image: UIImage? { imageView.image }

    func setImage(_ newImage: UIImage) {
        imageView.image = newImage
        imageView.isHidden = false
        // 换图重置回适应屏幕
        zoomScale = 1
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// 最近一次「铺满视口」时的 bounds 尺寸；放大态 layoutSubviews 也会被调，
    /// 不能无脑重铺（会把 zoomScale 重置掉），只在尺寸真变化（首帧/旋转）时重置
    private var fittedSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != fittedSize, bounds.width > 0, bounds.height > 0 else { return }
        fittedSize = bounds.size
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            // 已放大 → 双击回适应屏幕
            setZoomScale(1, animated: true)
        } else {
            // 适应屏幕 → 放大到 2.5x，以双击点为中心
            let scale: CGFloat = 2.5
            let point = gesture.location(in: imageView)
            let rect = CGRect(
                x: point.x - bounds.width / scale / 2,
                y: point.y - bounds.height / scale / 2,
                width: bounds.width / scale,
                height: bounds.height / scale
            )
            zoom(to: rect, animated: true)
        }
    }

    var isZoomedIn: Bool { zoomScale > minimumZoomScale + 0.01 }
}

extension LNZoomScrollView: UIScrollViewDelegate {
    func viewForZooming(in _: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // 内容小于视口时保持居中（缩小时避免贴左上角）
        let offsetX = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let offsetY = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        imageView.center = CGPoint(x: scrollView.contentSize.width / 2 + offsetX,
                                   y: scrollView.contentSize.height / 2 + offsetY)
        // 1x 时禁内部滚动，让横滑穿透给外层分页容器；放大后内部自由平移
        scrollView.isScrollEnabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
    }
}

// MARK: - 横向分页容器（UIScrollView，整页精确吸附）

/// 图片横向分页容器。
///
/// 为什么不用 `TabView(.page)`：它底层是 `UIPageViewController`，页宽在布局阶段
/// 被缓存。本预览是 modal 呈现，容器宽度会经历「过渡值 → 最终值」的变化，
/// UIPageViewController 会拿过渡中的宽度当页宽，之后滑动就吸附在两张图中间
/// （b62 去掉导航栈包裹后仍然复现，说明不是手势冲突而是页宽失配）。
///
/// 这里用 `UIScrollView.isPagingEnabled`（系统相册同款）：
/// - 页宽约束到 `frameLayoutGuide.widthAnchor`，永远等于实时容器宽度；
/// - `scrollViewWillEndDragging` 再按整页修正 `targetContentOffset`，
///   即便有亚像素误差也一定落在整页上；
/// - 宽度变化（首帧/旋转）时按当前页重贴，不会累积偏移。
private struct LNPagingView<Page: View>: UIViewControllerRepresentable {
    let count: Int
    let startIndex: Int
    @Binding var index: Int
    /// 请求关闭（上滑 / 在最后一张继续左滑）：由 SwiftUI 侧统一走 close() 回传页码
    let onDismissRequest: () -> Void
    /// (页序号, 是否在预加载窗口内)
    let pageBuilder: (Int, Bool) -> Page

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> LNPagingController<Page> {
        let controller = LNPagingController(count: count, startIndex: startIndex, pageBuilder: pageBuilder)
        context.coordinator.binding = $index
        context.coordinator.dismissHandler = onDismissRequest
        controller.onIndexChange = { newValue in
            if context.coordinator.binding.wrappedValue != newValue {
                context.coordinator.binding.wrappedValue = newValue
            }
        }
        controller.onDismissRequest = { context.coordinator.dismissHandler?() }
        return controller
    }

    func updateUIViewController(_ controller: LNPagingController<Page>, context: Context) {
        context.coordinator.binding = $index
        context.coordinator.dismissHandler = onDismissRequest
        controller.onIndexChange = { newValue in
            if context.coordinator.binding.wrappedValue != newValue {
                context.coordinator.binding.wrappedValue = newValue
            }
        }
        controller.onDismissRequest = { context.coordinator.dismissHandler?() }
        // 外部（页码/按钮）改了页：同步滚动过去；用户正在滑动时会被内部忽略
        controller.syncIndexFromOutside(index)
    }

    final class Coordinator {
        var binding: Binding<Int> = .constant(0)
        var dismissHandler: (() -> Void)?
    }
}

private final class LNPagingController<Page: View>: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var pages: [UIHostingController<Page>] = []
    private let pageCount: Int
    private let pageBuilder: (Int, Bool) -> Page
    private var currentIndex: Int
    private var lastWidth: CGFloat = 0
    private var isUserInteracting = false
    /// 上次渲染窗口的中心页；中心没变就不重建各页 rootView
    private var renderedCenter: Int = .min

    var onIndexChange: ((Int) -> Void)?
    /// 上滑关闭 / 末页继续左滑越界 → 请求关闭（由外层统一回传当前页码）
    var onDismissRequest: (() -> Void)?

    /// 上滑关闭手势：竖向位移明显大于横向、且当前页未放大时才判定
    private lazy var swipeUpGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleSwipeUp(_:)))
        gesture.delegate = self
        return gesture
    }()

    init(count: Int, startIndex: Int, pageBuilder: @escaping (Int, Bool) -> Page) {
        self.pageCount = max(count, 1)
        self.pageBuilder = pageBuilder
        self.currentIndex = min(max(startIndex, 0), max(count - 1, 0))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        scrollView.isPagingEnabled = true
        scrollView.alwaysBounceHorizontal = pageCount > 1
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        buildPages()

        // 上滑关闭：挂在根视图上，与分页 scrollView 的 pan 并行识别（delegate 允许）
        view.addGestureRecognizer(swipeUpGesture)
    }

    private func buildPages() {
        renderedCenter = currentIndex
        for index in 0 ..< pageCount {
            let host = UIHostingController(rootView: pageBuilder(index, isWithinWindow(index)))
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            stackView.addArrangedSubview(host.view)
            // 页宽恒等于滚动容器可视宽度——分页吸附的前提
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor).isActive = true
            host.didMove(toParent: self)
            pages.append(host)
        }
    }

    private func isWithinWindow(_ index: Int) -> Bool {
        abs(index - currentIndex) <= 1
    }

    /// 窗口中心页变化时刷新各页的 active 标记（已加载的图在 @State 里保留，滑回来即显）
    private func refreshWindowIfNeeded() {
        guard renderedCenter != currentIndex else { return }
        renderedCenter = currentIndex
        for (index, host) in pages.enumerated() {
            host.rootView = pageBuilder(index, isWithinWindow(index))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = scrollView.bounds.width
        guard width > 0, abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        // 首帧与旋转：contentSize 先按新页宽落定，再按当前页贴齐（无动画）
        scrollView.layoutIfNeeded()
        scrollView.setContentOffset(CGPoint(x: CGFloat(currentIndex) * width, y: 0), animated: false)
    }

    // MARK: - 对外同步

    /// 外部改了页码：滚到对应页。用户正在拖动/减速时忽略，避免打断手势。
    func syncIndexFromOutside(_ newIndex: Int) {
        guard !isUserInteracting else { return }
        let clamped = min(max(newIndex, 0), pageCount - 1)
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        refreshWindowIfNeeded()
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let target = CGPoint(x: CGFloat(clamped) * width, y: 0)
        guard abs(scrollView.contentOffset.x - target.x) > 0.5 else { return }
        scrollView.setContentOffset(target, animated: true)
    }

    // MARK: - 关闭手势（上滑 / 末页越界）

    @objc private func handleSwipeUp(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        // 竖向上滑明显占主导、位移过阈值、且当前页未处于放大态（放大时上下滑是平移图片）
        guard translation.y < -110,
              abs(translation.y) > abs(translation.x),
              velocity.y < 0,
              !currentPageIsZoomed() else { return }
        onDismissRequest?()
    }

    /// 与分页 scrollView 的 pan 并行识别：否则竖向上滑会被 scrollView 的
    /// 纵向 bounce 吞掉，我们的手势永远到不了 ended
    func gestureRecognizer(_: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }

    /// 当前页是否被捏合放大过：翻页容器每页是 UIHostingController 包着的
    /// LNZoomScrollView，遍历子树找 zoomScale > 1 的 UIScrollView
    private func currentPageIsZoomed() -> Bool {
        guard pages.indices.contains(currentIndex) else { return false }
        return containsZoomedScrollView(pages[currentIndex].view)
    }

    private func containsZoomedScrollView(_ view: UIView) -> Bool {
        if let scrollView = view as? UIScrollView,
           scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            return true
        }
        return view.subviews.contains { containsZoomedScrollView($0) }
    }

    // MARK: - UIScrollViewDelegate

    /// 拖拽期间达到过的最大 offsetX：末页「再左滑退出」靠它判定。
    /// 之前放在 willEndDragging 看目标落点，但正常翻页式左滑是缓慢拖拽释放，
    /// 橡皮筋越界量和速度都够不到阈值，永远不触发。
    private var peakOffsetX: CGFloat = 0
    /// 本次拖拽是否已请求过关闭（防重复 dismiss）
    private var dismissRequested = false

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserInteracting = true
        dismissRequested = false
        peakOffsetX = scrollView.contentOffset.x
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        if isUserInteracting {
            peakOffsetX = max(peakOffsetX, scrollView.contentOffset.x)
        }
        let page = min(max(Int((scrollView.contentOffset.x / width).rounded()), 0), pageCount - 1)
        guard page != currentIndex else { return }
        currentIndex = page
        onIndexChange?(page)
        refreshWindowIfNeeded()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView,
                                   withVelocity _: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let page = (targetContentOffset.pointee.x / width).rounded()
        let clamped = min(max(page, 0), CGFloat(pageCount - 1))
        targetContentOffset.pointee.x = clamped * width
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        isUserInteracting = false
        defer { peakOffsetX = 0 }
        // 末页「再左滑退出」：只要这次拖拽曾把内容拉过末页右缘 15% 页宽，
        // 无论快甩还是慢拖都算退出意图（翻页落点吸附恰好停在末页，不会误触发）
        let width = scrollView.bounds.width
        if width > 0, currentIndex == pageCount - 1, !dismissRequested {
            let lastX = CGFloat(pageCount - 1) * width
            if peakOffsetX > lastX + width * 0.15 {
                dismissRequested = true
                onDismissRequest?()
                return
            }
        }
        guard !decelerate else { return }
        snapToCurrentPage()
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        isUserInteracting = false
        snapToCurrentPage()
    }

    /// 兜底吸附：万一系统没完全对齐（页宽亚像素误差），这里补一次
    private func snapToCurrentPage() {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let target = CGPoint(x: CGFloat(currentIndex) * width, y: 0)
        guard abs(scrollView.contentOffset.x - target.x) > 0.5 else { return }
        scrollView.setContentOffset(target, animated: true)
    }
}

import AVFoundation
import SwiftUI
@preconcurrency import KSPlayer

/// 章末视频 / 短剧单集播放器（b58：全屏改由 SwiftUI 呈现）。
///
/// 演进史：
/// - b54：修好控制条（宿主 IOSVideoPlayerView），但全屏用 KSPlayer 自带的
///   PlayerFullScreenViewController —— 它会从 SwiftUI 阅读页的宿主控制器里
///   present 一个 UIKit 全屏 VC，退出后偶发残留，吞掉整个界面的点击
///   （表现：返回列表后点哪都没反应，得再点一次才进）；而且全屏时播放器视图被
///   reparent 出 SwiftUI 层级，回来时 ScrollView 复位到章首。
/// - b58：全屏完全改由 SwiftUI `fullScreenCover` 呈现——
///   * 阅读页始终挂载，滚动位置天然不丢；
///   * 不再有 UIKit VC 残留，点击卡死根治；
///   * 全屏页自带「旋转」按钮（强制横屏 / 竖屏切换）与关闭按钮，行为可控；
///   * 内嵌与全屏共用同一个 KSPlayerLayer（同一个播放实例），交接时只是把
///     layer 换给另一个视图，不会双音轨。
/// - 另外：中间播放按钮从图标原始大小放大到 76pt（KSPlayer 默认没有尺寸约束）。
struct LNVideoView: View {
    let item: LNMediaItem
    let source: any LNLibrarySource
    /// 画面高度：章内嵌 / 短剧用 240；传 nil 表示按 16:9 自适应铺满宽度
    /// （电影整页播放需要更大的画面）
    var playerHeight: CGFloat? = 240
    /// 全屏关闭回调：阅读页靠它把滚动位置拉回视频处（章尾）。
    /// 必须保持为最后一个参数——阅读页是用尾随闭包传的。
    var onFullscreenEnd: (() -> Void)? = nil

    @State private var box = LNKSPlayerBox()
    /// 全屏 ↔ 内嵌的进度/播放状态同步（全屏是独立播放实例）
    @State private var sync = LNPlayerSyncBox()
    @State private var url: URL?
    @State private var options: KSOptions?
    @State private var duration: Double?
    @State private var failed = false

    /// 流式播放失败的具体原因（展示出来便于诊断）
    @State private var streamError: String?
    /// 是否允许流式（回退一次后关闭，避免死循环）
    @State private var allowStreaming = true
    /// SwiftUI 全屏呈现
    @State private var showFullscreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if failed {
                VStack(alignment: .leading, spacing: 4) {
                    Label("无法播放：\(item.fileName)", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let streamError {
                        Text("播放失败：\(streamError)\n请把这段发给开发者")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let streamError {
                // 流式失败已自动回退下载模式：播放正常但保留原因，便于远程诊断
                Text("流式不可用已改下载播放（\(streamError)）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let url, let options {
                LNKSPlayerHost(box: box, url: url, options: options,
                               autoFullscreenOnPlay: shouldAutoFullscreen,
                               onRequestFullscreen: requestFullscreen)
                    .modifier(LNPlayerSizing(height: playerHeight))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if !failed {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.06))
                    ProgressView()
                }
                .modifier(LNPlayerSizing(height: playerHeight))
            }
            HStack(spacing: 8) {
                Text(item.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                if let duration, duration > 0, duration.isFinite {
                    Text(timeText(duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    requestFullscreen()
                } label: {
                    Label("全屏", systemImage: "rectangle.expand.vertical")
                        .font(.caption)
                        .foregroundStyle(ReadingTheme.accent)
                }
                .accessibilityLabel("全屏播放")
            }
        }
        .task(id: item.path) { await load() }
        .onAppear {
            box.onDuration = { total in
                if duration != total { duration = total }
            }
            box.onFinishError = { handlePlaybackError($0) }
            box.onRequestFullscreen = { requestFullscreen() }
        }
        .fullScreenCover(isPresented: $showFullscreen, onDismiss: {
            // 退出全屏：把全屏里的进度/播放状态写回内嵌实例，再续播
            if let layer = box.view?.playerLayer, sync.time > 0 {
                layer.seek(time: sync.time, autoPlay: sync.wasPlaying) { _ in }
            }
            // 全屏里改过字幕选择的话，让内嵌实例跟着切（保持两边一致）
            if let embedded = box.view {
                if let id = sync.subtitleID {
                    embedded.pendingSubtitleID = id
                } else if embedded.srtControl.selectedSubtitleInfo != nil {
                    // 全屏里选了「不显示字幕」：内嵌也要关掉
                    embedded.srtControl.selectedSubtitleInfo = nil
                }
            }
            // 滚动位置拉回视频处（章尾），避免阅读页回到章首
            onFullscreenEnd?()
        }) {
            if let url, let options {
                LNKSPlayerFullscreen(box: box, url: url, options: options,
                                     startTime: sync.time, autoplay: sync.wasPlaying,
                                     sync: sync, title: item.fileName)
            }
        }
    }

    /// 进入全屏：记录内嵌实例的进度/播放状态并暂停它。
    /// 全屏用**独立播放实例**（同一个 URL + 同一份 options，认证头也在里面），
    /// 不再在两个视图之间交接 KSPlayerLayer——
    /// 交接依赖 UIKit 视图重新挂载 + delegate 转移，在 SwiftUI fullScreenCover 里
    /// 实测会断（播放中中心按钮不消失、进度不走、控制条无响应）。
    private func requestFullscreen() {
        guard let layer = box.view?.playerLayer else { return }
        sync.time = layer.player.currentPlaybackTime
        sync.wasPlaying = layer.state.isPlaying
        // 字幕选择也带过去（全屏是独立实例，不传的话用户在内嵌选的中文字幕会丢）
        sync.subtitleID = box.view?.srtControl.selectedSubtitleInfo?.subtitleID
        layer.pause()
        showFullscreen = true
    }

    /// 点击播放自动全屏——只对视频生效，音频（mp3/m4a/flac 等）不弹全屏。
    /// kind 已经是 .video 的前提下，再按扩展名兜底一次（与 LNScanner.audioExts 对齐）。
    private var shouldAutoFullscreen: Bool {
        let ext = (item.fileName as NSString).pathExtension.lowercased()
        let audioExts: Set<String> = [
            "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf", "ogg", "opus",
            "ape", "wma", "amr", "m4b",
        ]
        return !audioExts.contains(ext)
    }

    // MARK: - 加载

    private func load() async {
        guard url == nil, !failed else { return }
        // KSPlayer 全局偏好（幂等）：不自动播放 + 直接用 FFmpeg 内核。
        // FFmpeg 失败自动换 AVPlayer 重试（mp4/mov 等被反代拦 FFmpeg 特征时，
        // AVPlayer 同 URL 通常可达——LocalNovel 流式已验证；mkv 则 AVPlayer
        // 也会失败，走错误回退下载）。
        KSOptions.isAutoPlay = false
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSAVPlayer.self

        // 优先流式播放：NAS WebDAV 远端 URL + 认证头，按需拉流秒开。
        // FFmpeg 内核原生吃 headers，mkv 也能流式播。
        if allowStreaming, let (remoteURL, headers) = try? await source.streamingVideo(for: item.path) {
            let newOptions = KSOptions()
            for (key, value) in headers {
                newOptions.appendHeader([key: value])
            }
            // FFmpeg 默认 UA 是 "KSPlayer"，可能被反代/CDN 拦截；
            // 伪装成 AVPlayer 的 UA（LocalNovel 流式同款，已验证 NAS 可达）
            newOptions.userAgent = "AppleCoreMedia/1.0"
            setPlayer(url: remoteURL, options: newOptions)
            Task { await loadSiblingSubtitles() }
            return
        }
        // 回退：本地文件 / SMB / 流式失败后的整文件下载
        guard let localURL = try? await source.localURL(for: item.path) else {
            failed = true
            return
        }
        setPlayer(url: localURL, options: KSOptions())
        Task { await loadSiblingSubtitles() }
    }

    /// 静态字幕扩展名（与 KSPlayer 的 `isSubtitle` 对齐：ass / srt / ssa / vtt）
    private static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    /// 挂载同目录外挂字幕。
    ///
    /// KSPlayer 的 `DirectorySubtitleDataSouce` 只在 `fileURL.isFileURL` 时扫目录，
    /// NAS 视频是 http 流式播放，字幕文件永远发现不了（内嵌字幕不受影响）。
    /// 这里主动去视频同目录找同名文件（movie.srt / movie.zh-CN.ass / movie_chi.srt），
    /// 下载到本地缓存后交给播放器。
    private func loadSiblingSubtitles() async {
        guard box.subtitleURLs.isEmpty else { return }
        let dir = (item.path as NSString).deletingLastPathComponent
        let videoBase = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !videoBase.isEmpty,
              let nodes = try? await source.list(at: dir.isEmpty ? "/" : dir) else { return }
        let matches = nodes.filter { node in
            guard !node.isDirectory else { return false }
            let ext = (node.name as NSString).pathExtension.lowercased()
            guard Self.subtitleExtensions.contains(ext) else { return false }
            let base = (node.name as NSString).deletingPathExtension
            if base == videoBase { return true }
            // movie.zh.srt / movie_chi.srt / movie-1.srt 也算同名，
            // 但不能把 movie2.srt 算到 movie 头上（要求分隔符）
            guard base.hasPrefix(videoBase),
                  let next = base.dropFirst(videoBase.count).first else { return false }
            return next == "." || next == "_" || next == "-" || next == " "
        }
        guard !matches.isEmpty else { return }
        var locals: [URL] = []
        for node in matches {
            if let local = try? await source.localURL(for: node.path) {
                locals.append(local)
            }
        }
        guard !locals.isEmpty else { return }
        box.subtitleURLs = locals
        // 宿主已创建就直接挂上；没创建则由 makeUIView 读 box.subtitleURLs 补挂
        box.view?.attachSubtitles(locals)
    }

    private func setPlayer(url newURL: URL, options newOptions: KSOptions) {
        duration = nil
        url = newURL
        options = newOptions
        box.coverImage = nil
        Task { await loadCoverImage(url: newURL, options: newOptions) }
    }

    /// 播放前抓一帧真实画面当封面，替换掉渐变占位图。
    ///
    /// 用 AVAssetImageGenerator 而不是 KSPlayer 的 thumbnailImageAtCurrentTime：
    /// 后者要等播放器 ready，而封面恰恰要在 ready 之前就有。
    /// 认证头从 `options.avOptions` 取（appendHeader 会同时写这里），
    /// 所以 NAS WebDAV 流式 URL 也能抓到；本地 fileURL 直接可抓。
    /// 失败不打扰用户——保留渐变占位图即可。
    private func loadCoverImage(url: URL, options: KSOptions) async {
        let headers = options.avOptions[AVURLAssetHTTPHeaderFieldsKey] as? [String: String]
        guard let image = await Self.generateCover(url: url, headers: headers) else { return }
        box.coverImage = image
        // 宿主已创建就直接换图；未创建则由 makeUIView 读 box.coverImage 补上
        Task { @MainActor in
            self.box.view?.installPlaceholder(cover: self.box.coverImage)
        }
    }

    /// 在指定时间点抓一帧，后台执行（AVAssetImageGenerator 自带队列，不阻塞主线程）。
    /// 取 0.1 秒而非 0：有些视频第 0 帧全黑。
    private static func generateCover(url: URL, headers: [String: String]?) async -> UIImage? {
        let assetOptions: [String: Any]? = headers.map { [AVURLAssetHTTPHeaderFieldsKey: $0] }
        let asset = AVURLAsset(url: url, options: assetOptions)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(value: 1, timescale: 10) // 0.1s
        do {
            let cgImage = try await generator.image(at: time).image
            return UIImage(cgImage: cgImage)
        } catch {
            // 某些格式（如部分 mkv 编码）AVFoundation 抽帧失败：静默回退渐变占位图
            return nil
        }
    }

    /// 播放出错：流式失败自动回退整文件下载；下载模式再失败才亮错误卡片
    private func handlePlaybackError(_ error: Error?) {
        guard let error else { return }
        let message = error.localizedDescription
        if allowStreaming, url?.isFileURL == false {
            streamError = message
            allowStreaming = false
            url = nil
            options = nil
            Task { await load() }
        } else if failed == false {
            if streamError == nil { streamError = message }
            failed = true
            url = nil
            options = nil
        }
    }

    private func timeText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// 播放器画面尺寸：
/// - 给定高度 → 固定高度（章内嵌 / 短剧，保持 240pt 小卡片）
/// - nil → 按 16:9 自适应铺满可用宽度（电影整页播放）
private struct LNPlayerSizing: ViewModifier {
    let height: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let height {
            content.frame(height: height)
        } else {
            content
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }
}

/// 全屏 ↔ 内嵌之间的进度/播放状态同步盒子。
/// 全屏是独立的播放实例，进入时记录内嵌进度、退出时把全屏进度写回来。
final class LNPlayerSyncBox {
    var time: Double = 0
    var wasPlaying = false
    /// 进入全屏时选中的字幕 ID（全屏是独立播放实例，字幕靠它接上）
    var subtitleID: String?
}

/// 桥接 IOSVideoPlayerView 回调的小盒子（weak delegate 的持有方）。
final class LNKSPlayerBox: NSObject, PlayerControllerDelegate {
    /// 当前内嵌宿主的播放器视图（全屏接管 layer 时用它找回内嵌视图）
    weak var view: LNPlayerView?
    var onDuration: ((Double) -> Void)?
    var onFinishError: ((Error?) -> Void)?
    /// 请求进入全屏（SwiftUI 侧置 showFullscreen = true）
    var onRequestFullscreen: (() -> Void)?
    /// 已下载到本地的外挂字幕（NAS 同目录）。
    /// 存在盒子里而不是只存在 @State 上：宿主视图可能晚于字幕下载完成才创建，
    /// 创建/更新时都要能拿到这份列表补挂。
    var subtitleURLs: [URL] = []
    /// 异步抓到的视频首帧（播放前封面），nil 时用内置渐变占位图。
    /// 同样放盒子里：抓图完成可能早于/晚于宿主视图创建，两边都要能读到。
    var coverImage: UIImage?

    func playerController(state _: KSPlayerState) {}
    func playerController(currentTime _: TimeInterval, totalTime: TimeInterval) {
        guard totalTime > 0, totalTime.isFinite else { return }
        onDuration?(totalTime)
    }
    func playerController(finish error: Error?) {
        onFinishError?(error)
    }
    func playerController(maskShow _: Bool) {}
    func playerController(action _: PlayerButtonType) {}
    func playerController(bufferedCount _: Int, consumeTime _: TimeInterval) {}
    func playerController(seek _: TimeInterval) {}
}

/// KSPlayer 播放器视图定制：
/// 1. 中间播放按钮放大到 76pt（KSPlayer 默认靠图标原尺寸，小卡片里几乎看不清）；
/// 2. 横屏按钮接管为「请求 SwiftUI 全屏」——不再走 KSPlayer 的 UIKit 全屏
///    （那个会残留全屏控制器吞掉后续点击，还会让阅读页滚动复位）；
/// 3. 竖屏内嵌下常显横屏/倍速/字幕按钮；
/// 4. 首次播放（用户点播放后 → .bufferFinished，因为 isAutoPlay=false）自动请求全屏。
final class LNPlayerView: IOSVideoPlayerView {
    var autoFullscreenOnPlay = false
    var onRequestFullscreen: (() -> Void)?

    private var didAutoFullscreen = false
    /// 是否已挂载过「外挂字幕」（NAS 同目录下载来的）。
    /// 只有这种情况才接管字幕菜单——内嵌字幕继续交给 KSPlayer 原生菜单处理。
    private var hasAttachedExternal = false
    /// 上次构建菜单时的状态签名，避免状态回调里反复重建
    private var lastMenuSignature = ""
    /// 待恢复的字幕选择（全屏实例创建时内嵌字幕还没解析出来，要等字幕列表齐了再选）
    var pendingSubtitleID: String?

    /// makeUIView 里调用：一次性配置
    func configure() {
        // 顶栏返回键不做事，且阅读页有自己的返回 → 直接隐藏（用户反馈：点了没反应）
        backBlock = {}
        backButton.isHidden = true

        // 画中画按钮图标在深色场景下渲染异常（只剩个怪框），
        // 且我们的全屏是 SwiftUI cover，PiP 意义不大 → 隐藏
        toolBar.pipButton.isHidden = true

        // 进度条 thumb：KSPlayer 的 addConstraint() 会把 thumb 设成 circle.fill，
        // 再叠加 KSSlider.thumbRect 的 ±20pt 放大 → 左边缘一颗大白圆点。
        // 注意必须放在 init 之后（configure 在 makeUIView 里调用），否则会被盖回去；
        // 内嵌/全屏两个宿主都要生效，所以放这里而不是各自 makeUIView。
        toolBar.timeSlider.setThumbImage(UIImage(), for: .normal)
        toolBar.timeSlider.setThumbImage(UIImage(), for: .highlighted)

        // 中间大播放按钮：默认没有尺寸约束，只有图标本身大小，太小了
        replayButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            replayButton.widthAnchor.constraint(equalToConstant: 76),
            replayButton.heightAnchor.constraint(equalToConstant: 76),
        ])
        replayButton.layer.cornerRadius = 38
        let symbol = UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
        replayButton.setPreferredSymbolConfiguration(symbol, forImageIn: .normal)
        replayButton.setPreferredSymbolConfiguration(symbol, forImageIn: .selected)

        // 接管横屏按钮：KSPlayer 的原生全屏会和 SwiftUI 阅读页打架
        landscapeButton.removeTarget(nil, action: nil, for: .allEvents)
        landscapeButton.addTarget(self, action: #selector(handleFullscreenTap), for: .touchUpInside)
    }

    @objc private func handleFullscreenTap() {
        onRequestFullscreen?()
    }

    // MARK: - 播放前占位图

    /// 给 KSPlayer 的封面层放一张占位图，避免 video 还没开始解码时整块纯黑。
    ///
    /// 原理：IOSVideoPlayerView 自带 `maskImageView`（播放前显示封面、readyToPlay
    /// 时自动淡出）。我们走 `set(url:options:)` 没有传 cover，那层就是透明的，
    /// 底下的 Metal 视图在首帧解码前是黑的 —— 用户看到的就是「未播放前黑屏」。
    /// 这里画一张深色渐变 + 播放图标的占位图塞进去，播放开始时 KSPlayer 自己淡出，
    /// 不用我们监听状态手工管显隐，也不影响控制条。
    ///
    /// 传入已抓到的真实首帧则显示它；否则用渐变占位图。
    /// 文件名不画进图里（画面下方已有），保证图片可复用、不随每集重建。
    func installPlaceholder(cover: UIImage? = nil) {
        // 只在播放开始前装封面；ready 之后 KSPlayer 已把 maskImageView 淡出，
        // 此时若 updateUIView 再调本方法把 alpha 设回 1，播放中会突然盖出一张封面图。
        if let state = playerLayer?.state, state != .initialized, state != .preparing {
            return
        }
        maskImageView.contentMode = .scaleAspectFill
        maskImageView.clipsToBounds = true
        maskImageView.image = cover ?? Self.makePlaceholderImage()
        maskImageView.alpha = 1
    }

    /// 纯代码绘制占位图，不引入资源文件（避免改 pbxproj）。
    /// UIKit 绘图必须在主 actors 上，调用方本来就是 UIView 的 @MainActor 上下文。
    @MainActor static func makePlaceholderImage() -> UIImage {
        let size = CGSize(width: 640, height: 360)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2 // 高分屏清晰
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            // 深色渐变底：比纯黑柔和，且暗色/浅色模式下都一致（播放器场景）
            let colors = [
                UIColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1).cgColor,
                UIColor(red: 0.20, green: 0.23, blue: 0.27, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            // 中央播放图标：语义化 SF Symbol，白 65% 透明度
            let config = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
            if let symbol = UIImage(systemName: "play.circle", withConfiguration: config) {
                let icon = symbol.withTintColor(.white.withAlphaComponent(0.65),
                                                renderingMode: .alwaysOriginal)
                let iconSide: CGFloat = 64
                icon.draw(in: CGRect(x: (size.width - iconSide) / 2,
                                     y: (size.height - iconSide) / 2,
                                     width: iconSide, height: iconSide))
            }
        }
    }

    // MARK: - 外挂字幕（NAS 同目录）

    /// 挂载已下载到本地的字幕文件。
    ///
    /// 为什么需要这段：KSPlayer 的 `DirectorySubtitleDataSouce` 只在
    /// `fileURL.isFileURL` 时扫视频同目录——NAS 视频是 http 流式播放，
    /// 目录里的 .srt/.ass 永远不会被发现。这里由 LNVideoView 主动从 NAS
    /// 同目录把同名字幕下载到缓存，再交给播放器挂载。
    ///
    /// 幂等：`addSubtitle` 内部按 subtitleID 去重，重复调用安全
    /// （内嵌宿主 / 全屏宿主 / 进度同步都会各自调一次）。
    func attachSubtitles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls {
            srtControl.addSubtitle(info: URLSubtitleInfo(url: url))
        }
        hasAttachedExternal = true

        // 没有内嵌字幕/未选字幕时，自动启用第一个外挂字幕（主流播放器行为）
        let externalIDs = Set(urls.map(\.absoluteString))
        if srtControl.selectedSubtitleInfo == nil,
           let first = srtControl.subtitleInfos.first(where: { externalIDs.contains($0.subtitleID) }) {
            srtControl.selectedSubtitleInfo = first
        }

        toolBar.srtButton.isHidden = false
        syncSubtitleMenu(force: true)
    }

    /// 全屏实例的字幕接续：内嵌字幕要等 readyToPlay 之后才解析出来，
    /// 所以不是创建时选，而是每次状态回调尝试一次，选中后清空 pending。
    private func restorePendingSubtitleIfNeeded() {
        guard let id = pendingSubtitleID else { return }
        guard let match = srtControl.subtitleInfos.first(where: { $0.subtitleID == id }) else { return }
        srtControl.selectedSubtitleInfo = match
        pendingSubtitleID = nil
        lastMenuSignature = ""
    }

    /// 重建字幕菜单（带勾选态）。
    ///
    /// KSPlayer 的字幕菜单只在 `.readyToPlay`（以及其后 1 秒）构建一次，
    /// NAS 外挂字幕往往比这更晚才下载完 —— 不重建的话菜单里永远看不到它们。
    /// 内嵌字幕场景不接管，保持上游原生行为。
    private func syncSubtitleMenu(force: Bool = false) {
        guard hasAttachedExternal else { return }
        let signature = "\(srtControl.subtitleInfos.count)#\(srtControl.selectedSubtitleInfo?.subtitleID ?? "-")"
        guard force || signature != lastMenuSignature else { return }
        lastMenuSignature = signature

        let currentID = srtControl.selectedSubtitleInfo?.subtitleID
        var actions: [UIAction] = [
            UIAction(title: "不显示字幕", state: currentID == nil ? .on : .off) { [weak self] _ in
                Task { @MainActor in
                    self?.srtControl.selectedSubtitleInfo = nil
                    self?.lastMenuSignature = ""
                }
            },
        ]
        for info in srtControl.subtitleInfos {
            actions.append(
                UIAction(title: info.name,
                         state: info.subtitleID == currentID ? .on : .off) { [weak self] _ in
                    Task { @MainActor in
                        self?.srtControl.selectedSubtitleInfo = info
                        self?.lastMenuSignature = ""
                    }
                }
            )
        }
        toolBar.srtButton.menu = UIMenu(title: "字幕", children: actions)
        toolBar.srtButton.showsMenuAsPrimaryAction = true
        toolBar.srtButton.isHidden = false
    }

    override func updateUI(isLandscape: Bool) {
        super.updateUI(isLandscape: isLandscape)
        // KSPlayer 竖屏内嵌下会隐藏这些按钮；统一常显，
        // 小卡片里也能随时全屏、调倍速、选字幕
        landscapeButton.isHidden = false
        toolBar.playbackRateButton.isHidden = false
        if !srtControl.subtitleInfos.isEmpty {
            toolBar.srtButton.isHidden = false
        }
    }

    override func player(layer: KSPlayerLayer, state: KSPlayerState) {
        super.player(layer: layer, state: state)
        // 中间播放按钮显隐自己兜底保证一次：
        // 上游逻辑依赖状态回调链，全屏接管后偶尔不同步 → 播放中按钮不消失。
        switch state {
        case .buffering, .bufferFinished:
            replayButton.isHidden = true
        case .paused, .playedToTheEnd, .error:
            replayButton.isHidden = false
            replayButton.isSelected = (state == .playedToTheEnd)
        default:
            break
        }

        // 字幕列表可能在播放过程中变长（内嵌字幕晚于 readyToPlay、外挂字幕下载完成），
        // 每次状态回调顺便对齐菜单；签名没变时是一次字符串比较，开销可忽略
        restorePendingSubtitleIfNeeded()
        syncSubtitleMenu()

        guard state == .bufferFinished, autoFullscreenOnPlay, !didAutoFullscreen else { return }
        didAutoFullscreen = true
        onRequestFullscreen?()
    }
}

/// 内嵌宿主：自带控制条的 IOSVideoPlayerView。
struct LNKSPlayerHost: UIViewRepresentable {
    let box: LNKSPlayerBox
    let url: URL
    let options: KSOptions
    /// 视频类内容才自动全屏（音频不弹全屏）
    let autoFullscreenOnPlay: Bool
    let onRequestFullscreen: () -> Void

    func makeUIView(context _: Context) -> LNPlayerView {
        let playerView = LNPlayerView()
        playerView.configure()
        playerView.set(url: url, options: options)
        playerView.installPlaceholder(cover: box.coverImage)
        playerView.delegate = box
        playerView.playTimeDidChange = { _, total in
            guard total > 0, total.isFinite else { return }
            box.onDuration?(total)
        }
        playerView.autoFullscreenOnPlay = autoFullscreenOnPlay
        playerView.onRequestFullscreen = onRequestFullscreen
        // NAS 同目录字幕：宿主可能晚于字幕下载完成才创建，创建时补挂一次
        playerView.attachSubtitles(box.subtitleURLs)
        box.view = playerView
        return playerView
    }

    func updateUIView(_ playerView: LNPlayerView, context _: Context) {
        // 流式失败回退下载、换章等场景：URL 变了就重设（KSPlayer 内部会重建 layer）
        if playerView.playerLayer?.url != url {
            playerView.set(url: url, options: options)
            playerView.installPlaceholder(cover: box.coverImage)
        }
        // 首帧异步抓到晚于宿主创建时，补上真实封面（=== 按对象身份去重，避免重复安装）
        if let cover = box.coverImage, playerView.maskImageView.image !== cover {
            playerView.installPlaceholder(cover: cover)
        }
        // 字幕晚到（下载完成）时补挂；attachSubtitles 内部按 subtitleID 去重，幂等
        playerView.attachSubtitles(box.subtitleURLs)
    }

    static func dismantleUIView(_ playerView: LNPlayerView, coordinator _: ()) {
        // 阅读页滚走/退出时停播
        Task { @MainActor in
            playerView.pause()
        }
    }
}

/// 全屏宿主：接管内嵌播放器的 KSPlayerLayer（同一播放实例，无双音轨）。
/// 退出时把 layer 交还内嵌视图，delegate 与画面一起回位。
/// 全屏宿主：全屏用**独立的播放实例**（同 URL + 同 options，认证头复用），
/// 进入时 seek 到内嵌进度并按原播放状态续播，退出时把进度写回同步盒子。
///
/// 为什么不再和嵌入视图共享 KSPlayerLayer：layer 交接依赖「UIKit 视图重新挂载 +
/// delegate 转移」，在 SwiftUI 的 fullScreenCover 里实测状态回调会断——
/// 表现为播放中中心播放按钮不消失、进度条不走、按钮点着没反应。
/// 双实例虽然多占一份解码，但行为完全可预测，进度也能无缝衔接。
struct LNKSFullscreenHost: UIViewRepresentable {
    let box: LNKSPlayerBox
    let url: URL
    let options: KSOptions
    /// 进入时的播放位置（秒）
    let startTime: Double
    /// 进入时是否正在播放
    let autoplay: Bool
    let sync: LNPlayerSyncBox

    final class Coordinator {
        let box: LNKSPlayerBox
        let sync: LNPlayerSyncBox
        init(box: LNKSPlayerBox, sync: LNPlayerSyncBox) {
            self.box = box
            self.sync = sync
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(box: box, sync: sync) }

    func makeUIView(context _: Context) -> LNPlayerView {
        let playerView = LNPlayerView()
        playerView.configure()
        playerView.autoFullscreenOnPlay = false
        playerView.set(url: url, options: options)
        playerView.installPlaceholder(cover: box.coverImage)
        // 全屏实例自己就是 layer 的 delegate（状态回调直接驱动自己的控制条）
        playerView.delegate = box
        playerView.playTimeDidChange = { _, total in
            guard total > 0, total.isFinite else { return }
            box.onDuration?(total)
        }
        // 续播：未 ready 时 KSPlayer 把 seek 存进 shouldSeekTo / isAutoPlay，
        // 等 readyToPlay 回调再消费（seek 到 startTime 并按 autoPlay 播放）。
        // 关键：全局 KSOptions.isAutoPlay=false，KSPlayerLayer 初始化时不会
        // prepareToPlay()，所以那些存起来的标志永远等不到 ready —— 表现为
        // 全屏后卡住不动。autoplay=true 时必须显式触发准备流程。
        if let layer = playerView.playerLayer {
            layer.seek(time: max(0, startTime), autoPlay: autoplay) { _ in }
            if autoplay {
                layer.prepareToPlay()
            }
        }
        // NAS 同目录字幕（独立实例要单独挂一份）
        playerView.attachSubtitles(box.subtitleURLs)
        // 接上内嵌选中的字幕；内嵌轨道还没解析出来时由状态回调重试
        playerView.pendingSubtitleID = sync.subtitleID
        return playerView
    }

    func updateUIView(_ view: LNPlayerView, context _: Context) {
        // 字幕可能在进入全屏后才下载完 → 补挂（幂等）
        view.attachSubtitles(box.subtitleURLs)
        // 首帧异步抓到晚于全屏创建时补上（=== 按对象身份去重）
        if let cover = box.coverImage, view.maskImageView.image !== cover {
            view.installPlaceholder(cover: cover)
        }
    }

    static func dismantleUIView(_ playerView: LNPlayerView, coordinator: Coordinator) {
        Task { @MainActor in
            guard let layer = playerView.playerLayer else { return }
            // 记录退出时的进度与播放状态，交给 LNVideoView 的 onDismiss 写回内嵌实例
            coordinator.sync.time = layer.player.currentPlaybackTime
            coordinator.sync.wasPlaying = layer.state.isPlaying
            // 字幕选择一并带回去（全屏里可能换过字幕）
            coordinator.sync.subtitleID = playerView.srtControl.selectedSubtitleInfo?.subtitleID
            layer.pause()
            playerView.playerLayer = nil
        }
    }
}

/// SwiftUI 全屏播放页：黑色背景 + 播放器接管 + 旋转/关闭按钮。
/// 旋转按钮按主流播放器习惯放在**画面垂直居中、贴右边**（中央播放键的右侧），
/// 关闭按钮留右上角。
private struct LNKSPlayerFullscreen: View {
    let box: LNKSPlayerBox
    let url: URL
    let options: KSOptions
    let startTime: Double
    let autoplay: Bool
    let sync: LNPlayerSyncBox
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var forcedLandscape = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LNKSFullscreenHost(box: box, url: url, options: options,
                               startTime: startTime, autoplay: autoplay, sync: sync)
                .ignoresSafeArea()
        }
        // 旋转按钮：垂直居中、贴右边（与中央播放按钮同一行）
        .overlay(alignment: .trailing) {
            Button {
                forcedLandscape.toggle()
                ReaderScreenOrientation.apply(forcedLandscape ? "2" : "1")
            } label: {
                Image(systemName: rotorSymbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .padding(.trailing, 12)
            .accessibilityLabel(forcedLandscape ? "切回竖屏" : "横屏旋转")
        }
        // 标题：右上角关闭键之外，左上角放文件名（KSPlayer 自带返回键已隐藏）
        .overlay(alignment: .topLeading) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.leading, 16)
                .padding(.top, 16)
                .allowsHitTesting(false)
        }
        // 关闭按钮：右上角
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 10)
            .padding(.trailing, 16)
            .accessibilityLabel("退出全屏")
        }
        .onAppear {
            // 全屏播放页里允许自由旋转（跟手转），点按钮则强制横/竖
            ReaderScreenOrientation.apply("0")
        }
        .onDisappear {
            ReaderScreenOrientation.restoreApplicationDefault()
        }
        .statusBar(hidden: true)
    }

    /// 旋转图标：iOS 16+ 用「屏幕旋转」专属符号，旧系统退回环形箭头（都保证能渲染）
    private var rotorSymbol: String {
        if #available(iOS 16.0, *) {
            return "rectangle.portrait.rotate"
        }
        return "arrow.clockwise"
    }
}

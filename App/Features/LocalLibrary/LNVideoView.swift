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
    /// 全屏关闭回调：阅读页靠它把滚动位置拉回视频处（章尾）
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
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if !failed {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.06))
                    ProgressView()
                }
                .frame(height: 240)
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
            return
        }
        // 回退：本地文件 / SMB / 流式失败后的整文件下载
        guard let localURL = try? await source.localURL(for: item.path) else {
            failed = true
            return
        }
        setPlayer(url: localURL, options: KSOptions())
    }

    private func setPlayer(url newURL: URL, options newOptions: KSOptions) {
        duration = nil
        url = newURL
        options = newOptions
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

/// 全屏 ↔ 内嵌之间的进度/播放状态同步盒子。
/// 全屏是独立的播放实例，进入时记录内嵌进度、退出时把全屏进度写回来。
final class LNPlayerSyncBox {
    var time: Double = 0
    var wasPlaying = false
}

/// 桥接 IOSVideoPlayerView 回调的小盒子（weak delegate 的持有方）。
final class LNKSPlayerBox: NSObject, PlayerControllerDelegate {
    /// 当前内嵌宿主的播放器视图（全屏接管 layer 时用它找回内嵌视图）
    weak var view: LNPlayerView?
    var onDuration: ((Double) -> Void)?
    var onFinishError: ((Error?) -> Void)?
    /// 请求进入全屏（SwiftUI 侧置 showFullscreen = true）
    var onRequestFullscreen: (() -> Void)?

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
        playerView.delegate = box
        playerView.playTimeDidChange = { _, total in
            guard total > 0, total.isFinite else { return }
            box.onDuration?(total)
        }
        playerView.autoFullscreenOnPlay = autoFullscreenOnPlay
        playerView.onRequestFullscreen = onRequestFullscreen
        box.view = playerView
        return playerView
    }

    func updateUIView(_ playerView: LNPlayerView, context _: Context) {
        // 流式失败回退下载、换章等场景：URL 变了就重设（KSPlayer 内部会重建 layer）
        if playerView.playerLayer?.url != url {
            playerView.set(url: url, options: options)
        }
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
        // 全屏实例自己就是 layer 的 delegate（状态回调直接驱动自己的控制条）
        playerView.delegate = box
        playerView.playTimeDidChange = { _, total in
            guard total > 0, total.isFinite else { return }
            box.onDuration?(total)
        }
        // 续播：未 ready 时 KSPlayer 会把 seek 存起来，ready 后自动 seek + 播放
        if let layer = playerView.playerLayer {
            layer.seek(time: max(0, startTime), autoPlay: autoplay) { _ in }
        }
        return playerView
    }

    func updateUIView(_ view: LNPlayerView, context _: Context) {}

    static func dismantleUIView(_ playerView: LNPlayerView, coordinator: Coordinator) {
        Task { @MainActor in
            guard let layer = playerView.playerLayer else { return }
            // 记录退出时的进度与播放状态，交给 LNVideoView 的 onDismiss 写回内嵌实例
            coordinator.sync.time = layer.player.currentPlaybackTime
            coordinator.sync.wasPlaying = layer.state.isPlaying
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

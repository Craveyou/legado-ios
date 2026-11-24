import SwiftUI
@preconcurrency import KSPlayer

/// 章末视频 / 短剧单集播放器（b54：修正 KSPlayer 集成层级）。
///
/// b53 的教训：KSVideoPlayer.Coordinator.makeView 返回的是
/// KSMEPlayer 的裸 Metal 渲染视图（videoOutput），控制条根本不在这层——
/// 所以满屏黑、无任何控件。控制条在上层的 IOSVideoPlayerView。
///
/// b54 直接宿主 IOSVideoPlayerView（UIKit，iOS 13+，SwiftUI 的
/// KSVideoPlayerView 要 iOS 16 用不了）：
/// - 自带完整控制条：播放/暂停、拖动、倍速菜单、字幕选择、音轨切换
/// - 自带长按 2x 倍速（松手恢复）
/// - 自带横屏全屏：点控制条右上角按钮，视图自动 reparent 进
///   PlayerFullScreenViewController（真旋转、动画），退出自动还原位置；
///   也可以程序触发 landscapeButton.sendActions 主动全屏
/// - playTimeDidChange / PlayerControllerDelegate 回传时长与播放错误，
///   保留「流式失败 → 自动回退整文件下载」的降级链路
/// - KSOptions.isAutoPlay = false：点击播放才开始，不自动响
struct LNVideoView: View {
    let item: LNMediaItem
    let source: any LNLibrarySource
    /// 全屏播放结束（退出全屏）回调：阅读页靠它把滚动位置拉回视频处
    var onFullscreenEnd: (() -> Void)? = nil

    @State private var box = LNKSPlayerBox()
    @State private var url: URL?
    @State private var options: KSOptions?
    @State private var duration: Double?
    @State private var failed = false

    /// 流式播放失败的具体原因（展示出来便于诊断）
    @State private var streamError: String?
    /// 是否允许流式（回退一次后关闭，避免死循环）
    @State private var allowStreaming = true

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
                               autoFullscreenOnPlay: shouldAutoFullscreen)
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
                    // 触发 KSPlayer 原生横屏全屏（reparent + 真旋转，退出自动还原）
                    box.view?.landscapeButton.sendActions(for: .touchUpInside)
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
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
            box.onFullscreenEnd = { onFullscreenEnd?() }
        }
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

/// 桥接 IOSVideoPlayerView 回调的小盒子（weak delegate 的持有方）。
final class LNKSPlayerBox: NSObject, PlayerControllerDelegate {
    /// 当前宿主的播放器视图（用于程序触发横屏全屏）
    weak var view: LNPlayerView?
    var onDuration: ((Double) -> Void)?
    var onFinishError: ((Error?) -> Void)?
    /// 全屏退出回调（用于阅读页把滚动位置拉回视频处，避免回到章首）
    var onFullscreenEnd: (() -> Void)?

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
/// 1. 内嵌（竖屏）时 KSPlayer 默认隐藏横屏按钮——这里强制显示，让用户随时能全屏；
/// 2. 首次播放（用户点播放后才可能进入 .bufferFinished，因为 isAutoPlay=false）
///    自动进入全屏（可通过 autoFullscreenOnPlay 关闭，音频不启用）；
/// 3. 全屏进出回调给上层（退出后阅读页可拉回滚动位置）。
final class LNPlayerView: IOSVideoPlayerView {
    var autoFullscreenOnPlay = false
    var onFullscreenChanged: ((Bool) -> Void)?

    private var didAutoFullscreen = false
    private var isInFullscreen = false

    override func updateUI(isLandscape: Bool) {
        super.updateUI(isLandscape: isLandscape)
        // KSPlayer 竖屏内嵌下会隐藏横屏/倍速/字幕按钮；统一常显，
        // 小卡片里也能随时全屏、调倍速、选字幕
        landscapeButton.isHidden = false
        toolBar.playbackRateButton.isHidden = false
        if !srtControl.subtitleInfos.isEmpty {
            toolBar.srtButton.isHidden = false
        }
    }

    override func updateUI(isFullScreen: Bool) {
        super.updateUI(isFullScreen: isFullScreen)
        guard isInFullscreen != isFullScreen else { return }
        isInFullscreen = isFullScreen
        onFullscreenChanged?(isFullScreen)
    }

    override func player(layer: KSPlayerLayer, state: KSPlayerState) {
        super.player(layer: layer, state: state)
        guard state == .bufferFinished, autoFullscreenOnPlay, !didAutoFullscreen else { return }
        didAutoFullscreen = true
        // 等画面真正出来再进全屏，避免全屏后先看到长时间黑屏
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !self.isInFullscreen, self.window != nil else { return }
            self.updateUI(isFullScreen: true)
        }
    }
}

/// UIKit 播放器宿主：IOSVideoPlayerView 自带控制条与全屏逻辑。
struct LNKSPlayerHost: UIViewRepresentable {
    let box: LNKSPlayerBox
    let url: URL
    let options: KSOptions
    /// 视频类内容才自动全屏（音频不弹全屏）
    let autoFullscreenOnPlay: Bool

    func makeUIView(context _: Context) -> LNPlayerView {
        let playerView = LNPlayerView()
        // 顶栏返回键在非全屏时不做任何事，避免误触发阅读页导航返回
        playerView.backBlock = {}
        playerView.set(url: url, options: options)
        playerView.delegate = box
        playerView.playTimeDidChange = { _, total in
            guard total > 0, total.isFinite else { return }
            box.onDuration?(total)
        }
        playerView.autoFullscreenOnPlay = autoFullscreenOnPlay
        playerView.onFullscreenChanged = { [weak box] isFull in
            // 退出全屏后留一点时间等 dismiss 动画与视图回收，再拉回滚动位置
            guard !isFull else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                box?.onFullscreenEnd?()
            }
        }
        // KSSlider 把 thumb 区域放大了 ±20pt，默认白色 thumb 在小卡片里
        // 就是一颗顶着左边缘的大圆点；隐藏 thumb，进度由轨道填充色表达
        playerView.toolBar.timeSlider.setThumbImage(UIImage(), for: .normal)
        playerView.toolBar.timeSlider.setThumbImage(UIImage(), for: .highlighted)
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
        // 阅读页滚走/退出时停播；全屏 reparent 不走 dismantle，不影响播放
        Task { @MainActor in
            playerView.pause()
        }
    }
}

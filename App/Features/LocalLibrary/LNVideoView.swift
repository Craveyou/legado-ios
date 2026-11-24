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
                LNKSPlayerHost(box: box, url: url, options: options)
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
        }
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
    weak var view: IOSVideoPlayerView?
    var onDuration: ((Double) -> Void)?
    var onFinishError: ((Error?) -> Void)?

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

/// UIKit 播放器宿主：IOSVideoPlayerView 自带控制条与全屏逻辑。
struct LNKSPlayerHost: UIViewRepresentable {
    let box: LNKSPlayerBox
    let url: URL
    let options: KSOptions

    func makeUIView(context _: Context) -> IOSVideoPlayerView {
        let playerView = IOSVideoPlayerView()
        // 顶栏返回键在非全屏时不做任何事，避免误触发阅读页导航返回
        playerView.backBlock = {}
        playerView.set(url: url, options: options)
        playerView.delegate = box
        playerView.playTimeDidChange = { _, total in
            guard total > 0, total.isFinite else { return }
            box.onDuration?(total)
        }
        // KSSlider 把 thumb 区域放大了 ±20pt，默认白色 thumb 在小卡片里
        // 就是一颗顶着左边缘的大圆点；隐藏 thumb，进度由轨道填充色表达
        playerView.toolBar.timeSlider.setThumbImage(UIImage(), for: .normal)
        playerView.toolBar.timeSlider.setThumbImage(UIImage(), for: .highlighted)
        box.view = playerView
        return playerView
    }

    func updateUIView(_ playerView: IOSVideoPlayerView, context _: Context) {
        // 流式失败回退下载、换章等场景：URL 变了就重设（KSPlayer 内部会重建 layer）
        if playerView.playerLayer?.url != url {
            playerView.set(url: url, options: options)
        }
    }

    static func dismantleUIView(_ playerView: IOSVideoPlayerView, coordinator _: ()) {
        // 阅读页滚走/退出时停播；全屏 reparent 不走 dismantle，不影响播放
        Task { @MainActor in
            playerView.pause()
        }
    }
}

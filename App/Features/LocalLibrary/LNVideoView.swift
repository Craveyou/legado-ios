import SwiftUI
@preconcurrency import KSPlayer

/// 章末视频 / 短剧单集播放器（b53 起换 KSPlayer 全格式内核）。
///
/// 为什么换内核：AVPlayer 解不了 mkv / rmvb / wmv 等容器，
/// NAS 视频显示「禁止播放」的根因就是它。KSPlayer 2.3.4（纯源码 SPM，iOS 13+）
/// 用 FFmpeg 解码，自带：
/// - 全格式播放（mkv/rmvb/wmv/avi/flv…）
/// - 完整控制条：播放/暂停、拖动、倍速菜单、字幕选择、音轨/清晰度切换
/// - **长按 2x 倍速**（松手恢复，VideoPlayerView 内置手势）
/// - **横屏全屏**（控制条右上角按钮，真旋转不是画面 hack）
/// - 内嵌字幕自动加载（mkv 内挂字幕直接可选）
///
/// 实现要点：
/// - 用底层 KSVideoPlayer（UIViewRepresentable，裸 UIKit 播放器视图），
///   不用 KSVideoPlayerView——后者带 .toolbar(.hidden)，会连累阅读页导航栏。
/// - 内嵌与全屏**共用同一个 Coordinator**（= 同一个 KSPlayerLayer =
///   同一个播放实例），绝不在全屏时新建播放器，避免双音轨。
/// - 流式：NAS WebDAV 远端 URL + appendHeader 认证头（FFmpeg http 协议原生支持），
///   失败自动回退整文件下载；本地文件 / SMB 直接 file URL。
/// - KSOptions.isAutoPlay = false：和旧版一致「点击播放才开始」，不自动响。
/// - firstPlayerType 直接用 KSMEPlayer（FFmpeg）：跳过 AVPlayer 试错，
///   mkv 第一次就能播；AVPlayer 解不了的格式会多一轮失败重试。
struct LNVideoView: View {
    let item: LNMediaItem
    let source: any LNLibrarySource

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var url: URL?
    @State private var options: KSOptions?
    @State private var duration: Double?
    @State private var failed = false
    @State private var fullscreen = false

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
                    .lineLimit(2)
            }
            if let url, let options {
                playerCard(url: url, options: options)
            } else if !failed {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.06))
                    ProgressView()
                }
                .frame(height: 200)
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
                    fullscreen = true
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                        .font(.caption)
                        .foregroundStyle(ReadingTheme.accent)
                }
                .accessibilityLabel("全屏播放")
            }
        }
        .task(id: item.path) { await load() }
        .fullScreenCover(isPresented: $fullscreen) {
            if let url, let options {
                LNKSPlayerFullscreen(coordinator: coordinator, url: url, options: options)
            }
        }
    }

    /// 内嵌播放卡片：KSPlayer 裸 UIKit 视图（自带全部控制条）。
    @ViewBuilder
    private func playerCard(url: URL, options: KSOptions) -> some View {
        ZStack {
            Color.black.opacity(0.001)
            KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                .onPlay { _, total in
                    // 时长由播放器回报，流式/本地统一处理
                    if total > 0, total.isFinite, duration != total {
                        duration = total
                    }
                }
                .onFinish { _, error in
                    handlePlaybackError(error)
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(height: 240)
    }

    // MARK: - 加载

    private func load() async {
        guard url == nil, !failed else { return }
        // KSPlayer 全局偏好：不自动播放 + 直接用 FFmpeg 内核（可重复设置，幂等）
        KSOptions.isAutoPlay = false
        KSOptions.firstPlayerType = KSMEPlayer.self

        // 优先流式播放：NAS WebDAV 远端 URL + 认证头，按需拉流秒开。
        // FFmpeg 内核原生吃 headers，mkv 也能流式播。
        if allowStreaming, let (remoteURL, headers) = try? await source.streamingVideo(for: item.path) {
            let options = KSOptions()
            for (key, value) in headers {
                options.appendHeader([key: value])
            }
            setPlayer(url: remoteURL, options: options)
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

/// 全屏播放器：复用内嵌同一个 Coordinator（同一个播放实例），避免双音轨。
/// KSPlayer 控制条自带：倍速菜单、字幕选择、横屏全屏（真旋转）、拖动进度。
private struct LNKSPlayerFullscreen: View {
    let coordinator: KSVideoPlayer.Coordinator
    let url: URL
    let options: KSOptions

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReadingNavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("退出全屏")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

import SwiftUI
import AVKit
import AVFoundation

/// 章末视频 / 短剧单集：点击播放、不自动播放；支持全屏、长按倍速、旋转画面。
///
/// 重要：内嵌播放器与全屏播放器**必须共用同一个 AVPlayer 实例**，
/// 否则两处同播 → 双音轨。
///
/// 实现要点（b50，整体搬自 LocalNovel 的成熟实现）：
/// - 播放器用 **UIViewControllerRepresentable 直接返回 AVPlayerViewController**，
///   SwiftUI 自动完成 childViewController 装配。之前手写 UIViewRepresentable
///   + addChild 的装配链路在 LazyVStack/弹层里反复黑屏（b47-b49 的教训）。
/// - 加载后**不设 rate**：AVPlayer 对未播放的实例直接设 `rate = 1.0` 会立刻开播
///   （「没点播放自己响」的根因）；倍速只在正在播放时套用。
/// - 长按手势挂在 controller.view 上（cancelsTouchesInView=false + 并行识别），
///   系统播放控件照常响应；SwiftUI 层手势会被系统手势吞掉，不能用。
struct LNVideoView: View {
    let item: LNMediaItem
    let source: any LNLibrarySource

    @State private var player: AVPlayer?
    @State private var duration: Double?
    @State private var failed = false
    @State private var fullscreen = false

    /// 倍速：长按内嵌画面循环切换；全屏里也有按钮
    @State private var speed: Float = 1.0
    @State private var speedHint: String?

    private let speeds: [Float] = [1.0, 1.25, 1.5, 2.0, 0.75]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if failed {
                Label("无法播放：\(item.fileName)", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let player {
                ZStack {
                    LNPlayerSurface(player: player, onLongPress: cycleSpeed)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        // 全屏时内嵌画面仍然渲染同一 player，视觉上没问题（只有一个音轨）
                        .overlay(alignment: .topTrailing) {
                            HStack(spacing: 6) {
                                Button {
                                    fullscreen = true
                                } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(Color.black.opacity(0.45), in: Circle())
                                }
                                .accessibilityLabel("全屏播放")
                            }
                            .padding(8)
                        }
                        .overlay(alignment: .bottomLeading) {
                            if speed != 1.0 {
                                Text("\(speed, specifier: "%.2g")×")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.black.opacity(0.55), in: Capsule())
                                    .padding(8)
                            }
                        }
                }
                .overlay(alignment: .center) {
                    if let speedHint {
                        Text(speedHint)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Color.black.opacity(0.7), in: Capsule())
                            .transition(.opacity)
                    }
                }
                // 播放/暂停由系统控制条接管；用户点播放时把记住的倍速套回去
                // （系统控件的 play 固定以 1.0 开播）
                .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                    guard status == .playing, player.rate != speed else { return }
                    player.rate = speed
                }
            } else {
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
                if let duration, duration > 0 {
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
            LNVideoFullscreen(item: item, source: source, player: player,
                              speed: $speed, onSpeedChange: applySpeed)
        }
    }

    private func load() async {
        guard player == nil, !failed else { return }
        guard let url = try? await source.localURL(for: item.path) else {
            failed = true
            return
        }
        let p = AVPlayer(url: url)
        // 注意：这里绝不能 p.rate = speed —— 未播放的 player 直接设 rate 会立刻开播
        player = p
        let asset = AVURLAsset(url: url)
        if let cm = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(cm)
            if seconds.isFinite, seconds > 0 { duration = seconds }
        }
    }

    private func applySpeed(_ value: Float) {
        speed = value
        // 暂停状态下直接设 rate 会把视频启动起来；只在正在播放时改 rate，
        // 暂停时先记住，等用户点播放后由 timeControlStatus 监听套用。
        if let player, player.timeControlStatus == .playing {
            player.rate = value
        }
    }

    private func cycleSpeed() {
        guard let index = speeds.firstIndex(of: speed) else { return }
        let next = speeds[(index + 1) % speeds.count]
        applySpeed(next)
        speedHint = "播放速度 \(formatSpeed(next))×"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            speedHint = nil
        }
    }

    private func formatSpeed(_ value: Float) -> String {
        value == 1 ? "1.0" : String(format: "%.2g", value)
    }

    private func timeText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// 全屏播放器：复用内嵌传进来的同一个 AVPlayer，绝不自己新建，避免双音轨。
/// 长按画面也能循环倍速；「旋转」是画面旋转（转 90° 后握持手机方向即可），退出自动复原。
private struct LNVideoFullscreen: View {
    let item: LNMediaItem
    let source: any LNLibrarySource
    let player: AVPlayer?
    @Binding var speed: Float
    let onSpeedChange: (Float) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rotated = false

    private let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        ReadingNavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let player {
                        LNPlayerSurface(player: player, onLongPress: cycleSpeed)
                            .frame(width: rotated ? geo.size.height : geo.size.width,
                                   height: rotated ? geo.size.width : geo.size.height)
                            .rotationEffect(.degrees(rotated ? 90 : 0))
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()
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
                    HStack(spacing: 12) {
                        Menu {
                            ForEach(speeds, id: \.self) { value in
                                Button {
                                    onSpeedChange(value)
                                } label: {
                                    HStack {
                                        Text("\(formatSpeed(value))×")
                                        if abs(speed - value) < 0.01 {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text("\(formatSpeed(speed))×")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.white.opacity(0.18), in: Capsule())
                        }
                        .accessibilityLabel("播放倍速")
                        Button {
                            rotated.toggle()
                        } label: {
                            Image(systemName: rotated ? "arrow.counterclockwise" : "rotate.3deg")
                                .foregroundStyle(rotated ? ReadingTheme.accent : .white)
                        }
                        .accessibilityLabel(rotated ? "恢复画面方向" : "旋转画面")
                        Button("完成") { dismiss() }
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .onAppear { onSpeedChange(speed) }
    }

    private func cycleSpeed() {
        guard let index = speeds.firstIndex(of: speed) else { return }
        let next = speeds[(index + 1) % speeds.count]
        onSpeedChange(next)
    }

    private func formatSpeed(_ value: Float) -> String {
        value == 1 ? "1.0" : String(format: "%.2g", value)
    }
}

/// AVPlayerViewController 的 SwiftUI 宿主（搬自 LocalNovel 的 FullscreenPlayerHost）：
/// **UIViewControllerRepresentable 直接返回控制器**，SwiftUI 自动装配 child，
/// 不存在手动 addSubview/addChild 的坑。长按手势挂 controller.view 上，
/// 与系统播放控件并行识别（照搬 LocalNovel 的 RateBoostGesture）。
private struct LNPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let onLongPress: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLongPress: onLongPress) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        controller.view.backgroundColor = .black

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        longPress.minimumPressDuration = 0.4
        longPress.allowableMovement = 24
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        controller.view.addGestureRecognizer(longPress)
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.onLongPress = onLongPress
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onLongPress: () -> Void

        init(onLongPress: @escaping () -> Void) {
            self.onLongPress = onLongPress
        }

        @objc func handle(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            onLongPress()
        }

        // 与系统播放控件的手势并行识别，互不阻断
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

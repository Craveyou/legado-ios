import SwiftUI
import UIKit
import ImageIO
import QuartzCore

// MARK: - 动图解码与播放
// 参照 LocalNovel FrameDecoder / AnimatedImageView：ImageIO 逐帧解码 + CADisplayLink 播放。
// 零第三方依赖，iOS 15 全兼容。内存保护：最多 12 张动图驻留、单边 1200px。

struct LNAnimatedFrame {
    let image: UIImage
    let duration: TimeInterval
}

private final class LNFrameBox: NSObject {
    let frames: [LNAnimatedFrame]
    init(_ frames: [LNAnimatedFrame]) { self.frames = frames }
}

/// 跨并发域传递帧数组（UIImage 非 Sendable）
struct LNAnimatedFramesPayload: @unchecked Sendable {
    let frames: [LNAnimatedFrame]
}

/// NSCache 本身线程安全；加 @unchecked Sendable 仅用于 Swift 6 静态属性检查。
final class LNAnimatedFrameCache: @unchecked Sendable {
    static let shared = LNAnimatedFrameCache()
    private let cache = NSCache<NSURL, LNFrameBox>()
    private let queue = DispatchQueue(label: "ln.animated.decode",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

    private init() { cache.countLimit = 6 }

    /// 只查缓存，不触发解码（主线程安全）
    func cached(for url: URL) -> [LNAnimatedFrame]? {
        cache.object(forKey: url as NSURL)?.frames
    }

    /// 后台解帧；主线程绝不参与
    func load(url: URL) async -> LNAnimatedFramesPayload {
        if let hit = cached(for: url) { return LNAnimatedFramesPayload(frames: hit) }
        return await withCheckedContinuation { continuation in
            queue.async {
                let decoded = LNAnimatedDecoder.decode(url: url)
                if !decoded.isEmpty {
                    self.cache.setObject(LNFrameBox(decoded), forKey: url as NSURL)
                }
                continuation.resume(returning: LNAnimatedFramesPayload(frames: decoded))
            }
        }
    }
}

enum LNAnimatedDecoder {
    static func isAnimated(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// 帧数与单边尺寸都收紧：90 帧 1200px 一次解码要吃几百 MB，
    /// 45 帧 1000px 在手机上看不出差别，内存和耗时都减半。
    static func decode(url: URL, maxFrames: Int = 45, maxDimension: Int = 1000) -> [LNAnimatedFrame] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            if let image = loadStatic(url: url, maxPixel: maxDimension) {
                return [LNAnimatedFrame(image: image, duration: 0)]
            }
            return []
        }

        let step = max(1, count / maxFrames)
        var indices: [Int] = []
        var i = 0
        while i < count {
            indices.append(i)
            i += step
        }

        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: maxDimension,
            kCGImageSourceShouldCacheImmediately as String: true
        ]

        var frames: [LNAnimatedFrame] = []
        frames.reserveCapacity(indices.count)
        for index in indices {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index,
                                                               options as CFDictionary) else { continue }
            let image = UIImage(cgImage: cg)
            var duration: TimeInterval = 0
            for k in index..<min(index + step, count) {
                duration += delay(at: k, in: source)
            }
            frames.append(LNAnimatedFrame(image: image, duration: max(0.02, duration)))
        }
        return frames
    }

    static func loadStatic(url: URL, maxPixel: Int = 1600) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: maxPixel,
            kCGImageSourceShouldCacheImmediately as String: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                           options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func delay(at index: Int, in source: CGImageSource) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else {
            return 0.1
        }
        if let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
            let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double ?? 0
            let clamped = gif[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0
            let d = unclamped > 0 ? unclamped : clamped
            return d >= 0.02 ? d : 0.1
        }
        if let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any],
           let d = png["DelayTime"] as? Double, d >= 0.02 {
            return d
        }
        return 0.1
    }
}

// MARK: - 播放视图

final class LNAnimatedFrameView: UIView {
    private let imageView = UIImageView()
    private var link: CADisplayLink?
    private var currentURL: URL?
    private var frames: [LNAnimatedFrame] = []
    private var cumulative: [TimeInterval] = []
    private var total: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private var lastTimestamp: TimeInterval = 0
    private var currentIndex = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        addSubview(imageView)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    /// 帧还没解好时先显示首帧静态图，避免大白块
    func setPlaceholder(_ image: UIImage?) {
        guard frames.isEmpty else { return }
        imageView.image = image
    }

    func configure(url: URL, frames: [LNAnimatedFrame]) {
        guard currentURL != url, !frames.isEmpty else { return }
        currentURL = url
        self.frames = frames
        cumulative = []
        var acc: TimeInterval = 0
        for f in frames {
            acc += f.duration
            cumulative.append(acc)
        }
        total = max(acc, 0.02)
        elapsed = 0
        currentIndex = -1
        showFrame(at: 0)
    }

    func start() {
        guard link == nil, total > 0 else { return }
        lastTimestamp = 0
        let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func releaseFrames() {
        stop()
        frames = []
        cumulative = []
        imageView.image = nil
        currentURL = nil
        currentIndex = -1
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp == 0 { lastTimestamp = link.timestamp }
        let delta = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        elapsed = (elapsed + delta).truncatingRemainder(dividingBy: total)

        var index = 0
        while index < cumulative.count - 1, cumulative[index] < elapsed { index += 1 }
        showFrame(at: index)
    }

    private func showFrame(at index: Int) {
        guard index != currentIndex, frames.indices.contains(index) else { return }
        currentIndex = index
        imageView.image = frames[index].image
    }
}

/// 动图视图（SwiftUI 壳）：帧数据在后台解，解好再交给 UIView 播放。
/// 之前直接在 updateUIView 里同步解帧，等于每次刷新都在主线程卡一次，是滚动卡顿的元凶之一。
struct LNAnimatedImageView: View {
    let url: URL
    let isVisible: Bool
    var placeholder: UIImage?

    @State private var frames: [LNAnimatedFrame] = []

    var body: some View {
        LNAnimatedFrameRepresentable(url: url,
                                     frames: frames,
                                     isVisible: isVisible,
                                     placeholder: placeholder)
            .task(id: "\(url.absoluteString)|\(isVisible)") {
                if let hit = LNAnimatedFrameCache.shared.cached(for: url) {
                    frames = hit
                    return
                }
                guard isVisible else { return }   // 没上屏不解码
                frames = (await LNAnimatedFrameCache.shared.load(url: url)).frames
            }
    }
}

struct LNAnimatedFrameRepresentable: UIViewRepresentable {
    let url: URL
    let frames: [LNAnimatedFrame]
    let isVisible: Bool
    let placeholder: UIImage?

    func makeUIView(context: Context) -> LNAnimatedFrameView {
        LNAnimatedFrameView(frame: .zero)
    }

    func updateUIView(_ uiView: LNAnimatedFrameView, context: Context) {
        uiView.setPlaceholder(placeholder)
        if !frames.isEmpty {
            uiView.configure(url: url, frames: frames)
        }
        if isVisible { uiView.start() } else { uiView.stop() }
    }

    static func dismantleUIView(_ uiView: LNAnimatedFrameView, coordinator: ()) {
        uiView.releaseFrames()
    }
}

import UIKit
import ImageIO

/// 解码结果：UIImage 不是 Sendable，用 @unchecked 包一层跨并发域传递。
struct LNLoadedImage: @unchecked Sendable {
    let image: UIImage
    /// 原始宽高比（宽 / 高），用于加载前预留高度、避免图片到位后布局跳动
    let aspectRatio: CGFloat
}

/// 图片加载器：ImageIO 后台降采样 + NSCache 内存缓存。
///
/// 之前 `UIImage(data:)` + `UIGraphicsImageRenderer` 全在主线程执行，
/// 一张 4000px 的漫画图解码就要几十毫秒、占几十 MB，连续滚动必然掉帧。
/// 这里改成：
/// · 用 `CGImageSourceCreateThumbnailAtIndex` 只解目标尺寸（比全图解码快数倍、内存只有 1/N）；
/// · 解码全部在后台并发队列，主线程只做赋值；
/// · 结果进 NSCache（按像素成本计费，上限 128MB），滚回去不再重解。
///
/// ⚠️ 条漫清晰度：`kCGImageSourceThumbnailMaxPixelSize` 限制的是**最长边**。
/// 若直接传 1440，一张 800×5000 的条漫会被压成 230×1440，宽度只有 230px，
/// 撑满 430pt 屏幕就糊了。这里改成「按目标宽度反算长边」：
/// 先读原图像素宽高 → 目标宽度 = maxPixel → 需要的最长边 = max(宽, 高) × (maxPixel / 宽)，
/// 再用一个总像素上限兜底防止超长图 OOM。
final class LNImageLoader: @unchecked Sendable {
    static let shared = LNImageLoader()

    /// 单张图解码后的像素总量上限（约 40MB 内存）。超长条漫超过就整体缩小，
    /// 保证不会一张图吃掉几百 MB。
    private static let maxTotalPixels: CGFloat = 10_000_000

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "ln.image.decode",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

    private init() {
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.countLimit = 240
    }

    /// 缓存命中直接返回（纯内存操作，主线程调用安全）
    func cached(_ url: URL, maxPixel: CGFloat) -> LNLoadedImage? {
        guard let image = cache.object(forKey: key(url, maxPixel)) else { return nil }
        return LNLoadedImage(image: image, aspectRatio: Self.ratio(of: image))
    }

    /// 异步加载；未命中缓存时在后台解码
    func load(_ url: URL, maxPixel: CGFloat) async -> LNLoadedImage? {
        if let hit = cached(url, maxPixel: maxPixel) { return hit }
        let cacheKey = key(url, maxPixel)
        let target = max(240, maxPixel)
        return await withCheckedContinuation { continuation in
            queue.async {
                let loaded = Self.decode(url: url, maxPixel: target)
                if let loaded {
                    self.cache.setObject(loaded.image, forKey: cacheKey,
                                         cost: Self.cost(of: loaded.image))
                }
                continuation.resume(returning: loaded)
            }
        }
    }

    /// 预取（章节打开时提前解码前几张，滚动到位置时不卡）
    func prefetch(_ urls: [URL], maxPixel: CGFloat) {
        let cacheKey = urls.map { key($0, maxPixel) }
        for (index, url) in urls.enumerated() {
            if cache.object(forKey: cacheKey[index]) != nil { continue }
            let key = cacheKey[index]
            let target = max(240, maxPixel)
            queue.async {
                guard let loaded = Self.decode(url: url, maxPixel: target) else { return }
                self.cache.setObject(loaded.image, forKey: key, cost: Self.cost(of: loaded.image))
            }
        }
    }

    // MARK: - 解码

    private static func decode(url: URL, maxPixel: CGFloat) -> LNLoadedImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        // 读原图像素宽高（不解码像素，只读元数据，很快）
        var pixelWidth: CGFloat = 0
        var pixelHeight: CGFloat = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            pixelWidth = CGFloat((props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0)
            pixelHeight = CGFloat((props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0)
        }

        // 目标宽度 = maxPixel（屏幕点宽 × 2，Retina 够清晰；不放大原图，只缩小）。
        // ImageIO 只能限制最长边，所以由「缩放后的宽高」反算最长边。
        let targetLongEdge: Int
        if pixelWidth > 0, pixelHeight > 0 {
            // 缩放系数：原图比目标宽才缩；原图本来就窄（条漫常见）则保持原尺寸，不插值放大
            let scale = min(1, maxPixel / pixelWidth)
            var outWidth = pixelWidth * scale
            var outHeight = pixelHeight * scale
            // 总像素兜底：超长条漫（如 800×20000）整张高清解会吃掉几百 MB，
            // 超过上限就按 sqrt 比例整体再缩一档（此时宽度会小于目标，但避免 OOM）
            if outWidth * outHeight > maxTotalPixels {
                let guardScale = sqrt(maxTotalPixels / (outWidth * outHeight))
                outWidth *= guardScale
                outHeight *= guardScale
            }
            targetLongEdge = max(240, Int(max(outWidth, outHeight)))
        } else {
            targetLongEdge = Int(maxPixel)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 处理 EXIF 旋转
            kCGImageSourceThumbnailMaxPixelSize: targetLongEdge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = UIImage(cgImage: cgImage)
        return LNLoadedImage(image: image, aspectRatio: ratio(of: image))
    }

    private static func ratio(of image: UIImage) -> CGFloat {
        let height = max(image.size.height, 1)
        let value = image.size.width / height
        return value.isFinite && value > 0 ? value : 0.75
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    private func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.path)|\(Int(maxPixel))" as NSString
    }
}

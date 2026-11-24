import SwiftUI
import UIKit

/// 章节插图：静态图后台降采样 + 动图异步逐帧 + 点击放大。
///
/// 性能约束（本次卡顿修复的核心）：
/// · 主线程不做任何文件 I/O 与图片解码，全部交给 LNImageLoader 的后台队列；
/// · 加载前按宽高比占位，图片到位不改变滚动高度，避免「一卡一跳」；
/// · 动图由 LNAnimatedImageView 自己异步解帧，未上屏不占用 CPU。
struct LNImageView: View {
    let item: LNMediaItem
    let source: any LNLibrarySource
    let onTap: () -> Void

    @State private var image: UIImage?
    @State private var aspectRatio: CGFloat = 0
    @State private var resolvedURL: URL?
    @State private var isOnScreen = false

    /// 目标解码边长：Pro Max 宽 430pt × 3 = 1290px，取 1440 够锐且不浪费内存。
    /// 不用 @Environment(\.displayScale)（iOS 16+），也不用 UIScreen.main（新版已弃用）。
    private var maxPixel: CGFloat { 1440 }

    var body: some View {
        Group {
            if item.kind == .animatedImage, let resolvedURL {
                LNAnimatedImageView(url: resolvedURL,
                                    isVisible: isOnScreen,
                                    placeholder: image)
                    .aspectRatio(aspectRatio > 0 ? aspectRatio : 0.75, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(placeholderColor)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(placeholderColor)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .transaction { $0.animation = nil }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .task(id: item.path) { await load() }
        .accessibilityLabel(item.fileName)
        .accessibilityAddTraits(.isImage)
    }

    private var placeholderColor: Color { Color.secondary.opacity(0.08) }

    /// 未知比例时按 3:4 竖图预留，图片到位再变高度
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(placeholderColor)
            .aspectRatio(aspectRatio > 0 ? aspectRatio : 0.75, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
    }

    private func load() async {
        guard resolvedURL == nil else { return }
        guard let url = try? await source.localURL(for: item.path) else { return }
        resolvedURL = url
        // 动图也只解首帧做占位，帧数据由 LNAnimatedImageView 异步加载
        guard let loaded = await LNImageLoader.shared.load(url, maxPixel: maxPixel) else { return }
        image = loaded.image
        if aspectRatio == 0 { aspectRatio = loaded.aspectRatio }
    }
}

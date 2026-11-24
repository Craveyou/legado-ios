import SwiftUI
import UIKit

/// 阅读页隐藏底部 Tab 栏。
///
/// 经验教训：iOS 17/18/27 上，从 `List` 里的 NavigationLink push 出的详情页，
/// 单靠 `.toolbar(.hidden, for: .tabBar)` 会失效（SwiftUI 的 tabBar 由外层 TabView 管，
/// 子页面的 toolbar 覆盖不到）。所以**所有版本统一走 UIKit 强制控制**：
/// 直接找到宿主 UITabBarController 设 tabBar.isHidden，并同步修正底部安全区，
/// 这样正文不会被空出来的 49pt 截掉。
struct LNHidesTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { LNTabBarController.setHidden(true) }
            .onDisappear { LNTabBarController.setHidden(false) }
    }
}

/// 列表页兜底：确保从阅读页返回后 tab 栏恢复可见。
struct LNShowsTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear { LNTabBarController.setHidden(false) }
    }
}

extension View {
    /// 当前页面隐藏底部 tab 栏（阅读页）
    func lnHidesTabBar() -> some View { modifier(LNHidesTabBarModifier()) }
    /// 明确恢复底部 tab 栏（列表页）
    func lnShowsTabBar() -> some View { modifier(LNShowsTabBarModifier()) }
}

/// 底部 tab 栏显隐控制。
///
/// 旋转 bug 修复（b57）：视频全屏会把设备转到横屏再转回来，旧实现有两个坑——
/// 1. 安全区用 `+=` / `-=` 累加：旋转后系统会重算安全区，累加值漂移，tab 栏被顶到错误位置
///    且点击区域错位（表现为「上移卡死」）；
/// 2. `frame.height` 在 tabBar 被 transform 后拿到的是变换后的高度，再隐藏一次偏移翻倍。
/// 现在改为：**保存每个子控制器原始底部安全区 → 隐藏时统一 = 原值 - 新高度，显示时原值还原**，
/// 高度用不受 transform 影响的 `bounds.height`；旋转时按新高度重贴一次。
enum LNTabBarController {
    /// 隐藏时保存的各子控制器原始底部安全区（按控制器对象地址），恢复时原样还原
    @MainActor private static var hiddenStates: [ObjectIdentifier: [ObjectIdentifier: CGFloat]] = [:]
    /// 旋转监听只注册一次
    @MainActor private static var orientationObserver: NSObjectProtocol?
    /// 最近一次期望的显隐状态（旋转/重试都以它为准，避免“想隐藏却恢复失败”的漂移）
    @MainActor private static var desiredHidden = false

    static func setHidden(_ hidden: Bool) {
        Task { @MainActor in
            ensureOrientationObserver()
            desiredHidden = hidden
            applyWithRetry(hidden, attempts: 3)
        }
    }

    /// 视图切换瞬间（全屏控制器 dismiss、导航过渡中）可能找不到 tabBarController，
    /// 找不到就短延迟重试——否则这次恢复丢失，hiddenStates 留脏，之后一旋转就会把
    /// 列表页的 tab 栏也藏起来（表现为 tab 栏错位、点不动）。
    @MainActor
    private static func applyWithRetry(_ hidden: Bool, attempts: Int) {
        if let controller = find() {
            apply(hidden, to: controller)
        } else if attempts > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                // 期间又变了一次就以最新意图为准
                applyWithRetry(desiredHidden, attempts: attempts - 1)
            }
        }
    }

    /// 旋转后重算：tab 栏高度会变（竖屏 49 / 横屏 32），
    /// transform 与安全区必须按新高度重贴，否则回到竖屏后位置错乱、点击不响应。
    /// 注意：按 desiredHidden 重算而不是“当前是否被隐藏”——避免隐藏态残留。
    @MainActor
    static func refreshForCurrentOrientation() {
        guard let controller = find() else { return }
        apply(desiredHidden, to: controller)
    }

    @MainActor
    private static func ensureOrientationObserver() {
        guard orientationObserver == nil else { return }
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in refreshForCurrentOrientation() }
        }
    }

    @MainActor
    private static func apply(_ hidden: Bool, to controller: UITabBarController) {
        let id = ObjectIdentifier(controller)
        // bounds.height：不受 transform 影响，隐藏后再调也拿得到真实高度。
        // 极端时（布局尚未完成）取到 0，用标准 49pt 兜底——否则这次显隐会被整个跳过，
        // 状态与画面不一致，后续更容易出现「tab 栏错位、点不动」。
        let measured = controller.tabBar.bounds.height
        let height = measured > 0 ? measured : 49

        if hidden {
            // 只在第一次隐藏时保存原始安全区，避免重复调用覆盖原值
            if hiddenStates[id] == nil {
                var saved: [ObjectIdentifier: CGFloat] = [:]
                for child in controller.viewControllers ?? [] {
                    saved[ObjectIdentifier(child)] = child.additionalSafeAreaInsets.bottom
                }
                hiddenStates[id] = saved
            }
            let saved = hiddenStates[id] ?? [:]
            UIView.performWithoutAnimation {
                controller.tabBar.isHidden = true
                controller.tabBar.transform = CGAffineTransform(translationX: 0, y: height)
                for child in controller.viewControllers ?? [] {
                    // 幂等赋值（不是累加）：旋转/重复调用都不会漂移
                    child.additionalSafeAreaInsets.bottom =
                        (saved[ObjectIdentifier(child)] ?? 0) - height
                }
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
            }
        } else {
            let saved = hiddenStates.removeValue(forKey: id) ?? [:]
            UIView.performWithoutAnimation {
                controller.tabBar.isHidden = false
                controller.tabBar.transform = .identity
                for child in controller.viewControllers ?? [] {
                    // 原值还原（可能是 0，也可能被其它页面设置过）
                    child.additionalSafeAreaInsets.bottom = saved[ObjectIdentifier(child)] ?? 0
                }
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
            }
        }
    }

    @MainActor
    private static func find() -> UITabBarController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // 不用 keypath：UIWindowScene.windows / UIWindow.isKeyWindow 都是主线程隔离属性
        var allWindows: [UIWindow] = []
        for scene in scenes { allWindows.append(contentsOf: scene.windows) }
        let keyWindow = allWindows.first { $0.isKeyWindow } ?? allWindows.first
        return find(in: keyWindow?.rootViewController)
    }

    @MainActor
    private static func find(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tab = controller as? UITabBarController { return tab }
        for child in controller.children {
            if let found = find(in: child) { return found }
        }
        if let presented = controller.presentedViewController {
            return find(in: presented)
        }
        return nil
    }
}

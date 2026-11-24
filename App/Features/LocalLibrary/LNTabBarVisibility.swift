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

enum LNTabBarController {
    /// 记录哪些 tabBarController 当前被我们隐藏过（按对象地址），保证 inset 加减严格对称。
    /// @MainActor 隔离：只在主线程方法里读写，同时满足 Swift 6 严格并发检查。
    @MainActor private static var hiddenTabs = Set<ObjectIdentifier>()

    static func setHidden(_ hidden: Bool) {
        Task { @MainActor in apply(hidden) }
    }

    @MainActor
    private static func apply(_ hidden: Bool) {
        guard let controller = find() else { return }
        let id = ObjectIdentifier(controller)
        guard hiddenTabs.contains(id) != hidden else { return }

        // isHidden 会被 SwiftUI TabView 在下次布局时改回去，这里同时用 transform 兜底：
        // 把 tabBar 平移到屏幕外，并把子控制器的底部附加安全区减掉 tabBar 高度，
        // 否则正文底部会空出一条。
        let height = controller.tabBar.frame.height
        UIView.performWithoutAnimation {
            controller.tabBar.isHidden = hidden
            controller.tabBar.transform = hidden
                ? CGAffineTransform(translationX: 0, y: height)
                : .identity
            for child in controller.viewControllers ?? [] {
                child.additionalSafeAreaInsets.bottom += hidden ? -height : height
            }
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
        if hidden { hiddenTabs.insert(id) } else { hiddenTabs.remove(id) }
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

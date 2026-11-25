import SwiftUI
@preconcurrency import WebKit
import UIKit

// MARK: - 状态模型

/// 内嵌浏览器状态：由 KVO 从 WKWebView 同步上来，UI 只读这些字段。
/// WKWebView 本身是命令式的，所以模型只持一个 weak 引用负责转发操作。
@MainActor
final class LNBrowserModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var pageTitle: String = ""
    @Published var currentURLString: String = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var errorMessage: String?
    /// 是否已经打开过页面：false 时显示起始页（避免一进来就是一片白）
    @Published var hasLoadedOnce = false

    weak var webView: WKWebView?

    /// 搜索词走 Bing：不预置任何具体站点内容，只做搜索引擎入口
    private static let searchTemplate = "https://www.bing.com/search?q="

    /// 把地址栏输入解析成可加载的 URL：
    /// - 带 scheme 的直接用（http/https/about/file/data）
    /// - 形如 example.com / 192.168.1.1:5005 的补 https://
    /// - 其余当搜索词
    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "about", "file", "data"].contains(scheme) {
            return url
        }
        // 有「.」且不含空格 → 当域名（含 IP:端口）
        if text.contains("."), !text.contains(" ") {
            if let url = URL(string: "https://" + text) { return url }
        }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: Self.searchTemplate + encoded)
    }

    func load(_ input: String) {
        guard let url = Self.resolve(input) else { return }
        errorMessage = nil
        hasLoadedOnce = true
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }

    /// 回到起始页：停掉当前加载并清掉展示状态（webView 留在原地被起始页盖住）
    func goHome() {
        webView?.stopLoading()
        errorMessage = nil
        hasLoadedOnce = false
        currentURLString = ""
        pageTitle = ""
        progress = 0
        isLoading = false
    }
}

// MARK: - 浏览器页面

struct LNBrowserView: View {
    @StateObject private var model = LNBrowserModel()
    @State private var addressText = ""
    @State private var showsShare = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar

            ZStack(alignment: .top) {
                LNBrowserWebHost(model: model)

                // 加载进度：2pt 细线贴顶，不占布局
                if model.isLoading, model.progress < 1 {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                        .tint(ReadingTheme.accent)
                        .accessibilityLabel("页面加载进度")
                }

                if !model.hasLoadedOnce {
                    startPage
                }

                if let message = model.errorMessage, model.hasLoadedOnce {
                    errorPage(message)
                }
            }

            bottomBar
        }
        .background(ReadingTheme.canvas.ignoresSafeArea())
        .navigationTitle("浏览器")
        .navigationBarTitleDisplayMode(.inline)
        .lnShowsTabBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    LNUserscriptListView()
                } label: {
                    Image(systemName: "curlybraces")
                }
                .accessibilityLabel("油猴脚本")
            }
        }
        // 页面导航后同步地址栏；用户正在编辑时不打断输入
        .onChange(of: model.currentURLString) { newValue in
            guard !addressFocused else { return }
            addressText = newValue
        }
        .sheet(isPresented: $showsShare) {
            if let url = URL(string: model.currentURLString), !model.currentURLString.isEmpty {
                LNShareSheet(items: [url])
            }
        }
        .accessibilityIdentifier("ln.browser.root")
    }

    // MARK: 地址栏

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ReadingTheme.ink.opacity(0.4))
                .accessibilityHidden(true)

            TextField("搜索或输入网址", text: $addressText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // webSearch：既方便输入网址，也支持中文搜索词（URL 键盘没有中文）
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    addressFocused = false
                    model.load(addressText)
                }
                .accessibilityLabel("地址栏")

            if !addressText.isEmpty {
                Button {
                    addressText = ""
                    addressFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(ReadingTheme.ink.opacity(0.3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空地址栏")
            }

            Button {
                if model.isLoading {
                    model.stop()
                } else {
                    model.reload()
                }
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ReadingTheme.ink.opacity(model.hasLoadedOnce ? 0.7 : 0.25))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasLoadedOnce)
            .accessibilityLabel(model.isLoading ? "停止加载" : "刷新")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(ReadingTheme.groupedCanvas,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ReadingTheme.canvas)
    }

    // MARK: 底部工具栏

    private var bottomBar: some View {
        HStack(spacing: 0) {
            barButton(symbol: "chevron.left", label: "后退", enabled: model.canGoBack) {
                model.goBack()
            }
            barButton(symbol: "chevron.right", label: "前进", enabled: model.canGoForward) {
                model.goForward()
            }
            barButton(symbol: "house", label: "回到起始页", enabled: true) {
                addressFocused = false
                addressText = ""
                model.goHome()
            }
            barButton(symbol: "square.and.arrow.up", label: "分享当前页面",
                      enabled: !model.currentURLString.isEmpty) {
                showsShare = true
            }
        }
        .frame(height: 48)
        .background(ReadingTheme.canvas)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ReadingTheme.separator.opacity(0.5))
                .frame(height: 0.5)
        }
    }

    private func barButton(symbol: String, label: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(ReadingTheme.ink.opacity(enabled ? 0.75 : 0.2))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: 起始页

    private var startPage: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "safari")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(ReadingTheme.accent.opacity(0.85))
                    .padding(.top, 72)
                    .accessibilityHidden(true)

                Text("网页浏览器")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ReadingTheme.ink)

                Text("在上方输入网址或搜索词，回车即可打开")
                    .font(.subheadline)
                    .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                // 不在渲染时预读剪贴板（iOS 16+ 会弹「允许粘贴」），点击时才读
                Button {
                    addressFocused = false
                    guard let clipboard = UIPasteboard.general.string,
                          !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    addressText = clipboard
                    model.load(clipboard)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                        Text("粘贴并打开剪贴板链接")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                    .font(.subheadline)
                    .foregroundStyle(ReadingTheme.accent)
                    .padding(14)
                    .background(ReadingTheme.groupedCanvas,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .accessibilityLabel("粘贴并打开剪贴板中的链接")

                HStack(spacing: 10) {
                    startChip("Bing 搜索", "https://www.bing.com")
                    startChip("百度", "https://www.baidu.com")
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
        .background(ReadingTheme.canvas)
    }

    private func startChip(_ title: String, _ urlString: String) -> some View {
        Button {
            addressFocused = false
            addressText = urlString
            model.load(urlString)
        } label: {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.8))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(ReadingTheme.groupedCanvas,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开 \(title)")
    }

    // MARK: 错误页

    private func errorPage(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(ReadingTheme.ink.opacity(0.4))
                .accessibilityHidden(true)
            Text("无法打开页面")
                .font(.headline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.85))
            Text(message)
                .font(.footnote)
                .foregroundStyle(ReadingTheme.ink.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                model.errorMessage = nil
                model.reload()
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(ReadingTheme.accentFill)
            .accessibilityLabel("重新加载页面")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReadingTheme.canvas)
    }
}

// MARK: - WKWebView 宿主

struct LNBrowserWebHost: UIViewRepresentable {
    let model: LNBrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 共享 Cookie / 登录态，和系统浏览器行为一致
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 油猴 GM_* 调用的回传通道
        configuration.userContentController.add(context.coordinator.runtime,
                                                name: LNUserscriptRuntime.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.isOpaque = false
        webView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.scrollView.backgroundColor = UIColor(ReadingTheme.canvas)

        context.coordinator.attach(webView)
        context.coordinator.runtime.attach(to: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: LNUserscriptRuntime.messageHandlerName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var model: LNBrowserModel
        let runtime = LNUserscriptRuntime(store: LNUserscriptStore.shared)
        private var observations: [NSKeyValueObservation] = []

        init(model: LNBrowserModel) {
            self.model = model
        }

        func attach(_ webView: WKWebView) {
            model.webView = webView
            // KVO → 主线程回写。所有对 webView 属性的读取都放在 MainActor 里，
            // 避免 Swift 6 严格并发在非隔离回调里访问 @MainActor 类型。
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.model.progress = webView.estimatedProgress }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.model.isLoading = webView.isLoading }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.model.canGoBack = webView.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.model.canGoForward = webView.canGoForward }
                },
                webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.model.currentURLString = webView.url?.absoluteString ?? "" }
                },
                webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.model.pageTitle = webView.title ?? "" }
                },
            ]
        }

        // MARK: 导航回调

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.errorMessage = nil
            model.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            handle(error)
        }

        private func handle(_ error: Error) {
            let nsError = error as NSError
            // 用户主动停止 / 新导航打断旧请求：不算错误
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            model.isLoading = false
            model.errorMessage = nsError.localizedDescription
        }

        /// target=_blank 之类的新窗口：直接用当前 webview 加载，不开新 tab（P1 不做多标签）
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        /// 只接管 http(s)/about/file/data，其它（tel、mailto、itms-apps…）交给系统
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme.isEmpty || ["http", "https", "about", "file", "data"].contains(scheme) {
                // 主框架导航才重新装配脚本：iframe 导航不能把主页面已注入的脚本清掉
                if navigationAction.targetFrame?.isMainFrame ?? true {
                    runtime.installScripts(for: url, in: webView)
                }
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
            }
        }

        // MARK: JS 弹窗（不实现会静默无响应，页面会像卡住）

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor @Sendable () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            present(alert, completionHandler: completionHandler)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
            present(alert) { completionHandler(false) }
        }

        private func present(_ alert: UIAlertController, completionHandler: @escaping @MainActor @Sendable () -> Void) {
            guard let controller = topViewController() else {
                completionHandler()
                return
            }
            controller.present(alert, animated: true)
        }

        private func topViewController() -> UIViewController? {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            while let presented = top?.presentedViewController {
                top = presented
            }
            return top
        }
    }
}

// MARK: - 分享

private struct LNShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

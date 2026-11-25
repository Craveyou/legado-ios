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
    /// 请求桌面版网站（默认移动版，脚本的移动端分支才会生效）
    @Published var prefersDesktopSite = false

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

    /// 切换移动 / 桌面版。UA 必须在这里立刻写进 WKWebView 再 reload，
    /// 否则 reload 会赶在 SwiftUI 的 updateUIView 之前用旧 UA 发请求。
    func toggleDesktopSite() {
        prefersDesktopSite.toggle()
        webView?.customUserAgent = prefersDesktopSite
            ? LNBrowserUserAgent.desktop
            : LNBrowserUserAgent.mobile
        webView?.reload()
    }

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

// MARK: - 收藏网址

struct LNBrowserFavorite: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var urlString: String

    /// 补全 scheme 后的地址
    var resolvedURLString: String {
        let text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return text
        }
        return "https://" + text
    }

    var host: String {
        URL(string: resolvedURLString)?.host ?? urlString
    }

    /// 图标上显示的首字：优先名称，其次域名（去掉 www.）
    var badge: String {
        var source = title.trimmingCharacters(in: .whitespaces)
        if source.isEmpty {
            source = host
            if source.hasPrefix("www.") { source = String(source.dropFirst(4)) }
        }
        guard let first = source.first else { return "·" }
        return String(first).uppercased()
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }
}

@MainActor
final class LNBrowserFavorites: ObservableObject {
    static let shared = LNBrowserFavorites()

    @Published private(set) var items: [LNBrowserFavorite] = []

    private let fileURL: URL

    /// 首次启动给两个常用入口，用户可以删掉换成自己的
    private static let starter: [LNBrowserFavorite] = [
        LNBrowserFavorite(title: "Bing", urlString: "https://www.bing.com"),
        LNBrowserFavorite(title: "百度", urlString: "https://www.baidu.com"),
    ]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("browser-favorites.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LNBrowserFavorite].self, from: data) {
            items = decoded
        } else {
            items = Self.starter
            persist()
        }
    }

    func add(_ favorite: LNBrowserFavorite) {
        guard !items.contains(where: { $0.id == favorite.id }) else {
            update(favorite)
            return
        }
        items.append(favorite)
        persist()
    }

    func update(_ favorite: LNBrowserFavorite) {
        guard let index = items.firstIndex(where: { $0.id == favorite.id }) else {
            add(favorite)
            return
        }
        items[index] = favorite
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - User-Agent

/// 明确给站点一个 iOS 移动端 UA。
///
/// 为什么不能靠 WKWebView 默认值：默认 UA 要经 `preferredContentMode` 决定，
/// 部分场景（iPad、站点声明、系统版本差异）会退化成 `Macintosh; Intel Mac OS X`，
/// 此时油猴脚本里 `/iPhone|iPad|iPod/.test(navigator.userAgent)` 全部落空，
/// 脚本就会按「桌面端」分支渲染控件。这里把标识写死，行为可预期。
enum LNBrowserUserAgent {
    static var mobile: String {
        let version = UIDevice.current.systemVersion
        let underscored = version.replacingOccurrences(of: ".", with: "_")
        let major = version.split(separator: ".").first.map(String.init) ?? "18"
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let osToken = device == "iPad" ? "CPU OS" : "CPU iPhone OS"
        return "Mozilla/5.0 (\(device); \(osToken) \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    /// Safari 在 Mac 上的标准 UA
    static let desktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

// MARK: - 浏览器页面

struct LNBrowserView: View {
    @StateObject private var model = LNBrowserModel()
    @ObservedObject private var favorites = LNBrowserFavorites.shared
    @State private var addressText = ""
    @State private var activeSheet: BrowserSheet?
    @State private var favoriteEditMode = false
    @FocusState private var addressFocused: Bool

    /// 同一层级只能挂一个 .sheet，否则后一个会覆盖前一个，所以用 enum 收敛
    private enum BrowserSheet: Identifiable {
        case share(URL)
        case favorite(LNBrowserFavorite)

        var id: String {
            switch self {
            case .share(let url): return "share:\(url.absoluteString)"
            case .favorite(let favorite): return "favorite:\(favorite.id.uuidString)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    favoritesPage
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
            // 地址栏搬到导航栏中间：内容区整块留给网页 / 收藏页
            ToolbarItem(placement: .principal) {
                addressBar
            }
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share(let url):
                LNShareSheet(items: [url])
            case .favorite(let draft):
                LNBrowserFavoriteEditor(draft: draft) { saved in
                    favorites.update(saved)
                }
            }
        }
        .accessibilityIdentifier("ln.browser.root")
    }

    // MARK: 地址栏（导航栏内）

    private var addressBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
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
                        .font(.system(size: 14))
                        .foregroundStyle(ReadingTheme.ink.opacity(0.3))
                        .frame(width: 22, height: 22)
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ReadingTheme.ink.opacity(model.hasLoadedOnce ? 0.7 : 0.25))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasLoadedOnce)
            .accessibilityLabel(model.isLoading ? "停止加载" : "刷新")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(ReadingTheme.groupedCanvas,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity)
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
            barButton(symbol: model.prefersDesktopSite ? "iphone" : "desktopcomputer",
                      label: model.prefersDesktopSite ? "切换到移动版网站" : "切换到桌面版网站",
                      enabled: model.hasLoadedOnce) {
                model.toggleDesktopSite()
            }
            barButton(symbol: "square.and.arrow.up", label: "分享当前页面",
                      enabled: !model.currentURLString.isEmpty) {
                if let url = URL(string: model.currentURLString), !model.currentURLString.isEmpty {
                    activeSheet = .share(url)
                }
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

    // MARK: 起始页（自定义收藏网址）

    private var favoritesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("收藏网址")
                        .font(.headline)
                        .foregroundStyle(ReadingTheme.ink.opacity(0.85))
                    Spacer()
                    if !favorites.items.isEmpty {
                        Button(favoriteEditMode ? "完成" : "编辑") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                favoriteEditMode.toggle()
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(ReadingTheme.accent)
                        .accessibilityLabel(favoriteEditMode ? "结束编辑收藏" : "编辑收藏")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: 4),
                          alignment: .leading,
                          spacing: 18) {
                    ForEach(favorites.items) { item in
                        favoriteTile(item)
                    }
                    addFavoriteTile
                }
                .padding(.horizontal, 20)

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
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .accessibilityLabel("粘贴并打开剪贴板中的链接")

                Text("在地址栏输入网址或搜索词，回车即可打开。长按收藏可编辑或删除。")
                    .font(.caption)
                    .foregroundStyle(ReadingTheme.ink.opacity(0.4))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ReadingTheme.canvas)
    }

    private func favoriteTile(_ item: LNBrowserFavorite) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                if favoriteEditMode {
                    activeSheet = .favorite(item)
                } else {
                    open(item)
                }
            } label: {
                VStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(ReadingTheme.groupedCanvas)
                            .frame(width: 56, height: 56)
                        Text(item.badge)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(ReadingTheme.accent)
                    }
                    Text(item.displayTitle)
                        .font(.caption)
                        .foregroundStyle(ReadingTheme.ink.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    activeSheet = .favorite(item)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    favorites.remove(id: item.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .accessibilityLabel("打开 \(item.displayTitle)")

            if favoriteEditMode {
                Button {
                    favorites.remove(id: item.id)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.red)
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("删除 \(item.displayTitle)")
            }
        }
    }

    private var addFavoriteTile: some View {
        Button {
            activeSheet = .favorite(LNBrowserFavorite(title: "", urlString: ""))
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(ReadingTheme.ink.opacity(0.18),
                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: 56, height: 56)
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(ReadingTheme.ink.opacity(0.4))
                }
                Text("添加")
                    .font(.caption)
                    .foregroundStyle(ReadingTheme.ink.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加收藏网址")
    }

    private func open(_ item: LNBrowserFavorite) {
        addressFocused = false
        let target = item.resolvedURLString
        addressText = target
        model.load(target)
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
        // 默认给移动端 UA：脚本的 (移动端 / 桌面端) 分支全靠它判断
        webView.customUserAgent = model.prefersDesktopSite
            ? LNBrowserUserAgent.desktop
            : LNBrowserUserAgent.mobile
        webView.isOpaque = false
        webView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.scrollView.backgroundColor = UIColor(ReadingTheme.canvas)

        context.coordinator.attach(webView)
        context.coordinator.runtime.attach(to: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.model = model
        let desired = model.prefersDesktopSite ? LNBrowserUserAgent.desktop : LNBrowserUserAgent.mobile
        if webView.customUserAgent != desired {
            webView.customUserAgent = desired
        }
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
        /// 去重：UA 没变就不重复写日志
        private var lastRecordedUserAgent: String?

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
            // 把真实 UA 记进运行日志：脚本按 UA 分移动端/桌面端分支，
            // 控件形态不对时先看这一行
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
                guard let ua = value as? String else { return }
                Task { @MainActor in
                    guard let self, self.lastRecordedUserAgent != ua else { return }
                    self.lastRecordedUserAgent = ua
                    LNUserscriptLog.shared.record(scriptID: LNUserscriptLog.environmentID,
                                                  name: "浏览器环境",
                                                  message: "User-Agent: \(ua)",
                                                  isError: false)
                }
            }
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

        /// 只接管 http(s)/about/file/data，其它（tel、mailto、itms-apps…）交给系统。
        /// 用带 preferences 的重载：每次导航明确指定移动/桌面形态，比在 configuration 上改更可靠。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     preferences: WKWebpagePreferences,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            preferences.preferredContentMode = model.prefersDesktopSite ? .desktop : .mobile

            guard let url = navigationAction.request.url else {
                decisionHandler(.allow, preferences)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme.isEmpty || ["http", "https", "about", "file", "data"].contains(scheme) {
                // 主框架导航才重新装配脚本：iframe 导航不能把主页面已注入的脚本清掉
                if navigationAction.targetFrame?.isMainFrame ?? true {
                    runtime.installScripts(for: url, in: webView)
                }
                decisionHandler(.allow, preferences)
            } else {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel, preferences)
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

// MARK: - 收藏编辑

private struct LNBrowserFavoriteEditor: View {
    @Environment(\.dismiss) private var dismiss
    let draft: LNBrowserFavorite
    let onSave: (LNBrowserFavorite) -> Void

    @State private var title: String
    @State private var urlString: String

    init(draft: LNBrowserFavorite, onSave: @escaping (LNBrowserFavorite) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _title = State(initialValue: draft.title)
        _urlString = State(initialValue: draft.urlString)
    }

    private var isNew: Bool {
        draft.title.isEmpty && draft.urlString.isEmpty
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    TextField("名称（可留空）", text: $title)
                        .accessibilityLabel("收藏名称")
                    TextField("网址，例如 www.example.com", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel("收藏网址")
                } footer: {
                    Text("没写 https:// 会自动补上；名称留空时显示域名。")
                }
            }
            .navigationTitle(isNew ? "添加收藏" : "编辑收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var item = draft
                        item.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        item.urlString = trimmedURL
                        onSave(item)
                        dismiss()
                    }
                    .disabled(trimmedURL.isEmpty)
                }
            }
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

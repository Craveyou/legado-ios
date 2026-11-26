import SwiftUI
import WebKit
import LocalAuthentication

struct OtherSettingsView: View {
    @AppStorage("auto_refresh") private var autoRefresh = false
    @AppStorage("onlyUpdateRead") private var onlyUpdateRead = false
    @AppStorage("bookshelfSort") private var bookshelfSort = 0
    @AppStorage("defaultHomePage") private var defaultHomePage = "bookshelf"
    @AppStorage("privacy.blurBackground") private var privacyBlur = false
    @AppStorage("privacy.lockEnabled") private var privacyLock = false
    @State private var settings = ApplicationSettingsStore.shared.settings
    @State private var maintenance: Maintenance?
    @State private var isWorking = false
    @State private var message: String?

    private enum Maintenance: String, Identifiable {
        case webCache = "清理网页缓存"
        case database = "整理数据库"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("启动与书架") {
                Picker("启动页面", selection: $defaultHomePage) {
                    Text("书架").tag("bookshelf")
                    Text("发现").tag("explore")
                    Text("设置").tag("settings")
                }
                Toggle("启动时更新书架", isOn: $autoRefresh)
                Toggle("自动更新仅检查已读至最新章的书", isOn: $onlyUpdateRead).disabled(!autoRefresh)
                Picker("默认书架排序", selection: $bookshelfSort) {
                    ForEach(BookshelfSort.allCases) { sort in Text(sort.title).tag(sort.rawValue) }
                }
            }
            Section {
                Toggle(isOn: $privacyBlur) { Label("后台模糊", systemImage: "eye.slash") }
                Toggle(isOn: $privacyLock) { Label("面容 ID / 触控 ID 解锁", systemImage: "faceid") }
            } header: { Text("隐私与安全") } footer: {
                Text("后台模糊：切到后台或任务切换器时，页面内容会被遮挡。\n解锁：启动和切回前台时需要通过面容 ID、触控 ID 或设备密码验证。请先在系统设置中设置设备密码与生物识别，否则验证不可用时会直接放行。")
            }
            Section("网络与存储") {
                NavigationLink {
                    NetworkSettingsView()
                } label: { Label("网络与缓存设置", systemImage: "network") }
                Button("清理网页缓存", systemImage: "globe") { maintenance = .webCache }
                Button("整理数据库", systemImage: "externaldrive.badge.checkmark") { maintenance = .database }
            }
            Section {
                Toggle("记录运行日志", isOn: Binding(get: { settings.recordLog }, set: { enabled in
                    var value = ApplicationSettingsStore.shared.settings
                    value.recordLog = enabled
                    do { try ApplicationSettingsStore.shared.save(value); settings = value }
                    catch { message = error.localizedDescription }
                }))
                NavigationLink {
                    DiagnosticLogView()
                } label: { Label("日志与诊断", systemImage: "doc.text.magnifyingglass") }
            } header: { Text("诊断") } footer: {
                Text("日志仅保存在本机，最多保留 500 条。网络日志不记录请求正文与 Header，URL 查询参数和常见凭据会隐藏。")
            }
        }
        .navigationTitle("其他设置")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay { if isWorking { ProgressView("正在处理…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .onAppear { settings = ApplicationSettingsStore.shared.settings }
        .confirmationDialog(maintenance?.rawValue ?? "", isPresented: Binding(
            get: { maintenance != nil }, set: { if !$0 { maintenance = nil } }
        ), titleVisibility: .visible) {
            if let operation = maintenance {
                Button(operation.rawValue) { Task { await perform(operation) } }
            }
            Button("取消", role: .cancel) { maintenance = nil }
        } message: {
            Text(maintenance == .webCache ? "清理网页和图片的临时缓存，保留登录 Cookie、书架和阅读进度。" : "回收数据库中的空闲空间，保留全部书籍、规则和阅读记录。")
        }
        .alert("操作结果", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }

    @MainActor private func perform(_ operation: Maintenance) async {
        maintenance = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch operation {
            case .webCache:
                await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache], modifiedSince: .distantPast)
                URLCache.shared.removeAllCachedResponses()
            case .database:
                let database = try LegadoDatabase(url: LegadoDatabase.defaultURL())
                try await database.compact()
            }
            DiagnosticLog.shared.record(category: "存储", message: "\(operation.rawValue)完成")
            message = "\(operation.rawValue)完成"
        } catch {
            DiagnosticLog.shared.record(.error, category: "存储", message: error.localizedDescription)
            message = error.localizedDescription
        }
    }
}

struct NetworkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ApplicationSettingsStore.shared.settings
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                ReadingTextField("留空使用默认浏览器 UA", text: $settings.userAgent, axis: .vertical)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityLabel("User-Agent")
            } header: { Text("默认 User-Agent") } footer: {
                Text("书源或 RSS 单独设置的 UA 优先于此项。")
            }
            Section {
                TextField("例如 http://127.0.0.1:7890", text: $settings.proxy)
                    .keyboardType(.URL).textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityLabel("全局代理")
            } header: { Text("全局代理") } footer: {
                Text("支持 HTTP、HTTPS 和 SOCKS5 地址，不含账号密码。书源代理优先于全局代理；使用代理时由代理解析域名。")
            }
            Section {
                TextEditor(text: $settings.hosts)
                    .font(.system(.footnote, design: .monospaced)).frame(minHeight: 130)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityLabel("Hosts")
            } header: { Text("自定义 Hosts") } footer: {
                Text("每行填写 IP地址 域名，例如 192.168.1.2 books.example.com。支持 IPv4、IPv6 和 # 注释。适用于应用内 HTTP/HTTPS 请求；系统网页、登录网页和系统媒体播放器使用系统网络设置。")
            }
            Section("连接") {
                Picker("请求超时", selection: $settings.timeoutSeconds) {
                    Text("跟随书源").tag(0)
                    ForEach([5, 10, 15, 30, 60, 120, 180, 300], id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Stepper("搜索并发数：\(settings.concurrentSources)", value: $settings.concurrentSources, in: 1...64)
                Toggle("兼容无效证书的书源", isOn: $settings.ignoreCertificateErrors)
                Text("证书兼容开启时允许自签名或过期证书；关闭后由系统验证 HTTPS 证书。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("章节缓存") {
                Picker("容量上限", selection: $settings.chapterCacheMB) {
                    ForEach([16, 32, 64, 128, 256, 512, 1024, 2048, 4096], id: \.self) {
                        Text($0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB").tag($0)
                    }
                }
                Stepper(settings.prefetchChapters == 0 ? "关闭章节预加载" : "预加载 \(settings.prefetchChapters) 章", value: $settings.prefetchChapters, in: 0...20)
                Text("超出上限时清理最久未读取的章节；容量调整在保存时生效。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("恢复本页默认值") {
                    let recordLog = settings.recordLog
                    settings = .init()
                    settings.recordLog = recordLog
                }
            }
        }
        .navigationTitle("网络与缓存")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }.disabled(isSaving)
            }
        }
        .disabled(isSaving)
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @MainActor private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            settings.recordLog = ApplicationSettingsStore.shared.settings.recordLog
            try ApplicationSettingsStore.shared.save(settings)
            try await ChapterContentCache.live().pruneIfNeeded()
            DiagnosticLog.shared.record(category: "设置", message: "网络与缓存设置已保存")
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
// MARK: - 隐私与安全（b90 重做：对齐主流 App 观感）
// 视觉：遮罩背景是「离开那一刻界面的毛玻璃快照」——任务切换器里能看到隐约的页面
// 轮廓，但文字内容被彻底糊掉；不再用纯色 + 大 logo 的启动页样式。
// - 仅「后台模糊」：毛玻璃快照，无任何浮层，回前台 0.18s 淡出；
// - 「解锁」开启：毛玻璃之上叠中央锁图标 + 「轻点解锁」，自动弹面容/触控 ID，
//   验证通过整层淡出；失败/取消则停在锁定页，轻点任意处重试。
// 遮罩挂在 UIWindow 顶层（SwiftUI overlay 盖不住全屏 cover：大图预览、全屏播放器
// 都在更高的 presentation 层，只有 window 层遮罩能保证切换器快照不泄露内容）。

/// 遮罩模式：none=未激活；blur=仅后台模糊；locked=等待设备认证。
enum PrivacyShieldMode {
    case none, blur, locked
}

/// 挂在 App 根部的隐私闸门：转发 active 状态切换给窗口遮罩控制器。
struct PrivacyGateModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { PrivacyShieldController.shared.installUnlockHandler() }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.willResignActiveNotification)) { _ in
                PrivacyShieldController.shared.handleWillResignActive()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in
                PrivacyShieldController.shared.handleDidBecomeActive()
            }
    }
}

@MainActor
final class PrivacyShieldController {
    static let shared = PrivacyShieldController()
    private init() {}

    private var mode: PrivacyShieldMode = .none
    private var shield: PrivacyShieldView?
    private var isAuthenticating = false
    /// 本次 active 周期是否还需要自动弹认证：willResignActive 时置 true，
    /// 认证发起过一次就置 false——认证弹窗本身引起的 active 回调不再重弹，
    /// 用户取消后改为「轻点解锁」手动重试。
    private var needsAutoUnlockOnActive = true
    private var onUnlockRequest: (() -> Void)?

    private var blurEnabled: Bool { UserDefaults.standard.bool(forKey: "privacy.blurBackground") }
    private var lockEnabled: Bool { UserDefaults.standard.bool(forKey: "privacy.lockEnabled") }

    /// UI 自动化 / Demo 跑批时禁用，避免卡在系统认证弹窗
    private var automationDisabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiAutomation")
            || ProcessInfo.processInfo.arguments.contains("-uiDemo")
    }

    func installUnlockHandler() {
        onUnlockRequest = { Task { await PrivacyShieldController.shared.authenticate() } }
    }

    func handleWillResignActive() {
        guard !automationDisabled else { return }
        guard blurEnabled || lockEnabled else { return }
        needsAutoUnlockOnActive = true
        show(mode: lockEnabled ? .locked : .blur)
    }

    func handleDidBecomeActive() {
        guard !automationDisabled else { return }
        if lockEnabled {
            guard needsAutoUnlockOnActive else { return }   // 本次 active 周期已认证，不再动作
            needsAutoUnlockOnActive = false
            if mode != .locked { show(mode: .locked) }      // 冷启动：未经 resign，在此补盖
            if !isAuthenticating { onUnlockRequest?() }     // 自动弹面容 / 触控 ID
        } else if mode == .blur {
            hide()
        }
    }

    @MainActor
    func authenticate() async {
        guard mode == .locked, !isAuthenticating else { return }
        guard lockEnabled else { hide(animated: false); return }   // 开关被关掉后遮罩残留的兜底
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedFallbackTitle = "使用密码"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            // 设备未设置密码 / 无可用生物识别：不能把用户锁在门外，放行（设置页 footer 有说明）
            hide()
            return
        }
        do {
            // .deviceOwnerAuthentication：生物识别失败自动回退设备密码
            if try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                localizedReason: "解锁熊猫阅读") {
                hide()
            }
        } catch {
            // 用户取消 / 认证失败：保持锁定页，轻点任意处重试
            shield?.showAuthFailure()
        }
    }

    private func show(mode newMode: PrivacyShieldMode) {
        mode = newMode
        // 已有遮罩（例如认证弹窗引起的二次 resign）：只切换锁定浮层，不重新截图，
        // 避免背景闪烁、也避免把上一张遮罩截进快照。
        if let shield {
            shield.setLocked(newMode == .locked)
            return
        }
        guard let window = PrivacyShieldController.topWindow() else { return }
        // 构造时就地取 window 快照（此时遮罩尚未加入 window，截不到自己）
        let view = PrivacyShieldView(window: window, mode: newMode) { [weak self] in
            self?.onUnlockRequest?()
        }
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(view)
        shield = view
    }

    private func hide(animated: Bool = true) {
        mode = .none
        guard let shield else { return }
        self.shield = nil
        guard animated else {
            shield.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            shield.alpha = 0
        } completion: { _ in
            shield.removeFromSuperview()
        }
    }

    private static func topWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
            ?? scenes.first?.keyWindow
            ?? scenes.flatMap { $0.windows }.last
    }
}

/// 遮罩视图：界面毛玻璃快照 +（锁定态）中央锁图标浮层。
/// 双层 material 叠加：单层模糊仍能隐约辨认大标题，两层后只剩色块轮廓，
/// 与微信 / Telegram 任务切换器的观感一致，同时保证文字不可读。
private final class PrivacyShieldView: UIView {
    private var unlockHandler: (() -> Void)?
    private var lockStack: UIStackView?
    private let hintLabel = UILabel()

    init(window: UIWindow, mode: PrivacyShieldMode, unlockHandler: @escaping () -> Void) {
        super.init(frame: window.bounds)
        self.unlockHandler = unlockHandler
        backgroundColor = .systemBackground
        accessibilityViewIsModal = true
        clipsToBounds = true

        // 1) 当前界面快照做底：切换器里保留页面轮廓（主流观感）
        if let snapshot = window.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(snapshot)
        }

        // 2) 两层毛玻璃把文字糊成不可辨识的色块
        for style in [UIBlurEffect.Style.systemThickMaterial, UIBlurEffect.Style.systemThinMaterial] {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: style))
            blur.frame = bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            blur.isUserInteractionEnabled = false
            addSubview(blur)
        }

        // 3) 极轻底色：白底阅读页模糊后也不留文字轮廓
        let tint = UIView(frame: bounds)
        tint.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.12)
        tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tint.isUserInteractionEnabled = false
        addSubview(tint)

        if mode == .locked {
            installLockOverlay()
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// 锁定浮层：中央锁图标 + 「轻点解锁」，整屏可点重试
    private func installLockOverlay() {
        guard lockStack == nil else {
            hintLabel.text = "轻点解锁"
            return
        }

        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .light)
        icon.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.text = "轻点解锁"
        hintLabel.font = .systemFont(ofSize: 15, weight: .medium)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [icon, hintLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
        ])
        lockStack = stack

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        isAccessibilityElement = true
        accessibilityLabel = "已锁定，轻点解锁"
        accessibilityTraits = .button
    }

    /// 已有遮罩时切换模式（避免重新截图造成的闪烁）
    func setLocked(_ locked: Bool) {
        if locked { installLockOverlay() }
    }

    func showAuthFailure() {
        hintLabel.text = "验证未通过，轻点重试"
    }

    @objc private func handleTap() {
        unlockHandler?()
    }
}

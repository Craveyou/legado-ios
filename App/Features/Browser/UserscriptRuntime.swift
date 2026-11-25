import Foundation
@preconcurrency import WebKit

/// 油猴运行时：把匹配的脚本注入 WKWebView，并处理脚本发回的 GM_* 调用。
///
/// 注入策略：
/// - 每个脚本包成独立 IIFE，GM_* 函数定义在闭包里 —— 页面看不到，也不会被其它脚本污染；
/// - 注入到 **page world**（`WKContentWorld.page`），这样 `unsafeWindow` 能摸到页面自身变量；
/// - `GM_getValue` 是同步 API，靠「注入前把该脚本的存储值内联成 JSON 字面量」实现同步读取，
///   写入仍走 messageHandler 异步落盘（同页面内读自己刚写的值也是准的）。
@MainActor
final class LNUserscriptRuntime: NSObject, WKScriptMessageHandler {
    nonisolated static let messageHandlerName = "ln_userscript"

    private let store: LNUserscriptStore
    private weak var webView: WKWebView?

    init(store: LNUserscriptStore) {
        self.store = store
        super.init()
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    // MARK: 注入

    /// 导航开始前调用：清掉上一次的脚本，按本次 URL 重新装配。
    /// 必须在 `decidePolicyFor` 里（放行之前）调用，WKWebView 会在随后的加载中读取。
    func installScripts(for url: URL, in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()

        let matched = store.scripts(for: url)
        guard !matched.isEmpty else { return }

        for script in matched {
            let source = makeSource(for: script)
            let userScript: WKUserScript
            switch script.runAt {
            case .documentStart:
                userScript = WKUserScript(source: source,
                                          injectionTime: .atDocumentStart,
                                          forMainFrameOnly: true,
                                          in: .page)
            case .documentEnd:
                userScript = WKUserScript(source: source,
                                          injectionTime: .atDocumentEnd,
                                          forMainFrameOnly: true,
                                          in: .page)
            case .documentIdle:
                // idle 没有对应时机：document-end 之后用 requestIdleCallback 再推一拍
                let wrapped = """
                (function(){
                  var run = function(){ \(source) };
                  if (window.requestIdleCallback) { requestIdleCallback(function(){ run(); }); }
                  else { setTimeout(run, 0); }
                })();
                """
                userScript = WKUserScript(source: wrapped,
                                          injectionTime: .atDocumentEnd,
                                          forMainFrameOnly: true,
                                          in: .page)
            }
            controller.addUserScript(userScript)
        }
    }

    /// 生成「GM 桥 + 用户脚本」的完整源码
    private func makeSource(for script: LNUserscript) -> String {
        let id = script.id.uuidString
        let storeLiteral = store.gmStoreLiteral(scriptID: script.id)
        let name = Self.jsonString(script.name)
        let version = Self.jsonString(script.version)
        let namespace = Self.jsonString(script.namespace)

        return """
        (function(){
        var __lnId = \(Self.jsonString(id));
        var __lnBridge = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.messageHandlerName)) || null;
        function __lnPost(payload){ try { if (__lnBridge) { __lnBridge.postMessage(payload); } } catch (e) {} }
        var __gmStore = \(storeLiteral);
        function GM_getValue(key, defaultValue){
          key = String(key);
          return Object.prototype.hasOwnProperty.call(__gmStore, key) ? __gmStore[key] : defaultValue;
        }
        function GM_setValue(key, value){
          key = String(key);
          __gmStore[key] = value;
          var json = '';
          try { json = JSON.stringify(value); } catch (e) { json = 'null'; }
          __lnPost({op:'setValue', script:__lnId, key:key, json:json});
        }
        function GM_deleteValue(key){
          key = String(key);
          delete __gmStore[key];
          __lnPost({op:'deleteValue', script:__lnId, key:key});
        }
        function GM_listValues(){ return Object.keys(__gmStore); }
        function GM_addStyle(css){
          var style = document.createElement('style');
          style.textContent = String(css);
          (document.head || document.documentElement).appendChild(style);
          return style;
        }
        function GM_log(){
          try {
            var args = ['[userscript]'].concat([].slice.call(arguments));
            console.log.apply(console, args);
          } catch (e) {}
        }
        var __lnXhrSeq = 0;
        var __lnXhrCallbacks = {};
        window.__lnXHR = function(reqId, payload){
          var details = __lnXhrCallbacks[reqId];
          if (!details) { return; }
          delete __lnXhrCallbacks[reqId];
          try {
            if (payload && payload.error) {
              if (details.onerror) { details.onerror(payload); }
            } else {
              if (details.onload) { details.onload(payload); }
              if (details.onreadystatechange) { details.onreadystatechange(payload); }
            }
          } catch (e) {}
        };
        function GM_xmlhttpRequest(details){
          details = details || {};
          var reqId = 'r' + (++__lnXhrSeq) + '_' + Date.now();
          __lnXhrCallbacks[reqId] = details;
          __lnPost({
            op:'xhr',
            script:__lnId,
            reqId:reqId,
            method:(details.method || 'GET'),
            url:String(details.url || ''),
            headers:details.headers || {},
            data:(details.data == null ? null : String(details.data)),
            timeout:(Number(details.timeout) || 0)
          });
          return { abort: function(){ __lnPost({op:'xhrAbort', reqId:reqId}); } };
        }
        function GM_notification(details){
          try { console.log('[userscript] notification: ' + ((details && details.text) || '')); } catch (e) {}
        }
        function GM_getResourceText(){ return null; }
        function GM_getResourceURL(){ return null; }
        function GM_registerMenuCommand(){ }
        var unsafeWindow = window;
        var GM_info = {
          scriptHandler: 'Legado iOS',
          version: '1.0',
          script: { name: \(name), version: \(version), namespace: \(namespace) }
        };

        // ===== 用户脚本正文 =====
        \(script.code)
        })();
        """
    }

    private static func jsonString(_ value: String) -> String {
        LNUserscriptStore.jsonString(value)
    }

    // MARK: - GM 消息处理

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName,
              let body = message.body as? [String: Any],
              let op = body["op"] as? String else { return }

        let scriptID = (body["script"] as? String).flatMap { UUID(uuidString: $0) }

        switch op {
        case "setValue":
            guard let id = scriptID,
                  let key = body["key"] as? String,
                  let json = body["json"] as? String else { return }
            store.setGMValue(scriptID: id, key: key, json: json)

        case "deleteValue":
            guard let id = scriptID, let key = body["key"] as? String else { return }
            store.deleteGMValue(scriptID: id, key: key)

        case "xhr":
            performXHR(body)

        case "xhrAbort":
            // P2 不做请求中断（请求通常很快），忽略
            break

        case "log":
            if let text = body["message"] as? String { print("[userscript] \(text)") }

        default:
            break
        }
    }

    /// 代替页面发请求：WKWebView 里的 fetch 受同源策略限制，
    /// GM_xmlhttpRequest 必须走原生 URLSession 才能跨域。
    private func performXHR(_ body: [String: Any]) {
        guard let reqId = body["reqId"] as? String,
              let urlString = body["url"] as? String,
              let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = (body["method"] as? String ?? "GET").uppercased()
        if let headers = body["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let data = body["data"] as? String, !data.isEmpty {
            request.httpBody = data.data(using: .utf8)
        }
        if let timeout = body["timeout"] as? Double, timeout > 0 {
            request.timeoutInterval = timeout / 1000.0
        }

        // 用 async/await 而不是 dataTask 闭包：回调天然回到 MainActor，
        // 可以直接操作 webView，不会触发 Swift 6 的跨隔离捕获检查。
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                var payload: [String: Any] = [
                    "readyState": 4,
                    "status": http?.statusCode ?? 0,
                    "statusText": Self.statusText(http?.statusCode ?? 0),
                    "responseText": text,
                    "finalUrl": http?.url?.absoluteString ?? urlString,
                ]
                if let headers = http?.allHeaderFields {
                    var flattened: [String: String] = [:]
                    for (key, value) in headers {
                        flattened["\(key)"] = "\(value)"
                    }
                    payload["responseHeaders"] = flattened
                }
                self.deliverXHR(reqId: reqId, payload: payload)
            } catch {
                self.deliverXHR(reqId: reqId, payload: [
                    "readyState": 4,
                    "status": 0,
                    "statusText": "",
                    "responseText": "",
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func deliverXHR(reqId: String, payload: [String: Any]) {
        guard let webView else { return }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let safeId = Self.jsonString(reqId)
        let script = "window.__lnXHR && window.__lnXHR(\(safeId), \(json));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return ""
        }
    }
}

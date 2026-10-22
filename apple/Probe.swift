// WKWebView host shared by the macOS executable and the iOS simulator app.
import Foundation
import WebKit

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

func emit(_ s: String) {
  print(s)
  fflush(stdout)
}

func jsonString(_ obj: Any) -> String {
  guard JSONSerialization.isValidJSONObject(obj),
    let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
  else { return "{}" }
  return String(decoding: d, as: UTF8.self)
}

func fnv1a(_ d: Data) -> UInt32 {
  var h: UInt32 = 0x811c_9dc5
  for b in d {
    h ^= UInt32(b)
    h = h &* 0x0100_0193
  }
  return h
}

func parseArgs(_ argv: [String]) -> [String: String] {
  var out: [String: String] = [:]
  var i = 1
  while i < argv.count {
    let a = argv[i]
    if a.hasPrefix("--") {
      let key = String(a.dropFirst(2))
      if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
        out[key] = argv[i + 1]
        i += 2
        continue
      }
      out[key] = "1"
    }
    i += 1
  }
  return out
}

/// Calls a private `-(void)set...:(BOOL)` selector if the object responds to it.
@discardableResult
func setPrivateBool(_ obj: NSObject, _ selName: String, _ value: Bool) -> Bool {
  let sel = NSSelectorFromString(selName)
  guard obj.responds(to: sel), let imp = obj.method(for: sel) else { return false }
  typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
  let f = unsafeBitCast(imp, to: Fn.self)
  f(obj, sel, value)
  return true
}

@MainActor
final class Probe: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
  let webRoot: URL
  let args: [String: String]
  let mode: String
  let config: String
  let base = "probe://app"
  var webView: WKWebView!
  var results: [String: Any] = [:]
  var arrivals: [Double] = []
  var killMethod = ""
  var killAt = 0.0
  var finished = false
  var configNotes: [String: Any] = [:]

  // platform hooks
  var hideWindow: () -> Void = {}
  var showWindow: () -> Void = {}
  var windowVisible: () -> Bool = { true }
  var extraHostInfo: [String: Any] = [:]

  init(webRoot: URL, args: [String: String]) {
    self.webRoot = webRoot
    self.args = args
    self.mode = args["mode"] ?? "main"
    self.config = args["config"] ?? "default"
    super.init()
  }

  func makeConfiguration() -> WKWebViewConfiguration {
    let c = WKWebViewConfiguration()
    c.setURLSchemeHandler(self, forURLScheme: "probe")
    c.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "probe")
    let prefs = c.preferences
    // config = tokens joined by '+': nosuspend, timer, autoinc, suppress, activity
    // ("private" = timer+autoinc+suppress, "all" = everything)
    var tokens = Set(config.split(separator: "+").map(String.init))
    if tokens.contains("private") { tokens.formUnion(["timer", "autoinc", "suppress"]) }
    if tokens.contains("all") { tokens.formUnion(["timer", "autoinc", "suppress", "nosuspend", "activity"]) }
    if tokens.contains("nosuspend") {
      if #available(macOS 14.0, iOS 17.0, *) {
        prefs.inactiveSchedulingPolicy = WKPreferences.InactiveSchedulingPolicy.none
        configNotes["inactiveSchedulingPolicy"] = "none"
      } else {
        configNotes["inactiveSchedulingPolicy"] = "unavailable"
      }
    }
    if tokens.contains("timer") {
      configNotes["_setHiddenPageDOMTimerThrottlingEnabled:NO"] = setPrivateBool(
        prefs, "_setHiddenPageDOMTimerThrottlingEnabled:", false)
    }
    if tokens.contains("autoinc") {
      configNotes["_setHiddenPageDOMTimerThrottlingAutoIncreases:NO"] = setPrivateBool(
        prefs, "_setHiddenPageDOMTimerThrottlingAutoIncreases:", false)
    }
    if tokens.contains("suppress") {
      configNotes["_setPageVisibilityBasedProcessSuppressionEnabled:NO"] = setPrivateBool(
        prefs, "_setPageVisibilityBasedProcessSuppressionEnabled:", false)
    }
    if tokens.contains("activity") {
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical], reason: "probe")
      configNotes["beginActivity"] = "userInitiated+latencyCritical"
    }
    if args["secure-scheme"] != nil {
      let pool = WKProcessPool()
      let sel = NSSelectorFromString("_registerURLSchemeAsSecure:")
      if pool.responds(to: sel) {
        pool.perform(sel, with: "probe")
        configNotes["_registerURLSchemeAsSecure"] = true
      } else {
        configNotes["_registerURLSchemeAsSecure"] = false
      }
      c.processPool = pool
    }
    return c
  }
  var activity: NSObjectProtocol?

  func attach(_ wv: WKWebView) {
    webView = wv
    wv.navigationDelegate = self
    if #available(macOS 13.3, iOS 16.4, *) { wv.isInspectable = true }
  }

  func start() {
    let startPath: String
    switch mode {
    case "throttle": startPath = "/coi/index.html?mode=throttle&config=\(config)"
    default: startPath = "/nocoi/index.html?mode=\(mode)"
    }
    let timeout = Double(args["timeout"] ?? "300") ?? 300
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
      self.results["timeout"] = ["afterSecs": timeout]
      emit("RESULT timeout {\"afterSecs\":\(timeout)}")
      self.finish(code: 2)
    }
    let url = args["start-url"] ?? (base + startPath)
    emit("PROBE start mode=\(mode) config=\(config) url=\(url)")
    webView.load(URLRequest(url: URL(string: url)!))
  }

  func finish(code: Int32) {
    if finished { return }
    finished = true
    var host: [String: Any] = [
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "webkitBundleVersion": Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "?",
      "mode": mode,
      "config": config,
      "configNotes": configNotes,
    ]
    for (k, v) in extraHostInfo { host[k] = v }
    results["host"] = host
    emit("RESULT host \(jsonString(host))")
    if let out = args["out"] {
      try? jsonString(results).data(using: .utf8)?.write(to: URL(fileURLWithPath: out))
    }
    emit("PROBE_DONE code=\(code)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(code) }
  }

  // MARK: WKScriptMessageHandlerWithReply
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    if let s = message.body as? String, s == "ping" {
      replyHandler("pong", nil)
    } else if let s = message.body as? String, s == "__done" {
      replyHandler("ok", nil)
      DispatchQueue.main.async { self.finish(code: 0) }
    } else {
      replyHandler(message.body, nil)
    }
  }

  // MARK: WKNavigationDelegate
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    let t = nowMs()
    let info: [String: Any] = [
      "terminatedCallback": true,
      "method": killMethod,
      "msFromKillToCallback": killAt > 0 ? Int(t - killAt) : -1,
    ]
    results["crash-host"] = info
    emit("RESULT crash-host \(jsonString(info))")
    if !killMethod.isEmpty {
      webView.load(URLRequest(url: URL(string: base + "/coi/index.html?recovered=1&mode=\(mode)")!))
    } else {
      finish(code: 3)
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    emit("PROBE navigation failed: \(error)")
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    emit("PROBE provisional navigation failed: \(error)")
  }

  // MARK: WKURLSchemeHandler
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    let req = task.request
    guard let url = req.url else { return }
    let path = url.path
    var query: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
      query[item.name] = item.value ?? ""
    }
    var status = 200
    var ctype = "text/plain; charset=utf-8"
    var body = Data()
    var isolate = false

    if path.hasPrefix("/coi/") || path.hasPrefix("/nocoi/") {
      isolate = path.hasPrefix("/coi/")
      let rel = String(path.dropFirst(isolate ? 5 : 7))
      if let d = try? Data(contentsOf: webRoot.appendingPathComponent(rel)) {
        body = d
        ctype = rel.hasSuffix(".html") ? "text/html; charset=utf-8" : rel.hasSuffix(".js") ? "text/javascript" : "application/octet-stream"
      } else {
        status = 404
      }
    } else if path == "/ping" {
      body = Data("pong".utf8)
    } else if path == "/wping" {
      arrivals.append(nowMs())
      body = Data("ok".utf8)
    } else if path == "/echo" {
      let (b, src) = readBody(req)
      let marker = query["marker"].map { b.range(of: Data($0.utf8)) != nil } ?? false
      let j: [String: Any] = [
        "len": b.count, "fnv": fnv1a(b), "ct": req.value(forHTTPHeaderField: "Content-Type") ?? "",
        "marker": marker, "src": src,
      ]
      body = Data(jsonString(j).utf8)
      ctype = "application/json"
    } else if path.hasPrefix("/result/") {
      let phase = String(path.dropFirst(8)).removingPercentEncoding ?? "unknown"
      let (b, _) = readBody(req)
      record(phase, b)
      body = Data("ok".utf8)
    } else if path.hasPrefix("/cmd/") {
      body = Data(command(String(path.dropFirst(5)), query).utf8)
    } else {
      status = 404
    }

    var headers: [String: String] = [
      "Content-Type": ctype,
      "Cache-Control": "no-store",
      "Cross-Origin-Resource-Policy": "same-origin",
    ]
    if isolate {
      headers["Cross-Origin-Opener-Policy"] = "same-origin"
      headers["Cross-Origin-Embedder-Policy"] = "require-corp"
    }
    headers["Content-Length"] = String(body.count)
    let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    task.didReceive(resp)
    task.didReceive(body)
    task.didFinish()
  }

  func readBody(_ req: URLRequest) -> (Data, String) {
    if let b = req.httpBody { return (b, "httpBody") }
    if let s = req.httpBodyStream {
      var d = Data()
      s.open()
      var buf = [UInt8](repeating: 0, count: 65536)
      while true {
        let n = s.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        d.append(buf, count: n)
      }
      s.close()
      return (d, "httpBodyStream")
    }
    return (Data(), "none")
  }

  func record(_ phase: String, _ b: Data) {
    let text = String(decoding: b, as: UTF8.self)
    if let obj = try? JSONSerialization.jsonObject(with: b) { results[phase] = obj }
    emit("RESULT \(phase) \(text)")
    if phase == "done" {
      DispatchQueue.main.async { self.finish(code: 0) }
    }
  }

  func command(_ name: String, _ q: [String: String]) -> String {
    switch name {
    case "crash":
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.killWebContent() }
      return "ok"
    case "arrivals":
      let from = Double(q["from"] ?? "0") ?? 0
      let to = Double(q["to"] ?? "0") ?? 0
      let n = arrivals.filter { $0 > from && $0 < to }.count
      return "{\"count\":\(n),\"total\":\(arrivals.count)}"
    case "throttle-start":
      DispatchQueue.main.async { self.runThrottle() }
      return "ok"
    default:
      return "unknown"
    }
  }

  func killWebContent() {
    killAt = nowMs()
    let sel = NSSelectorFromString("_killWebContentProcess")
    let pidSel = NSSelectorFromString("_webProcessIdentifier")
    if webView.responds(to: sel) {
      killMethod = "_killWebContentProcess"
      webView.perform(sel)
    } else if webView.responds(to: pidSel), let pid = webView.value(forKey: "_webProcessIdentifier") as? Int32,
      pid > 0
    {
      killMethod = "kill(_webProcessIdentifier)"
      kill(pid, SIGKILL)
    } else {
      killMethod = "none"
      emit("RESULT crash-host {\"error\":\"no kill method reachable\"}")
      finish(code: 4)
    }
  }

  // W2-lite: visible → hidden → visible, with a host → page beat every second.
  func runThrottle() {
    let visibleSecs = Double(args["visible-secs"] ?? "10") ?? 10
    let hiddenSecs = Double(args["hidden-secs"] ?? "90") ?? 90
    let afterSecs = 10.0
    var segs: [String: Any] = ["visibleStart": nowMs()]
    var beats = 0
    func beat() {
      if finished { return }
      beats += 1
      webView.evaluateJavaScript("__probeEvent('B')", completionHandler: nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { beat() }
    }
    beat()
    segs["visibleBeforeHide"] = windowVisible()
    DispatchQueue.main.asyncAfter(deadline: .now() + visibleSecs) {
      segs["hideAt"] = nowMs()
      self.hideWindow()
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { segs["visibleWhileHidden"] = self.windowVisible() }
      DispatchQueue.main.asyncAfter(deadline: .now() + hiddenSecs) {
        segs["showAt"] = nowMs()
        self.showWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + afterSecs) {
          segs["end"] = nowMs()
          segs["visibleAfterShow"] = self.windowVisible()
          segs["hostBeatsSent"] = beats
          self.webView.evaluateJavaScript("probeThrottleDone(\(jsonString(segs)))", completionHandler: nil)
        }
      }
    }
  }
}

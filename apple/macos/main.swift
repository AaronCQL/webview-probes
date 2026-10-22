import AppKit
import WebKit

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let cli = parseArgs(CommandLine.arguments)
let probe = Probe(webRoot: URL(fileURLWithPath: cli["web"] ?? "web"), args: cli)
let window = NSWindow(
  contentRect: NSRect(x: 80, y: 80, width: 900, height: 700),
  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.title = "probe"
let webView = WKWebView(frame: window.contentView!.bounds, configuration: probe.makeConfiguration())
webView.autoresizingMask = [.width, .height]
window.contentView!.addSubview(webView)
probe.attach(webView)
probe.hideWindow = {
  if cli["hide"] == "minimize" { window.miniaturize(nil) } else { window.orderOut(nil) }
}
probe.showWindow = {
  if window.isMiniaturized { window.deminiaturize(nil) }
  window.makeKeyAndOrderFront(nil)
}
probe.windowVisible = { window.occlusionState.contains(.visible) }
probe.extraHostInfo = [
  "hide": cli["hide"] ?? "orderOut",
  "screens": NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.backingScaleFactor)" },
]
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
probe.start()
app.run()

import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  var probe: Probe?

  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    setvbuf(stdout, nil, _IOLBF, 0)
    let cli = parseArgs(CommandLine.arguments)
    if cli["modules"] != "0" { runModuleTests() }
    if cli["mode"] == "modules" {
      emit("PROBE_DONE code=0")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
      return true
    }
    if cli["stockfish"] == "1" { runStockfishProbe() }
    let p = Probe(webRoot: Bundle.main.resourceURL!.appendingPathComponent("web"), args: cli)
    probe = p
    let w = UIWindow(frame: UIScreen.main.bounds)
    let vc = UIViewController()
    let wv = WKWebView(frame: w.bounds, configuration: p.makeConfiguration())
    wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    vc.view = wv
    w.rootViewController = vc
    w.makeKeyAndVisible()
    window = w
    p.attach(wv)
    p.extraHostInfo = ["device": UIDevice.current.model, "systemVersion": UIDevice.current.systemVersion]
    p.start()
    return true
  }
}

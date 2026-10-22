# webview-probes

Small CI probes of system webview behaviour — WKWebView (macOS and the iOS simulator) and WebView2 (Windows) — plus a check that tiny native modules written in C, Rust, Zig and Go can be linked or loaded together.

This is throwaway code. Each workflow prints `RESULT <phase> <json>` lines to its log, and `tools/collect.py` gathers them into a JSON artifact (`*-results.json`).

## Layout

| path | what |
|---|---|
| `web/` | the probe page (`probe.js`), shared by every host. It covers COI/SAB, the POST body matrix, latency, Worker/SharedWorker during a 2 s main-thread block, crash recovery, hidden-window throttling and the event soak |
| `apple/Probe.swift` | the WKWebView host (`WKURLSchemeHandler` for `probe://app`, `WKScriptMessageHandlerWithReply`), shared by macOS and iOS |
| `apple/macos/` | the macOS executable (an NSWindow; built with `swiftc`, no Xcode project) |
| `apple/ios/` | the iOS simulator app (built with `swiftc`, ad-hoc signed, run with `simctl launch --console-pty`). It statically links the four modules, and optionally Stockfish |
| `windows/Probe/` | the WebView2 host (C# WinForms + `CoreWebView2Controller`). It serves `https://probe.localhost` via `WebResourceRequested` and a `probe://` custom scheme, and loads the module DLLs |
| `modules/` | `include/probe_module.h` (a tiny C ABI) and four implementations: `c/`, `rust/`, `zig/`, `go/` |
| `tools/loopback.py` | a loopback HTTP server with COOP/COEP, used as the COI alternative on WebKit |
| `tools/collect.py` | RESULT lines → JSON |

## Workflows

- `env`: runner, Xcode, simulator, WebView2 and toolchain versions.
- `apple`:
  - **macos** job: main suite on the custom scheme, the custom scheme registered as secure, and a loopback-HTTP page. The hidden-window throttling matrix runs only on `workflow_dispatch` with `throttle: true`.
  - **ios** job: builds the four modules for `arm64-apple-ios-simulator`, links them into one app, then runs the module calls, the main suite, the secure-scheme check and the loopback page.
- `windows`: builds the module DLLs and the host, then runs the module loading/unloading check, the main suite on both origins, the 10k events/s soak (post vs wake+pull) and the hidden-window throttling matrix.
- `stockfish-ios`: official Stockfish (sf_17.1) built as a static library for the simulator, run on a thread with stdin/stdout swapped for pipes.

Run any of them from the Actions tab (`workflow_dispatch`), or with `gh workflow run <name>`.

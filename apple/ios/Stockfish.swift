import Foundation

@_silgen_name("sf_entry")
func sf_entry(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

/// Runs the statically linked Stockfish main() on its own thread with fd 0/1 swapped
/// for pipes, then drives it over UCI: uci, isready, go depth 10.
func runStockfishProbe() {
  var r: [String: Any] = ["built": true]
  logFD = dup(1)
  var toEngine: [Int32] = [0, 0]
  var fromEngine: [Int32] = [0, 0]
  pipe(&toEngine)
  pipe(&fromEngine)
  dup2(toEngine[0], 0)
  dup2(fromEngine[1], 1)
  setvbuf(stdout, nil, _IONBF, 0)
  let t = Thread {
    var args: [UnsafeMutablePointer<CChar>?] = [strdup("stockfish"), nil]
    let rc = sf_entry(1, &args)
    emit("PROBE stockfish main returned \(rc)")
  }
  t.stackSize = 16 << 20
  t.start()

  var buffer = Data()
  func send(_ s: String) {
    let d = Array((s + "\n").utf8)
    _ = d.withUnsafeBufferPointer { write(toEngine[1], $0.baseAddress, $0.count) }
  }
  // read lines until one starts with `prefix` or timeout
  func waitFor(_ prefix: String, timeout: Double) -> (String?, [String]) {
    let deadline = Date().addingTimeInterval(timeout)
    var lines: [String] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while Date() < deadline {
      while let nl = buffer.firstIndex(of: 10) {
        let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...nl)
        lines.append(line)
        if line.hasPrefix(prefix) { return (line, lines) }
      }
      var pfd = pollfd(fd: fromEngine[0], events: Int16(POLLIN), revents: 0)
      if poll(&pfd, 1, 200) > 0 {
        let n = read(fromEngine[0], &chunk, chunk.count)
        if n > 0 { buffer.append(chunk, count: n) } else { break }
      }
    }
    return (nil, lines)
  }
  let t0 = Date()
  send("uci")
  let (uciok, uciLines) = waitFor("uciok", timeout: 20)
  r["uciok"] = uciok != nil
  r["id"] = uciLines.first { $0.hasPrefix("id name") } ?? ""
  r["uci_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
  send("isready")
  let t1 = Date()
  let (ready, _) = waitFor("readyok", timeout: 30)
  r["readyok"] = ready != nil
  r["isready_ms"] = Int(Date().timeIntervalSince(t1) * 1000)
  send("position startpos")
  send("go depth 10")
  let t2 = Date()
  let (best, goLines) = waitFor("bestmove", timeout: 60)
  r["bestmove"] = best ?? ""
  r["go_depth10_ms"] = Int(Date().timeIntervalSince(t2) * 1000)
  r["last_info"] = goLines.last { $0.hasPrefix("info depth") } ?? ""
  if best == nil { r["tail"] = Array(goLines.suffix(5)) }
  send("quit")
  r["pass"] = best != nil
  emit("RESULT stockfish \(jsonString(r))")
}

import Foundation

final class CallbackBox {
  var calls: Int64 = 0
  var sum: Int64 = 0
}

private let countCallback: pm_callback_fn = { ctx, _, value in
  let box = Unmanaged<CallbackBox>.fromOpaque(ctx!).takeUnretainedValue()
  box.calls += 1
  box.sum += value
}

func testModule(_ entry: () -> UnsafePointer<pm_module>?, label: String) -> [String: Any] {
  guard let mp = entry() else { return ["lang": label, "ok": false, "error": "entry returned NULL"] }
  let m = mp.pointee
  var r: [String: Any] = ["lang": label, "name": String(cString: m.name), "abi": Int(m.version)]
  let sum = m.add(40, 2)
  r["add_40_2"] = sum
  let input = Array("h\u{e9}llo \u{2192} w\u{f6}rld \u{1F600}".utf8)
  var outPtr: UnsafeMutablePointer<UInt8>? = nil
  var outLen = 0
  let rc = input.withUnsafeBufferPointer { m.reverse($0.baseAddress, $0.count, &outPtr, &outLen) }
  let reversed = String(decoding: UnsafeBufferPointer(start: outPtr, count: outLen), as: UTF8.self)
  m.free_bytes(outPtr, outLen)
  r["reverse"] = reversed
  let expected = String(String(decoding: input, as: UTF8.self).reversed())
  let box = CallbackBox()
  let ctx = Unmanaged.passUnretained(box).toOpaque()
  var host = pm_host(version: 1, ctx: ctx, callback: countCallback)
  let counter = m.counter_new(0)
  let t0 = DispatchTime.now().uptimeNanoseconds
  let calls = m.count_to(counter, 100_000, &host, 7)
  let t1 = DispatchTime.now().uptimeNanoseconds
  m.counter_free(counter)
  r["count_to_calls"] = calls
  r["callback_sum_ok"] = box.sum == 100_000 * 100_001 / 2
  r["ns_per_callback"] = Double(t1 - t0) / 100_000.0
  r["ok"] = rc == 0 && sum == 42 && reversed == expected && calls == 100_000 && box.calls == 100_000
  return r
}

typealias Entry = () -> UnsafePointer<pm_module>?

let moduleEntries: [(String, Entry)] = [
  ("c", { probe_c_module() }),
  ("rust", { probe_rust_module() }),
  ("zig", { probe_zig_module() }),
  ("go", { probe_go_module() }),
]

func runModuleTests() {
  var out: [String: Any] = [:]
  for (lang, entry) in moduleEntries {
    out[lang] = testModule(entry, label: lang)
  }
  // all four at once from background threads (Go runtime + Rust in one process, concurrently)
  let lock = NSLock()
  var concurrent: [String: Bool] = [:]
  DispatchQueue.concurrentPerform(iterations: moduleEntries.count) { i in
    let (lang, entry) = moduleEntries[i]
    var ok = true
    for _ in 0..<5 { ok = ok && ((testModule(entry, label: lang)["ok"] as? Bool) ?? false) }
    lock.lock(); concurrent[lang] = ok; lock.unlock()
  }
  out["concurrent_threads_ok"] = concurrent
  emit("RESULT modules \(jsonString(out))")
}

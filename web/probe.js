// Shared probe page. Talks to the native host via:
//  - same-origin fetch to the host's scheme handler (/ping, /echo, /result/<phase>, /cmd/<name>, ...)
//  - script messages: window.webkit.messageHandlers.probe (WKWebView, with reply)
//                     or window.chrome.webview (WebView2, reply posted back as "R:<id>:<payload>")
'use strict';

const params = new URLSearchParams(location.search);
const MODE = params.get('mode') || 'main';
const COI_PATH = location.pathname.startsWith('/coi/');
const isWK = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.probe);
const isWV2 = !!(window.chrome && window.chrome.webview);
const enc = new TextEncoder();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function show(s) {
  const el = document.getElementById('log');
  if (el) el.textContent += '\n' + s;
}

async function report(phase, obj) {
  show(phase);
  if (phase === 'done' && location.protocol.startsWith('http') && !location.hostname.endsWith('probe.localhost')) {
    // results go to the loopback server; tell the native host we are finished
    setTimeout(() => { msgCall('__done').catch(() => {}); }, 300);
  }
  try {
    await fetch('/result/' + encodeURIComponent(phase), { method: 'POST', body: JSON.stringify(obj) });
  } catch (e) {
    show('report failed ' + e);
  }
}

async function cmd(name, query) {
  const r = await fetch('/cmd/' + name + (query ? '?' + query : ''), { method: 'POST', body: '' });
  return r.text();
}

// ---------- script-message transport ----------
let msgSeq = 0;
const pending = new Map();
let hostEventHandler = null;
if (isWV2) {
  window.chrome.webview.addEventListener('message', (e) => {
    const d = e.data;
    if (typeof d === 'string' && d.charCodeAt(0) === 82 /* R */ && d[1] === ':') {
      const i = d.indexOf(':', 2);
      const id = +d.slice(2, i);
      const cb = pending.get(id);
      if (cb) { pending.delete(id); cb(d.slice(i + 1)); }
    } else if (hostEventHandler) {
      hostEventHandler(d);
    }
  });
}
// host → page events on WebKit come via evaluateJavaScript calling this
window.__probeEvent = (d) => { if (hostEventHandler) hostEventHandler(d); };

function msgCall(s) {
  if (isWK) return window.webkit.messageHandlers.probe.postMessage(s);
  if (isWV2) {
    return new Promise((res) => {
      const id = ++msgSeq;
      pending.set(id, res);
      window.chrome.webview.postMessage('Q:' + id + ':' + s);
    });
  }
  return Promise.reject(new Error('no message transport'));
}

// ---------- helpers ----------
function fnv1a(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

function pct(sorted, p) {
  if (!sorted.length) return null;
  const i = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[i];
}

function stats(us) {
  const s = us.slice().sort((a, b) => a - b);
  const r = (x) => (x == null ? null : Math.round(x * 10) / 10);
  return {
    n: s.length,
    p50_us: r(pct(s, 50)),
    p90_us: r(pct(s, 90)),
    p99_us: r(pct(s, 99)),
    max_us: r(s[s.length - 1]),
    mean_us: r(s.reduce((a, b) => a + b, 0) / (s.length || 1)),
  };
}

function timerResolution() {
  const deltas = [];
  const t0 = performance.now();
  let last = t0;
  while (deltas.length < 2000 && performance.now() - t0 < 300) {
    const t = performance.now();
    if (t !== last) { deltas.push(t - last); last = t; }
  }
  deltas.sort((a, b) => a - b);
  return {
    min_nonzero_delta_us: deltas.length ? Math.round(deltas[0] * 1000 * 100) / 100 : null,
    median_delta_us: deltas.length ? Math.round(pct(deltas, 50) * 1000 * 100) / 100 : null,
    samples: deltas.length,
  };
}

function workerCall(w, msg, timeoutMs) {
  return new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('worker timeout')), timeoutMs || 10000);
    w.onmessage = (e) => { clearTimeout(t); res(e.data); };
    w.onerror = (e) => { clearTimeout(t); rej(new Error('worker error ' + (e.message || ''))); };
    w.postMessage(msg);
  });
}

async function envInfo() {
  let sabNew = false, sabErr = null;
  try { new SharedArrayBuffer(16); sabNew = true; } catch (e) { sabErr = String(e); }
  let wasmShared = null;
  try {
    const m = new WebAssembly.Memory({ initial: 1, maximum: 1, shared: true });
    wasmShared = Object.prototype.toString.call(m.buffer);
  } catch (e) { wasmShared = 'error: ' + e; }
  let worker = null;
  try {
    const w = new Worker('worker.js');
    worker = await workerCall(w, { cmd: 'env' }, 5000);
    w.terminate();
  } catch (e) { worker = { error: String(e) }; }
  return {
    href: location.href,
    ua: navigator.userAgent,
    crossOriginIsolated: self.crossOriginIsolated === true,
    isSecureContext: self.isSecureContext === true,
    sabType: typeof SharedArrayBuffer,
    sabConstructible: sabNew,
    sabError: sabErr,
    wasmSharedBuffer: wasmShared,
    hardwareConcurrency: navigator.hardwareConcurrency,
    timer: timerResolution(),
    worker,
    transport: isWK ? 'webkit.messageHandlers' : isWV2 ? 'chrome.webview' : 'none',
  };
}

// ---------- A2: POST body matrix ----------
function bodyCases() {
  const bytes256 = Uint8Array.from({ length: 256 }, (_, i) => i);
  const big = new Uint8Array(1 << 20);
  for (let i = 0; i < big.length; i++) big[i] = (i * 31 + 7) & 255;
  const fd = (withFile) => {
    const f = new FormData();
    f.append('m', 'pm-mark');
    if (withFile) f.append('f', new Blob(['pm-mark in file']), 'f.txt');
    return f;
  };
  return [
    // [name, makeBody, expectedBytes|null(=check marker only), via]
    ['none', () => undefined, new Uint8Array(0), 'fetch'],
    ['string', () => 'hello pm-mark \u00fc', enc.encode('hello pm-mark \u00fc'), 'fetch'],
    ['arraybuffer', () => bytes256.buffer.slice(0), bytes256, 'fetch'],
    ['uint8array-view', () => new Uint8Array(bytes256.buffer, 10, 50), bytes256.subarray(10, 60), 'fetch'],
    ['arraybuffer-1mib', () => big.buffer.slice(0), big, 'fetch'],
    ['urlsearchparams', () => new URLSearchParams({ a: '1', m: 'pm-mark' }), enc.encode('a=1&m=pm-mark'), 'fetch'],
    ['formdata-strings', () => fd(false), null, 'fetch'],
    ['xhr-string', () => 'xhr pm-mark', enc.encode('xhr pm-mark'), 'xhr'],
    ['xhr-arraybuffer', () => bytes256.buffer.slice(0), bytes256, 'xhr'],
    // Blob-backed bodies last: historically these crashed or arrived empty on WebKit.
    ['blob', () => new Blob(['blob pm-mark']), enc.encode('blob pm-mark'), 'fetch'],
    ['blob-binary-64k', () => new Blob([big.subarray(0, 65536)]), big.subarray(0, 65536), 'fetch'],
    ['blob-empty', () => new Blob([]), new Uint8Array(0), 'fetch'],
    ['file', () => new File(['file pm-mark'], 'a.txt', { type: 'text/plain' }), enc.encode('file pm-mark'), 'fetch'],
    ['formdata-file', () => fd(true), null, 'fetch'],
    ['request-from-blob', () => new Blob(['req pm-mark']), enc.encode('req pm-mark'), 'request'],
    ['xhr-blob', () => new Blob(['xhrblob pm-mark']), enc.encode('xhrblob pm-mark'), 'xhr'],
  ];
}

function xhrPost(url, body) {
  return new Promise((res, rej) => {
    const x = new XMLHttpRequest();
    x.open('POST', url);
    x.timeout = 8000;
    x.onload = () => res({ status: x.status, text: x.responseText });
    x.onerror = () => rej(new Error('xhr error'));
    x.ontimeout = () => rej(new Error('xhr timeout'));
    x.send(body);
  });
}

async function bodies() {
  const out = {};
  for (const [name, make, expected, via] of bodyCases()) {
    const url = '/echo?kind=' + name + '&marker=pm-mark';
    const r = { via };
    const t0 = performance.now();
    try {
      let status, text;
      if (via === 'xhr') {
        ({ status, text } = await xhrPost(url, make()));
      } else {
        const ac = new AbortController();
        const timer = setTimeout(() => ac.abort(), 8000);
        const init = { method: 'POST', signal: ac.signal };
        const b = make();
        if (b !== undefined) init.body = b;
        const resp = via === 'request' ? await fetch(new Request(url, init)) : await fetch(url, init);
        status = resp.status;
        text = await resp.text();
        clearTimeout(timer);
      }
      const j = JSON.parse(text);
      r.status = status;
      r.recvLen = j.len;
      r.contentType = j.ct;
      r.marker = j.marker;
      r.bodySource = j.src;
      if (expected) {
        r.sentLen = expected.length;
        r.fnvMatch = j.fnv === fnv1a(expected);
        r.ok = j.len === expected.length && r.fnvMatch;
      } else {
        r.ok = j.len > 0 && j.marker === true;
      }
    } catch (e) {
      r.ok = false;
      r.error = String(e);
    }
    r.ms = Math.round(performance.now() - t0);
    out[name] = r;
    await report('body-' + name, r); // incremental: survives a host crash on a later case
  }
  await report('bodies', out);
}

// ---------- A3: latency ----------
let clockNote = null;
async function makeClock() {
  let sab = null;
  try {
    if (typeof SharedArrayBuffer === 'function') { sab = new SharedArrayBuffer(8); clockNote = 'SharedArrayBuffer'; }
    else { sab = new WebAssembly.Memory({ initial: 1, maximum: 1, shared: true }).buffer; clockNote = 'wasm-shared-memory'; }
  } catch (e) { clockNote = 'no SAB: ' + e; return null; }
  try {
    const a = new Int32Array(sab);
    const w = new Worker('clock.js');
    try { w.postMessage(sab); } catch (e) { clockNote += ' postMessage failed: ' + e; w.terminate(); return null; }
    const t = Date.now();
    while (Atomics.load(a, 0) === 0 && Date.now() - t < 3000) await sleep(10);
    if (Atomics.load(a, 0) === 0) { clockNote += ' (worker never ticked)'; w.terminate(); return null; }
    const calibrate = () => {
      const c0 = Atomics.load(a, 0), t0 = performance.now();
      while (performance.now() - t0 < 300) {}
      const c1 = Atomics.load(a, 0), t1 = performance.now();
      return ((c1 - c0) >>> 0) / ((t1 - t0) * 1000); // ticks per µs
    };
    return { a, w, calibrate, read: () => Atomics.load(a, 0) };
  } catch (e) {
    clockNote += ' error: ' + e;
    return null;
  }
}

async function bench(name, fn, n, clock, tpu) {
  for (let i = 0; i < 100; i++) await fn();
  const us = [];
  const tb0 = performance.now();
  for (let i = 0; i < n; i++) {
    if (clock) {
      const c0 = clock.read();
      await fn();
      const c1 = clock.read();
      us.push(((c1 - c0) >>> 0) / tpu);
    } else {
      const t0 = performance.now();
      await fn();
      us.push((performance.now() - t0) * 1000);
    }
  }
  const total = performance.now() - tb0;
  const s = stats(us);
  s.batch_mean_us = Math.round((total * 1000) / n * 10) / 10;
  return s;
}

async function latency() {
  const n = +(params.get('n') || 2000);
  const clock = await makeClock();
  const tpu = clock ? clock.calibrate() : null;
  const res = {
    clock: clock ? 'sab-counter' : 'performance.now',
    clockSource: clockNote,
    clock_ticks_per_us: tpu && Math.round(tpu * 100) / 100,
    timer: timerResolution(),
  };
  const ping = 'ping';
  const bodyStr = 'x'.repeat(1024);
  res.msg = await bench('msg', async () => { const r = await msgCall(ping); if (r !== 'pong') throw new Error('bad reply ' + r); }, n, clock, tpu);
  res.fetch_get = await bench('fetch_get', async () => { await (await fetch('/ping')).text(); }, n, clock, tpu);
  res.fetch_post = await bench('fetch_post', async () => { await (await fetch('/ping', { method: 'POST', body: ping })).text(); }, n, clock, tpu);
  res.msg_1k = await bench('msg_1k', async () => { await msgCall(bodyStr); }, Math.min(n, 500), clock, tpu);
  res.fetch_post_1k = await bench('fetch_post_1k', async () => { await (await fetch('/ping', { method: 'POST', body: bodyStr })).text(); }, Math.min(n, 500), clock, tpu);
  if (clock) {
    res.clock_ticks_per_us_after = Math.round(clock.calibrate() * 100) / 100;
    clock.w.terminate();
  }
  await report('latency', res);
}

// ---------- A4: worker → native while the main thread is blocked ----------
async function workerBlock() {
  const w = new Worker('worker.js');
  const resultP = workerCall(w, { cmd: 'pingloop', ms: 4500 }, 15000);
  await sleep(1000);
  const blockStart = Date.now();
  while (Date.now() - blockStart < 2000) {}
  const blockEnd = Date.now();
  let r;
  try { r = await resultP; } catch (e) { await report('worker-block', { error: String(e) }); return; }
  w.terminate();
  const d = r.done;
  const inBlock = d.filter((t) => t > blockStart + 20 && t < blockEnd);
  const before = d.filter((t) => t < blockStart);
  let maxGap = 0;
  for (let i = 1; i < d.length; i++) {
    if (d[i] > blockStart && d[i - 1] < blockEnd) maxGap = Math.max(maxGap, d[i] - d[i - 1]);
  }
  let hostArrivals = null;
  try { hostArrivals = JSON.parse(await cmd('arrivals', 'from=' + (blockStart + 20) + '&to=' + blockEnd)); } catch (e) { hostArrivals = String(e); }
  await report('worker-block', {
    blockMs: blockEnd - blockStart,
    completionsTotal: d.length,
    completionsBeforeBlock: before.length,
    completionsDuringBlock: inBlock.length,
    maxGapDuringBlockMs: maxGap,
    hostArrivalsDuringBlock: hostArrivals,
    errors: r.errors,
    lastError: r.lastError,
    pass: inBlock.length > 10 && maxGap < 500,
  });
}

// ---------- A6: crash + recovery ----------
async function crash() {
  await report('crash-pre', { t: Date.now() });
  try { await cmd('crash'); } catch (e) { /* expected if the process dies first */ }
  await sleep(15000);
  await report('crash-noeffect', { t: Date.now() });
  await report('done', {});
}

// ---------- A5: hidden-window throttling ----------
function segCount(times, a, b) {
  const xs = times.filter((t) => t >= a && t < b);
  let maxGap = 0;
  for (let i = 1; i < xs.length; i++) maxGap = Math.max(maxGap, xs[i] - xs[i - 1]);
  const secs = (b - a) / 1000;
  return { n: xs.length, per_s: Math.round((xs.length / secs) * 100) / 100, maxGapMs: maxGap };
}

async function throttleMode() {
  const ticks = [], rafs = [], timeouts = [], beats = [];
  const events = [];
  setInterval(() => ticks.push(Date.now()), 100);
  const chain = () => { timeouts.push(Date.now()); setTimeout(chain, 100); };
  chain();
  const raf = () => { rafs.push(Date.now()); requestAnimationFrame(raf); };
  requestAnimationFrame(raf);
  for (const ev of ['visibilitychange', 'freeze', 'resume', 'pagehide', 'pageshow', 'blur', 'focus']) {
    (ev === 'visibilitychange' || ev === 'freeze' || ev === 'resume' ? document : window).addEventListener(ev, () =>
      events.push([Date.now(), ev, document.visibilityState]));
  }
  const w = new Worker('worker.js');
  w.postMessage({ cmd: 'ticks', ms: 100 });
  hostEventHandler = (d) => { beats.push(Date.now()); };
  window.probeThrottleDone = async (segs) => {
    let wt = [];
    try { wt = (await workerCall(w, { cmd: 'getticks' }, 5000)).ticks; } catch (e) { wt = []; }
    const out = { segs, events, config: params.get('config') || 'default' };
    for (const [name, a, b] of [['visible', segs.visibleStart, segs.hideAt], ['hidden', segs.hideAt, segs.showAt], ['after', segs.showAt, segs.end]]) {
      out[name] = {
        interval: segCount(ticks, a, b),
        timeoutChain: segCount(timeouts, a, b),
        raf: segCount(rafs, a, b),
        worker: segCount(wt, a, b),
        hostBeats: segCount(beats, a, b),
      };
    }
    out.hiddenStateSeen = events.some((e) => e[2] === 'hidden');
    await report('throttle', out);
    await report('done', {});
  };
  await cmd('throttle-start');
}

// ---------- C7: event soak ----------
async function eventsMode() {
  const delivery = params.get('delivery') || 'post';
  let recv = 0, lastSeq = -1, outOfOrder = 0;
  const lat = [];
  let frames = 0, gaps50 = 0, maxGap = 0, lastFrame = performance.now();
  let running = true;
  const raf = () => {
    const t = performance.now();
    const g = t - lastFrame;
    if (g > 50) gaps50++;
    if (g > maxGap) maxGap = g;
    lastFrame = t;
    frames++;
    if (running) requestAnimationFrame(raf);
  };
  requestAnimationFrame(raf);
  const onEvent = (seq, ms) => {
    recv++;
    if (seq !== lastSeq + 1) outOfOrder++;
    lastSeq = seq;
    if ((seq & 63) === 0) lat.push(Date.now() - ms);
  };
  let pulling = false, again = false;
  const pull = async () => {
    if (pulling) { again = true; return; }
    pulling = true;
    do {
      again = false;
      const arr = await (await fetch('/pull', { method: 'POST', body: '' })).json();
      for (const e of arr) onEvent(e.seq, e.ms);
    } while (again);
    pulling = false;
  };
  const t0 = Date.now();
  let finished = false;
  const prog = setInterval(() => {
    fetch('/result/events-progress', { method: 'POST', body: JSON.stringify({ t: Date.now() - t0, recv, lastSeq, frames, gaps50 }) }).catch(() => {});
  }, 5000);
  const finish = async (sent) => {
    if (finished) return;
    finished = true;
    clearInterval(prog);
    if (delivery === 'wakepull') { while (pulling) await sleep(5); await pull(); }
    running = false;
    lat.sort((a, b) => a - b);
    await report('events-page', {
      delivery, sent, recv, outOfOrder,
      latency_ms_p50: pct(lat, 50), latency_ms_p99: pct(lat, 99), latency_ms_max: lat[lat.length - 1],
      frames, rafGapsOver50ms: gaps50, rafMaxGapMs: Math.round(maxGap), durationMs: Date.now() - t0,
    });
    await report('done', {});
  };
  hostEventHandler = (d) => {
    if (typeof d !== 'string') return;
    if (d.charCodeAt(0) === 69 /* E */) {
      const i = d.indexOf(':', 2);
      onEvent(+d.slice(2, i), +d.slice(i + 1));
    } else if (d === 'W') {
      pull();
    } else if (d.startsWith('END:')) {
      finish(+d.slice(4));
    }
  };
  await cmd('events-start', 'delivery=' + delivery + '&rate=' + (params.get('rate') || 10000) + '&secs=' + (params.get('secs') || 30));
}

// ---------- driver ----------
async function main() {
  try {
    if (!COI_PATH) {
      await report('env-nocoi', await envInfo());
      location.href = '/coi/index.html' + location.search;
      return;
    }
    if (params.has('recovered')) {
      await report('crash-recovered', { t: Date.now(), ping: await (await fetch('/ping')).text() });
      await report('done', {});
      return;
    }
    if (MODE === 'throttle') return await throttleMode();
    if (MODE === 'events') return await eventsMode();
    await report('env-coi', await envInfo());
    if (MODE === 'envonly') return await report('done', {});
    if (MODE === 'loopback') {
      await latency();
      await workerBlock();
      return await report('done', {});
    }
    await bodies();
    await latency();
    await workerBlock();
    if (params.get('crash') === '0') await report('done', {});
    else await crash();
  } catch (e) {
    await report('error', { msg: String(e), stack: e && e.stack });
    await report('done', {});
  }
}

main();

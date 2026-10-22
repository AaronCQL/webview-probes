// Dedicated worker used by the page probes.
let ticks = [];

self.onmessage = async (e) => {
  const m = e.data;
  if (m.cmd === 'env') {
    let sabNew = false;
    try { new SharedArrayBuffer(8); sabNew = true; } catch (_) {}
    self.postMessage({ coi: self.crossOriginIsolated === true, sabType: typeof SharedArrayBuffer, sabNew });
  } else if (m.cmd === 'pingloop') {
    // fetch the native side in a tight loop until m.ms elapsed; record completion times.
    const end = Date.now() + m.ms;
    const done = [];
    let errors = 0, lastError = null;
    while (Date.now() < end) {
      try {
        const r = await fetch('/wping', { method: 'POST', body: 'w' });
        await r.text();
        done.push(Date.now());
      } catch (err) {
        errors++; lastError = String(err);
        await new Promise((r) => setTimeout(r, 10));
      }
    }
    self.postMessage({ done, errors, lastError });
  } else if (m.cmd === 'ticks') {
    ticks = [];
    setInterval(() => ticks.push(Date.now()), m.ms || 100);
  } else if (m.cmd === 'getticks') {
    self.postMessage({ ticks });
  }
};

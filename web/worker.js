// Worker used by the page probes. Runs as a dedicated Worker, or as a SharedWorker (onconnect).
let ticks = [];

async function handle(m, reply) {
  if (m.cmd === 'env') {
    let sabNew = false;
    try { new SharedArrayBuffer(8); sabNew = true; } catch (_) {}
    reply({ coi: self.crossOriginIsolated === true, sabType: typeof SharedArrayBuffer, sabNew });
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
    reply({ done, errors, lastError });
  } else if (m.cmd === 'ticks') {
    ticks = [];
    setInterval(() => ticks.push(Date.now()), m.ms || 100);
  } else if (m.cmd === 'getticks') {
    reply({ ticks });
  }
}

self.onmessage = (e) => handle(e.data, (r) => self.postMessage(r));
self.onconnect = (e) => {
  const port = e.ports[0];
  port.onmessage = (ev) => handle(ev.data, (r) => port.postMessage(r));
  port.start();
};

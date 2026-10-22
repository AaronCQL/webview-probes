// Counter clock: spins and publishes an incrementing counter into a SharedArrayBuffer.
self.onmessage = (e) => {
  const a = new Int32Array(e.data);
  let n = 0;
  for (;;) {
    n = (n + 1) | 0;
    Atomics.store(a, 0, n);
  }
};

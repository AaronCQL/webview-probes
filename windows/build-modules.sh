#!/bin/bash
# Builds the four demo modules as x64 Windows DLLs into build/win (run from Git Bash).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=build/win
mkdir -p "$OUT"
: > "$OUT/status.txt"
step() {
  local name=$1; shift
  echo "::group::module $name"
  if "$@"; then echo "$name ok" | tee -a "$OUT/status.txt"; else echo "$name FAILED" | tee -a "$OUT/status.txt"; fi
  echo "::endgroup::"
}
build_c() {
  clang -shared -O2 -Imodules/include modules/c/module.c -o "$OUT/probe_c.dll" ||
    gcc -shared -O2 -Imodules/include modules/c/module.c -o "$OUT/probe_c.dll"
}
build_rust() {
  cargo build --release --manifest-path modules/rust/Cargo.toml &&
    cp modules/rust/target/release/probe_rust.dll "$OUT/"
}
build_zig() {
  zig version && zig build-lib -dynamic -target x86_64-windows-gnu -lc -O ReleaseSmall \
    -femit-bin="$OUT/probe_zig.dll" modules/zig/module.zig
}
build_go() {
  go version && (cd modules/go && CGO_ENABLED=1 CC=gcc go build -buildmode=c-shared -o ../../$OUT/probe_go.dll .)
}
for l in c rust zig go; do step $l build_$l; done
for f in "$OUT"/*.dll; do
  echo "== $f $(stat -c %s "$f") bytes"; objdump -p "$f" | grep -E "probe_[a-z]+_module" || echo "  (export not found)"
done
cat "$OUT/status.txt"

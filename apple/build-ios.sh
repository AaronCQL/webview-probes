#!/bin/bash
# Builds four static module libraries for the iOS simulator (arm64) and links
# them all into one simulator app at build/ios/Probe.app.
# Each module step is allowed to fail; failures are recorded in build/ios/status.txt
# and the app links whatever succeeded (missing modules get a stub returning NULL).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=build/ios
mkdir -p "$OUT"
: > "$OUT/status.txt"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TGT=arm64-apple-ios15.0-simulator
CLANG=$(xcrun --sdk iphonesimulator -f clang)
export IPHONEOS_DEPLOYMENT_TARGET=15.0
LIBS=()
STUBS=""

step() { # name, command...
  local name=$1; shift
  echo "::group::module $name"
  if "$@" > "$OUT/$name.log" 2>&1; then
    echo "$name ok" | tee -a "$OUT/status.txt"; cat "$OUT/$name.log"; echo "::endgroup::"; return 0
  else
    echo "$name FAILED" | tee -a "$OUT/status.txt"; cat "$OUT/$name.log"; echo "::endgroup::"; return 1
  fi
}

build_c() {
  "$CLANG" -target $TGT -isysroot "$SDK" -O2 -Imodules/include -c modules/c/module.c -o "$OUT/c.o" &&
    ar rcs "$OUT/libprobe_c.a" "$OUT/c.o"
}
build_rust() {
  rustup target add aarch64-apple-ios-sim &&
    cargo build --release --manifest-path modules/rust/Cargo.toml --target aarch64-apple-ios-sim &&
    cp modules/rust/target/aarch64-apple-ios-sim/release/libprobe_rust.a "$OUT/"
}
build_zig() {
  zig version && zig build-lib -target aarch64-ios-simulator -O ReleaseSmall -fPIC \
    -femit-bin="$OUT/libprobe_zig.a" modules/zig/module.zig
}
build_go() {
  go version &&
    (cd modules/go && CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$CLANG" \
      CGO_CFLAGS="-target $TGT -isysroot $SDK -O2" CGO_LDFLAGS="-target $TGT -isysroot $SDK" \
      go build -buildmode=c-archive -o "../../$OUT/libprobe_go.a" .)
}

for lang in c rust zig go; do
  if step "$lang" "build_$lang"; then
    LIBS+=("$OUT/libprobe_$lang.a")
  else
    STUBS+="const pm_module *probe_${lang}_module(void) { return 0; }"$'\n'
  fi
done
for l in "${LIBS[@]}"; do echo "== $l"; lipo -info "$l" || true; done

if [ -n "$STUBS" ]; then
  printf '#include "probe_module.h"\n%s' "$STUBS" > "$OUT/stubs.c"
  "$CLANG" -target $TGT -isysroot "$SDK" -Imodules/include -c "$OUT/stubs.c" -o "$OUT/stubs.o"
  LIBS+=("$OUT/stubs.o")
fi

APP="$OUT/Probe.app"
rm -rf "$APP"; mkdir -p "$APP"
EXTRA_SWIFT=()
[ -f "$OUT/stockfish/libstockfish.a" ] && EXTRA_SWIFT=(apple/ios/Stockfish.swift "$OUT/stockfish/libstockfish.a" -lc++) || EXTRA_SWIFT=(apple/ios/StockfishStub.swift)
echo "::group::link app"
xcrun --sdk iphonesimulator swiftc -O -swift-version 5 -target $TGT -sdk "$SDK" -parse-as-library \
  -import-objc-header apple/ios/Bridge.h -Imodules/include \
  apple/Probe.swift apple/ios/App.swift apple/ios/Modules.swift "${EXTRA_SWIFT[@]}" \
  "${LIBS[@]}" -framework CoreFoundation -framework Security -lresolv \
  -o "$APP/Probe" 2>&1 | tee "$OUT/link.log"
rc=${PIPESTATUS[0]}
echo "::endgroup::"
[ $rc -eq 0 ] || { echo "link FAILED" | tee -a "$OUT/status.txt"; exit 1; }
echo "link ok" | tee -a "$OUT/status.txt"
cp apple/ios/Info.plist "$APP/"
cp -R web "$APP/web"
codesign --force --sign - "$APP"
# which runtimes ended up in the binary
for s in _probe_c_module _probe_rust_module _probe_zig_module _probe_go_module _x_cgo_init _rust_eh_personality; do
  if nm "$APP/Probe" | grep -q " $s\$"; then echo "symbol $s present"; else echo "symbol $s absent"; fi
done | tee -a "$OUT/status.txt"
ls -la "$APP"

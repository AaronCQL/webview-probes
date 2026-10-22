#!/bin/bash
# Builds official Stockfish as a static library for the iOS simulator (arm64).
# main() is renamed so the app can call it on a thread; NNUE nets are embedded (incbin).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/ios/stockfish
mkdir -p "$OUT/obj"
TAG=${SF_TAG:-sf_17.1}
[ -d build/Stockfish ] || git clone --depth 1 --branch "$TAG" https://github.com/official-stockfish/Stockfish build/Stockfish
make -C build/Stockfish/src net
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
CXX=$(xcrun --sdk iphonesimulator -f clang++)
FLAGS="-target arm64-apple-ios15.0-simulator -isysroot $SDK -std=c++17 -O3 -DNDEBUG -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8 -DUSE_NEON_DOTPROD -march=armv8.2-a+dotprod -fno-exceptions -Wno-everything"
cd build/Stockfish/src
for f in $(find . -name '*.cpp'); do
  o="../../../$OUT/obj/$(echo "$f" | sed 's|^\./||; s|/|_|g').o"
  extra=""
  [ "$f" = "./main.cpp" ] && extra="-Dmain=stockfish_main"
  $CXX $FLAGS $extra -c "$f" -o "$o" &
done
wait
cd - >/dev/null
cat > "$OUT/sf_entry.cpp" <<'CPP'
int stockfish_main(int argc, char* argv[]);
extern "C" int sf_entry(int argc, char* argv[]) { return stockfish_main(argc, argv); }
CPP
$CXX $FLAGS -c "$OUT/sf_entry.cpp" -o "$OUT/obj/sf_entry.o"
rm -f "$OUT/libstockfish.a"
ar rcs "$OUT/libstockfish.a" "$OUT"/obj/*.o
ls -la "$OUT/libstockfish.a"

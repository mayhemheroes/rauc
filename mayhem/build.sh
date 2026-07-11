#!/usr/bin/env bash
#
# rauc/mayhem/build.sh — build rauc's two OSS-Fuzz harnesses as sanitized libFuzzer targets
# (+ standalone reproducers), plus a self-contained manifest-parse golden oracle for mayhem/test.sh.
#
# Fuzzed surface (attacker-controlled RAUC update artifacts parsed by librauc):
#   manifest_fuzzer — fuzz/manifest.c drives load_manifest_mem(): a RAUC manifest is a GKeyFile
#                     ([update]/[bundle]/[image.*]/[handler]/[hooks]/[meta.*]); parse + validate.
#   bundle_fuzzer   — fuzz/bundle.c writes the input to a temp .raucb and drives check_bundle()
#                     with CHECK_BUNDLE_NO_VERIFY: parses the bundle container (squashfs/verity/
#                     casync/crypt framing) and the embedded manifest, signature verification off.
#
# Build model: rauc builds with meson. We reuse upstream's fuzz/meson.build (option -Dfuzzing=true,
# which selects clang's built-in -fsanitize=fuzzer for the harness) to compile librauc.a + the
# harness objects WITH $SANITIZER_FLAGS (so the parsers themselves are instrumented), then LINK each
# target ourselves so we can (a) drop in the additive nbd_stub.o that resolves the streaming-off
# r_nbd_error_quark reference (see mayhem/harnesses/nbd_stub.c) and (b) emit both a libFuzzer binary
# and a $STANDALONE_FUZZ_MAIN reproducer per harness.
#
# Build contract comes from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN. Outputs land in /mayhem (== $OUT for our deploy).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: -gdwarf-3 keeps DWARF < 4 (Mayhem triage requirement, §6.2 item 10); overridable.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${SRC:=/mayhem}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN SRC OUT MAYHEM_JOBS

cd "$SRC"

BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"

# ── 1) meson configure + build librauc.a and the harness objects, instrumented ────────────────────
# CFLAGS/CXXFLAGS carry the sanitizers; -fsanitize=fuzzer-no-link adds libFuzzer coverage callbacks to
# the whole library so the parser code is traced (the harness gets -fsanitize=fuzzer at link). The
# option set mirrors the OSS-Fuzz build: static lib, b_lundef off (sanitizer interceptors), fuzzing
# on, and every heavy/host-only subsystem (gpt/json/network/service/streaming/composefs) disabled so
# the only fuzzed surface is the manifest/bundle parser and the only extra dep is glib+openssl.
export CFLAGS="${CFLAGS:-} $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
export CXXFLAGS="${CXXFLAGS:-} $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"

meson setup "$BUILD" \
  -Ddefault_library=static \
  -Db_lundef=false \
  -Dfuzzing=true \
  -Dgpt=disabled \
  -Djson=disabled \
  -Dnetwork=false \
  -Dservice=false \
  -Dstreaming=false \
  -Dcomposefs=disabled

# Build the library + the two harness objects (the final harness link is done by hand below, so we
# stop short of meson's own broken streaming-off fuzzer link).
ninja -C "$BUILD" librauc.a \
  fuzz/manifest_fuzzer.p/manifest.c.o \
  fuzz/bundle_fuzzer.p/bundle.c.o

# ── 2) additive nbd quark shim + per-harness link (libFuzzer target + standalone reproducer) ───────
GLIB_CFLAGS="$(pkg-config --cflags glib-2.0)"
GLIB_LIBS="$(pkg-config --libs glib-2.0 gio-2.0 gio-unix-2.0 gobject-2.0 openssl)"

NBD_STUB="$BUILD/nbd_stub.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $GLIB_CFLAGS -c "$SRC/mayhem/harnesses/nbd_stub.c" -o "$NBD_STUB"

# Standalone run-once driver (reads one input file, calls LLVMFuzzerTestOneInput once). The base
# ships StandaloneFuzzTargetMain.c; compile it without the libFuzzer runtime.
STANDALONE_OBJ="$BUILD/standalone_main.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$STANDALONE_OBJ"

for harness in manifest bundle; do
  HARNESS_OBJ="$BUILD/fuzz/${harness}_fuzzer.p/${harness}.c.o"

  # libFuzzer target -> /mayhem/<harness>_fuzzer
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
      "$HARNESS_OBJ" "$NBD_STUB" \
      -Wl,--start-group "$BUILD/librauc.a" -Wl,--end-group \
      -pthread $GLIB_LIBS \
      -o "$OUT/${harness}_fuzzer"

  # standalone reproducer (no libFuzzer runtime) -> /mayhem/<harness>_fuzzer-standalone
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
      "$HARNESS_OBJ" "$STANDALONE_OBJ" "$NBD_STUB" \
      -Wl,--start-group "$BUILD/librauc.a" -Wl,--end-group \
      -pthread $GLIB_LIBS \
      -o "$OUT/${harness}_fuzzer-standalone"

  echo "built ${harness}_fuzzer (+ standalone)"
done

# ── 3) self-contained golden oracle for mayhem/test.sh (manifest-parse known-answer test) ──────────
# Compiled + linked WITH sanitizers (so it exercises the instrumented parser) but NO libFuzzer.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $GLIB_CFLAGS -DG_LOG_DOMAIN='"rauc"' -D_GNU_SOURCE \
    -include "$BUILD/config.h" -I"$SRC/include" \
    -c "$SRC/mayhem/harnesses/manifest_oracle.c" -o "$BUILD/manifest_oracle.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS \
    "$BUILD/manifest_oracle.o" "$NBD_STUB" \
    -Wl,--start-group "$BUILD/librauc.a" -Wl,--end-group \
    -pthread $GLIB_LIBS \
    -o "$OUT/manifest_oracle"
echo "built manifest_oracle (golden test)"

echo "build.sh complete:"
ls -la "$OUT/manifest_fuzzer" "$OUT/bundle_fuzzer" \
       "$OUT/manifest_fuzzer-standalone" "$OUT/bundle_fuzzer-standalone" \
       "$OUT/manifest_oracle" 2>&1 || true

#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS OpenEXR's own test binaries (built by mayhem/build.sh into build.test/) plus
# known-answer probes of the command-line tools. Behavioral oracle: a test counts as passed only when it
# exits 0 AND prints its own success marker ("ok" / "Running <name>"), and every probe asserts exact
# header values, so a program neutered to exit(0) fails. Does not compile.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


TB="$SRC/build.test"
BIN="$TB/bin"
IMG="$SRC/src/test/OpenEXRTest"
for b in IexTest OpenEXRCoreTest OpenEXRTest OpenEXRUtilTest exrheader exrinfo exrmaketiled exrstdattr; do
  [ -x "$BIN/$b" ] || { echo "missing $BIN/$b — mayhem/build.sh must build it" >&2; emit_ctrf "openexr-tests" 0 1 0; exit 1; }
done

RES="$(mktemp -d)"
trap 'rm -rf "$RES"' EXIT

# run_one <binary> <test-name>: pass iff rc==0 and the suite printed its own marker.
run_one() {
  local bin="$1" name="$2" log rc
  log="$RES/${bin}.${name}.log"
  if [ "$bin" = IexTest ]; then "$BIN/$bin" >"$log" 2>&1; else "$BIN/$bin" "$name" >"$log" 2>&1; fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $bin $name (rc=$rc)" >"$RES/${bin}.${name}.res"; tail -n 20 "$log" >&2; return
  fi
  # Each runner prints its own completion marker; a neutered (exit(0)) binary prints nothing.
  if { [ "$bin" = OpenEXRCoreTest ] && grep -qx "Running $name" "$log"; } ||
     { [ "$bin" = IexTest ] && grep -qE '^ ?ok$' "$log"; } ||
     { [ "$bin" != OpenEXRCoreTest ] && [ "$bin" != IexTest ] && grep -qE '^removing temp(orary)? dir' "$log"; }; then
    echo "PASS $bin $name" >"$RES/${bin}.${name}.res"
  else
    echo "FAIL $bin $name (no success marker)" >"$RES/${bin}.${name}.res"; tail -n 20 "$log" >&2
  fi
}
export -f run_one
export BIN RES

CORE_TESTS="$(cd "$TB" && ctest -N -R '^OpenEXRCore\.' | sed -n 's/^ *Test *#[0-9]*: OpenEXRCore\.//p')"
[ -n "$CORE_TESTS" ] || { echo "no OpenEXRCore tests listed by ctest" >&2; emit_ctrf "openexr-tests" 0 1 0; exit 1; }

FAST_TESTS="testCpuId testDwaLookups testXdr testAttributes testBadTypeAttributes testCustomAttributes
 testExistingStreamsUTF8 testHeader testLineOrder testLut testMagic testMultiPartSharedAttributes testMultiView
 testPartHelper testBackwardCompatibility testCompressionApi testDeepScanLineMultipleRead testIsComplete
 testPreviewImage testSampleImages testWav testLJ2KBoundary testMultiScanlinePartThreading testStandardAttributes
 testNativeFormat testTiledYa testMultiPartApi testChannels testExistingStreams testCopyPixels testFutureProofing
 testInputPart testRle testTiledCompression testMultiPartThreading testConversion testCRgba testRgba
 testCompositeDeepScanLine testCopyMultiPartFile testYca"
UTIL_TESTS="testImageChannel testIO testFlatImage"

{
  echo "IexTest IexTest"
  for t in $CORE_TESTS; do echo "OpenEXRCoreTest $t"; done
  for t in $FAST_TESTS; do echo "OpenEXRTest $t"; done
  for t in $UTIL_TESTS; do echo "OpenEXRUtilTest $t"; done
} | xargs -P "$MAYHEM_JOBS" -L 1 bash -c 'run_one "$0" "$1"'

# Known-answer probes of the CLI tools (dynamically linked; exact values from the committed images).
# kat <name> <command...>: stdin holds expected lines; each must appear verbatim in the command's stdout.
kat() {
  local name="$1"; shift
  local out line ok=1
  out="$("$@" 2>/dev/null)"
  while IFS= read -r line; do
    printf '%s\n' "$out" | grep -qxF -- "$line" || { echo "KAT $name: missing line: $line" >&2; ok=0; }
  done
  if [ "$ok" = 1 ]; then echo "PASS kat $name" >"$RES/kat.$name.res"; else echo "FAIL kat $name" >"$RES/kat.$name.res"; fi
}

kat header-scanline "$BIN/exrheader" "$IMG/v1.7.test.1.exr" <<'KATEOF'
compression (type compression): zip: zlib/deflate compression, in blocks of 16 scan lines.
dataWindow (type box2i): (20 20) - (197 174)
displayWindow (type box2i): (0 0) - (216 196)
    Z, 32-bit floating-point, sampling 1 1
type (type string): "scanlineimage"
KATEOF
kat header-tiled "$BIN/exrheader" "$IMG/tiled.exr" <<'KATEOF'
dataWindow (type box2i): (0 0) - (59 56)
    tile size 20 by 20 pixels
type (type string): "tiledimage"
KATEOF
kat header-dwaa "$BIN/exrheader" "$IMG/comp_dwaa_v2.exr" <<'KATEOF'
compression (type compression): dwaa: lossy DCT based compression, in blocks of 32 scanlines. More efficient for partial buffer access.
dataWindow (type box2i): (0 0) - (586 674)
dwaCompressionLevel (type float): 85
KATEOF
kat info "$BIN/exrinfo" "$IMG/v1.7.test.1.exr" <<'KATEOF'
  compression: 'zip'
  displayWindow: [ 0, 0 - 216 196 ] 217 x 197
  dataWindow: [ 20, 20 - 197 174 ] 178 x 155
   'Z': float samp 1 1
KATEOF
# Write path: retile a scanline image, stamp a comment, read both results back.
"$BIN/exrmaketiled" -t 16 16 "$IMG/v1.7.test.1.exr" "$RES/tiled.exr" >/dev/null 2>&1
kat maketiled "$BIN/exrheader" "$RES/tiled.exr" <<'KATEOF'
    tile size 16 by 16 pixels
type (type string): "tiledimage"
dataWindow (type box2i): (20 20) - (197 174)
KATEOF
"$BIN/exrstdattr" -comments "mayhem-kat" "$RES/tiled.exr" "$RES/stamped.exr" >/dev/null 2>&1
kat stdattr "$BIN/exrheader" "$RES/stamped.exr" <<'KATEOF'
comments (type string): "mayhem-kat"
    tile size 16 by 16 pixels
KATEOF

passed="$(cat "$RES"/*.res 2>/dev/null | grep -c '^PASS')"
failed="$(cat "$RES"/*.res 2>/dev/null | grep -c '^FAIL')"
cat "$RES"/*.res 2>/dev/null | grep '^FAIL' >&2 || true
# A test that produced no result at all (never ran) counts as a failure.
expected=$(( 1 + $(echo "$CORE_TESTS" | wc -w) + $(echo "$FAST_TESTS" | wc -w) + $(echo "$UTIL_TESTS" | wc -w) + 6 ))
missing=$(( expected - passed - failed ))
[ "$missing" -gt 0 ] && failed=$(( failed + missing ))
emit_ctrf "openexr-tests" "$passed" "$failed" 0

#!/usr/bin/env bash
#
# mayhem/build.sh — builds the OpenEXR fuzz harnesses (sanitized, libFuzzer + standalone reproducers)
# and the project's own test suite (normal flags). Runs in the commit image as `mayhem` in /mayhem.
# Air-gapped: Imath (the only fetched dependency) is read from the in-image checkout at
# $OPENEXR_IMATH_SRC (Dockerfile), never from the network. Re-runnable on an already-built tree.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${OPENEXR_IMATH_SRC:=/opt/toolchains/deps/Imath}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

FUZZERS="openexr_attribute_fuzzer openexr_encoding_fuzzer openexr_exrcheck_fuzzer \
openexr_exrcorecheck_fuzzer openexr_exrgaps_fuzzer openexr_htj2k_fuzzer openexr_roundtrip_fuzzer"

# CMake takes the compiler from the exported CC/CXX (by name). The image's ccache pre-fill resolves them to its
# masquerade dir while a plain re-run resolves /usr/bin; CMake's own "compiler changed" cache wipe then breaks
# the Imath reconfigure, so on a mismatch drop the stale configure state ourselves first.
reset_if_compiler_changed() {
  local cache="$1/CMakeCache.txt" cur
  [ -f "$cache" ] || return 0
  cur="$(command -v "$CXX")"
  grep -qx "CMAKE_CXX_COMPILER:[A-Z]*=$cur" "$cache" || rm -rf "$cache" "$1/CMakeFiles"
}
# Shared by both trees: vendored OpenJPH/libdeflate, Imath from the in-image checkout, static libs.
COMMON_CMAKE="-G \"Unix Makefiles\" \
 -DBUILD_SHARED_LIBS=OFF -DOPENEXR_FORCE_INTERNAL_IMATH=ON -DOPENEXR_FORCE_INTERNAL_DEFLATE=ON \
 -DOPENEXR_FORCE_INTERNAL_OPENJPH=ON -DOPENEXR_BUILD_EXAMPLES=OFF -DOPENEXR_BUILD_DOCS=OFF \
 -DOPENEXR_BUILD_PYTHON=OFF -DOPENEXR_INSTALL=OFF -DOPENEXR_INSTALL_TOOLS=OFF \
 -DFETCHCONTENT_SOURCE_DIR_IMATH=$OPENEXR_IMATH_SRC -DFETCHCONTENT_FULLY_DISCONNECTED=ON"

# 1) Sanitized fuzz tree. LeakSanitizer is switched off at build time by linking lsan_off.o.
FB="$SRC/build.fuzz"
mkdir -p "$FB"
reset_if_compiler_changed "$FB"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FB/lsan_off.o"
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN"   -o "$FB/standalone_main.o"

# The oss-fuzz CMake only enables its targets when $LIB_FUZZING_ENGINE is set; the fuzzer link line
# is rewritten below for the standalone reproducers.
FUZZ_CF="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
eval cmake -S "$SRC" -B "$FB" $COMMON_CMAKE \
  -DCMAKE_BUILD_TYPE= \
  -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_BUILD_OSS_FUZZ=ON \
  -DCMAKE_C_FLAGS=\"$FUZZ_CF\" -DCMAKE_CXX_FLAGS=\"$FUZZ_CF\" \
  -DCMAKE_EXE_LINKER_FLAGS=\"$SANITIZER_FLAGS $FB/lsan_off.o\"
cmake --build "$FB" --target oss_fuzz -j"$MAYHEM_JOBS"

# 2) Install the libFuzzer binaries and derive the standalone ones by re-linking with the run-once driver.
for f in $FUZZERS; do
  cp "$FB/src/test/oss-fuzz/$f" "$SRC/$f"
  ( cd "$FB/src/test/oss-fuzz"
    link="$(cat "CMakeFiles/$f.dir/link.txt")"
    link="${link//-fsanitize=fuzzer / $FB/standalone_main.o }"
    link="${link//-o $f /-o $SRC/$f-standalone }"
    eval "$link" )
done

# 3) The project's own test suite and tools, normal flags (independent of the sanitized tree).
TB="$SRC/build.test"
reset_if_compiler_changed "$TB"
eval cmake -S "$SRC" -B "$TB" $COMMON_CMAKE \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON -DOPENEXR_BUILD_TOOLS=ON \
  -DCMAKE_C_FLAGS=\"$COVERAGE_FLAGS\" -DCMAKE_CXX_FLAGS=\"$COVERAGE_FLAGS\"
cmake --build "$TB" -j"$MAYHEM_JOBS" \
  --target IexTest OpenEXRCoreTest OpenEXRTest OpenEXRUtilTest exrheader exrinfo exrstdattr exrmaketiled

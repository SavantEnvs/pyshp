#!/usr/bin/env bash
#
# mayhem/build.sh — build the pyshp fuzz harness + ready the functional test suite.
#
# pyshp is PURE PYTHON (a single module, src/shapefile.py). The "fuzzed code" is
# shapefile.Reader parsing an attacker-controlled .shp byte stream. Mayhem targets
# must be a native ELF that libFuzzer drives (fuzz-smoke + the DWARF gate), so we
# compile a small C driver (mayhem/fuzz_shp_driver.c) that EMBEDS CPython and
# dispatches each input into fuzz_shapefile.TestOneInput — the parser stays 100%
# Python, the target is a real libFuzzer ELF carrying DWARF < 4 symbols.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base
# image exports the build contract (CC, CXX, SANITIZER_FLAGS, DEBUG_FLAGS,
# LIB_FUZZING_ENGINE, STANDALONE_FUZZ_MAIN, SRC). Idempotent + air-gapped: a wheelhouse
# is baked into the image (mayhem/Dockerfile) so the offline PATCH re-run installs from
# it with --no-index; recompiling the harness on the already-built tree just re-links.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the environment (overridable), with sane fallbacks.
# SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty value (the sanitizer
# off-switch) is honored; the others default on empty too.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS SRC

cd "$SRC"

# ---------------------------------------------------------------------------
# 1) Install the project + its test deps into a fixed, $HOME-independent venv so
#    mayhem/test.sh only RUNS the suite. Pure Python: no sanitizer build here —
#    the suite is the honest functional oracle (project's NORMAL install).
#    --no-index --find-links keeps it air-gapped (resolves from the wheelhouse).
# ---------------------------------------------------------------------------
VENV="${PYSHP_VENV:-/opt/toolchains/python/venv}"
# `--copies`: put a REAL interpreter binary at the venv path (not a symlink to the
# system python). Two reasons: (1) it lives at a fixed $HOME-independent location,
# and (2) the anti-reward-hack sabotage check neuters non-system executables — a
# symlinked venv resolves /proc/self/exe to /usr/bin/python3 (a SPARED system path),
# so the neuter would miss the program-under-test and the oracle would look blind.
# A copied interpreter under /opt/toolchains IS neutered, so a no-op'd shapefile.py
# (or interpreter) makes the suite fail, proving the oracle is behavioral (§6.3).
if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv --copies "$VENV"
fi

# BASE predates pyproject.toml/src/: the module is $SRC/shapefile.py and the suite is its README
# doctests (`python shapefile.py`), run in place by test.sh. Nothing to install into the venv; it only
# supplies the interpreter test.sh runs (pip stays available for the offline wheelhouse).
"$VENV/bin/python" -c "import sys; print('build.sh: venv python', sys.version.split()[0])"

# ---------------------------------------------------------------------------
# 2) Build the native fuzz harness ELF that embeds CPython. The driver itself is
#    instrumented with $SANITIZER_FLAGS + $DEBUG_FLAGS (DWARF < 4); libpython is
#    linked via python3-config --embed. PYSHP_PATHS points sys.path at the harness
#    dir + the pyshp source so the parser imports the in-tree shapefile.py.
# ---------------------------------------------------------------------------
PYCFG="${PYTHON_CONFIG:-python3-config}"
PY_CFLAGS="$("$PYCFG" --cflags)"
PY_EMBED_LDFLAGS="$("$PYCFG" --embed --ldflags 2>/dev/null || "$PYCFG" --ldflags)"

# Defines: which dirs to PREPEND to sys.path. Tokens are inserted at position 0
# in order, so the LAST token ends up FIRST — list mayhem then $SRC so $SRC
# (the in-tree, patchable shapefile.py) wins over any installed copy, with the
# harness dir ($SRC/mayhem, holding fuzz_shapefile.py) right after.
DEFS=(
  -DPYSHP_MODULE='"fuzz_shapefile"'
  -DPYSHP_FUNC='"TestOneInput"'
  -DPYSHP_PATHS="\"$SRC/mayhem:$SRC\""
)

# 2a) The fuzzer binary (linked against the libFuzzer engine).
# shellcheck disable=SC2086
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS $PY_CFLAGS "${DEFS[@]}" $LIB_FUZZING_ENGINE \
  "$SRC/mayhem/fuzz_shp_driver.c" \
  -o /mayhem/fuzz_shp \
  $PY_EMBED_LDFLAGS

# 2b) The standalone (NON-fuzzer) run-once reproducer (linked against the LLVM
#     standalone driver instead of the libFuzzer engine). Respects $SANITIZER_FLAGS.
# shellcheck disable=SC2086
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS $PY_CFLAGS "${DEFS[@]}" \
  "$STANDALONE_FUZZ_MAIN" \
  "$SRC/mayhem/fuzz_shp_driver.c" \
  -o /mayhem/fuzz_shp-standalone \
  $PY_EMBED_LDFLAGS

echo "build.sh: built /mayhem/fuzz_shp (+ -standalone) and installed the test venv"

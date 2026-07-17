#!/usr/bin/env bash
#
# mayhem/test.sh — RUN pyshp's own pytest suite (the functional oracle).
#
# build.sh already created the venv and installed pyshp (editable) + pytest +
# hypothesis. This script only RUNS the suite and maps the result to a CTRF
# summary; it never compiles or installs.
#
# The suite is BEHAVIORAL: pyshp's tests assert decoded shapes/records/field
# values and diff round-tripped output, so a PATCH that neuters shapefile.py to a
# no-op (exit 0) produces wrong/empty results and FAILS here — satisfying the
# anti-reward-hacking oracle requirement (§6.3).
#
# We deselect `network` (needs the internet — unavailable offline / in the
# air-gapped re-run) and `slow` (long benchmarks) so the oracle is fast and
# deterministic. The remaining suite still exercises the full read/write/decode
# surface with real assertions.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

VENV="${PYSHP_VENV:-/opt/toolchains/python/venv}"
PY="$VENV/bin/python"
if [ ! -x "$PY" ]; then
  echo "test.sh: venv python missing at $PY — build.sh must run first" >&2
  emit_ctrf_fail() { :; }
  # Fall through to emit a failing CTRF below.
fi

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker); returns non-zero iff failed>0.
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

if [ ! -x "$PY" ]; then
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

JUNIT="$(mktemp /tmp/pyshp-junit.XXXXXX.xml)"
# Run the suite, emit JUnit XML for machine-readable counts. Don't let a non-zero
# pytest exit abort the script before we parse + emit CTRF.
set +e
"$PY" -m pytest tests/test_shapefile.py \
  -m "not network and not slow" \
  -p no:cacheprovider \
  -q --no-header \
  --junit-xml="$JUNIT"
set -e

# Map JUnit -> CTRF counts.
read -r P F S < <("$PY" - "$JUNIT" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except Exception:
    print("0 1 0"); sys.exit(0)
suites = root.findall("testsuite") or ([root] if root.tag == "testsuite" else [])
tests = errors = failures = skipped = 0
for s in suites:
    tests   += int(s.get("tests", 0))
    errors  += int(s.get("errors", 0))
    failures+= int(s.get("failures", 0))
    skipped += int(s.get("skipped", 0))
failed = errors + failures
passed = tests - failed - skipped
if passed < 0:
    passed = 0
print(f"{passed} {failed} {skipped}")
PY
)
rm -f "$JUNIT"

emit_ctrf "pytest" "${P:-0}" "${F:-1}" "${S:-0}"

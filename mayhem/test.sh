#!/usr/bin/env bash
#
# mayhem/test.sh — RUN pyshp's own README doctests (the functional oracle).
#
# build.sh already created the venv. This script only RUNS the doctests and maps the result to a
# CTRF summary; it never compiles or installs.
#
# The suite is BEHAVIORAL: the README examples assert decoded shapes/records/field values and
# written files' content, so a PATCH that neuters shapefile.py to a no-op (exit 0) produces
# wrong/empty results and FAILS here — satisfying the anti-reward-hacking oracle requirement (§6.3).
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

# The suite is README.md's doctests (what upstream's `python shapefile.py` runs): every example
# asserts a decoded shape/record/field value or a written file's content. Count examples via doctest.
set +e
OUT="$("$PY" - <<'PY'
import doctest, io, sys
sys.path.insert(0, ".")
import shapefile
with open("README.md", "rb") as fobj:
    text = fobj.read().decode("utf8").replace("\r\n", "\n")
test = doctest.DocTestParser().get_doctest(string=text, globs={}, name="README", filename="README.md", lineno=0)
runner = doctest.DocTestRunner(verbose=False)
failed, attempted = runner.run(test)
print("DOCTEST %d %d" % (attempted, failed))
PY
)"
RC=$?
set -e
printf '%s\n' "$OUT" | tail -40
read -r P F < <(printf '%s\n' "$OUT" | awk '/^DOCTEST /{print $2-$3, $3}' | tail -1)
if [ -z "${P:-}" ] || [ "$RC" -ne 0 ]; then
  emit_ctrf "doctest" "${P:-0}" "$(( ${F:-0} > 0 ? ${F:-0} : 1 ))" 0
else
  emit_ctrf "doctest" "$P" "$F" 0
fi

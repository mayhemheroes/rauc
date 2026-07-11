#!/usr/bin/env bash
#
# rauc/mayhem/test.sh — RUN the self-contained manifest-parse golden oracle (built by
# mayhem/build.sh) and emit a CTRF summary. exit 0 iff the oracle passes.
#
# Why not rauc's own meson suite: most of it (bundle/install/dm/signature/update_handler) needs
# root, loopback mounts and a fakeroot/dm environment that isn't available at image-build time.
# Instead the oracle (mayhem/harnesses/manifest_oracle.c) is a known-answer test on the exact fuzzed
# entry point (load_manifest_mem): it parses a well-formed manifest and asserts the decoded fields,
# then asserts a malformed manifest (mandatory `compatible` missing) is rejected. This is a real
# PATCH-grade oracle — a no-op / "return TRUE" change to the parser fails either the field asserts
# or the reject assert. This script only RUNS the prebuilt binary; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}" ; : "${OUT:=/mayhem}"

ORACLE="$OUT/manifest_oracle"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if [ ! -x "$ORACLE" ]; then
  echo "missing $ORACLE — run mayhem/build.sh first" >&2
  emit_ctrf "rauc-manifest-oracle" 0 1 0; exit 2
fi

echo "=== running manifest-parse golden oracle ==="
# detect_leaks=0: glib interns strings / one-time allocations the oracle intentionally doesn't free.
out="$(ASAN_OPTIONS=detect_leaks=0 "$ORACLE" 2>&1)"; rc=$?
echo "$out"

# Oracle prints: ORACLE passed=<n> failed=<m>
PASSED=$(printf '%s\n' "$out" | sed -n 's/.*passed=\([0-9][0-9]*\).*/\1/p' | tail -1)
FAILED=$(printf '%s\n' "$out" | sed -n 's/.*failed=\([0-9][0-9]*\).*/\1/p' | tail -1)
: "${PASSED:=0}" "${FAILED:=0}"

# If the oracle crashed before printing a parseable line, trust its exit code.
if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "could not parse oracle output; using exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "rauc-manifest-oracle" 1 0 0; exit 0; }
  emit_ctrf "rauc-manifest-oracle" 0 1 0; exit 1
fi

# A nonzero exit (e.g. ASan/UBSan abort) is a failure even if asserts printed 0.
[ "$rc" -ne 0 ] && FAILED=$(( FAILED > 0 ? FAILED : 1 ))

emit_ctrf "rauc-manifest-oracle" "$PASSED" "$FAILED" 0

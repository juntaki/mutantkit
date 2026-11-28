#!/usr/bin/env bash
#
# Hermetic test of orchestrate-ci.sh's exit contract using a fake `mutantkit`
# (no real CI, no real mutation run). Each case scripts what doctor/plan/run/
# gate do and asserts the orchestration's exit code and log content:
# a failing `run` must never be turned into success by a passing gate, a
# genuine gate failure keeps its code, and a gate result that cannot be
# persisted fails closed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
orchestrate="$here/orchestrate-ci.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

mkdir -p "$work/bin"
cat > "$work/bin/mutantkit" <<'FAKE'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
case "$cmd" in
  doctor|plan) echo "$cmd" >> "$CALL_LOG"; [ "$cmd" = plan ] && [ -n "${FAKE_PLAN_EXIT:-}" ] && exit "$FAKE_PLAN_EXIT"; exit "${FAKE_DOCTOR_PLAN_EXIT:-0}" ;;
  run)
    if [ "${1:-}" = "--help" ]; then echo "--also-report"; exit 0; fi
    echo run >> "$CALL_LOG"
    if [ "${FAKE_RUN_WRITES_REPORT:-1}" = 1 ]; then echo '{"report":true}' > "$REPORT_JSON_PATH"; fi
    exit "${FAKE_RUN_EXIT:-0}" ;;
  gate)
    if [ "${1:-}" = "--help" ]; then echo "--json"; exit 0; fi
    echo gate >> "$CALL_LOG"
    [ "${FAKE_GATE_EMPTY:-0}" = 1 ] && exit "${FAKE_GATE_EXIT:-0}"
    echo '{"schemaVersion":1,"passed":'"${FAKE_GATE_PASSED:-true}"',"violations":[]}'
    exit "${FAKE_GATE_EXIT:-0}" ;;
  --version) echo "mutantkit fake"; exit 0 ;;
esac
FAKE
chmod +x "$work/bin/mutantkit"

# case <name> <expected-exit> <log-grep or ""> [VAR=value ...]
run_case() {
  local name="$1" expected="$2" pattern="$3"; shift 3
  local root="$work/$name"
  mkdir -p "$root"
  local log="$root.log" rc=0
  env PATH="$work/bin:$PATH" PROJECT_ROOT="$root" PLAN_PATH="$root/plan.json" \
    REPORT_JSON_PATH="$root/report.json" GATE_RESULT_PATH="$root/gate-result.json" \
    GITHUB_OUTPUT="$root/out" CALL_LOG="$root/calls" "$@" "$orchestrate" > "$log" 2>&1 || rc=$?
  if [ "$rc" != "$expected" ]; then
    echo "FAIL $name: exit $rc, expected $expected"; sed 's/^/    /' "$log"; failures=$((failures+1)); return
  fi
  if [ -n "$pattern" ] && ! grep -q -- "$pattern" "$log"; then
    echo "FAIL $name: log lacks '$pattern'"; sed 's/^/    /' "$log"; failures=$((failures+1)); return
  fi
  if ! grep -q '^baseline-applied=false$' "$root/out"; then
    echo "FAIL $name: baseline-applied output not written exactly once as false"; failures=$((failures+1)); return
  fi
  echo "ok   $name"
}

# assert_not_called <case> <subcommand>: the fake never saw that subcommand.
assert_not_called() {
  if grep -qx "$2" "$work/$1/calls" 2>/dev/null; then
    echo "FAIL $1: '$2' ran but must have been skipped"; failures=$((failures+1))
  fi
}

run_case clean-pass               0 '"passed":true'
run_case run-fails-gate-passes    1 'the job fails on the run failure' FAKE_RUN_EXIT=1
run_case run-interrupted-partial  7 'the job fails on the run failure' FAKE_RUN_EXIT=7
run_case run-integrity-gate-ok    2 'the job fails on the run failure' FAKE_RUN_EXIT=2
run_case quality-failure-surfaces 4 '"passed":false' FAKE_GATE_EXIT=4 FAKE_GATE_PASSED=false
run_case run-and-gate-both-fail   2 'gate exited 4' FAKE_RUN_EXIT=2 FAKE_GATE_EXIT=4
run_case doctor-fails-fatal       1 '' FAKE_DOCTOR_PLAN_EXIT=1
assert_not_called doctor-fails-fatal run
assert_not_called doctor-fails-fatal gate
run_case plan-fails-fatal         1 '' FAKE_PLAN_EXIT=1
assert_not_called plan-fails-fatal run
run_case run-fails-no-report      1 'the job fails on the run failure' FAKE_RUN_EXIT=1 FAKE_RUN_WRITES_REPORT=0 FAKE_GATE_EXIT=1
# gate exits 0 but its verdict was lost (empty result): fail closed.
run_case gate-result-empty        1 'missing or empty' FAKE_GATE_EMPTY=1
# Persistence failure: the result path's directory is read-only, so the
# redirect cannot create gate-result.json (gate itself never starts).
mkdir -p "$work/persist-fail/ro"
chmod 555 "$work/persist-fail/ro"
run_case gate-result-unwritable   1 'missing or empty' \
  GATE_RESULT_PATH="$work/persist-fail/ro/gate-result.json"
chmod 755 "$work/persist-fail/ro"

if [ "$failures" -ne 0 ]; then echo "$failures case(s) failed"; exit 1; fi
echo "orchestrate-ci selftest: all cases passed"

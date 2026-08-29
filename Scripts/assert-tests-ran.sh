#!/usr/bin/env bash
# `swift test --filter <pattern>` exits 0 and reports "passed" even when the
# filter matched zero tests. A typo'd filter, a renamed or deleted test suite
# whose CI entry was never updated, or any other classifier/metadata error
# would otherwise produce a silently green job that validated nothing at all.
#
# Usage: assert-tests-ran.sh <log-file> <description-for-the-error-message>
#
# Reads the final "Test run with N tests..." line Swift Testing always
# prints (pass or fail) and fails loudly if N is zero or was not found at
# all -- an unparseable log is treated the same as zero, per this policy's
# own "unknown -> run(and therefore: fail if nothing ran)" stance, not
# assumed harmless.
set -euo pipefail

log_file="$1"
description="$2"

if [ ! -f "$log_file" ]; then
  echo "::error::${description}: expected log file '${log_file}' does not exist -- cannot confirm any test ran"
  exit 1
fi

run_count="$(grep -oE 'Test run with [0-9]+ tests?' "$log_file" | tail -1 | grep -oE '[0-9]+' || true)"

if [ -z "$run_count" ]; then
  echo "::error::${description}: could not find a 'Test run with N tests' summary line in ${log_file} -- treating as zero, not as a harmless format change"
  exit 1
fi

if [ "$run_count" -eq 0 ]; then
  echo "::error::${description}: matched zero tests -- a classifier/filter/typo error must fail CI, not silently pass"
  exit 1
fi

echo "assert-tests-ran: ${description} ran ${run_count} test(s) -- OK"

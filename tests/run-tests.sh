#!/bin/sh
# tests/run-tests.sh - Test suite for fras-check.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/skills/fras-map/scripts/fras-check.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

PASSED_COUNT=0
FAILED_COUNT=0

log_pass() {
  echo "  [PASS] $1"
  PASSED_COUNT=$((PASSED_COUNT + 1))
}

log_fail() {
  echo "  [FAIL] $1: $2" >&2
  FAILED_COUNT=$((FAILED_COUNT + 1))
}

setup_git_repo() {
  fixture_name="$1"
  target_dir="$2"
  cp -R "$FIXTURES_DIR/$fixture_name/." "$target_dir/"
  (
    cd "$target_dir"
    git init -q
    git config user.name "FRAS Test"
    git config user.email "fras-test@example.com"
    git add -A
    git commit -q -m "initial commit"
  )
}

echo "=== Running FRAS Checker Test Suite ==="

# -------------------------------------------------------------
# 1. Valid fixture
# -------------------------------------------------------------
echo "Testing valid fixture..."
TMP_VALID="$(mktemp -d)"
setup_git_repo "valid" "$TMP_VALID"

# Normal run
if (cd "$TMP_VALID" && sh "$CHECK_SCRIPT" >/dev/null 2>&1); then
  log_pass "valid fixture exited with 0"
else
  log_fail "valid fixture" "expected exit code 0"
fi

# --stale mode
if (cd "$TMP_VALID" && sh "$CHECK_SCRIPT" --stale >/dev/null 2>&1); then
  log_pass "valid fixture --stale exited with 0"
else
  log_fail "valid fixture --stale" "expected exit code 0"
fi

# --base mode with untracked FRAS update warning
(
  cd "$TMP_VALID"
  echo "# modified" >> src/core.py
  git commit -q -am "modify core.py"
  output=$(sh "$CHECK_SCRIPT" --base HEAD~1 2>&1 || true)
  if echo "$output" | grep -q "warning file=docs/fras/core.fras"; then
    log_pass "valid fixture --base detected modified source without FRAS update"
  else
    log_fail "valid fixture --base" "warning annotation not found in output"
  fi
)
rm -rf "$TMP_VALID"

# -------------------------------------------------------------
# 2. Hard error fixtures
# -------------------------------------------------------------
run_error_test() {
  fixture="$1"
  expected_needle="$2"
  desc="$3"
  echo "Testing $desc ($fixture)..."

  TMP_ERR="$(mktemp -d)"
  setup_git_repo "$fixture" "$TMP_ERR"

  output=""
  exit_code=0
  output=$( (cd "$TMP_ERR" && sh "$CHECK_SCRIPT" 2>&1) ) || exit_code=$?

  if [ "$exit_code" -eq 1 ]; then
    if echo "$output" | grep -qi "$expected_needle"; then
      log_pass "$fixture exited with 1 and matched error needle: '$expected_needle'"
    else
      log_fail "$fixture" "exited with 1 but output did not match '$expected_needle'. Got:\n$output"
    fi
  else
    log_fail "$fixture" "expected exit code 1 but got $exit_code. Output:\n$output"
  fi

  rm -rf "$TMP_ERR"
}

run_error_test "err-format" "Invalid L2 line format" "format error"
run_error_test "err-l1-path-missing" "L1 target L2 file does not exist" "L1 -> path missing"
run_error_test "err-l2-path-not-tracked" "matches no git-tracked files" "L2 path not tracked"
run_error_test "err-l2-r-path-missing" "L2 R: target path does not exist" "L2 R: path missing"
run_error_test "err-l1-too-long" "L1 block exceeds 50 lines" "L1 exceeds 50 lines"
run_error_test "err-l2-too-long" "L2 file exceeds 80 lines" "L2 exceeds 80 lines"
run_error_test "err-test-symbol-missing" "Test reference \[T:" "test symbol missing in git grep"
run_error_test "err-private-address" "Private IP or internal hostname detected" "private address detected"

echo "========================================"
echo "Tests passed: $PASSED_COUNT, Tests failed: $FAILED_COUNT"

if [ "$FAILED_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0

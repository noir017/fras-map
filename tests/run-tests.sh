#!/bin/sh
# tests/run-tests.sh - Comprehensive test suite for fras-check.sh

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
# 1. Valid fixture & Feature tests
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

# --stale mode on clean repo
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

# --base with non-existent base ref (should warn and exit 0)
(
  cd "$TMP_VALID"
  output=$(sh "$CHECK_SCRIPT" --base deadbeef1234567890abcdef1234567890abcdef 2>&1 || true)
  status=$?
  if [ "$status" -eq 0 ] && echo "$output" | grep -q "Base ref.*does not exist in repository"; then
    log_pass "valid fixture --base with non-existent ref warned and exited 0"
  else
    log_fail "valid fixture --base with non-existent ref" "expected warning and exit 0. Got: $output"
  fi
)
rm -rf "$TMP_VALID"

# Directory entry match under --base
echo "Testing directory entry warning under --base..."
TMP_DIR_REPO="$(mktemp -d)"
(
  cd "$TMP_DIR_REPO"
  git init -q
  git config user.name "FRAS Test"
  git config user.email "fras-test@example.com"
  mkdir -p docs/fras skill
  cat << 'EOF' > AGENTS.md
# Project
## Codebase Map (FRAS)
```fras
[skill] -> docs/fras/skill.fras | F:Skill docs
```
EOF
  cat << 'EOF' > docs/fras/skill.fras
skill/ [Core]: F:Bundled skill directory
EOF
  echo "initial" > skill/SKILL.md
  git add -A && git commit -q -m "init"
  echo "modified skill" >> skill/SKILL.md
  git commit -q -am "update skill"
  output=$(sh "$CHECK_SCRIPT" --base HEAD~1 2>&1 || true)
  if echo "$output" | grep -q "warning file=docs/fras/skill.fras"; then
    log_pass "directory entry matched file change under --base"
  else
    log_fail "directory entry match" "expected warning on directory entry. Got: $output"
  fi
)
rm -rf "$TMP_DIR_REPO"

# Glob stale test: modifying non-first file in glob
echo "Testing glob stale check on non-first file..."
TMP_GLOB="$(mktemp -d)"
(
  cd "$TMP_GLOB"
  git init -q
  git config user.name "FRAS Test"
  git config user.email "fras-test@example.com"
  mkdir -p docs/fras src
  cat << 'EOF' > AGENTS.md
# Project
## Codebase Map (FRAS)
```fras
[core] -> docs/fras/core.fras | F:Core module
```
EOF
  cat << 'EOF' > docs/fras/core.fras
src/*.py [Core]: F:Core files
EOF
  echo "a" > src/a.py
  echo "b" > src/b.py
  git add -A && git commit -q -m "init"

  # Modify b.py (the second file) 5 times
  i=1
  while [ "$i" -le 5 ]; do
    echo "change $i" >> src/b.py
    git commit -q -am "change $i to b"
    i=$((i + 1))
  done

  output=$(sh "$CHECK_SCRIPT" --stale 2>&1 || true)
  if echo "$output" | grep -q "\[STALE\].*src/\*\.py.*modified 5 times"; then
    log_pass "glob stale check correctly detected commits on non-first file in glob"
  else
    log_fail "glob stale check" "expected STALE report for src/*.py. Got:\n$output"
  fi
)
rm -rf "$TMP_GLOB"

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
      log_pass "$fixture exited with 1 and matched: '$expected_needle'"
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
run_error_test "err-test-in-source" "does not match test declaration" "test name only in source declaration"
run_error_test "err-test-dot" "does not match test declaration" "test name with dot not regex matched"
run_error_test "err-priv-comment" "Private IP or internal hostname detected" "private address in comment line"
run_error_test "err-priv-multilevel" "Private IP or internal hostname detected" "multi-level .lan/.internal hostname"
run_error_test "err-api-missing" "API symbol.*not found" "missing A: symbol in target files"

echo "========================================"
echo "Tests passed: $PASSED_COUNT, Tests failed: $FAILED_COUNT"

if [ "$FAILED_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0

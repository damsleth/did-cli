#!/bin/bash
set -euo pipefail

trap 'echo "review-smoke: failed at line $LINENO" >&2' ERR

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

assert_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq "$expected" "$file"; then
    echo "Expected '$expected' in $file" >&2
    exit 1
  fi
}

make_tmp_repo() {
  local tmp
  tmp="$(mktemp -d)"
  cp -R "$REPO_ROOT" "$tmp/repo"
  echo "$tmp/repo"
}

test_help_bootstraps_env() {
  local repo out
  repo="$(make_tmp_repo)"
  rm -f "$repo/.env"
  out="$repo/help.out"

  (cd "$repo" && ./did-cli.zsh help >"$out" 2>&1)

  test -f "$repo/.env"
  assert_contains "$out" "did-cli - Command-line interface for did"
}

test_config_bootstraps_and_escapes() {
  local repo out cookie
  repo="$(make_tmp_repo)"
  rm -f "$repo/.env"
  out="$repo/config.out"
  cookie=$'abc\'d value'

  (cd "$repo" && ./did-cli.zsh config --cookie "$cookie" >"$out" 2>&1)
  (cd "$repo" && ./did-cli.zsh help >>"$out" 2>&1)
  (cd "$repo" && COOKIE_EXPECTED="$cookie" zsh -c 'source ./.env && [[ "$DID_COOKIE" == "$COOKIE_EXPECTED" ]]')

  assert_contains "$out" "DID_COOKIE updated"
}

test_missing_flag_value_fails_fast() {
  local repo out
  repo="$(make_tmp_repo)"
  cat >"$repo/.env" <<'EOF'
DID_URL=did.crayonconsulting.no
DID_COOKIE=dummy
debug=0
DID_DEFAULT_OUTPUT=json
DID_USER_DISPLAY_NAME=
EOF
  out="$repo/missing.out"

  if (cd "$repo" && ./did-cli.zsh report --week >"$out" 2>&1); then
    echo "Expected report --week to fail" >&2
    exit 1
  fi

  assert_contains "$out" "Missing value for --week"
}

test_week_input_does_not_execute_code() {
  local repo out marker payload
  repo="$(make_tmp_repo)"
  cat >"$repo/.env" <<'EOF'
DID_URL=did.crayonconsulting.no
DID_COOKIE=dummy
debug=0
DID_DEFAULT_OUTPUT=json
DID_USER_DISPLAY_NAME=
EOF
  out="$repo/injection.out"
  marker="$(mktemp /tmp/did-cli-marker.XXXXXX)"
  rm -f "$marker"
  payload="1' and __import__('pathlib').Path('$marker').write_text('x') and '1"

  if (cd "$repo" && ./did-cli.zsh submit --week "$payload" --year 2026 --confirm >"$out" 2>&1); then
    echo "Expected submit with invalid week payload to fail" >&2
    exit 1
  fi

  test ! -f "$marker"
  assert_contains "$out" "Invalid week"
}

test_help_bootstraps_env
test_config_bootstraps_and_escapes
test_missing_flag_value_fails_fast
test_week_input_does_not_execute_code

echo "review-smoke: ok"

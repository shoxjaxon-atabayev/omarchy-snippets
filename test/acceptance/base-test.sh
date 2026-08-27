#!/bin/bash

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source test/acceptance/base-test.sh from an acceptance test; do not run it directly" >&2
  exit 1
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
ARTIFACTS="${OMARCHY_SNIPPETS_ACCEPTANCE_DIR:-/tmp/omarchy-snippets-acceptance}"

mkdir -p "$ARTIFACTS"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"
  local step=${description,,}

  step=${step// /-}
  step=${step//[^a-z0-9-]/}

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  screenshot "failure-$step"
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

screenshot() {
  timeout 10 grim "$ARTIFACTS/$1.png" 2>/dev/null || true
}

screen_contains() {
  local text="$1"
  local snapshot="/tmp/omarchy-snippets-acceptance-ocr-$$.png"

  if ! timeout 10 grim "$snapshot" 2>/dev/null; then
    rm -f "$snapshot"
    return 1
  fi
  tesseract "$snapshot" stdout --psm 11 2>/dev/null | grep -Fi -- "$text" >/dev/null
  local status=$?
  rm -f "$snapshot"
  return $status
}

# Poll a command until it succeeds; screenshot and fail on timeout.
wait_until() {
  local description="$1" timeout="$2"
  shift 2

  local deadline=$((SECONDS + timeout))

  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      fail "$description" "timed out after ${timeout}s waiting for: $*"
    fi
    sleep 1
  done

  pass "$description"
}

layer_present() {
  hyprctl -j layers | jq -e --arg ns "$1" '[.. | objects | select(.namespace? == $ns)] | length > 0'
}

layer_absent() {
  ! layer_present "$1"
}

# This is a standalone plugin, not a core component: it only appears in the
# bar once a user has installed it (`omarchy plugin add`) and enabled it
# (`omarchy plugin enable community.shoxjaxon.snippets`). Skip rather than
# fail when that setup step hasn't happened on this machine, the same way
# Omarchy's own shell-test harness skips when no compositor is reachable.
require_plugin_enabled() {
  local shell_config="$HOME/.config/omarchy/shell.json"

  if [[ -f $shell_config ]] && jq -e '
      [(.bar.layout // {}) | to_entries[] | .value | select(type == "array") | .[]
        | if type == "object" then (.id // "") else . end]
      | index("community.shoxjaxon.snippets") != null
    ' "$shell_config" >/dev/null 2>&1; then
    return 0
  fi

  pass "plugin not installed/enabled; skipping acceptance run (run: omarchy plugin add <this repo> --enable)"
  exit 0
}

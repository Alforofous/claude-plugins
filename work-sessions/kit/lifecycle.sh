#!/bin/bash
# Session start and end for the kit, run by the plugin's hooks module with the event's JSON on stdin:
# `lifecycle.sh start` prints sessions waiting for a decision and reaps stale ones; `lifecycle.sh end` reaps this one once Claude exits.
set -u
KIT="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$HOME/.cc/sessions"

input=$(cat)
field() { printf '%s' "$input" | jq -r ".$1 // empty"; }

cwd=$(field cwd)
git -C "${cwd:-$PWD}" rev-parse --git-dir >/dev/null 2>&1 || exit 0

claude_pid() {
  local p=$$
  while [ "${p:-0}" -gt 1 ]; do
    [ "$(basename "$(ps -o comm= -p "$p" 2>/dev/null)")" = claude ] && { echo "$p"; return 0; }
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}

lease_by_pid() {
  local pid=$1 f
  for f in "$KIT_ROOT"/*/lease.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r .claude_pid "$f")" = "$pid" ] && { jq -r .id "$f"; return 0; }
  done
  return 1
}

detach() {
  compgen -G "$KIT_ROOT/*/lease.json" >/dev/null || return 0
  perl -e 'use POSIX; POSIX::setsid(); exec @ARGV' "$@" </dev/null >/dev/null 2>&1 &
}

pid=$(claude_pid) || exit 0
session_id=$(field session_id)

case "${1:-}" in
  start)
    sid=$(lease_by_pid "$pid") || sid=$(printf '%s' "$session_id" | tr -d '-' | cut -c1-8)
    [ -n "$sid" ] || exit 0
    "$KIT/session.sh" notices 2>/dev/null
    detach "$KIT/session.sh" reap --stale
    ;;
  end)
    [ "$(field reason)" = clear ] && exit 0
    sid=$(lease_by_pid "$pid") || exit 0
    detach "$KIT/session.sh" reap --wait-pid "$pid" "$sid"
    ;;
esac
exit 0

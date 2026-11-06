#!/bin/bash
# Session lease kit: start an isolated session, list what it left behind, and remove it.
# A repo adds its own setup in <repo>/.claude/session-profile.sh, a bash file the kit sources:
#   SESSION_PORTS="name:base ..."  ports to reserve; the session gets base + slot, exported as PORT_<NAME>
#   SESSION_DOCKER=1               the session runs containers, under compose project $SESSION_DOCKER_PROJECT
#   session_check                  optional; prints a reason and fails to refuse a start
#   session_env                    optional; prints KEY=VALUE lines every shell command of the session gets
#   session_setup                  optional; runs in the new checkout's context after it is created
#   session_stop / session_down    optional; stop or remove the session's containers
# Every profile function sees SESSION_ID, SESSION_REPO, SESSION_CHECKOUT, SESSION_DOCKER_PROJECT, SESSION_TMP and PORT_*;
# session_setup, session_stop and session_down also see session_env's variables.
#
#   session.sh start <slug>          fresh checkout on its own branch, then the repo's profile setup
#   session.sh plan [sid]            what cleanup would do, one row per item
#   session.sh apply [sid] [--delete kind:id ...] [--unsaved discard|keep] [--non-interactive]
#   session.sh reap --stale          clean sessions whose Claude process is gone
#   session.sh reap --wait-pid <pid> <sid>
#   session.sh notices               sessions waiting for a decision
#   session.sh ls
set -u

KIT_ROOT="$HOME/.cc/sessions"
CONFIG="${WORK_SESSIONS_CONFIG:-$HOME/.claude/work-sessions.conf}"
SID_RE='^[0-9a-f]{8}$'

die() { echo "session: $*" >&2; exit 1; }

conf() {
  local key=$1 default=$2 value=""
  [ -f "$CONFIG" ] && value=$(awk -F: -v k="$key" '
    /^[[:space:]]*#/ { next }
    { gsub(/[[:space:]]/, "", $1) }
    $1 == k { v = $2; sub(/#.*/, "", v); gsub(/[[:space:]]/, "", v); print v; exit }' "$CONFIG")
  echo "${value:-$default}"
}

mode_for() {
  local kind=$1 default=$2 mode
  mode=$(conf "$kind" "$default")
  case "$mode" in delete|ask|report|keep) ;; *) mode=$default ;; esac
  if [ "$kind" = unsaved_work ] && [ "$mode" != keep ]; then mode=ask; fi
  echo "$mode"
}

repo_root() {
  local common
  common=$(git -C "${1:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  dirname "$common"
}

load_profile() {
  SESSION_PORTS=""; SESSION_DOCKER=""
  unset -f session_check session_env session_setup session_stop session_down 2>/dev/null
  local f="$1/.claude/session-profile.sh"
  [ -f "$f" ] || return 0
  # shellcheck source=/dev/null
  . "$f" || die "could not load $f."
}

has_fn() { declare -F "$1" >/dev/null; }

export_session_env() {
  local sid=$1 name port
  export SESSION_ID=$sid SESSION_REPO=$(lease_get "$sid" .repo) SESSION_CHECKOUT=$(lease_get "$sid" .checkout)
  export SESSION_DOCKER_PROJECT=$(lease_get "$sid" .docker_project) SESSION_TMP="$KIT_ROOT/$sid/tmp"
  while IFS=$'\t' read -r name port; do
    [ -n "$name" ] && export "PORT_$(echo "$name" | tr '[:lower:]-' '[:upper:]_')=$port"
  done < <(jq -r '.ports // {} | to_entries[] | "\(.key)\t\(.value)"' "$(lease_file "$sid")")
  # shellcheck source=/dev/null
  [ -f "$(env_file "$sid")" ] && . "$(env_file "$sid")"
  return 0
}

env_file() { echo "$KIT_ROOT/$1/env"; }

write_env() {
  local sid=$1 line key f
  f=$(env_file "$sid")
  : > "$f"
  has_fn session_env || return 0
  session_env | while IFS= read -r line; do
    key=${line%%=*}
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    printf 'export %s=%q\n' "$key" "${line#*=}"
  done > "$f"
}

default_branch() {
  local b
  b=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) && { echo "${b#origin/}"; return; }
  echo main
}

docker_up() { command -v docker >/dev/null && docker info >/dev/null 2>&1; }

claude_pid() {
  [ -n "${CLAUDE_PID:-}" ] && kill -0 "$CLAUDE_PID" 2>/dev/null && { echo "$CLAUDE_PID"; return 0; }
  local p=$$ comm
  while [ "${p:-0}" -gt 1 ]; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null)
    case "$(basename "$comm" 2>/dev/null)" in claude) echo "$p"; return 0 ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}

pid_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/  */ /g'; }

lease_file() { echo "$KIT_ROOT/$1/lease.json"; }
lease_get() { jq -r "$2 // empty" "$(lease_file "$1")" 2>/dev/null; }
lease_set() {
  local f tmp
  f=$(lease_file "$1"); tmp="$f.tmp"; shift
  jq "$@" "$f" > "$tmp" && mv "$tmp" "$f"
}

lease_of_pid() {
  local pid=$1 f
  for f in "$KIT_ROOT"/*/lease.json; do
    [ -f "$f" ] && [ "$(jq -r .claude_pid "$f")" = "$pid" ] && { jq -r .id "$f"; return 0; }
  done
  return 1
}

resolve_sid() {
  local sid=${1:-${CC_SESSION:-}} pid
  if [ -z "$sid" ] && pid=$(claude_pid); then sid=$(lease_of_pid "$pid") || sid=""; fi
  [ -n "$sid" ] || sid=$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr -d '-' | cut -c1-8)
  [ -n "$sid" ] || die "no session ID: run this from a Claude Code session, or pass the ID."
  [[ "$sid" =~ $SID_RE ]] || die "'$sid' is not a session ID (8 hex characters)."
  echo "$sid"
}

port_free() { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }

claim_slot() {
  local sid=$1 n spec ok
  mkdir -p "$KIT_ROOT/slots"
  for n in $(seq 1 50); do
    mkdir "$KIT_ROOT/slots/$n" 2>/dev/null || continue
    ok=1
    for spec in $SESSION_PORTS; do port_free $((${spec#*:} + n)) || { ok=""; break; }; done
    if [ -n "$ok" ]; then
      echo "$sid" > "$KIT_ROOT/slots/$n/owner"
      echo "$n"; return 0
    fi
    rmdir "$KIT_ROOT/slots/$n"
  done
  return 1
}

ports_json() {
  local n=$1 spec
  for spec in $SESSION_PORTS; do jq -n --arg k "${spec%%:*}" --argjson v $((${spec#*:} + n)) '{($k): $v}'; done | jq -s 'add // {}'
}

snapshot_json() {
  local repo=$1
  jq -n \
    --argjson branches "$(git -C "$repo" for-each-ref refs/heads --format='%(refname:short)' | jq -R . | jq -s .)" \
    --argjson stashes "$(git -C "$repo" stash list --format=%H 2>/dev/null | jq -R . | jq -s .)" \
    --argjson worktrees "$(git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p' | jq -R . | jq -s .)" \
    --argjson containers "$( (docker_up && docker ps -aq --no-trunc) 2>/dev/null | jq -R . | jq -s .)" \
    --argjson git_config "$(git -C "$repo" config --local --list | sort | jq -R . | jq -s .)" \
    '{branches: $branches, stashes: $stashes, worktrees: $worktrees, containers: $containers, git_config: $git_config}'
}

cmd_start() {
  local slug=${1:-} sid repo cpid wt n base project=""
  [ -n "$slug" ] || die "usage: session.sh start <slug>"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "slug must be lower-case letters, digits and dashes."
  sid=$(resolve_sid "")
  repo=$(repo_root) || die "not inside a git repository."
  [ ! -f "$(lease_file "$sid")" ] || die "session $sid already has a lease. Run /session-end first, or 'session.sh ls'."
  load_profile "$repo"
  if has_fn session_check; then
    local why
    why=$(session_check) || die "${why:-session_check refused to start.}"
  fi
  [ -z "$SESSION_DOCKER" ] || docker_up || die "Docker is not running."
  cpid=$(claude_pid) || die "cannot find the Claude Code process above this shell."

  mkdir -p "$KIT_ROOT/$sid/tmp"
  n=$(claim_slot "$sid") || { rm -rf "${KIT_ROOT:?}/$sid"; die "no free port slot."; }
  wt="$repo/.claude/worktrees/$sid"
  base=$(default_branch "$repo")
  [ -n "$SESSION_DOCKER" ] && project="cc-$sid"

  jq -n --arg id "$sid" --argjson pid "$cpid" --arg pstart "$(pid_start "$cpid")" \
    --arg repo "$repo" --arg wt "$wt" --arg branch "cc/$sid/$slug" --arg project "$project" \
    --argjson slot "$n" --argjson ports "$(ports_json "$n")" --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson before "$(snapshot_json "$repo")" \
    '{id: $id, state: "starting", claude_pid: $pid, claude_started: $pstart, repo: $repo,
      checkout: $wt, branch: $branch, docker_project: $project, slot: $slot, ports: $ports,
      started_at: $started, before: $before}' > "$(lease_file "$sid")"

  echo "→ lease $sid, port slot $n"
  git -C "$repo" fetch -q origin "$base" || die "git fetch origin $base failed."
  git -C "$repo" worktree add -q -b "cc/$sid/$slug" "$wt" "origin/$base" || die "git worktree add failed."
  git -C "$wt" branch -q --unset-upstream 2>/dev/null || true

  export_session_env "$sid"
  write_env "$sid"
  export_session_env "$sid"
  if has_fn session_setup; then
    (session_setup) || die "the repo's session setup failed (lease kept; /session-end cleans it)."
  fi

  lease_set "$sid" '.state = "active"'
  jq -r '"",
    "session   \(.id)",
    "checkout  \(.checkout)",
    "branch    \(.branch)",
    "env       '"$(env_file "$sid")"'",
    (if .docker_project != "" then "docker    \(.docker_project)" else empty end),
    (.ports | to_entries[] | "\(.key | . + "          " | .[0:10])localhost:\(.value)")' "$(lease_file "$sid")"
}

row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

ancestors() {
  local p=$$
  while [ "${p:-0}" -gt 1 ]; do echo "$p"; p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); done
}

session_pids() {
  local sid=$1 wt skip ports
  wt=$(lease_get "$sid" .checkout)
  skip=" $(ancestors | tr '\n' ' ') $(lease_get "$sid" .claude_pid) "
  ports=$(jq -r '.ports // {} | [.[]] | map("-iTCP:\(.)") | join(" ")' "$(lease_file "$sid")")
  {
    lsof -d cwd -Fpn 2>/dev/null | KIT_WT="$wt" awk '
      BEGIN { wt = ENVIRON["KIT_WT"] }
      /^p/ { pid = substr($0, 2) }
      /^n/ { path = substr($0, 2); if (path == wt || index(path, wt "/") == 1) print pid }'
    ps -A -ww -o pid=,command= | KIT_WT="$wt/" awk 'index($0, ENVIRON["KIT_WT"]) { print $1 }'
    [ -n "$ports" ] && for p in $(lsof -nP $ports -sTCP:LISTEN -t 2>/dev/null); do
      case "$(ps -o command= -p "$p" 2>/dev/null)" in *[Dd]ocker*|*vpnkit*) ;; *) echo "$p" ;; esac
    done
  } | sort -un | while read -r p; do
    case "$skip" in *" $p "*) ;; *) echo "$p" ;; esac
  done | descendants_too "$skip"
}

descendants_too() {
  local skip=$1 found
  found=" $(tr '\n' ' ') "
  local again=1
  while [ -n "$again" ]; do
    again=""
    while read -r pid ppid; do
      case "$found" in *" $ppid "*) ;; *) continue ;; esac
      case "$found$skip" in *" $pid "*) continue ;; esac
      found="$found$pid "; again=1
    done < <(ps -A -o pid=,ppid=)
  done
  for p in $found; do echo "$p"; done
}

nl_has() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1; }

# Branches session $1 made: its cc/<sid>/ branches plus every branch its checkout has switched to,
# read from the checkout's own HEAD reflog and remembered in the lease for after the checkout is gone.
own_branches() {
  local sid=$1 repo wt seen
  repo=$(lease_get "$sid" .repo); wt=$(lease_get "$sid" .checkout)
  if [ -d "$wt" ]; then
    seen=$(git -C "$wt" reflog --format=%gs 2>/dev/null | sed -n \
      -e 's/^checkout: moving from .* to //p' \
      -e 's/^Branch: renamed refs\/heads\/.* to refs\/heads\///p' | jq -R . | jq -s .)
    lease_set "$sid" --argjson seen "$seen" '.own_branches = ((.own_branches // []) + $seen | unique)'
  fi
  {
    git -C "$repo" for-each-ref "refs/heads/cc/$sid/" --format='%(refname:short)'
    lease_get "$sid" '.own_branches[]?'
  } | sort -u
}

cmd_plan() {
  local sid repo wt branch project before mode pid c v b s w changed own subject
  sid=$(resolve_sid "${1:-}")
  [ -f "$(lease_file "$sid")" ] || die "no lease for session $sid."
  repo=$(lease_get "$sid" .repo); wt=$(lease_get "$sid" .checkout)
  branch=$(lease_get "$sid" .branch); project=$(lease_get "$sid" .docker_project)
  before=$(lease_file "$sid")

  mode=$(mode_for processes delete)
  for pid in $(session_pids "$sid"); do
    row process "$pid" "$mode" "$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-80)"
  done

  mode=$(mode_for docker delete)
  [ -n "$project" ] && for c in $(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null); do
    row container "$c" "$mode" "$(docker inspect -f '{{.Name}} {{.State.Status}}' "$c" 2>/dev/null)"
  done
  [ -n "$project" ] && for v in $(docker volume ls -q --filter "label=com.docker.compose.project=$project" 2>/dev/null); do
    row volume "$v" "$mode" "docker volume"
  done

  if [ -d "$wt" ]; then
    changed=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$changed" != 0 ]; then
      row unsaved "$wt" "$(mode_for unsaved_work ask)" "$changed uncommitted file(s)"
    fi
  fi
  if git -C "$repo" show-ref -q --verify "refs/heads/$branch"; then
    c=$(git -C "$repo" rev-list --count "$branch" --not --remotes 2>/dev/null || echo 0)
    if [ "$c" != 0 ]; then
      row unsaved "$branch" "$(mode_for unsaved_work ask)" "$c commit(s) not on any remote"
    fi
  fi
  [ -d "$wt" ] && row worktree "$wt" "$(mode_for worktree delete)" "session checkout"
  for b in $(git -C "$repo" for-each-ref "refs/heads/cc/$sid/" --format='%(refname:short)'); do
    row branch "$b" "$(mode_for session_branch delete)" "session branch"
  done

  own=$(own_branches "$sid")

  mode=$(mode_for new_branches ask)
  for b in $(git -C "$repo" for-each-ref refs/heads --format='%(refname:short)'); do
    case "$b" in cc/*) continue ;; esac
    nl_has "$own" "$b" || continue
    jq -e --arg b "$b" '.before.branches | index($b)' "$before" >/dev/null || row new_branch "$b" "$mode" "created since start"
  done
  mode=$(mode_for new_stashes ask)
  for s in $(git -C "$repo" stash list --format=%H 2>/dev/null); do
    jq -e --arg s "$s" '.before.stashes | index($s)' "$before" >/dev/null && continue
    subject=$(git -C "$repo" log -1 --format=%s "$s" 2>/dev/null)
    b=$(printf '%s' "$subject" | sed -n -e 's/^WIP on \([^:]*\):.*/\1/p' -e 's/^On \([^:]*\):.*/\1/p')
    [ -n "$b" ] && nl_has "$own" "$b" && row new_stash "$s" "$mode" "$subject"
  done
  mode=$(mode_for new_worktrees ask)
  git -C "$repo" worktree list --porcelain | awk '
    /^worktree / { w = substr($0, 10) }
    /^branch refs\/heads\// { print w "\t" substr($0, 19) }' | while IFS=$'\t' read -r w b; do
    [ "$w" = "$wt" ] && continue
    nl_has "$own" "$b" || continue
    jq -e --arg w "$w" '.before.worktrees | index($w)' "$before" >/dev/null || row new_worktree "$w" "$mode" "created since start"
  done
  mode=$(mode_for new_containers ask)
  for c in $( (docker_up && docker ps -aq --no-trunc) 2>/dev/null); do
    jq -e --arg c "$c" '.before.containers | index($c)' "$before" >/dev/null && continue
    case "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null)" in cc-*) continue ;; esac
    w=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null)
    case "$w" in "$wt"|"$wt"/*) ;; *) continue ;; esac
    row new_container "${c:0:12}" "$mode" "$(docker inspect -f '{{.Name}} {{.Config.Image}}' "$c" 2>/dev/null)"
  done
  mode=$(mode_for git_config report)
  git -C "$repo" config --local --list | sort | while IFS= read -r line; do
    jq -e --arg l "$line" '.before.git_config | index($l)' "$before" >/dev/null && continue
    b=${line%%=*}; b=${b#branch.}; b=${b%.*}
    case "$line" in branch.*) nl_has "$own" "$b" && row git_config "${line%%=*}" "$mode" "$line" ;; esac
  done
  mode=$(mode_for pull_requests report)
  (cd "$repo" && gh pr list --author @me --state open --search "created:>=$(lease_get "$sid" .started_at)" \
    --json number,title,headRefName --jq '.[] | "\(.number)\t\(.headRefName)\t\(.title)"' 2>/dev/null) |
    while IFS=$'\t' read -r num b title; do
      nl_has "$own" "$b" && row pull_request "#$num" "$mode" "$title"
    done
  return 0
}

kill_ladder() {
  local pids="$*" sig waited
  [ -n "$pids" ] || return 0
  for sig in TERM KILL; do
    kill -"$sig" $pids 2>/dev/null || true
    waited=0
    while [ "$waited" -lt 5 ]; do
      local alive=""
      for p in $pids; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
      pids=$alive
      [ -z "$pids" ] && return 0
      sleep 1; waited=$((waited + 1))
    done
  done
}

remove_docker_project() {
  local project=$1
  [[ "$project" =~ ^cc-[0-9a-f]{8}$ ]] || die "refusing to touch Docker project '$project'."
  if has_fn session_down; then
    (session_down) >/dev/null 2>&1 || true
  fi
  local f="label=com.docker.compose.project=$project"
  local id
  for id in $(docker ps -aq --filter "$f"); do docker rm -f "$id" >/dev/null 2>&1; done
  for id in $(docker volume ls -q --filter "$f"); do docker volume rm "$id" >/dev/null 2>&1; done
  for id in $(docker network ls -q --filter "$f"); do docker network rm "$id" >/dev/null 2>&1; done
}

drop_stash() {
  local repo=$1 hash=$2 i
  i=$(git -C "$repo" stash list --format=%H | grep -n -x "$hash" | head -1 | cut -d: -f1)
  [ -n "$i" ] && git -C "$repo" stash drop -q "stash@{$((i - 1))}"
}

cmd_apply() {
  local sid="" unsaved="" noninteractive="" approved=" " plan repo wt project slot
  while [ $# -gt 0 ]; do
    case "$1" in
      --delete) approved="$approved$2 "; shift 2 ;;
      --unsaved) unsaved=$2; shift 2 ;;
      --non-interactive) noninteractive=1; shift ;;
      *) sid=$1; shift ;;
    esac
  done
  sid=$(resolve_sid "$sid")
  [ -f "$(lease_file "$sid")" ] || die "no lease for session $sid."
  repo=$(lease_get "$sid" .repo); wt=$(lease_get "$sid" .checkout)
  project=$(lease_get "$sid" .docker_project); slot=$(lease_get "$sid" .slot)
  [ -z "$project" ] || docker_up || die "Docker is not running, so its containers can't be checked; nothing was removed."
  load_profile "$repo"
  export_session_env "$sid"
  plan=$(cmd_plan "$sid")

  local has_unsaved="" pending=""
  if printf '%s\n' "$plan" | awk -F'\t' '$1 == "unsaved"' | grep -q .; then has_unsaved=1; fi
  if [ -n "$has_unsaved" ] && [ "$unsaved" = keep ]; then
    lease_set "$sid" '.state = "kept"'
    echo "kept session $sid as it is."; return 0
  fi
  if [ -n "$has_unsaved" ] && [ "$unsaved" != discard ]; then
    [ -n "$noninteractive" ] || die "session $sid has unsaved work; pass --unsaved discard or --unsaved keep."
    pending=1
  fi

  kill_ladder $(printf '%s\n' "$plan" | awk -F'\t' '$1 == "process" && $3 == "delete" { print $2 }')

  if [ -n "$pending" ]; then
    if [ -n "$project" ] && has_fn session_stop; then (session_stop) >/dev/null 2>&1; fi
    lease_set "$sid" '.state = "needs-decision"'
    echo "session $sid has unsaved work: programs stopped, containers stopped, nothing deleted."
    return 0
  fi

  [ -n "$project" ] && [ "$(mode_for docker delete)" = delete ] && remove_docker_project "$project"

  while IFS=$'\t' read -r kind id mode _; do
    [ -n "$kind" ] || continue
    [ "$mode" = ask ] && [ "$kind" != unsaved ] || continue
    case "$approved" in *" $kind:$id "*) ;; *) [ -n "$noninteractive" ] && pending=1; continue ;; esac
    case "$kind" in
      new_stash) drop_stash "$repo" "$id" ;;
      new_worktree) git -C "$repo" worktree remove --force "$id" ;;
      new_container) docker rm -f "$id" >/dev/null ;;
    esac
  done <<< "$plan"

  if [ -d "$wt" ] && [ "$(mode_for worktree delete)" = delete ]; then
    case "$wt" in "$repo/.claude/worktrees/$sid") ;; *) die "refusing to remove checkout '$wt'." ;; esac
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null || rm -rf "${wt:?}"
  fi
  git -C "$repo" worktree prune

  while IFS=$'\t' read -r kind id mode _; do
    [ "$kind" = new_branch ] && [ "$mode" = ask ] || continue
    case "$approved" in *" $kind:$id "*) git -C "$repo" branch -q -D "$id" ;; esac
  done <<< "$plan"

  if [ "$(mode_for session_branch delete)" = delete ]; then
    git -C "$repo" for-each-ref "refs/heads/cc/$sid/" --format='%(refname:short)' | while read -r b; do
      git -C "$repo" branch -q -D "$b"
    done
  fi

  local left
  left=$(cmd_plan "$sid" | awk -F'\t' '$3 == "delete"')
  if [ -n "$left" ]; then
    lease_set "$sid" '.state = "failed"'
    echo "session $sid: these could not be removed; the lease is kept so the next run retries:" >&2
    printf '%s\n' "$left" >&2
    return 1
  fi
  if [ -n "$pending" ]; then
    lease_set "$sid" '.state = "needs-decision"'
    echo "session $sid: cleaned, except items that need your answer (run /session-end $sid)."
    return 0
  fi

  [ -n "$slot" ] && rm -rf "${KIT_ROOT:?}/slots/$slot"
  rm -rf "${KIT_ROOT:?}/$sid"
  rmdir "$KIT_ROOT/slots" "$KIT_ROOT" "$(dirname "$KIT_ROOT")" 2>/dev/null
  rmdir "$repo/.claude/worktrees" "$repo/.claude" 2>/dev/null
  echo "session $sid: nothing left."
}

lease_dead() {
  local sid=$1 pid started
  pid=$(lease_get "$sid" .claude_pid); started=$(lease_get "$sid" .claude_started)
  [ -z "$pid" ] && return 0
  kill -0 "$pid" 2>/dev/null || return 0
  [ "$(pid_start "$pid")" != "$started" ]
}

cmd_reap() {
  case "${1:-}" in
    --stale)
      local d sid state
      for d in "$KIT_ROOT"/*/; do
        sid=$(basename "$d"); [[ "$sid" =~ $SID_RE ]] || continue
        state=$(lease_get "$sid" .state)
        case "$state" in starting|active|failed) ;; *) continue ;; esac
        lease_dead "$sid" && { echo "[$(date)] reaping stale $sid"; cmd_apply "$sid" --non-interactive; }
      done ;;
    --wait-pid)
      local pid=$2 sid=$3
      while kill -0 "$pid" 2>/dev/null; do sleep 2; done
      [ -f "$(lease_file "$sid")" ] || exit 0
      echo "[$(date)] Claude $pid exited, reaping $sid"
      cmd_apply "$sid" --non-interactive ;;
    *) die "usage: session.sh reap --stale | --wait-pid <pid> <sid>" ;;
  esac
}

cmd_notices() {
  local d sid
  for d in "$KIT_ROOT"/*/; do
    sid=$(basename "$d"); [[ "$sid" =~ $SID_RE ]] || continue
    case "$(lease_get "$sid" .state)" in
      needs-decision) echo "Session lease $sid ($(lease_get "$sid" .branch)) ended with unsaved work or items needing an answer. Tell the user; /session-end $sid resolves it." ;;
    esac
  done
}

cmd_ls() {
  local d sid any=""
  for d in "$KIT_ROOT"/*/; do
    sid=$(basename "$d"); [[ "$sid" =~ $SID_RE ]] || continue
    any=1
    jq -r '"\(.id)  \(.state)  \(.branch)  pid \(.claude_pid)  started \(.started_at)"' "$(lease_file "$sid")"
  done
  [ -n "$any" ] || echo "no sessions."
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  plan) shift; cmd_plan "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  reap) shift; cmd_reap "$@" ;;
  notices) cmd_notices ;;
  ls) cmd_ls ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1 ;;
esac

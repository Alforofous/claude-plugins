#!/bin/bash
# Two sessions share one repo; `session.sh plan` and `apply` for session A must only touch what A made.
# Hermetic: HOME, the repo, its origin, gh and docker are all fakes under a temp dir.
set -u

KIT="$(cd "$(dirname "$0")/.." && pwd)/session.sh"
T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" PATH="$T/bin:$PATH" GIT_CONFIG_NOSYSTEM=1
unset CC_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID WORK_SESSIONS_CONFIG
mkdir -p "$HOME" "$T/bin"
git config --global user.email test@example.com
git config --global user.name test
git config --global init.defaultBranch main

A=aaaaaaaa B=bbbbbbbb
REPO="$T/repo"
WT_A="$REPO/.claude/worktrees/$A" WT_B="$REPO/.claude/worktrees/$B"

cat > "$T/bin/gh" <<EOF
#!/bin/bash
jqexpr=""
while [ \$# -gt 0 ]; do [ "\$1" = --jq ] && jqexpr=\$2; shift; done
jq -r "\$jqexpr" <<'JSON'
[{"number": 1, "title": "PR from A", "headRefName": "feature-a"},
 {"number": 2, "title": "PR from B", "headRefName": "feature-b"}]
JSON
EOF
cat > "$T/bin/docker" <<EOF
#!/bin/bash
case "\$1" in
  info) exit 0 ;;
  ps) case "\$*" in *--filter*) ;; *) echo cccccccccccc1111; echo cccccccccccc2222 ;; esac ;;
  volume|network) ;;
  inspect)
    case "\$4" in cccccccccccc1111) dir="$WT_A/app" name=from-a ;; *) dir="$WT_B/app" name=from-b ;; esac
    case "\$3" in
      *working_dir*) echo "\$dir" ;;
      *compose.project*) echo app ;;
      *) echo "/\$name img" ;;
    esac ;;
esac
EOF
chmod +x "$T/bin/gh" "$T/bin/docker"

git init -q --bare "$T/origin.git"
git init -q "$REPO"
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" remote add origin "$T/origin.git"
git -C "$REPO" push -q -u origin main
git -C "$REPO" fetch -q origin
git -C "$REPO" remote set-head origin main

make_lease() {
  local sid=$1 wt=$2
  git -C "$REPO" worktree add -q -b "cc/$sid/work" "$wt" origin/main
  mkdir -p "$HOME/.cc/sessions/$sid/tmp"
  jq -n --arg id "$sid" --arg repo "$REPO" --arg wt "$wt" --arg branch "cc/$sid/work" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson branches "$(git -C "$REPO" for-each-ref refs/heads --format='%(refname:short)' | jq -R . | jq -s .)" \
    --argjson worktrees "$(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p' | jq -R . | jq -s .)" \
    --argjson git_config "$(git -C "$REPO" config --local --list | sort | jq -R . | jq -s .)" \
    '{id: $id, state: "active", claude_pid: 1, claude_started: "", repo: $repo, checkout: $wt, branch: $branch,
      docker_project: "", slot: null, ports: {}, started_at: $started,
      before: {branches: $branches, stashes: [], worktrees: $worktrees, containers: [], git_config: $git_config}}' \
    > "$HOME/.cc/sessions/$sid/lease.json"
}

work_in() {
  local wt=$1 name=$2
  git -C "$wt" checkout -q -b "feature-$name"
  git -C "$wt" commit -q --allow-empty -m "work $name"
  echo "$name" > "$wt/scratch-$name.txt"
  git -C "$wt" add "scratch-$name.txt"
  git -C "$wt" stash -q
  git -C "$wt" config "branch.feature-$name.note" "$name"
  git -C "$wt" checkout -q -b "feature-$name-next"
  git -C "$REPO" worktree add -q "$T/side-$name" "feature-$name"
}

make_lease $A "$WT_A"
make_lease $B "$WT_B"
work_in "$WT_A" a
work_in "$WT_B" b

fails=0
check() {
  local want=$1 label=$2 pattern=$3 plan=$4
  if printf '%s\n' "$plan" | grep -qE "$pattern"; then got=present; else got=absent; fi
  if [ "$got" = "$want" ]; then echo "ok    $label"; else echo "FAIL  $label (expected $want)"; fails=$((fails + 1)); fi
}

plan=$("$KIT" plan $A)
echo "--- plan $A"; printf '%s\n' "$plan"; echo "---"
check present "A's branch listed"          $'^new_branch\tfeature-a\t' "$plan"
check absent  "B's branch hidden"          $'^new_branch\tfeature-b' "$plan"
check present "A's stash listed"           $'^new_stash\t.*on feature-a' "$plan"
check absent  "B's stash hidden"           $'^new_stash\t.*on feature-b' "$plan"
check present "A's worktree listed"        $'^new_worktree\t.*/side-a\t' "$plan"
check absent  "B's worktree hidden"        $'^new_worktree\t.*/side-b\t' "$plan"
check present "A's git config listed"      $'^git_config\tbranch\\.feature-a\\.note\t' "$plan"
check absent  "B's git config hidden"      $'^git_config\tbranch\\.feature-b' "$plan"
check present "A's pull request listed"    $'^pull_request\t#1\t' "$plan"
check absent  "B's pull request hidden"    $'^pull_request\t#2\t' "$plan"
check present "A's container listed"       $'^new_container\tcccccccccccc\t.*from-a' "$plan"
check absent  "B's container hidden"       $'^new_container\t.*from-b' "$plan"

git -C "$REPO" worktree remove --force "$WT_A"
plan=$("$KIT" plan $A)
check present "A's branch still listed after its checkout is gone" $'^new_branch\tfeature-a\t' "$plan"

git -C "$REPO" worktree add -q "$WT_A" "cc/$A/work"
out=$("$KIT" apply $A 2>&1)
echo "--- apply $A (nothing selected)"; printf '%s\n' "$out"; echo "---"
check present "apply without selections finishes" 'nothing left' "$out"
check absent  "lease is gone" . "$(ls "$HOME/.cc/sessions/$A" 2>/dev/null)"
check present "unselected branch is kept" 'feature-a' "$(git -C "$REPO" branch --list feature-a)"
check present "B's branch untouched" 'feature-b' "$(git -C "$REPO" branch --list feature-b)"

[ "$fails" = 0 ] && echo "PASS" || { echo "$fails failure(s)"; exit 1; }

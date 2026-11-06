# work-sessions

Two things for Claude Code sessions that do real work in a repository:

- **`/session-start` and `/session-end`.** A session gets its own checkout on its own branch, its own ports and containers, and when it ends everything it made is removed. It asks only about unsaved work and about extra things it made beside its session branch, and never lists what another session made.
- **A progress row above the prompt** for any multi-step workflow: `ENG-42 ●●●●◉○○○○○ 5/10 Build   next Commit`. A workflow skill reports its steps through the `progress` tool, and the row follows along.

## Install

At the prompt of a terminal session:

```
/plugin install work-sessions --marketplace Alforofous/claude-plugins
```

From a shell:

```
claude plugin install work-sessions --marketplace Alforofous/claude-plugins
```

The kit needs `git`, `jq` and `bash`; a repository whose profile runs containers also needs Docker.

## Sessions

From inside a repository, type `/session-start <slug>`. Without anything else, a session is a fresh checkout of the default branch at `.claude/worktrees/<id>` on the branch `cc/<id>/<slug>`. `/session-end` removes the checkout and the branch, and stops every program still running in it. If Claude exits without one, the next session reaps what it left.

A repository adds its own setup in `.claude/session-profile.sh`, a bash file the kit sources:

```bash
SESSION_PORTS="postgres:15432 web:13000"   # each session gets base + its slot, as PORT_POSTGRES, PORT_WEB
SESSION_DOCKER=1                           # it runs containers, under compose project $SESSION_DOCKER_PROJECT

session_check() { [ -z "${DEPLOYMENT_DIR:-}" ] || { echo "unset DEPLOYMENT_DIR first"; return 1; }; }

session_env() {                            # every later shell command of the session gets these
  echo "COMPOSE_PROJECT_NAME=$SESSION_DOCKER_PROJECT"
  echo "POSTGRES_PORT=$PORT_POSTGRES"
  echo "PORT=$PORT_WEB"
}

session_setup() { cd "$SESSION_CHECKOUT" && pnpm install && pnpm db:up && pnpm migrate; }
session_stop()  { docker compose -p "$SESSION_DOCKER_PROJECT" stop; }
session_down()  { docker compose -p "$SESSION_DOCKER_PROJECT" down -v; }
```

Every function is optional. Each sees `SESSION_ID`, `SESSION_REPO`, `SESSION_CHECKOUT`, `SESSION_DOCKER_PROJECT`, `SESSION_TMP` and the `PORT_*` variables.

What `/session-end` deletes, asks about or only reports is set per kind in `~/.claude/work-sessions.conf`:

```
processes:       delete
docker:          delete
worktree:        delete
session_branch:  delete
unsaved_work:    ask
new_branches:    ask
new_stashes:     ask
new_worktrees:   ask
new_containers:  ask
git_config:      report
pull_requests:   report
```

## The progress row

A skill that runs a workflow calls the `progress` tool once with every step, then again as each step starts:

```
progress({ title: "ENG-42", steps: [{ name: "Build" }, { name: "Commit", startsOn: "^git commit" }, { name: "PR", startsOn: "^gh pr create" }], current: 1 })
progress({ current: 2 })
progress({ clear: true })
```

A step's `startsOn` is a regular expression, tested on the whole Bash command and on each part of a chained one (`cd app && git commit` matches `^git commit`): a command that matches it moves the row to that step by itself, so the row stays right even when the agent forgets to report. The row has a Hide button, and `/progress` shows or hides it.

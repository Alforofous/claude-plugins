---
name: session-start
description: Start an isolated work session in the current git repo - a fresh checkout on its own branch, plus whatever the repo's session profile sets up (ports, containers, migrations). Use only when the user runs /session-start.
disable-model-invocation: true
argument-hint: <slug>
---

`<KIT>` below is `kit/session.sh` in this plugin: two folders up from this skill's base directory.

1. Take the slug from the arguments (lower-case, dashes; derive one from the user's words if they gave a phrase). If none, ask for one in a single line.
2. Run from the repository root:
   `<KIT> start <slug>`
   Run it in the foreground. With a profile (`<repo>/.claude/session-profile.sh`) it also runs that repo's setup, which can take a minute or two; without one the session is just the checkout and its branch.
3. If it fails, show the error line and stop. The lease is kept, so `/session-end` cleans up a half-started session.
4. On success, `cd` into the printed checkout path and work there for the rest of the session. The printed `env` file holds the session's variables (its ports, its container project); the plugin loads it into every later shell command of this session. Check that it did: a new shell command that prints one of the env file's variables (`grep -m1 = <env file>` names one) shows its value. When it prints nothing, the plugin's hook was skipped; start each shell command with `set -a; . <env file>; set +a`, and say so in one line.
5. Reply with the printed summary block, plus the `→ work-sessions … is published` line when the start printed one, nothing else.

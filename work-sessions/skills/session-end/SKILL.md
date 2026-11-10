---
name: session-end
description: End the current work session and remove everything it created - programs, containers and volumes, checkout, branches - asking only about unsaved work and the extra branches, stashes, worktrees and containers it made beside its session branch. Use only when the user runs /session-end.
disable-model-invocation: true
argument-hint: "[session-id]"
---

`<KIT>` below is `kit/session.sh` in this plugin: two folders up from this skill's base directory. Run it as a command (`<KIT> plan`); it is a bash script, so `sh <KIT>` fails. The session ID is the argument if given; otherwise the kit finds this session's own lease.

1. Stop Claude-side things this session started: every background Bash task and Monitor (TaskStop), session crons (CronList → CronDelete).
2. `cd` back to the repository root (the main checkout, not the session checkout).
3. Run `<KIT> plan [id]`. Output is tab-separated: kind, id, mode, detail. Show it as a compact table grouped by mode (delete / ask / report).
4. Ask with ONE AskUserQuestion call, only if there are `ask` rows:
   - `unsaved` rows → one question: "Push / Discard / Keep session". On Push: push the branch (`git -C <checkout> push -u origin <branch>`, commit first only if the user says so), then re-run plan.
   - other `ask` rows → one multiSelect question listing them, selected = delete, unselected = keep; with a single such row, one Delete / Keep question naming it instead.
5. Run `<KIT> apply [id]` with `--delete <kind>:<id>` for each selected row and `--unsaved discard` or `--unsaved keep` when unsaved rows existed.
6. Report the script's last line, plus the `report` rows (pushed PRs, git settings) in one short list. Nothing else.

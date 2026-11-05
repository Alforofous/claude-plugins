# claude-plugins

Claude Code plugins for working through real issues with an agent: isolated sessions, visible workflow progress, and more as they prove themselves.

Add the marketplace once, at the prompt of a terminal session:

```
/plugin marketplace add Alforofous/claude-plugins
```

Then install any plugin from it with `/plugin`, or directly:

```
/plugin install work-sessions --marketplace Alforofous/claude-plugins
```

| Plugin | What it does |
|---|---|
| [work-sessions](work-sessions/) | `/session-start` and `/session-end`: a fresh checkout with its own ports and containers, removed in full when the session ends. Plus a progress row above the prompt for multi-step workflows. |

MIT licensed.

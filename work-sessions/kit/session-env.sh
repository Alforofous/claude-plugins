# Sourced before a shell command: loads this Claude session's env file, if its work session has one.
sid=$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr -d '-' | cut -c1-8)
if [ -n "$sid" ] && [ -f "$HOME/.cc/sessions/$sid/env" ]; then
  . "$HOME/.cc/sessions/$sid/env"
fi
unset sid

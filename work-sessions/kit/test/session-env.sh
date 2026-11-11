#!/bin/bash
# session-env.sh loads the env file of the Claude session it runs in, and does nothing without one.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
mkdir -p "$T/.cc/sessions/abcd1234"
echo 'export WS_TEST_PORT=15434' > "$T/.cc/sessions/abcd1234/env"

got=$(HOME="$T" CLAUDE_CODE_SESSION_ID=abcd1234-0000-4000-8000-000000000000 bash -c ". '$KIT/session-env.sh' && echo \"\${WS_TEST_PORT:-}\"")
[ "$got" = 15434 ] || { echo "FAIL: env not loaded for the session's id (got '$got')"; fail=1; }

got=$(HOME="$T" CLAUDE_CODE_SESSION_ID=ffff0000-0000-4000-8000-000000000000 bash -c ". '$KIT/session-env.sh' && echo ran\${WS_TEST_PORT:-}")
[ "$got" = ran ] || { echo "FAIL: a session without an env file should run the command unchanged (got '$got')"; fail=1; }

got=$(HOME="$T" bash -c "unset CLAUDE_CODE_SESSION_ID; . '$KIT/session-env.sh' && echo ran")
[ "$got" = ran ] || { echo "FAIL: no session id should run the command unchanged (got '$got')"; fail=1; }

[ $fail = 0 ] && echo "session-env: ok"
exit $fail

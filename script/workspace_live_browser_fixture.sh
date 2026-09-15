#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGIL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export MIX_ENV="${MIX_ENV:-dev}"
export SIGIL_FIXTURE_PORT="${SIGIL_FIXTURE_PORT:-4017}"
unset PHX_SERVER || true
cd "$SIGIL_DIR"
if command -v mise >/dev/null 2>&1; then
  exec mise exec erlang@29.0.4 elixir@1.20.2-otp-29 -- mix run --no-start script/workspace_live_browser_fixture.exs
fi
exec mix run --no-start script/workspace_live_browser_fixture.exs

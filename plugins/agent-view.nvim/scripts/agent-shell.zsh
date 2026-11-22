# Direct interactive launches use the same registration as dashboard agents.
# Node spawns the executable from PATH, bypassing these shell functions.
# Use command claude (or codex/pi) to deliberately bypass registration.
_agent_view_launcher="${${(%):-%N}:A:h}/run-assistant.cjs"
claude() { command node "$_agent_view_launcher" claude --empty --cwd "$PWD" -- "$@"; }
codex() { command node "$_agent_view_launcher" codex --empty --cwd "$PWD" -- "$@"; }
pi() { command node "$_agent_view_launcher" pi --empty --cwd "$PWD" -- "$@"; }

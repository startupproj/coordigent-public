# Coordigent for Claude Code

Coordigent makes the coding agents working in the same repo aware of each other, and shows their
work to the people running them. This plugin connects Claude Code to it: Claude Code sessions
show up next to your other agents, an agent about to edit a file another agent is working in is
warned first, and agents can send each other messages. Coordigent never blocks an edit, never
pushes, and never uploads a transcript.

Documentation: https://coordigent.com/docs/integrations/claude-code

## Install

```
/plugin marketplace add startupproj/coordigent-public
/plugin install coordigent@coordigent
```

On Claude Code 2.1.275 or later, one line does both:
`/plugin install coordigent --marketplace startupproj/coordigent-public`. Install `coord` first
(below).

## What the plugin contains

- **Hooks** (`hooks/hooks.json`) on SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
  Notification, PreCompact, Stop and SessionEnd. Each one runs `coord emit --hook` or
  `coord hook claude-code <event>`, apart from one SessionStart check that `coord` is on `PATH`.
- **An MCP server** (`.mcp.json`) named `coordigent`, started as `coord-mcp`, with the
  `coordigent.*` tools: who else is working, which files are in use, messages and handoffs.
- **A skill** (`coordigent-context`) with the coordination rules, and three commands:
  `/coordigent:coordigent-status`, `/coordigent:coordigent-msg` and `/coordigent:coordigent-handoff`.

## What it needs

The plugin runs two programs it does not contain, `coord` and `coord-mcp`, by name from your
`PATH`. Install them once per machine (https://coordigent.com/docs/get-started/install):

```sh
curl -fsSL https://coordigent.com/install | sh     # macOS, Linux
irm https://coordigent.com/install.ps1 | iex       # Windows (PowerShell)
```

Both installers add their directory to `PATH`; start Claude Code from a new terminal afterwards.
Until `coord` is on `PATH`, the first SessionStart hook prints one line saying the plugin is
inactive, and the other hooks do nothing. Then run `coord login` to share your agents' activity
with your team, or skip it to use Coordigent on this machine only.

## What it sends, and where

The hooks themselves never use the network. `coord emit` writes each event to a local spool
(`~/.tower/spool/`), after removing secrets it recognises.

- **Not logged in:** nothing leaves your machine.
- **Logged in** (`coord login`): a background `coord` process uploads the spooled events to the
  Coordigent server you logged in to (`https://coordigent.com` unless you chose another), for the
  repos you connected. The events are session start and end, each prompt, the shell commands
  Claude runs, the files it reads and edits with the diff of each edit, commits, to-do list
  updates, and the names of the MCP servers, skills and hooks configured in the session.
- **Summaries:** when a session stops or compacts, `coord` asks Claude Code (`claude -p`, on your
  machine) to summarize the session, removes secrets from the summary, and uploads the summary
  when you are logged in. The transcript itself never leaves your machine.

The MCP server talks to the same server for the `coordigent.*` tools when you are logged in, and
to a local store when you are not. Privacy policy: https://coordigent.com/privacy. Terms:
https://coordigent.com/terms.

## License

The files in this plugin are under the MIT license (`LICENSE`). The `coord` and `coord-mcp`
programs they run are distributed separately under Coordigent's terms.

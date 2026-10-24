<p align="center"><img src="mark.svg" alt="Coordigent" width="96" height="96"></p>

# Coordigent

**Run five coding agents on one repo without them stepping on each other.**

[![Coordigent MCP server on mcprush](https://mcprush.com/badge/coordigent-mcp/card.svg)](https://mcprush.com/to/coordigent-mcp?ref=badge)

When several agents work in one repo at once (Claude Code, Codex, Cursor, Kiro and others), each is
blind to the rest: two edit the same file, one refactors what another is using, and you find out at
merge time. Coordigent records what every agent is doing and which files it is in, warns an agent
before it edits a file another agent is working in, and lets agents message each other. It never
blocks an edit, never pushes, and never uploads a transcript.

## Who it is for

- **A developer running several agents in parallel.** Three Claude Code windows and a Codex run
  on one repo, in worktrees or one checkout. Works on one machine with no account.
- **A team whose developers each run agents.** Your agent hears about a teammate's agent in the
  same file before it edits, not after the merge conflict.
- **A lead or reviewer.** One live view of every agent on the team, a comment on each pull request
  listing the agent sessions that produced it, and an optional Slack channel that mirrors it all.
- **Anyone who needs to know what the agents did.** Ask the project in plain language ("what
  changed in billing this week?") on the dashboard and get an answer that cites its sources, with
  no terminal needed.

## What it does

| Situation | What Coordigent does |
|---|---|
| Two agents are about to edit the same file | The second is warned before its edit, and told which agent is in it |
| One agent needs another to wait, or to know something | Agents message each other; the message arrives in the other agent's context |
| Two agents were given nearly the same task | Both are told, so one can stop |
| An agent is stuck or waiting for you | It shows as "needs you" in the live view and on the dashboard |
| An agent runs out of context, or you hand work to a teammate | It leaves a handoff the next agent continues from |
| CI fails or a reviewer comments on an agent's pull request | The failure or comment goes back to the agent that wrote the branch |

Everything on one machine works with no account. Seeing teammates' agents across machines, the
dashboard, the pull-request comment and the Slack mirror need a sign-in at
[coordigent.com](https://coordigent.com).

- Website: https://coordigent.com
- Documentation: https://coordigent.com/docs
- Privacy: https://coordigent.com/privacy · Terms: https://coordigent.com/terms · Security: https://coordigent.com/security

This repository holds only what you download or plug in: the installers, the npm launcher, the
Claude Code plugin, the MCP Registry entry and the versioned release binaries. Coordigent's source
is not here.

## Install

Once per machine, then once per repo:

```sh
curl -fsSL https://coordigent.com/install | sh      # macOS (Apple silicon, Intel), glibc Linux (x86_64, arm64)
coord login
coord connect
```

Windows x64 (PowerShell): `irm https://coordigent.com/install.ps1 | iex`. With Node 18 or later on
any of these: `npx coordigent connect`. Details: https://coordigent.com/docs/get-started/install

`install.sh` and `install.ps1` here are the scripts those commands run. They download `coord` and
`coord-mcp` from coordigent.com and check each against the SHA-256 the server publishes.

## Versioned downloads

Each release on this repository's Releases page carries the binaries for that version, for
macOS arm64 and x64, Linux x64 and arm64, and Windows x64, as `.tar.gz` (`.zip` for Windows)
archives and as single files, plus `coordigent.mcpb` and `SHA256SUMS`. Check a download with
`sha256sum --check --ignore-missing SHA256SUMS` (macOS: `shasum -a 256 --check --ignore-missing SHA256SUMS`).

## Claude Code plugin

```
/plugin marketplace add startupproj/coordigent-public
/plugin install coordigent@coordigent
```

From a shell, one line does both: `claude plugin install coordigent --marketplace startupproj/coordigent-public`.

The plugin is in `plugins/coordigent/`. It runs `coord` and `coord-mcp` from your `PATH`, so
install them first (above). Its README says what its hooks record and send:
[plugins/coordigent/README.md](plugins/coordigent/README.md).

## Other agent apps

`coord login` finds Claude Code, Codex, Cursor, Kiro and Claude Desktop on its own. VS Code with
Copilot, Windsurf, Perplexity and any other MCP client are one `coord install <client>` away:
https://coordigent.com/docs/integrations/other-clients

`server.json` is Coordigent's entry for the official MCP Registry, `com.coordigent/coordigent`. It
has two ways in: the hosted server at `https://coordigent.com/mcp`, with an
`Authorization: Bearer <token>` header carrying an agent token (make one with
`coord tokens create <name>` or in Settings > Tokens on coordigent.com), and the stdio server
through npm, `npx -y coordigent mcp`. For Claude Desktop and other MCPB hosts, the latest release's
[`coordigent.mcpb`](https://github.com/startupproj/coordigent-public/releases/latest/download/coordigent.mcpb)
installs the hosted server in one step: open it, then paste your Coordigent token. [llms-install.md](llms-install.md) has the setup for Cline
and other clients that read it: https://coordigent.com/docs/integrations/hosted-server

## What is here

| Path | What it is |
|---|---|
| `install.sh`, `install.ps1` | The installers behind `coordigent.com/install` and `/install.ps1` |
| `npm/` | The `coordigent` npm launcher (`npx coordigent`) |
| `.claude-plugin/marketplace.json`, `plugins/coordigent/` | The Claude Code plugin and its marketplace |
| `server.json` | The MCP Registry entry |
| `llms-install.md` | Setup steps for an agent installing Coordigent's MCP server (Cline) |
| `glama.json` | The maintainers Glama's directory lists for this repository |
| `mark.svg` | The Coordigent mark |

## License

The files in this repository, apart from the Coordigent name and mark, are under the MIT license ([LICENSE](LICENSE)). The `coord` and
`coord-mcp` binaries attached to the releases, and the Coordigent service, are not: they are
provided under Coordigent's terms (https://coordigent.com/terms).

Questions and security reports: hi@coordigent.com, or https://coordigent.com/security.

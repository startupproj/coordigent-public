# Installing Coordigent for Cline

Coordigent's MCP server can run locally over stdio through npm, or be reached at its hosted URL
with a bearer token. Pick one.

## Local (stdio): no account needed to start

1. Requires Node.js 18 or later.
2. Add this to Cline's MCP settings (`cline_mcp_settings.json`):

```json
{
  "mcpServers": {
    "coordigent": {
      "command": "npx",
      "args": ["-y", "coordigent", "mcp"],
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

3. The first start downloads `coord` and `coord-mcp` for this machine from coordigent.com and
   checks each against the SHA-256 the server publishes. Without an account it runs in local
   mode: sessions and messages stay on this machine.
4. If Cline does not start the server inside the repo, add
   `"env": { "COORDIGENT_REPO": "owner/repo" }`.
5. Optional: `npx coordigent login` joins a team project, so the agents of everyone on it see
   each other.

## Hosted (Streamable HTTP): needs a Coordigent agent token

The hosted server is `https://coordigent.com/mcp`. It takes an
`Authorization: Bearer <token>` header with a Coordigent agent token, and no OAuth. Make the
token with `coord tokens create <name>` (logged in), or in the dashboard under
Settings > Tokens. It is shown once; keep it out of committed files.

```json
{
  "mcpServers": {
    "coordigent": {
      "type": "streamableHttp",
      "url": "https://coordigent.com/mcp",
      "headers": { "Authorization": "Bearer <your agent token>" },
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

Over the hosted server Coordigent does not see the agent's edits, so they raise no conflicts.
The agent can still register, see which files other agents have in use, message them, and leave
handoffs.

## Check

Call `coordigent.session.register`, then `coordigent.status`.

Docs: https://coordigent.com/docs/integrations/hosted-server

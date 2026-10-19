#!/usr/bin/env node
// `coord-mcp <args>` after `npm i -g coordigent`: the launcher, always running coord-mcp, the
// stdio MCP server (bin/coordigent.js). Nothing but coord-mcp writes to stdout.
"use strict";

require("./coordigent.js").main(process.argv.slice(2), process.env, "coord-mcp");

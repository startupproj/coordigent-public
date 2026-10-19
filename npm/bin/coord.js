#!/usr/bin/env node
// `coord <args>` after `npm i -g coordigent`: the launcher, always running coord
// (bin/coordigent.js). Everything is passed through, `mcp` included.
"use strict";

require("./coordigent.js").main(process.argv.slice(2), process.env, "coord");

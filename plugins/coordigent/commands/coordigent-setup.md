---
description: Install Coordigent's coord command if it is missing and connect this repo
disable-model-invocation: true
---

Set Coordigent up for the repo in the current directory. Run these in a terminal and do not edit any file yourself.

1. If `command -v coord` finds `coord`, run `coord connect`.
2. Otherwise run `npx -y coordigent connect`. It downloads `coord` and `coord-mcp`, checks them against the server's checksums, signs the person in and connects the repo. It needs Node 18 or later; if `npx` is missing, say so and point the person at https://coordigent.com/docs/get-started/install.
3. If the command prints a sign-in link or a code, show it to the person and wait for them to finish.
4. Report what the command printed. Tell the person to start a new terminal so `coord` is on their PATH, and to restart Claude Code.

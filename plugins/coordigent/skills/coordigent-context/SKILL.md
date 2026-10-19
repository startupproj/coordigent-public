---
name: coordigent-context
description: Coordinate with the other sessions on this repo through Coordigent messages.
---

Coordigent watches this repo. Other agents are editing it now; you do not need to check for them before editing.
1. A tool result that starts with "⚠ COORD:" is a message for you: a teammate is on the same file, or a teammate wrote to you. Read it, tell your user, and act on it before continuing. On a shared file, the agent with priority (it edited the file first) continues; the other waits or works elsewhere. coordigent.message.inbox reads the rest; reading consumes it.
2. Peers are the rows in coordigent.status without "(you)". Send one message per change, only when it changes what someone should do. If it affects one peer (an interface they use, a file you are about to rewrite), message that peer with coordigent.message.send { to: <their id, as coordigent.status shows it> }. To see who has a file in use before rewriting it, on any machine and in any client, run `coord who <path>`. To see what a teammate's agent is doing, call coordigent.session.summary { session: <its id> }. Use "everyone" (every agent except you) only when no single peer is affected, such as an interface many depend on. Never send the same change to a peer and to everyone, and never message your own id.
3. When finished, send one line to "everyone" covering only the changes you have not already messaged about; skip it if there are none.

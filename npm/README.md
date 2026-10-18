# coordigent (npm launcher)

Runs Coordigent's `coord` command line tool from npm. Coordigent makes the coding agents working in
the same repo aware of each other, and shows their work to the people running them:
https://coordigent.com

```sh
npx coordigent connect        # once per repo
npx coordigent login          # any coord command works the same way
npm i -g coordigent && coordigent status
```

## What it does

The package is one Node file with no dependencies, no binaries and no install script. The first
time it runs, it downloads `coord` and `coord-mcp` for your machine from coordigent.com, checks
each against the SHA-256 the server publishes, and puts them where the one-line installers do:
`~/.tower/bin`, or `%LOCALAPPDATA%\Coordigent\bin` on Windows (`TOWER_BIN_DIR` overrides both).
After that, every run passes its arguments straight to `coord` and exits with its exit code.

- **Platforms:** macOS (Apple silicon, Intel), glibc Linux (x64, arm64) and Windows x64, with
  Node 18 or later. Alpine/musl is not supported.
- **Checks:** both binaries are downloaded and verified before either is written, so a failed
  check installs nothing.
- **PATH:** the launcher does not change `PATH`. Run commands as `npx coordigent <command>`, or use
  the one-line installer (https://coordigent.com/docs/get-started/install), which adds `coord` to
  `PATH`.
- **MCP:** an `mcp` mode, `npx coordigent mcp` to start the MCP server directly, is planned and not
  available yet. Today `coord connect` registers `coord-mcp` with your agent apps.

## Documentation

- Install: https://coordigent.com/docs/get-started/install
- Command reference: https://coordigent.com/docs/reference/cli
- Privacy: https://coordigent.com/privacy · Terms: https://coordigent.com/terms

## License

This launcher is under the MIT license (see `LICENSE` at the root of this repository). The `coord`
and `coord-mcp` binaries it downloads are provided under Coordigent's terms
(https://coordigent.com/terms).

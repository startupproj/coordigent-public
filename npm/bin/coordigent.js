#!/usr/bin/env node
// The npm launcher: `npx coordigent <args>`, or after `npm i -g coordigent`, `coord <args>`,
// `coord-mcp <args>` and `coordigent <args>`.
//
// It ships no binaries. On first run it downloads coord and coord-mcp for this
// machine from the server's /install/<artifact>, checks each against the SHA-256
// in /install/version the way scripts/install.sh does, and puts them where the
// installers do (~/.tower/bin, or %LOCALAPPDATA%\Coordigent\bin on Windows). Then,
// and on every later run, it runs `coord <args>`. Because the binaries live where
// the installers put them, `coord update` and every MCP config keep working.
//
// `coordigent mcp [args]` runs coord-mcp instead: the stdio MCP server, for an MCP
// client configured with `npx -y coordigent mcp` (the MCP Registry's npm entry,
// server.json). Its stdout is the MCP channel, so the launcher writes only to stderr.
//
// The package's `coord` and `coord-mcp` bins are bin/coord.js and bin/coord-mcp.js, which
// call main() here with the binary fixed. Separate files, not a check of the name this was
// invoked as: on Windows npm's .cmd shim runs `node <bin file>`, so the file is all that
// says which command was typed.
//
// Plain Node with no dependencies and no install scripts: the download happens at
// run time, so `npm i --ignore-scripts` installs a working launcher.
"use strict";

const { spawn, execFileSync } = require("node:child_process");
const { createHash } = require("node:crypto");
const { homedir } = require("node:os");
const { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } = require("node:fs");
const { join, dirname } = require("node:path");

const HOSTED_SERVER_URL = "https://coordigent.com";
const BINARIES = ["coord", "coord-mcp"];
/** The first argument that runs coord-mcp rather than coord. coord has no `mcp` command. */
const MCP_MODE = "mcp";

/** A failure the person can act on: printed as one message, exit 1, no stack. */
class LauncherError extends Error {}

function firstNonEmpty(...values) {
  return values.find((value) => typeof value === "string" && value.trim() !== "");
}

function towerDir(env) {
  return firstNonEmpty(env.TOWER_DIR) ?? join(homedir(), ".tower");
}

function savedServer(env) {
  try {
    return JSON.parse(readFileSync(join(towerDir(env), "config.json"), "utf8")).serverUrl;
  } catch {
    return undefined;
  }
}

/** The server coord itself would use: COORDIGENT_SERVER_URL, TOWER_SERVER_URL, the saved config, the hosted one. */
function resolveServer(env = process.env) {
  const url = firstNonEmpty(env.COORDIGENT_SERVER_URL, env.TOWER_SERVER_URL, savedServer(env)) ?? HOSTED_SERVER_URL;
  return url.trim().replace(/\/+$/, "");
}

/** Where the installers put the binaries: TOWER_BIN_DIR, else ~/.tower/bin (install.sh) or %LOCALAPPDATA%\Coordigent\bin (install.ps1). */
function resolveBinDir(env = process.env, platform = process.platform) {
  const override = firstNonEmpty(env.TOWER_BIN_DIR);
  if (override) return override;
  if (platform === "win32") {
    return join(firstNonEmpty(env.LOCALAPPDATA) ?? join(homedir(), "AppData", "Local"), "Coordigent", "bin");
  }
  return join(homedir(), ".tower", "bin");
}

function underRosetta() {
  try {
    return execFileSync("sysctl", ["-n", "sysctl.proc_translated"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim() === "1";
  } catch {
    return false;
  }
}

function hasGlibc() {
  return Boolean(process.report?.getReport?.().header?.glibcVersionRuntime);
}

/** The published artifact suffix for this machine; the same choices install.sh and install.ps1 make. */
function resolvePlatform({ platform = process.platform, arch = process.arch, rosetta = underRosetta, glibc = hasGlibc } = {}) {
  const key = `${platform}-${arch}`;
  switch (key) {
    case "darwin-arm64":
      return "darwin-arm64";
    // An x64 Node under Rosetta on an Apple Silicon Mac: the native build is the right one.
    case "darwin-x64":
      return rosetta() ? "darwin-arm64" : "darwin-x64";
    case "linux-x64":
    case "linux-arm64":
      if (!glibc()) {
        throw new LauncherError(
          "prebuilt Linux binaries require glibc; Alpine/musl is not supported.\n" +
            "Use a glibc-based Linux distribution, or run Coordigent from source with Bun."
        );
      }
      return key;
    case "win32-x64":
      return "windows-x64";
    default:
      throw new LauncherError(
        `no prebuilt binary for ${key}.\n` +
          "Supported: macOS arm64 and x64, Linux x64 and arm64 (glibc), Windows x64. Build from source with 'bun run build:cli'."
      );
  }
}

function exeSuffix(platform) {
  return platform.startsWith("windows-") ? ".exe" : "";
}

async function request(fetchImpl, url, server) {
  try {
    return await fetchImpl(url);
  } catch (error) {
    throw new LauncherError(
      `could not reach ${server} (${error?.cause?.code ?? error?.message ?? error}).\n` +
        "Check the network, or point at another server with COORDIGENT_SERVER_URL. Nothing was installed."
    );
  }
}

/** The published digests, or {} when the server publishes none (an older server, or one without binaries). */
async function fetchChecksums(fetchImpl, server) {
  try {
    const response = await fetchImpl(`${server}/install/version`);
    if (!response.ok) return {};
    const checksums = (await response.json())?.checksums;
    return checksums && typeof checksums === "object" ? checksums : {};
  } catch {
    return {};
  }
}

function downloadFailure(response, url, platform) {
  if (response.status === 429) {
    const seconds = Number.parseInt(response.headers.get("retry-after") ?? "", 10);
    const when = Number.isFinite(seconds) ? `in ${Math.max(1, Math.ceil(seconds / 60))} minute(s)` : "later";
    return new LauncherError(`could not download ${url}\nToo many downloads from this address. Try again ${when}.`);
  }
  if (response.status === 404 && platform.startsWith("windows-")) {
    return new LauncherError(`could not download ${url}\nWindows build not available yet.`);
  }
  return new LauncherError(
    `could not download ${url} (HTTP ${response.status})\nThe server may not be publishing binaries. See https://coordigent.com/docs/get-started/install.`
  );
}

/**
 * Downloads and checks every binary before writing any of them, so a refusal
 * halfway leaves nothing behind. Nothing unverified is ever made executable.
 */
async function install({ server, binDir, platform, fetchImpl, log }) {
  const checksums = await fetchChecksums(fetchImpl, server);
  const downloads = [];
  for (const name of BINARIES) {
    const artifact = `${name}-${platform}${exeSuffix(platform)}`;
    const url = `${server}/install/${artifact}`;
    log(`Downloading ${name} (${platform})`);
    const response = await request(fetchImpl, url, server);
    if (!response.ok) throw downloadFailure(response, url, platform);
    const bytes = Buffer.from(await response.arrayBuffer());

    const expected = checksums[artifact];
    if (typeof expected === "string" && expected !== "") {
      const actual = createHash("sha256").update(bytes).digest("hex");
      if (actual !== expected.toLowerCase()) {
        throw new LauncherError(
          `${artifact} does not match the checksum the server published.\n` +
            `  expected ${expected}\n  got      ${actual}\n` +
            "Nothing was installed. This is what a tampered or truncated download looks like."
        );
      }
    } else {
      log(`coordigent: the server published no checksum for ${artifact}; installing unverified.`);
    }
    downloads.push({ name, bytes });
  }

  mkdirSync(binDir, { recursive: true });
  for (const { name, bytes } of downloads) {
    const target = join(binDir, `${name}${exeSuffix(platform)}`);
    const tmp = `${target}.download`;
    writeFileSync(tmp, bytes, { mode: 0o755 });
    chmodSync(tmp, 0o755);
    renameSync(tmp, target);
  }
  log(`Installed coord and coord-mcp to ${binDir}`);
}

/** Like install.sh: a machine with no config yet records the server the binaries came from, with no token. */
function rememberServer(env, server) {
  const config = join(towerDir(env), "config.json");
  if (existsSync(config)) return;
  mkdirSync(towerDir(env), { recursive: true });
  writeFileSync(config, `{\n  "serverUrl": "${server}"\n}\n`, { mode: 0o600, flag: "wx" });
}

/**
 * Which binary to run, and what to pass it. The `coord` and `coord-mcp` bins fix the binary and
 * pass every argument through. `coordigent` reads it from the arguments: `mcp …` is coord-mcp,
 * anything else coord.
 */
function resolveCommand(args, fixed) {
  if (BINARIES.includes(fixed)) return { name: fixed, args };
  return args[0] === MCP_MODE ? { name: "coord-mcp", args: args.slice(1) } : { name: "coord", args };
}

/**
 * True when `target` is one of this package's own bins rather than a binary: what npm leaves in
 * ~/.tower/bin when its global prefix is ~/.tower. Running it would start this launcher again,
 * forever.
 */
function isLauncherItself(target) {
  try {
    return dirname(realpathSync(target)) === realpathSync(__dirname);
  } catch {
    return false;
  }
}

function run(binary, args) {
  const child = spawn(binary, args, { stdio: "inherit" });
  // Ctrl-C reaches coord from the terminal already; stay alive until it exits.
  process.on("SIGINT", () => {});
  for (const signal of ["SIGTERM", "SIGHUP"]) process.on(signal, () => child.kill(signal));
  child.on("error", (error) => {
    process.stderr.write(`coordigent: could not run ${binary}: ${error.message}\n`);
    process.exit(1);
  });
  child.on("exit", (code, signal) => {
    if (signal) {
      process.removeAllListeners(signal);
      process.kill(process.pid, signal);
    }
    process.exit(code ?? 1);
  });
}

/** `fixed` is "coord" or "coord-mcp" from those bins; absent for `coordigent`. */
async function main(args = process.argv.slice(2), env = process.env, fixed = undefined) {
  const log = (line) => process.stderr.write(`${line}\n`);
  try {
    const binDir = resolveBinDir(env);
    // The platform is resolved before anything is fetched or written, like install.sh.
    const platform = resolvePlatform();
    const suffix = exeSuffix(platform);
    const command = resolveCommand(args, fixed);
    const binary = join(binDir, `${command.name}${suffix}`);
    if (isLauncherItself(binary)) {
      throw new LauncherError(
        `${binary} is this npm launcher, not the ${command.name} binary: npm's global prefix is the folder\n` +
          "the binaries go in. Install with another npm prefix, or set TOWER_BIN_DIR to another folder."
      );
    }
    if (!BINARIES.every((name) => existsSync(join(binDir, `${name}${suffix}`)))) {
      const server = resolveServer(env);
      await install({ server, binDir, platform, fetchImpl: fetch, log });
      try {
        rememberServer(env, server);
      } catch {
        // Optional, as in install.sh: coord login records the server too.
      }
    }
    run(binary, command.args);
  } catch (error) {
    if (!(error instanceof LauncherError)) throw error;
    log(`coordigent: ${error.message}`);
    process.exit(1);
  }
}

module.exports = { main, resolvePlatform, resolveServer, resolveBinDir, resolveCommand };

if (require.main === module) main();

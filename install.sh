#!/bin/sh
# Coordigent one-line installer.
#
#   curl -fsSL https://coordigent.com/install | sh
#
# Downloads the coord and coord-mcp binaries for this platform and puts them on
# PATH. Without a token it stops there and points at `coord login`, which
# approves this machine in the browser; no token is ever copied by hand.
#
# Headless and CI machines pass one instead, and the script runs `coord connect`
# with it to log in and register the Coordigent MCP server with every agent
# client installed on this machine:
#
#   curl -fsSL https://coordigent.com/install | sh -s -- --token <token>
#
# The server URL is substituted by the route that serves this script, so the
# binaries always come from the origin the script itself came from. Pass
# --server to override it (or to point a checkout at a self-hosted deployment).

set -eu

HOSTED_SERVER_URL="https://coordigent.com"
SERVER_URL="${TOWER_SERVER_URL:-@TOWER_SERVER_URL@}"
TOKEN="${TOWER_TOKEN:-}"
BIN_DIR="${TOWER_BIN_DIR:-$HOME/.tower/bin}"
RUN_CONNECT=1
UPDATE_PATH=1

need_value() {
  if [ "$2" -lt 2 ]; then
    echo "install.sh: $1 needs a value" >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --server)
      need_value "$1" $#
      SERVER_URL="$2"
      shift 2
      ;;
    --token)
      need_value "$1" $#
      TOKEN="$2"
      shift 2
      ;;
    --bin-dir)
      need_value "$1" $#
      BIN_DIR="$2"
      shift 2
      ;;
    --no-connect)
      RUN_CONNECT=0
      shift
      ;;
    --no-path-update)
      UPDATE_PATH=0
      shift
      ;;
    -h|--help)
      echo "Usage: install.sh [--server <url>] [--token <token>] [--bin-dir <dir>] [--no-connect] [--no-path-update]"
      exit 0
      ;;
    *)
      echo "install.sh: unknown option '$1'" >&2
      exit 1
      ;;
  esac
done

# An unsubstituted placeholder still starts with '@'; a real URL never does. That
# means the script is running from a checkout rather than being served, so fall
# back to the hosted instance.
case "$SERVER_URL" in
  @*)
    SERVER_URL="$HOSTED_SERVER_URL"
    ;;
  "")
    echo "install.sh: empty server URL. Re-run with --server https://coordigent.com" >&2
    exit 1
    ;;
esac

SERVER_URL="${SERVER_URL%/}"

OS="$(uname -s)"
ARCH="$(uname -m)"
is_musl() {
  getconf GNU_LIBC_VERSION >/dev/null 2>&1 && return 1
  for loader in /lib/ld-musl-*.so.1; do
    [ ! -e "$loader" ] || return 0
  done
  ldd --version 2>&1 | grep -qi musl
}
if [ "$OS" = Linux ] && is_musl; then
  echo "install.sh: prebuilt Linux binaries require glibc; Alpine/musl is not supported." >&2
  echo "Use a glibc-based Linux distribution, or run Coordigent from source with Bun." >&2
  exit 1
fi
case "$OS-$ARCH" in
  Darwin-arm64) PLATFORM="darwin-arm64" ;;
  Darwin-x86_64)
    # A shell running under Rosetta reports x86_64 even on an Apple Silicon Mac.
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
      PLATFORM="darwin-arm64"
    else
      PLATFORM="darwin-x64"
    fi
    ;;
  Linux-x86_64) PLATFORM="linux-x64" ;;
  Linux-aarch64|Linux-arm64) PLATFORM="linux-arm64" ;;
  *)
    echo "install.sh: no prebuilt binary for $OS-$ARCH." >&2
    echo "Supported: macOS arm64 and x86_64, Linux x86_64 and aarch64/arm64. Build from source with 'bun run build:cli'." >&2
    exit 1
    ;;
esac

# download <url> <file> [headers-file]: the response headers go to the third
# argument when there is one, so a refusal can say why.
if command -v curl >/dev/null 2>&1; then
  download() { curl -fsSL -o "$2" "$1" -D "${3:-/dev/null}"; }
elif command -v wget >/dev/null 2>&1; then
  download() {
    if [ -n "${3:-}" ]; then wget -S -O "$2" "$1" 2>"$3"; else wget -qO "$2" "$1"; fi
  }
else
  echo "install.sh: needs curl or wget." >&2
  exit 1
fi

# How to hash a file here. macOS ships shasum, Linux ships sha256sum, and Alpine
# may ship neither.
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  sha256() { echo ""; }
fi

# Why a binary download failed, from its response headers. The server limits
# downloads per address (a 429 with Retry-After in seconds); anything else is
# most likely a server that is not publishing binaries.
explain_download_failure() {
  status="$(sed -n 's/^[[:space:]]*HTTP\/[0-9.]*[[:space:]]\{1,\}\([0-9][0-9][0-9]\).*/\1/p' "$1" 2>/dev/null | tail -1)"
  if [ "$status" = "429" ]; then
    seconds="$(sed -n 's/^[[:space:]]*[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | tail -1)"
    if [ -n "$seconds" ]; then
      minutes=$(( (seconds + 59) / 60 ))
      [ "$minutes" -ge 1 ] || minutes=1
      echo "Too many downloads from this address. Try again in $minutes minute(s)." >&2
    else
      echo "Too many downloads from this address. Try again later." >&2
    fi
  else
    echo "The server may not be publishing binaries. See https://coordigent.com/docs/get-started/install." >&2
  fi
}

# The published digests, fetched once.
#
# Until this existed the installer piped bytes straight to disk and ran
# chmod +x, with nothing between a redirect and an executable on PATH. It is
# worth being clear about what this does and does not buy: it stops a corrupted
# download and a man-in-the-middle, and it does not stop a compromised server,
# because whoever can replace the binary can replace this manifest beside it.
# Signing with an offline key is what covers that, and this is the step that
# makes it possible rather than a substitute for it.
# The directory first: the manifest is fetched into it, and on a machine that
# has never installed before it does not exist yet. Created after the fetch,
# that download failed quietly and every first install went in unverified.
mkdir -p "$BIN_DIR"
CHECKSUMS=""
if download "$SERVER_URL/install/version" "$BIN_DIR/.version.json" 2>/dev/null; then
  CHECKSUMS="$(cat "$BIN_DIR/.version.json")"
  rm -f "$BIN_DIR/.version.json"
fi

published_sha() {
  # Pull one value out of the flat `checksums` object without needing jq.
  #
  # The artifact name appears twice in the response — once in the `artifacts`
  # array and once as a key in `checksums` — so the match requires the colon
  # that only the key has. Without it the array entry wins and every download
  # reads as unverified.
  printf '%s' "$CHECKSUMS" | tr ',' '\n' | grep "\"$1\"[[:space:]]*:" | head -1 |
    sed 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"//; s/".*//'
}

for name in coord coord-mcp; do
  artifact="$name-$PLATFORM"
  url="$SERVER_URL/install/$artifact"
  tmp="$BIN_DIR/$name.download"
  headers="$BIN_DIR/$name.headers"
  echo "Downloading $name ($PLATFORM)"
  if ! download "$url" "$tmp" "$headers"; then
    rm -f "$tmp"
    echo "install.sh: could not download $url" >&2
    explain_download_failure "$headers"
    rm -f "$headers"
    exit 1
  fi
  rm -f "$headers"

  # Between the download and the chmod, deliberately: nothing unverified should
  # ever become executable.
  expected="$(published_sha "$artifact")"
  if [ -n "$expected" ]; then
    actual="$(sha256 "$tmp")"
    if [ -z "$actual" ]; then
      rm -f "$tmp"
      echo "install.sh: cannot verify the download — no sha256sum or shasum on this machine." >&2
      echo "Install one, or build from source with 'bun run build:cli'." >&2
      exit 1
    fi
    if [ "$actual" != "$expected" ]; then
      rm -f "$tmp"
      echo "install.sh: $artifact does not match the checksum the server published." >&2
      echo "  expected $expected" >&2
      echo "  got      $actual" >&2
      echo "Nothing was installed. This is what a tampered or truncated download looks like." >&2
      exit 1
    fi
  else
    # An older server, or one whose build did not publish binaries. Say so
    # rather than failing closed on a deployment that predates the manifest.
    echo "install.sh: the server published no checksum for $artifact; installing unverified." >&2
  fi

  chmod +x "$tmp"
  mv -f "$tmp" "$BIN_DIR/$name"
done

# Whether a new shell is needed before `coord` resolves, decided before this
# script puts BIN_DIR on its own PATH.
case ":$PATH:" in
  *":$BIN_DIR:"*) ON_PATH=1 ;;
  *) ON_PATH=0 ;;
esac

PATH="$BIN_DIR:$PATH"
export PATH

# Make the binaries findable in new shells too. Appended once, never rewritten.
PATH_LINE="export PATH=\"$BIN_DIR:\$PATH\""
# A new machine may have no startup files yet. Create the current shell's
# entry point so opening a new terminal really makes coord available.
PROFILE=""
case "${SHELL:-}" in
  */zsh|zsh) PROFILE="${ZDOTDIR:-$HOME}/.zshrc" ;;
  */bash|bash) PROFILE="$HOME/.profile" ;;
  */sh|sh) PROFILE="$HOME/.profile" ;;
esac
create_profile() {
  [ -e "$1" ] && return 0
  # Profile edits are optional. Noclobber also keeps a concurrently created
  # file (or a dangling symlink) from being overwritten.
  if ! (mkdir -p "$(dirname "$1")" && set -C && : >"$1") 2>/dev/null; then
    echo "install.sh: could not create $1; continuing without it." >&2
  fi
}
if [ "$UPDATE_PATH" -eq 1 ] && [ "$ON_PATH" -eq 0 ] && [ -n "$PROFILE" ]; then
  create_profile "$PROFILE"
  case "${SHELL:-}" in
    */bash|bash) create_profile "$HOME/.bashrc" ;;
  esac
fi
PATH_PERSISTED=0
for rc in "$PROFILE" "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  [ "$UPDATE_PATH" -eq 1 ] || break
  [ "$ON_PATH" -eq 0 ] || break
  [ -f "$rc" ] || continue
  if grep -qF "$BIN_DIR" "$rc" 2>/dev/null; then
    PATH_PERSISTED=1
  elif (printf '\n# Added by the Coordigent installer\n%s\n' "$PATH_LINE" >>"$rc") 2>/dev/null; then
    echo "Added $BIN_DIR to PATH in $rc"
    PATH_PERSISTED=1
  else
    echo "install.sh: could not update $rc; continuing without changing it." >&2
  fi
done

echo "Installed coord and coord-mcp to $BIN_DIR"

# Which server this coord talks to. `coord login` and `coord update` fall back to
# the hosted server when nothing says otherwise, so a copy installed from staging or
# a self-hosted deployment would sign in to, and update from, the wrong one. On a
# machine with no config yet, record the server this script came from: a config with
# no token, which every command reads as logged out. An existing config is never
# rewritten; when it names another server, say which one this coord uses.
remember_server() {
  config="${TOWER_DIR:-$HOME/.tower}/config.json"
  if [ ! -f "$config" ]; then
    mkdir -p "$(dirname "$config")"
    (umask 077 && printf '{\n  "serverUrl": "%s"\n}\n' "$SERVER_URL" >"$config")
    return 0
  fi
  current=$(sed -n 's/.*"serverUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n 1)
  if [ -n "$current" ] && [ "${current%/}" != "${SERVER_URL%/}" ]; then
    echo "This coord uses $current. To use $SERVER_URL instead: coord login --server $SERVER_URL"
  fi
}

# Logged in means a config with a token, not just a config.
logged_in() {
  grep -q '"token"[[:space:]]*:[[:space:]]*"[^"]' "${TOWER_DIR:-$HOME/.tower}/config.json" 2>/dev/null
}

remember_server

# The tokenless ending: what to run next, and how to reach it from this shell.
next_login() {
  echo ""
  if [ "$ON_PATH" -eq 1 ]; then
    echo "Next: coord login"
  elif [ "$PATH_PERSISTED" -eq 1 ]; then
    echo "Next: coord login   (in a new terminal, or run $BIN_DIR/coord login)"
  else
    echo "Next: $BIN_DIR/coord login"
  fi
}

if [ "$RUN_CONNECT" -eq 0 ]; then
  next_login
  exit 0
fi

if [ -n "$TOKEN" ]; then
  exec "$BIN_DIR/coord" connect --server "$SERVER_URL" --token "$TOKEN"
fi

# No token supplied: connect still works if this machine already logged in.
if logged_in; then
  exec "$BIN_DIR/coord" connect
fi

# Not logged in, and `curl | sh` has no terminal on stdin to approve from, so
# login is the next thing the person runs rather than something run for them.
next_login

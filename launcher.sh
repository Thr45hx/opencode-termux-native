#!/data/data/com.termux/files/usr/bin/bash
# opencode — native Termux launcher (OpenCode, glibc Bun binary). No proot.
#
# OpenCode ships a glibc-dynamic Bun binary for linux-arm64. It runs natively
# once its interpreter is patchelf'd to Termux's glibc loader; the
# claude-resolvfix.so shim redirects /etc/resolv.conf and scrubs
# LD_PRELOAD/LD_LIBRARY_PATH so bionic child tools don't choke on glibc.
#
# Releases are distributed differently per major line:
#   1.x → GitHub release tarball (opencode-linux-arm64.tar.gz)
#   2.x → npm package @opencode/cli-linux-arm64 (binary at package/bin/opencode)
#
# Upstream's own `upgrade` (curl method) is unusable here: it drops a stock
# binary in ~/.opencode/bin and prepends it to PATH. This launcher intercepts
# `update`/`upgrade`, downloads the right artifact, re-patchelf's it, and
# verifies it before returning. `autoupdate: false` in opencode.jsonc stops the
# TUI/background updater; TUI `/update` is still upstream — use the CLI.
PREFIX="/data/data/com.termux/files/usr"
DIR="$HOME/agents/opencode"
BIN="$DIR/opencode"
GLD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
PE="$PREFIX/glibc/bin/patchelf"
SHIM="$PREFIX/lib/claude-resolvfix.so"
REPO="anomalyco/opencode"
CA="$PREFIX/etc/tls/cert.pem"
API_V2="https://opencode.ai/update/api/latest/cli/npm"
NPM_V1="https://registry.npmjs.org/opencode-ai/latest"

say(){ printf '[opencode] %s\n' "$*"; }
die(){ printf '[opencode] ERROR: %s\n' "$*" >&2; exit 1; }
norm(){ printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }
latest_v1(){ curl -fsSL "$NPM_V1" 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1; }
latest_v2(){ curl -fsSL "$API_V2" 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1; }

oc_run(){ env LD_PRELOAD="$SHIM" LD_LIBRARY_PATH="$PREFIX/glibc/lib" SSL_CERT_FILE="$CA" "$BIN" "$@"; }
oc_version(){ [ -x "$BIN" ] || return 0; oc_run --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }

usage(){
  cat <<'EOF'
Usage: opencode update [--major] [version]
       opencode upgrade [--major] [version]   (alias)

  (no args)   update within the current major line
              (fresh install / no binary: latest 2.x)
  --major     switch to the latest 2.x release
  version     pin a release, e.g. 2.1.3 or 1.19.4

Updates are fetched natively: 1.x from GitHub releases, 2.x from npm, then
re-patchelf'd for Termux. Upstream's own installer is never used.
EOF
}

[ -f "$BIN" ] && {
  [ "$(LD_PRELOAD= "$PE" --print-interpreter "$BIN" 2>/dev/null)" = "$GLD" ] || \
    LD_PRELOAD= "$PE" --set-interpreter "$GLD" "$BIN" 2>/dev/null
}

fetch_v1(){ # $1 = version (empty = latest 1.x)
  local v="${1:-}"
  [ -n "$v" ] || v="$(latest_v1)"
  [ -n "$v" ] || die "could not resolve latest 1.x version."
  v="${v#v}"
  curl -fL# "https://github.com/$REPO/releases/download/v${v}/opencode-linux-arm64.tar.gz" \
       -o "$TMP/o.tar.gz" || die "download failed."
}

fetch_v2(){ # $1 = version (empty = latest 2.x)
  local v="${1:-}"
  [ -n "$v" ] || v="$(latest_v2)"
  [ -n "$v" ] || die "could not resolve latest 2.x version from the channel API."
  v="${v#v}"
  curl -fL# "https://registry.npmjs.org/@opencode/cli-linux-arm64/-/cli-linux-arm64-${v}.tgz" \
       -o "$TMP/o.tar.gz" 2>/dev/null || \
  curl -fL# "https://registry.npmjs.org/@opencode-ai/cli-linux-arm64/-/cli-linux-arm64-${v}.tgz" \
       -o "$TMP/o.tar.gz" || die "download failed."
}

install_from(){
  tar xzf "$TMP/o.tar.gz" -C "$TMP" || die "extract failed."
  local src; src="$(find "$TMP" -type f -name opencode | head -1)"
  [ -n "$src" ] || die "opencode binary not in archive."
  mkdir -p "$DIR"
  install -m755 "$src" "$BIN" || die "install failed."
  LD_PRELOAD= "$PE" --set-interpreter "$GLD" "$BIN" 2>/dev/null
  [ "$(LD_PRELOAD= "$PE" --print-interpreter "$BIN" 2>/dev/null)" = "$GLD" ] || die "patchelf failed."
  local new; new="$(oc_version)"
  [ -n "$new" ] || die "installed binary failed to run."
  say "updated → ${new} (native, no proot)."
}

case "${1:-}" in
  update|upgrade)
    shift
    major=false; target=""; help=false
    for a in "$@"; do
      case "$a" in
        -h|--help) help=true ;;
        --major) major=true ;;
        -*) ;;
        *) [ -z "$target" ] && target="$a" ;;
      esac
    done
    [ "$help" = true ] && { usage; exit 0; }

    cur="$(oc_version)"
    ref="$(norm "${target:-$cur}")"
    maj="${ref%%.*}"

    line=2
    if [ -n "$target" ]; then
      [ -n "$maj" ] || die "invalid version: $target"
      line=1; [ "$maj" -ge 2 ] && line=2
    elif [ "$major" = true ]; then
      line=2
    elif [ -n "$maj" ]; then
      line=1; [ "$maj" -ge 2 ] && line=2
    fi

    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    if [ "$line" = 2 ]; then
      say "updating (2.x · npm · native) — current: ${cur:-none}, target: ${target:-latest}"
      fetch_v2 "$target"
    else
      say "updating (1.x · github · native) — current: ${cur:-none}, target: ${target:-latest}"
      fetch_v1 "$target"
    fi
    install_from
    exit 0
    ;;
esac

[ -f "$BIN" ] || die "binary not found at $BIN — run: opencode update"
exec env LD_PRELOAD="$SHIM" LD_LIBRARY_PATH="$PREFIX/glibc/lib" \
     SSL_CERT_FILE="$CA" "$BIN" "$@"

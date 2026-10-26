#!/data/data/com.termux/files/usr/bin/bash
#
# install.sh — OpenCode CLI, native on Termux (aarch64). No proot, no root.
#
# OpenCode ships a glibc-dynamic Bun binary. It runs native once its interpreter
# is patchelf'd to Termux's glibc loader; DNS comes from an LD_PRELOAD shim that
# redirects /etc/resolv.conf.
#
# Release lines are distributed differently:
#   2.x → npm package @opencode/cli-linux-arm64
#   1.x → GitHub release tarball (opencode-linux-arm64.tar.gz)
#
set -euo pipefail
say(){ printf '\033[1;36m[opencode-native]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[opencode-native] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
usage(){
  cat <<'EOF'
Usage: install.sh [--v1 | --v2] [version]

  (no args)   install the latest 2.x (npm)
  --v1        install the latest 1.x (GitHub releases)
  version     pin a release, e.g. 2.1.3 or 1.19.4
EOF
}

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
GL="$PREFIX/glibc"
GLD="$GL/lib/ld-linux-aarch64.so.1"
SHIM="$PREFIX/lib/claude-resolvfix.so"
RESOLV="$PREFIX/etc/resolv.conf"
DIR="$HOME_DIR/agents/opencode"
REPO="anomalyco/opencode"
RAW="https://raw.githubusercontent.com/Thr45hx/opencode-termux-native/main"

line=""; ver=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --v1) line=1 ;;
    --v2) line=2 ;;
    -*) die "unknown option: $1" ;;
    *) ver="$1" ;;
  esac
  shift
done
if [ -n "$ver" ]; then
  vn="${ver#v}"; maj="${vn%%.*}"
  case "$maj" in ''|*[!0-9]*) die "invalid version: $ver" ;; esac
  if [ "$maj" -ge 2 ]; then line=2; else line=1; fi
fi
[ -n "$line" ] || line=2

[ -d "$PREFIX" ] || die "Not a Termux environment."
case "$(uname -m)" in aarch64|arm64) ;; *) die "arm64/aarch64 only (found $(uname -m)).";; esac

# Base packages come first: on a fresh Termux curl may not exist yet, and the
# source fetch below needs it (dying with "curl required" here would be a bug).
say "Installing base packages (clang curl tar ca-certificates)…"
pkg update -y >/dev/null 2>&1 || true
pkg install -y clang curl tar ca-certificates >/dev/null || die "pkg install failed."

SRC="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
need=0; for f in launcher.sh fix_resolv.c; do [ -f "$SRC/$f" ] || need=1; done
if [ "$need" = 1 ]; then
  SRC="$(mktemp -d)"; say "Fetching source files…"
  for f in launcher.sh fix_resolv.c; do curl -fsSL "$RAW/$f" -o "$SRC/$f" || die "fetch $f failed"; done
fi

if [ ! -f "$GLD" ] || [ ! -x "$GL/bin/patchelf" ] || [ ! -x "$GL/bin/ld" ]; then
  say "Enabling the Termux glibc repo + runtime…"
  pkg install -y glibc-repo >/dev/null || die "glibc-repo failed."
  pkg update -y >/dev/null 2>&1 || true
  pkg install -y glibc patchelf-glibc binutils-glibc >/dev/null || die "glibc install failed."
fi
[ -f "$GLD" ] || die "glibc loader missing: $GLD"

if [ ! -f "$SHIM" ]; then
  say "Building DNS shim (claude-resolvfix.so)…"
  b="$(mktemp -d)"; cp "$SRC/fix_resolv.c" "$b/"
  ( cd "$b"
    clang --target=aarch64-linux-gnu -fPIC -O2 -fno-stack-protector -c fix_resolv.c -o fix_resolv.o
    "$GL/bin/ld" -shared -o libclaude-resolvfix.so fix_resolv.o -L"$GL/lib" -l:libc.so.6 -l:libdl.so.2
  ) || { rm -rf "$b"; die "shim build failed."; }
  install -m644 "$b/libclaude-resolvfix.so" "$SHIM"; rm -rf "$b"
fi
if [ ! -s "$RESOLV" ] || ! grep -q '^nameserver' "$RESOLV" 2>/dev/null; then
  mkdir -p "$(dirname "$RESOLV")"; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$RESOLV"
fi

mkdir -p "$DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ "$line" = 2 ] && [ -z "$ver" ] && [ -x "$DIR/opencode" ]; then
  say "Existing install found — moving to the latest 2.x (pass --v1 to stay on 1.x)."
fi
if [ "$line" = 2 ]; then
  if [ -z "$ver" ]; then
    ver="$(curl -fsSL https://opencode.ai/update/api/latest/cli/npm 2>/dev/null \
      | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1 || true)"
    [ -n "$ver" ] || die "could not resolve latest 2.x version."
  fi
  vn="${ver#v}"
  say "Downloading OpenCode 2 ($vn · npm · native)…"
  url="https://registry.npmjs.org/@opencode/cli-linux-arm64/-/cli-linux-arm64-${vn}.tgz"
  curl -fsSL "$url" -o "$TMP/o.tar.gz" 2>/dev/null || {
    url="https://registry.npmjs.org/@opencode-ai/cli-linux-arm64/-/cli-linux-arm64-${vn}.tgz"
    curl -fsSL "$url" -o "$TMP/o.tar.gz" || die "download failed."
  }
else
  if [ -z "$ver" ]; then
    ver="$(curl -fsSL https://registry.npmjs.org/opencode-ai/latest 2>/dev/null \
      | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1 || true)"
    [ -n "$ver" ] || die "could not resolve latest 1.x version."
  fi
  vn="${ver#v}"
  say "Downloading OpenCode 1 ($vn · github · native)…"
  url="https://github.com/$REPO/releases/download/v${vn}/opencode-linux-arm64.tar.gz"
  curl -fsSL "$url" -o "$TMP/o.tar.gz" || die "download failed."
fi
tar xzf "$TMP/o.tar.gz" -C "$TMP" || die "extract failed."
oc="$(find "$TMP" -type f -name opencode | head -1)"
[ -n "$oc" ] || die "opencode binary not in archive."
install -m755 "$oc" "$DIR/opencode"

"$GL/bin/patchelf" --set-interpreter "$GLD" "$DIR/opencode"
install -m755 "$SRC/launcher.sh" "$DIR/launcher.sh"
ln -sf "$DIR/launcher.sh" "$PREFIX/bin/opencode"

# Neutralize a prior *upstream* install. Its installer prepends ~/.opencode/bin to
# PATH in ~/.bashrc / ~/.zshrc, and that dir holds a stock-interpreter binary
# (unrunnable here) that would shadow our launcher. Comment out only the lines
# that reference that dir; everything else in the rc files is left alone.
for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.zshrc"; do
  [ -f "$rc" ] || continue
  grep -qE '^[[:space:]]*[^#[:space:]].*\.opencode/bin' "$rc" 2>/dev/null || continue
  cp -p "$rc" "$rc.bak-opencode"
  sed -i -E 's|^([[:space:]]*)([^#].*\.opencode/bin.*)$|\1# [opencode-termux-native] disabled: \2|' "$rc"
  say "Disabled stale ~/.opencode/bin PATH entry in $rc (backup: $rc.bak-opencode)"
done

# Disable OpenCode's upstream self-updater. On Termux its `upgrade` (curl method)
# runs the upstream install script, which drops a stock-interpreter binary in
# ~/.opencode/bin (unrunnable here) and prepends it to PATH in ~/.bashrc, quietly
# breaking the native install. The launcher intercepts `opencode update`/`upgrade`
# and does it the native way (re-download + patchelf) instead; setting
# autoupdate:false stops the TUI/background updater from re-triggering the bad path.
CFG_DIR="$HOME_DIR/.config/opencode"; CFGJSONC="$CFG_DIR/opencode.jsonc"; CFGJSON="$CFG_DIR/opencode.json"
if [ ! -f "$CFGJSONC" ] && [ ! -f "$CFGJSON" ]; then
  mkdir -p "$CFG_DIR"
  cat > "$CFGJSONC" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false
}
JSON
  say "Wrote $CFGJSONC (autoupdate disabled — update with 'opencode update')."
elif ! grep -qs '"autoupdate"' "$CFGJSONC" "$CFGJSON" 2>/dev/null; then
  say "TIP: add \"autoupdate\": false to your opencode config; update with 'opencode update'."
fi

say "Verifying…"
OC="$PREFIX/bin/opencode"
if "$OC" --version >/dev/null 2>&1; then say "Installed OpenCode $("$OC" --version 2>/dev/null | head -1) — native, no proot."; else say "Installed; run 'opencode'."; fi
echo
say "Auth:   opencode providers   (add API keys; free models + HuggingFace built in)"
say "Run:    opencode             (TUI)   |   opencode run \"...\"   (one-shot)"
say "Update: opencode update      (follows current major; --major jumps to 2.x)"

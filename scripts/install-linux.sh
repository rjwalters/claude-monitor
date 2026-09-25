#!/usr/bin/env bash
# install-linux.sh — one-command install/upgrade of the headless llm-monitor
# daemon on a Linux host (see README "Headless Mode / Linux").
#
# Acquires a binary (GitHub release, a from-source container build, or a
# local file), refuses to install one that is dynamically linked against the
# Swift runtime (the failure mode that left both fleet workers with a unit
# that couldn't start — see issue #187), installs it to a prefix (no sudo
# required for the default ~/.local prefix), installs/refreshes the systemd
# user unit with a rewritten ExecStart=, seeds accounts.env, and verifies the
# result with --version / selftest / systemctl status.
#
# Idempotent and safe to re-run: an unchanged version is reported as a no-op
# rather than reinstalled/restarted; a newer version upgrades in place and
# restarts the unit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
REPO="rjwalters/llm-monitor"
ASSET_NAME="llm-monitor-linux-x64"
UNIT_NAME="llm-monitor.service"
# Pre-2.0 names, retired on upgrade (the binary name survives as an alias).
LEGACY_UNIT_NAME="claude-monitor.service"
LEGACY_BIN_NAME="claude-monitor"
UNIT_SRC="$SCRIPT_DIR/$UNIT_NAME"

MODE=""
RELEASE_TAG=""
BINARY_PATH=""
PREFIX="$HOME/.local"
ACCOUNTS_ENV_PATH=""

log()  { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mwarning:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install-linux.sh (--from-release [TAG] | --from-source | --binary PATH)
                         [--prefix PATH] [--accounts-env PATH]

Install or upgrade the llm-monitor headless daemon on this Linux host:
acquires a binary, refuses one that is dynamically linked, installs it,
installs/refreshes the systemd user unit (rewriting ExecStart= to match),
seeds ~/.llm-monitor/accounts.env, and verifies the result. Idempotent —
safe to re-run for upgrades.

Binary source (exactly one required):
  --from-release [TAG]   Download the llm-monitor-linux-x64 asset from a
                          GitHub Release (latest if TAG is omitted) and
                          verify its checksum when the release API publishes
                          one.
  --from-source           Build inside the swift:6.1 Docker container with
                          --static-swift-stdlib (requires docker, no local
                          Swift toolchain needed).
  --binary PATH            Use an already-built binary from the local
                          filesystem.

Options:
  --prefix PATH           Install prefix; the binary goes to PATH/bin/
                          llm-monitor. Default: ~/.local (no sudo
                          required). A prefix not writable by the current
                          user (e.g. /usr/local) is installed via sudo.
  --accounts-env PATH     Seed ~/.llm-monitor/accounts.env from this file
                          (ACCOUNT_EMAIL_N / ACCOUNT_KEY_N pairs — see
                          README "Multiple Accounts"). Without this flag, an
                          empty 0600 placeholder is created if one doesn't
                          already exist.
  -h, --help               Show this help and exit.

Examples:
  install-linux.sh --from-release
  install-linux.sh --from-source
  install-linux.sh --binary ./LLMMonitor --prefix /usr/local
  install-linux.sh --from-release v2.0.0 --accounts-env ~/accounts.env
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-release)
            [[ -z "$MODE" ]] || fail "Only one of --from-release/--from-source/--binary may be given."
            MODE="release"
            shift
            if [[ $# -gt 0 && "$1" != -* ]]; then
                RELEASE_TAG="$1"
                shift
            fi
            ;;
        --from-source)
            [[ -z "$MODE" ]] || fail "Only one of --from-release/--from-source/--binary may be given."
            MODE="source"
            shift
            ;;
        --binary)
            [[ -z "$MODE" ]] || fail "Only one of --from-release/--from-source/--binary may be given."
            MODE="binary"
            [[ $# -ge 2 ]] || fail "--binary requires a PATH argument."
            BINARY_PATH="$2"
            shift 2
            ;;
        --prefix)
            [[ $# -ge 2 ]] || fail "--prefix requires a PATH argument."
            PREFIX="$2"
            shift 2
            ;;
        --accounts-env)
            [[ $# -ge 2 ]] || fail "--accounts-env requires a PATH argument."
            ACCOUNTS_ENV_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option '$1' (see --help)."
            ;;
    esac
done

[[ -n "$MODE" ]] || { usage >&2; fail "One of --from-release, --from-source, or --binary is required."; }

# Expand a leading ~ in --prefix (the shell only does this without quotes).
PREFIX="${PREFIX/#\~/$HOME}"
INSTALL_DIR="$PREFIX/bin"
INSTALL_BIN="$INSTALL_DIR/llm-monitor"
LEGACY_BIN="$INSTALL_DIR/$LEGACY_BIN_NAME"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGE_BIN="$STAGE_DIR/llm-monitor"

# --- Step 1: acquire a candidate binary into $STAGE_BIN -------------------

verify_digest() {
    local file="$1" digest="$2" algo expected actual
    algo="${digest%%:*}"
    expected="${digest#*:}"
    if [[ "$algo" != "sha256" ]]; then
        warn "Unsupported digest algorithm '$algo' on release asset — skipping checksum verification."
        return
    fi
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        fail "Checksum mismatch for downloaded binary: expected sha256:$expected, got sha256:$actual. Refusing to install a corrupted/tampered download."
    fi
    log "Checksum verified (sha256:$actual)."
}

acquire_from_release() {
    local api_path resolved_tag digest
    if [[ -n "$RELEASE_TAG" ]]; then
        api_path="repos/$REPO/releases/tags/$RELEASE_TAG"
    else
        api_path="repos/$REPO/releases/latest"
    fi

    if command -v gh >/dev/null 2>&1; then
        log "Fetching release metadata via 'gh api $api_path'..."
        local release_json
        release_json="$(gh api "$api_path" 2>/dev/null)" \
            || fail "Could not fetch release metadata for '$api_path'. Check network/gh auth, or use --from-source/--binary instead."
        resolved_tag="$(printf '%s' "$release_json" | jq -r '.tag_name // empty')"
        [[ -n "$resolved_tag" ]] || fail "No release found for '$api_path'."
        digest="$(printf '%s' "$release_json" | jq -r --arg name "$ASSET_NAME" '.assets[] | select(.name == $name) | .digest // empty')"

        log "Downloading $ASSET_NAME from release $resolved_tag..."
        gh release download "$resolved_tag" --repo "$REPO" --pattern "$ASSET_NAME" --dir "$STAGE_DIR" --clobber \
            || fail "Download failed for release '$resolved_tag' asset '$ASSET_NAME'."
        mv "$STAGE_DIR/$ASSET_NAME" "$STAGE_BIN"

        if [[ -n "$digest" ]]; then
            verify_digest "$STAGE_BIN" "$digest"
        else
            warn "Release asset has no published checksum digest — skipping checksum verification."
        fi
    else
        local url
        if [[ -n "$RELEASE_TAG" ]]; then
            url="https://github.com/$REPO/releases/download/$RELEASE_TAG/$ASSET_NAME"
        else
            url="https://github.com/$REPO/releases/latest/download/$ASSET_NAME"
        fi
        warn "'gh' CLI not found — downloading directly via curl (no checksum verification available this way)."
        command -v curl >/dev/null 2>&1 || fail "Neither 'gh' nor 'curl' is available to download the release asset."
        curl -fsSL -o "$STAGE_BIN" "$url" || fail "Download failed: $url"
    fi
}

acquire_from_source() {
    command -v docker >/dev/null 2>&1 || fail "--from-source requires docker (not found on PATH)."
    local src_dir="$REPO_ROOT/menubar-app/LLMMonitor"
    [[ -d "$src_dir" ]] || fail "Source directory not found at $src_dir — run this script from within an llm-monitor checkout."
    log "Building in the swift:6.1 container (~1 minute)..."
    docker run --rm -v "$src_dir:/src" -w /src swift:6.1 bash -c \
        'apt-get update -qq && apt-get install -y -qq libsqlite3-dev && swift build -c release --static-swift-stdlib' \
        || fail "Container build failed."
    local built_bin="$src_dir/.build/release/LLMMonitor"
    [[ -f "$built_bin" ]] || fail "Container build did not produce $built_bin."
    cp "$built_bin" "$STAGE_BIN"
}

acquire_from_binary() {
    [[ -f "$BINARY_PATH" ]] || fail "--binary path does not exist: $BINARY_PATH"
    cp "$BINARY_PATH" "$STAGE_BIN"
}

case "$MODE" in
    release) acquire_from_release ;;
    source)  acquire_from_source ;;
    binary)  acquire_from_binary ;;
esac
chmod 755 "$STAGE_BIN"

# --- Step 2: refuse a dynamically-linked binary before touching anything --

if command -v ldd >/dev/null 2>&1; then
    LDD_OUTPUT="$(ldd "$STAGE_BIN" 2>&1 || true)"
    if printf '%s\n' "$LDD_OUTPUT" | grep -qi 'not found'; then
        printf '%s\n' "$LDD_OUTPUT" >&2
        fail "Refusing to install: the binary has unresolved dynamic dependencies (see 'not found' lines above). Use a --static-swift-stdlib build — see README \"Headless Mode / Linux\"."
    fi
    log "ldd check passed (no unresolved dynamic dependencies)."
else
    warn "'ldd' not found — skipping the dynamic-link safety check."
fi

# Smoke-test the staged binary and read its version before installing
# anything — this also catches an architecture mismatch early.
NEW_VERSION="$("$STAGE_BIN" --version 2>&1)" \
    || fail "Staged binary failed to run '--version': $NEW_VERSION"
log "Staged binary: $NEW_VERSION"

# --- Step 3: install the binary (upgrade-in-place / no-op detection) ------

maybe_sudo() {
    if [[ -w "$INSTALL_DIR" ]] || { [[ ! -e "$INSTALL_DIR" ]] && [[ -w "$(dirname "$INSTALL_DIR")" ]]; }; then
        "$@"
    else
        log "'$PREFIX' is not writable by $(whoami) — using sudo for this step."
        sudo "$@"
    fi
}

OLD_VERSION=""
if [[ -x "$INSTALL_BIN" ]]; then
    OLD_VERSION="$("$INSTALL_BIN" --version 2>/dev/null || true)"
elif [[ -x "$LEGACY_BIN" && ! -L "$LEGACY_BIN" ]]; then
    OLD_VERSION="$("$LEGACY_BIN" --version 2>/dev/null || true)"
fi

BINARY_CHANGED=false
if [[ -n "$OLD_VERSION" && "$OLD_VERSION" == "$NEW_VERSION" ]]; then
    log "llm-monitor is already up to date ($NEW_VERSION at $INSTALL_BIN) — no-op, skipping reinstall."
else
    maybe_sudo mkdir -p "$INSTALL_DIR"
    maybe_sudo cp "$STAGE_BIN" "$INSTALL_BIN"
    maybe_sudo chmod 755 "$INSTALL_BIN"
    BINARY_CHANGED=true
    if [[ -n "$OLD_VERSION" ]]; then
        log "Upgraded $INSTALL_BIN: $OLD_VERSION -> $NEW_VERSION"
    else
        log "Installed $INSTALL_BIN ($NEW_VERSION)"
    fi
fi

# The pre-2.0 command name stays as an alias: `accounts push` from a peer
# (and any script or muscle memory) still calls `claude-monitor`. This also
# replaces a 1.x binary left at that path.
if [[ "$(readlink "$LEGACY_BIN" 2>/dev/null)" != "llm-monitor" ]]; then
    maybe_sudo ln -sfn "llm-monitor" "$LEGACY_BIN"
    log "Linked $LEGACY_BIN -> llm-monitor (compatibility alias)."
fi

# --- Step 4: install/refresh the systemd user unit -------------------------

[[ -f "$UNIT_SRC" ]] || fail "Reference unit file not found at $UNIT_SRC."

UNIT_DEST_DIR="$HOME/.config/systemd/user"
UNIT_DEST="$UNIT_DEST_DIR/$UNIT_NAME"
mkdir -p "$UNIT_DEST_DIR"

RENDERED_UNIT="$STAGE_DIR/$UNIT_NAME"
sed "s|^ExecStart=.*|ExecStart=$INSTALL_BIN|" "$UNIT_SRC" > "$RENDERED_UNIT"

UNIT_CHANGED=false
if [[ ! -f "$UNIT_DEST" ]] || ! cmp -s "$RENDERED_UNIT" "$UNIT_DEST"; then
    cp "$RENDERED_UNIT" "$UNIT_DEST"
    UNIT_CHANGED=true
    log "Installed/updated systemd user unit at $UNIT_DEST (ExecStart=$INSTALL_BIN)"
else
    log "systemd user unit already up to date at $UNIT_DEST."
fi

command -v systemctl >/dev/null 2>&1 || fail "systemctl not found — cannot manage the systemd user unit on this host."

systemctl --user show-environment >/dev/null 2>&1 \
    || fail "systemctl --user is not reachable in this session (no user D-Bus session). Use a full login shell (not 'ssh host cmd'), or have an admin run 'loginctl enable-linger $(whoami)' first, then re-run this script."

# Retire the pre-2.0 unit so two pollers never run side by side.
LEGACY_UNIT_DEST="$UNIT_DEST_DIR/$LEGACY_UNIT_NAME"
if [[ -f "$LEGACY_UNIT_DEST" ]]; then
    systemctl --user disable --now "$LEGACY_UNIT_NAME" 2>/dev/null || true
    rm -f "$LEGACY_UNIT_DEST"
    log "Stopped and removed the pre-2.0 unit $LEGACY_UNIT_NAME."
fi

systemctl --user daemon-reload

# --- Step 4b: move the data directory to its 2.0 name ----------------------
#
# Mirrors AppPaths.migrateLegacyDataDirectory, but runs *before* the unit
# starts: seeding accounts.env below must not create ~/.llm-monitor beside a
# not-yet-moved ~/.claude-monitor (the daemon would then see two real
# directories and refuse to merge them). ~/.claude-monitor stays as a symlink
# because loom-daemon reads it.
DATA_DIR="$HOME/.llm-monitor"
LEGACY_DATA_DIR="$HOME/.claude-monitor"
if [[ -L "$LEGACY_DATA_DIR" ]]; then
    mkdir -p "$DATA_DIR"
elif [[ -d "$LEGACY_DATA_DIR" ]]; then
    if [[ -e "$DATA_DIR" ]]; then
        fail "Both $LEGACY_DATA_DIR and $DATA_DIR exist as real directories. Merge or remove one, then re-run."
    fi
    mv "$LEGACY_DATA_DIR" "$DATA_DIR"
    ln -s ".llm-monitor" "$LEGACY_DATA_DIR"
    log "Moved $LEGACY_DATA_DIR to $DATA_DIR (old path kept as a symlink)."
else
    mkdir -p "$DATA_DIR"
    [[ -e "$LEGACY_DATA_DIR" ]] || ln -s ".llm-monitor" "$LEGACY_DATA_DIR"
fi

# --- Step 5: seed accounts.env (start-then-seed-then-restart ordering) ----
#
# The unit is enabled+started *before* accounts.env is seeded so the daemon
# has already created ~/.llm-monitor/usage.db's schema on first launch —
# this is independent of whether #188 has landed. accounts.env
# is picked up automatically on every poll cycle, but we still restart right
# after seeding it so a freshly-provisioned host doesn't wait a full poll
# interval for its first account sync.

systemctl --user enable --now "$UNIT_NAME"
log "systemd user unit '$UNIT_NAME' enabled and started."

if ! loginctl show-user "$(whoami)" -p Linger --value 2>/dev/null | grep -q '^yes$'; then
    log "Enabling lingering for $(whoami) so the poller survives logout..."
    if ! loginctl enable-linger "$(whoami)" 2>/dev/null; then
        warn "Could not enable lingering (loginctl denied it non-interactively). The unit will stop at logout unless an admin runs: sudo loginctl enable-linger $(whoami)"
    fi
else
    log "Lingering already enabled for $(whoami)."
fi

ACCOUNTS_ENV_DEST="$DATA_DIR/accounts.env"
ACCOUNTS_SEEDED=false
if [[ -n "$ACCOUNTS_ENV_PATH" ]]; then
    [[ -f "$ACCOUNTS_ENV_PATH" ]] || fail "--accounts-env path does not exist: $ACCOUNTS_ENV_PATH"
    cp "$ACCOUNTS_ENV_PATH" "$ACCOUNTS_ENV_DEST"
    chmod 600 "$ACCOUNTS_ENV_DEST"
    ACCOUNTS_SEEDED=true
    log "Seeded $ACCOUNTS_ENV_DEST from $ACCOUNTS_ENV_PATH"
elif [[ ! -f "$ACCOUNTS_ENV_DEST" ]]; then
    cat > "$ACCOUNTS_ENV_DEST" <<'EOF'
# llm-monitor accounts.env — ACCOUNT_EMAIL_N / ACCOUNT_KEY_N pairs.
# See README "Multiple Accounts": https://github.com/rjwalters/llm-monitor#multiple-accounts
# Edits here are picked up automatically while the daemon is running.
EOF
    chmod 600 "$ACCOUNTS_ENV_DEST"
    log "Created empty placeholder $ACCOUNTS_ENV_DEST (0600)."
else
    log "$ACCOUNTS_ENV_DEST already exists — leaving it untouched."
fi

# --- Step 6: restart if anything changed since the unit was (re)started ---

if [[ "$BINARY_CHANGED" == true || "$UNIT_CHANGED" == true || "$ACCOUNTS_SEEDED" == true ]]; then
    log "Restarting '$UNIT_NAME' to pick up the change..."
    systemctl --user restart "$UNIT_NAME"
else
    log "Nothing changed this run — leaving the running unit as-is."
fi

# --- Step 7: verify ---------------------------------------------------------

echo
log "Installed version: $("$INSTALL_BIN" --version)"
log "Running selftest..."
"$INSTALL_BIN" selftest || fail "selftest failed against the installed binary — see output above."

echo
echo "== systemctl --user status $UNIT_NAME (head) =="
systemctl --user status "$UNIT_NAME" --no-pager 2>&1 | head -n 10 || true

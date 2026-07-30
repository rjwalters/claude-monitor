#!/usr/bin/env bash
# daemon-env-harvest.sh — shared harvesters for a live launchd plist's /
# systemd unit's LOOM_*/token EnvironmentVariables (#4581).
#
# Extracted from loom-daemon-update.sh's perform_relaunch / perform_systemd_
# relaunch (#4118/#4126), which already apply the harvest-and-preserve
# pattern on ITS equivalent refused-restart fallback: before re-rendering the
# plist/unit, read back the LIVE installed file's LOOM_*/token env and
# re-export it, so the re-render never silently narrows to whatever LOOM_*
# vars happen to be exported in the invoking shell. scripts/loom's
# `loom_cmd_restart()` bare-exec fallback had the identical shape but skipped
# this step entirely (the #4522/#4579 incident) — sharing this lib lets both
# call sites apply the same, single-sourced pattern instead of drifting.
#
# Source this file (do not exec). Defines two functions:
#
#   harvest_plist_env <plist>
#     Echoes "<key>\t<base64(value)>" lines (one per key, base64 so values
#     with spaces/newlines survive) restricted to exactly the keys
#     render_launchd_plist (loom-daemon-start.sh) itself forwards — LOOM_*,
#     GH_TOKEN, GITEA_TOKEN, FORGE_TOKEN — and EXCLUDING:
#       - PATH / HOME     (start.sh resolves PATH deterministically; round-
#                          tripping the plist's PATH here would re-introduce
#                          the non-deterministic-render bug it fixed, #4172)
#       - LOOM_DAEMON_SUPERVISOR (start.sh hardcodes it; re-exporting is
#                          pointless)
#     Returns 2 (with a stderr diagnostic) when the plist is missing or
#     unparseable (plutil/jq absent, or the plist fails to parse) — NEVER
#     silently returns an empty set, which would let a caller re-render into
#     a silently-narrowed, FLAGS-OFF-defaults autonomy config (#4011).
#
#   harvest_unit_env <unit_path>
#     Echoes "<key>\t<value>" lines (no base64 — a systemd `Environment=`
#     line is single-valued) with the identical key allowlist/exclusion,
#     mirroring render_systemd_unit (loom-daemon-start.sh). Returns 2 (with a
#     stderr diagnostic) when the unit file is missing — same "never return
#     an empty set silently" contract as harvest_plist_env.
#
# Callers decide what "harvest failed" means for them (loom-daemon-update.sh's
# perform_relaunch/perform_systemd_relaunch treat it as a hard abort; see
# scripts/loom's loom_cmd_restart() for the equivalent bare-exec-fallback use).

harvest_plist_env() {
    local plist="$1"
    if [[ ! -f "$plist" ]]; then
        echo "Cannot harvest launchd env: plist not found at $plist" >&2
        return 2
    fi
    if ! command -v plutil >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "Cannot harvest launchd env: plutil and jq are both required on the macOS launchd path." >&2
        return 2
    fi
    local json
    json=$(plutil -convert json -o - "$plist" 2>/dev/null) || {
        echo "Cannot harvest launchd env: plist at $plist is not parseable by plutil." >&2
        return 2
    }
    printf '%s' "$json" | jq -r '
        .EnvironmentVariables // {}
        | to_entries[]
        | select(.key | test("^(LOOM_[A-Za-z0-9_]*|GH_TOKEN|GITEA_TOKEN|FORGE_TOKEN)$"))
        | select(.key != "LOOM_DAEMON_SUPERVISOR")
        | .key + "\t" + (.value | @base64)
    ' 2>/dev/null || {
        echo "Cannot harvest launchd env: failed to extract EnvironmentVariables from $plist." >&2
        return 2
    }
}

harvest_unit_env() {
    local unit_path="$1"
    if [[ ! -f "$unit_path" ]]; then
        echo "Cannot harvest systemd unit env: unit file not found at $unit_path" >&2
        return 2
    fi
    local line rest key value
    while IFS= read -r line; do
        [[ "$line" == Environment=* ]] || continue
        rest="${line#Environment=}"
        key="${rest%%=*}"
        value="${rest#*=}"
        case "$key" in
            LOOM_DAEMON_SUPERVISOR) continue ;;
            LOOM_*|GH_TOKEN|GITEA_TOKEN|FORGE_TOKEN) printf '%s\t%s\n' "$key" "$value" ;;
            *) continue ;;
        esac
    done < "$unit_path"
}

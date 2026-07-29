#!/usr/bin/env bash
# build-gate.sh - buildGate.command for this repo: fast build+test backstop
# across Rust, Python, and bash. Runs in the worktree; exits non-zero on the
# first failing stage (set -e) so buildGate.command's single exit code is
# meaningful. See .loom/docs/build-gate.md.
#
# Scope decisions (issue #3749):
#   - cargo test covers the Rust crates (loom-daemon, loom-api). As of #3985
#     the Rust step is scoped to `--lib --bins` (crate unit tests only) and
#     deliberately EXCLUDES the integration test TARGETS under
#     loom-daemon/tests/ (integration_basic.rs et al). Those spin up a real
#     tmux server and are therefore host-dependent — green only where a live
#     tmux is reachable. The local gate runs on the very host that is actively
#     running Loom (a busy, sometimes tmux-less machine), so a host-dependent
#     assertion there measures the host, not `main`. CI (.github/workflows/
#     ci.yml) controls its environment and still runs the FULL
#     `cargo test --workspace`, so the integration targets are covered exactly
#     where their environment is guaranteed. See "Local gate vs. CI" in
#     .loom/docs/build-gate.md.
#   - loom-tools pytest runs via `uv run` so the package is importable from
#     the project venv; scoped to exclude the live-network e2e suite
#     (tests/integration) and the known slow real-time bypass-poll integration
#     test file (already stubbed in-tree, but excluded here to keep the gate
#     fast and stable).
#   - bash scripts/test-installer.sh runs the 131-case installer suite.
#   - mcp-loom (TypeScript) is intentionally EXCLUDED: it needs npm install/ci
#     in a fresh worktree (no guaranteed warm node_modules), which adds
#     unpredictable latency to a gate that also runs once per PR. CI still
#     gates the mcp-loom build.
set -euo pipefail

# Gate/sweep scheduling priority (#4020, revises #3985).
#
# #3985 re-exec'd the gate at `nice -n 19` (the lowest priority) so it "could
# never starve the sweeps it shares a host with." That rationale rested on a
# now-FALSIFIED premise: that concurrent sweep builds were starving the gate's
# (and sweeps') timing-sensitive `cargo` tests. #4044/#4046 established those 17
# red daemon tests were macOS `syspolicyd` exec-latency artifacts, not CPU
# contention (968/968 passed later with no code change), and the one real gate
# timeout was cold-compile cost, settled by #4048 raising the budget 600->1200s
# (the gate then produced its first determinate verdict, Green at ~726s). So the
# gate was handicapped to the bottom of the run queue to solve a problem that was
# never real. The extreme 19-point handicap is withdrawn.
#
# The gate is NOT restored to `nice 0` parity with sweeps, though. Sweep children
# spawn at the default niceness (0); making the gate also 0 leaves both at the
# same value, and on the daemon host (macOS, non-root) a strictly-higher gate
# priority is not achievable from here — a lower (negative) nice requires
# privilege the daemon does not hold (`nice -n -5` => "setpriority: Permission
# denied"), so gate and sweeps would sit at an indistinguishable nice 0 with no
# measurable gap between them (AC2 of #4020 calls that a failure: "A patch that
# leaves both at the same value fails this AC").
#
# So the gate defaults to a MILD POSITIVE niceness (5): high enough above the
# sweep default (0) to be a real, non-zero, unprivileged-achievable gap — the
# gate yields slightly under contention so it can never starve the sweeps it
# shares a host with — but nowhere near the extreme nice-19 bottom-of-the-queue
# handicap that starved the gate itself into UNEVALUATED (the gate is the
# reliability substrate that halts dispatch when `main` goes red; a gate that
# never gets scheduled is a gate that is not gating). gate=5 > sweeps=0 is a
# measured one-sided gap in the achievable direction, satisfying AC2.
#
# The alternative — niceing sweep children *up* in the spawn path (loom-daemon
# spawn_child + spawn-claude.sh) to force a strict gate<sweep gap — is
# deliberately not done here: the issue directed the spawn path be left
# untouched, and the contention it would brace against is the one the evidence
# above withdrew.
#
# The re-exec mechanism and its knobs are preserved: LOOM_BUILD_GATE_NICENESS
# overrides the value (e.g. =0 for parity, =19 to restore the old handicap),
# LOOM_BUILD_GATE_NICE=0 disables the re-exec entirely, and the
# LOOM_BUILD_GATE_NICED sentinel guards against a re-exec loop. The re-exec is
# skipped when the effective niceness is 0 (a `nice -n 0` re-exec is a no-op
# fork); with the default of 5 the gate re-execs once under `nice -n 5`.
# Best-effort: if `nice` is absent we just proceed at normal priority.
_gate_niceness="${LOOM_BUILD_GATE_NICENESS:-5}"
if [[ -z "${LOOM_BUILD_GATE_NICED:-}" \
      && "${LOOM_BUILD_GATE_NICE:-1}" != "0" \
      && "${_gate_niceness}" != "0" ]] \
   && command -v nice >/dev/null 2>&1; then
  export LOOM_BUILD_GATE_NICED=1
  exec nice -n "${_gate_niceness}" "$0" "$@"
fi

cd "$(git rev-parse --show-toplevel)"

echo "[build-gate] cargo test --lib --bins (workspace unit tests; host-dependent integration targets are CI-only, #3985)"
cargo test --workspace --lib --bins

echo "[build-gate] loom-tools pytest (scoped, excludes network e2e + known slow poll test)"
(
  cd loom-tools
  uv run pytest tests/ -q \
    --ignore=tests/integration \
    --ignore=tests/tokens/test_agent_spawn_integration.py
)

echo "[build-gate] bash installer suite"
bash scripts/test-installer.sh

echo "[build-gate] all stages passed"

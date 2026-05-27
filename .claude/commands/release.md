# Release Manager

You are preparing a release of **Claude Monitor**.

## Overview

This is a careful, interactive release process. Every release must:

1. Verify the working tree is clean and CI is green on main
2. Analyze what changed since the last release
3. Help the user decide the correct semver bump
4. Draft and refine the CHANGELOG entry
5. Update the version in both version-bearing files
6. Commit, tag, and (with confirmation) push
7. Build the app locally and create a GitHub Release with the `.zip` attached

**Do not rush. Each phase requires user confirmation before proceeding.**

## Phase 1: Pre-flight Checks

```bash
# Working tree must be clean
git status

# Most recent CI runs on main
gh run list --branch main --limit 5 --json name,conclusion,headSha --jq '.[] | "\(.name): \(.conclusion)"'

# Open PRs that might need to land first
gh pr list --state open --json number,title --jq '.[] | "#\(.number) \(.title)"'
```

Present findings. If CI is failing or the tree is dirty, stop and resolve first. If there are open PRs, ask whether any should land before the release.

## Phase 2: Gather Changes

```bash
# Last release tag (semver-sorted)
git tag --sort=-v:refname | head -3

# Commits since that tag
git log <last-tag>..HEAD --oneline

# Diff stats
git diff <last-tag>..HEAD --stat
```

Present:

- **Last release** — tag, date
- **Commits since release** — count and full list
- **Change summary** — grouped by intent (features / fixes / refactor / docs / chore)
- **Files changed** — high-level: which subsystems (Swift sources, scripts, docs)

If there are zero commits since the last tag, stop — nothing to release.

## Phase 3: Semver Decision

Reference https://semver.org. Then walk the changes:

### Breaking (MAJOR bump)

- Database schema changes that aren't backward-compatible
- Removing or renaming a public CLI flag, menu-bar interaction, or settings key
- Anything that requires the user to redo setup (re-add accounts, re-paste tokens)

### New capabilities (MINOR bump)

- New popover columns, charts, account-management features
- New settings, polling strategies, integrations
- Notable UX additions

### Patch (PATCH bump)

- Bug fixes
- Performance / polling tweaks
- Internal refactors with no user-visible effect
- Doc/comment-only changes

Present your recommendation and **ask the user to confirm or override**.

## Phase 4: Draft CHANGELOG

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/) and is not pre-populated with an `[Unreleased]` section — the new entry is inserted directly below the top heading block.

Format (match the existing entries' tone):

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Summary

One short paragraph describing the release theme.

### Added

- ...

### Changed

- ...

### Fixed

- ...
```

Rules:

- Use today's date in `YYYY-MM-DD`
- Group under `### Added` / `### Changed` / `### Fixed` / `### Removed` / `### Renamed` — omit empty sections
- Bold the lead phrase of each bullet when it names a feature/UI element (`**Headroom score column.**`)
- Keep bullets concise but informative
- Reference issues/PRs as `(#NNN)` when relevant

Present the draft and iterate until approved.

## Phase 5: Apply Changes

Once approved:

1. **Insert the CHANGELOG entry** directly below the top metadata block (line ~6) in `CHANGELOG.md`.
2. **Bump version in both files:**
   - `menubar-app/ClaudeMonitor/Sources/UsageStore.swift` — `AppVersion.current = "X.Y.Z"`
   - `scripts/build-macos-app.sh` — both `CFBundleVersion` and `CFBundleShortVersionString`
3. **Sanity-check no other file holds the old version:**
   ```bash
   grep -rn "<old-version>" --include="*.swift" --include="*.sh" --include="*.json" --include="*.md" . | grep -v ".build" | grep -v node_modules
   ```
4. **Build to verify it compiles:**
   ```bash
   cd menubar-app/ClaudeMonitor && swift build
   ```
5. **Commit:**
   ```bash
   git add CHANGELOG.md menubar-app/ClaudeMonitor/Sources/UsageStore.swift scripts/build-macos-app.sh
   git commit -m "Release vX.Y.Z: <one-line summary>"
   ```
6. **Tag (annotated):**
   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z - <one-line summary>"
   ```

Show the result (`git log -1`, `git tag --list --sort=-v:refname | head -3`) and ask for final confirmation before pushing.

## Phase 6: Push

After confirmation:

```bash
git push origin main
git push origin vX.Y.Z
```

## Phase 7: Build and Publish GitHub Release

The build is local — there is no release workflow that produces the `.zip`. The app must be built and uploaded by hand.

1. **Build the app bundle:**
   ```bash
   ./scripts/build-macos-app.sh
   ```
   This produces `build/ClaudeMonitor.app` and `build/ClaudeMonitor.zip`. The script auto-detects the installed `claude-code` version (via npm) and patches the User-Agent in `AnthropicAPI.swift` before compiling — confirm with the user that the local `claude-code` is on the version they want to ship with.

2. **Verify the `.zip` exists** at `build/ClaudeMonitor.zip` and is non-trivially sized.

3. **Create the GitHub Release** using the CHANGELOG entry as the body:
   ```bash
   gh release create vX.Y.Z \
     --title "vX.Y.Z" \
     --notes "$(awk '/^## \[X\.Y\.Z\]/,/^## \[/{ if (/^## \[/ && !/X\.Y\.Z/) exit; print }' CHANGELOG.md | sed '$d')" \
     build/ClaudeMonitor.zip
   ```
   (Manually extract the new entry from CHANGELOG.md if the awk doesn't pick up cleanly — past releases have the body matching the `### Summary` + section bullets, without the `## [X.Y.Z] - DATE` header.)

4. **Verify the release page** shows the `.zip` asset and that the notes render correctly:
   ```bash
   gh release view vX.Y.Z --json name,assets,url --jq '.'
   ```

## Phase 8: Post-Release Summary

Present:

```
## Release Complete

- Version: vX.Y.Z
- Commit: <sha>
- Tag: vX.Y.Z
- GitHub Release: <url>
- Asset: ClaudeMonitor.zip (<size>)
- CHANGELOG: updated
```

## Important Notes

- **Two version-bearing files:** `menubar-app/ClaudeMonitor/Sources/UsageStore.swift` (`AppVersion.current`) and `scripts/build-macos-app.sh` (CFBundleVersion + CFBundleShortVersionString). Keep them in lockstep — `UpdateChecker` compares `AppVersion.current` to GitHub's latest tag, while macOS surfaces the `CFBundleShortVersionString` in About.
- **Tag format:** `vX.Y.Z` (annotated, with a one-line message).
- **Build is local.** `.github/workflows/build.yml` only runs `swift build` on push/PR; it does not produce or attach release artifacts.
- **`build-macos-app.sh` rewrites `AnthropicAPI.swift`** with the locally-installed `claude-code` User-Agent. Confirm that version is what you want to ship.
- **Installing the new build** (for sanity check): see CLAUDE.md — you must `rm -rf /Applications/ClaudeMonitor.app` first because `cp -R` doesn't replace a running app.
- **Do not push or create the release without explicit user confirmation** at each phase.

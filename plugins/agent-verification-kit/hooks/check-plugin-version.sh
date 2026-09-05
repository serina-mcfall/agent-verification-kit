#!/usr/bin/env bash
# Refuses a branch that changes a plugin's hooks or metadata without raising the
# version in its plugin.json.
#
#   bash check-plugin-version.sh [BASE_REF]      default: origin/main
#
# ---------------------------------------------------------------------------
# WHY. INC-0019, and it is the quietest defect this kit has produced.
#
# Stages 2 and 3 both shipped under version 0.1.0. The plugin cache directory is
# keyed by that version, so `/plugin install` correctly reported "already
# installed" and copied nothing. Every existing installation stayed on Stage 1
# while the README and the marketplace advertised three stages. The hooks were on
# `main`, they were in the marketplace clone, and they were not on anyone's machine.
#
# THE REASON IT SURVIVED A DELIBERATE INSTALL PROBE is worth stating, because the
# same blind spot will hide the next one. A FRESH install gets the current files
# regardless of version. Stage 2's install evidence was a first install, so it was
# real and it proved nothing about upgrades. Only an EXISTING installation is
# affected — and the person shipping is the least likely to have one.
#
# So this check is aimed at a failure mode the author cannot easily observe, which
# is the only kind worth automating.
#
# ---------------------------------------------------------------------------
# WHAT COUNTS AS A CHANGE NEEDING A BUMP
#
# Anything under `plugins/<name>/` that the installed copy would carry: hooks,
# hooks.json, and .claude-plugin/plugin.json itself. The description in that file
# is what a user reads when deciding to install, so shipping new wording under an
# old version means nobody with the plugin ever sees it.
#
# NOT the README, NOT records/, NOT the workflow — none of those are installed.
#
# ---------------------------------------------------------------------------
# THREE EXIT CODES, NEVER TWO
#
#   0  no installed file changed, or the version was raised
#   1  an installed file changed and the version did not go up
#   3  could not check
#
# Every failure mode of a diff-based checker produces an empty file list, and an
# empty list reads as "nothing to do". That is INC-0006. A missing plugin.json, a
# missing version field, an unresolvable base ref and a non-repo all exit 3.
# ---------------------------------------------------------------------------

set -u

BASE="${1:-${AVK_BASE_REF:-origin/main}}"

die() { printf 'check-plugin-version: CANNOT DETERMINE — %s\n' "$1" >&2; exit 3; }

REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside a git repository (cwd $(pwd))."
[ -n "$REPO" ] || die "not inside a git repository (cwd $(pwd))."

git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 \
    || die "base ref '$BASE' does not resolve. In CI this usually means a shallow clone. An unresolvable base yields an empty file list, which would otherwise look exactly like a branch that touched no plugin files."

MERGE_BASE=$(git merge-base "$BASE" HEAD 2>/dev/null) \
    || die "no merge base between '$BASE' and HEAD."

# Pathspec is `plugins`, NOT 'plugins/*' — a glob `*` does not cross `/` here, so the
# starred form matches nothing and returns an empty list. An empty list from a
# diff-based check reads as "clean", so that typo would have been a silent fail-open.
CHANGED=$(git diff --name-only "$MERGE_BASE..HEAD" -- plugins 2>/dev/null) \
    || die "git diff failed over $MERGE_BASE..HEAD."

# version_at <ref> <path> — prints the version, or nothing if unreadable.
version_at() {
    git show "$1:$2" 2>/dev/null \
        | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1
}

problems=""
n_plugins=0

# One plugin per plugin.json, so a repo shipping several is handled rather than assumed away.
for manifest in $(git ls-tree -r --name-only HEAD -- plugins | grep '/\.claude-plugin/plugin\.json$'); do
    n_plugins=$((n_plugins + 1))
    plugin_dir="${manifest%/.claude-plugin/plugin.json}"

    # Which installed files under THIS plugin changed?
    touched=$(printf '%s\n' "$CHANGED" | grep "^$plugin_dir/" | grep -v '^$')
    [ -z "$touched" ] && continue

    new_v=$(version_at HEAD "$manifest")
    [ -n "$new_v" ] || die "$manifest has no readable \"version\" field at HEAD. A plugin whose version cannot be read cannot be checked, and reporting a clean run would be a guess."

    old_v=$(version_at "$MERGE_BASE" "$manifest")
    if [ -z "$old_v" ]; then
        # New plugin on this branch — nothing to compare against, and that is fine.
        continue
    fi

    # Strictly greater by version ordering. `sort -V` so 0.10.0 beats 0.9.0, which
    # a string comparison gets backwards.
    if [ "$old_v" = "$new_v" ] \
       || [ "$(printf '%s\n%s\n' "$old_v" "$new_v" | sort -V | tail -1)" != "$new_v" ]; then
        problems="$problems
  $plugin_dir
      version at $BASE: $old_v
      version at HEAD:  $new_v$([ "$old_v" = "$new_v" ] && echo '   (unchanged)' || echo '   (WENT BACKWARDS)')
      installed files changed:
$(printf '%s\n' "$touched" | sed 's/^/        /')"
    fi
done

[ "$n_plugins" -gt 0 ] || die "no plugins/*/.claude-plugin/plugin.json found at HEAD. This script is looking in the wrong place, or the layout changed."

if [ -n "$problems" ]; then
    printf 'PLUGIN VERSION NOT RAISED — checked %d plugin(s) over %s..HEAD\n' \
        "$n_plugins" "$BASE" >&2
    printf '%s\n' "$problems" >&2
    cat >&2 <<'EOF'

The plugin cache is keyed by version. An existing installation compares versions,
sees no change, and copies NOTHING — `/plugin install` will say "already installed"
and be telling the truth. The new hooks reach main, reach the marketplace clone,
and never reach a single machine that already had the plugin.

A fresh install on a new machine WOULD get them, which is why this is easy to
test and conclude wrongly. Raise the version in plugin.json.
EOF
    exit 1
fi

# Say it CHECKED. An empty finding and a skipped run must not look alike.
printf 'check-plugin-version: checked %d plugin(s) over %s..HEAD — no installed file changed without a version raise.\n' \
    "$n_plugins" "$BASE"
exit 0

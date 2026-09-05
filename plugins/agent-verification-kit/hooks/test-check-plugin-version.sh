#!/usr/bin/env bash
# Controls for check-plugin-version.sh.
#
# WHY THIS EXISTS. Stages 2 and 3 both shipped under version 0.1.0. The plugin cache
# is keyed by that version, so every existing installation stayed on Stage 1 while
# the README and the marketplace advertised three stages. `/plugin install` reported
# "already installed" and copied nothing, exactly as designed — the defect was that
# nothing had told it there was anything new.
#
# That is INC-0019, and it is invisible by construction: a FRESH install on a new
# machine gets everything, which is why it survived a stage-2 install probe that
# looked conclusive. Only an existing installation is affected, and the person
# shipping is the least likely to have one.
#
# So: if the hooks changed and the version did not, fail the branch.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
SUT="$HOOKS/check-plugin-version.sh"
pass=0; fail=0

[ -r "$SUT" ] || { echo "FAIL  cannot read $SUT — nothing was tested"; exit 1; }

ok()  { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }

box=$(mktemp -d); trap 'rm -rf "$box"' EXIT

# A repo shaped like this one: plugins/<name>/hooks/ and a plugin.json beside it.
new_repo() {
    local d="$box/$1"; mkdir -p "$d/plugins/avk/hooks" "$d/plugins/avk/.claude-plugin"
    cd "$d" || return 1
    git init -q -b main
    git config user.email a@b.c; git config user.name A
    git config commit.gpgsign false
    printf 'echo hi\n' > plugins/avk/hooks/post-bash.sh
    printf '{\n  "name": "avk",\n  "version": "0.1.0"\n}\n' > plugins/avk/.claude-plugin/plugin.json
    git add -A; git commit -q -m base
    git checkout -q -b work
    printf '%s\n' "$d"
}
set_version() {
    printf '{\n  "name": "avk",\n  "version": "%s"\n}\n' "$1" > plugins/avk/.claude-plugin/plugin.json
}
run() { OUT=$(bash "$SUT" "${1:-main}" 2>&1); RC=$?; }

echo "0. NOT VACUOUS — a branch that touches no hook is clean:"
d=$(new_repo untouched); cd "$d" || exit 1
echo "docs" > README.md; git add -A; git commit -q -m "docs only"
run main
[ "$RC" = 0 ] && ok "a branch changing no hook exits 0" \
              || bad "a branch changing no hook exits 0" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "checked" \
    && ok "and it says it checked, so a skipped run cannot pass for a clean one" \
    || bad "and it says it checked, so a skipped run cannot pass for a clean one" "$OUT"

echo
echo "1. THE DEFECT — hooks changed, version did not:"
d=$(new_repo stale); cd "$d" || exit 1
printf 'echo changed\n' > plugins/avk/hooks/post-bash.sh
git add -A; git commit -q -m "change a hook, forget the version"
run main
[ "$RC" = 1 ] && ok "changing a hook without bumping the version exits 1" \
              || bad "changing a hook without bumping the version exits 1" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q "post-bash.sh" \
    && ok "and it names the hook that changed" \
    || bad "and it names the hook that changed" "$OUT"
printf '%s' "$OUT" | grep -q "0.1.0" \
    && ok "and it names the version that did not move" \
    || bad "and it names the version that did not move" "$OUT"

echo
echo "2. hooks changed AND version bumped is clean:"
d=$(new_repo bumped); cd "$d" || exit 1
printf 'echo changed\n' > plugins/avk/hooks/post-bash.sh
set_version 0.2.0
git add -A; git commit -q -m "change a hook and bump"
run main
[ "$RC" = 0 ] && ok "a bumped version exits 0" \
              || bad "a bumped version exits 0" "exit $RC: $OUT"

echo
echo "3. a version that goes BACKWARDS is not a bump:"
# A cache keyed by version does not necessarily re-copy for a lower one, and a
# decrease is far more likely to be a bad merge than a decision.
d=$(new_repo backwards); cd "$d" || exit 1
printf 'echo changed\n' > plugins/avk/hooks/post-bash.sh
set_version 0.0.9
git add -A; git commit -q -m "change a hook, lower the version"
run main
[ "$RC" = 1 ] && ok "a decreasing version exits 1" \
              || bad "a decreasing version exits 1" "exit $RC: $OUT"

echo
echo "4. 0.10.0 is NEWER than 0.9.0 — string comparison would get this wrong:"
d=$(new_repo semver); cd "$d" || exit 1
set_version 0.9.0; git add -A; git commit -q -m "start at 0.9.0"
git checkout -q main; git merge -q work 2>/dev/null || git reset -q --hard work
git checkout -q -b work2
printf 'echo changed\n' > plugins/avk/hooks/post-bash.sh
set_version 0.10.0
git add -A; git commit -q -m "bump to 0.10.0"
run main
[ "$RC" = 0 ] && ok "0.9.0 -> 0.10.0 is accepted as an increase" \
              || bad "0.9.0 -> 0.10.0 is accepted as an increase" "exit $RC: $OUT"

echo
echo "5. a change to plugin metadata alone still needs a bump:"
# The description is what a user reads when deciding to install. Shipping a new
# description under an old version means nobody with the plugin ever sees it.
d=$(new_repo metaonly); cd "$d" || exit 1
printf '{\n  "name": "avk",\n  "version": "0.1.0",\n  "description": "new words"\n}\n' \
    > plugins/avk/.claude-plugin/plugin.json
git add -A; git commit -q -m "reword the description, same version"
run main
[ "$RC" = 1 ] && ok "changed metadata with an unchanged version exits 1" \
              || bad "changed metadata with an unchanged version exits 1" "exit $RC: $OUT"

echo
echo "6. COULD NOT CHECK exits 3, never 0 — the INC-0006 rule:"
d=$(new_repo badref); cd "$d" || exit 1
printf 'echo x\n' > plugins/avk/hooks/post-bash.sh; git add -A; git commit -q -m x
run no-such-ref
[ "$RC" = 3 ] && ok "an unresolvable base ref exits 3" \
              || bad "an unresolvable base ref exits 3" "exit $RC: $OUT"

d=$(new_repo nojson); cd "$d" || exit 1
git rm -q plugins/avk/.claude-plugin/plugin.json
printf 'echo x\n' > plugins/avk/hooks/post-bash.sh
git add -A; git commit -q -m "hook changed, plugin.json deleted"
run main
[ "$RC" = 3 ] && ok "a missing plugin.json exits 3, not 0" \
              || bad "a missing plugin.json exits 3, not 0" "exit $RC: $OUT"

d=$(new_repo noversion); cd "$d" || exit 1
printf '{\n  "name": "avk"\n}\n' > plugins/avk/.claude-plugin/plugin.json
printf 'echo x\n' > plugins/avk/hooks/post-bash.sh
git add -A; git commit -q -m "hook changed, no version field"
run main
[ "$RC" = 3 ] && ok "a plugin.json with no version field exits 3" \
              || bad "a plugin.json with no version field exits 3" "exit $RC: $OUT"

mkdir -p "$box/notarepo"; cd "$box/notarepo" || exit 1
run main
[ "$RC" = 3 ] && ok "running outside a git repository exits 3" \
              || bad "running outside a git repository exits 3" "exit $RC: $OUT"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

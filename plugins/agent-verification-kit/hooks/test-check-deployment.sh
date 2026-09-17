#!/usr/bin/env bash
# Controls for check-deployment.sh.
#
# WHY THIS EXISTS. INC-0033 merged to main on 2026-09-07 and governed nothing on the
# author's machine until 2026-09-17. Ten days, across concurrent sessions, every one
# of them gated by a copy of verify-gate.sh from a different repository entirely.
#
# It was found by accident. Nothing in this kit compares the copy that ENFORCES
# against the copy it SHIPS — which is the same gap check-record.sh was built to
# close, one layer down: the kit gates commits on a stamp, test edits on a
# declaration and flaky passes on a trailer, and does not gate its own deployment.
#
# TWO FAILURES ARE IN SCOPE, and the second is the one that nearly got missed.
#
#   drift    a deployed file differs from the source. Loud once you look.
#   absence  a deployed hook SOURCES a sibling that was never deployed. These hooks
#            resolve siblings with dirname/readlink and fall back rather than fail,
#            so a missing library does not error — it degrades, silently, into the
#            channel NOTE-0032 measured as reaching nobody.
#
# THE SOURCE OF TRUTH IS A COMMITTED REF, NOT THE WORKING TREE. Control 8 asserts
# it. Comparing against the working tree would turn every in-progress hook edit red,
# and a control that is red during normal work is a control that gets switched off.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
SUT="$HOOKS/check-deployment.sh"
pass=0; fail=0

[ -r "$SUT" ] || { echo "FAIL  cannot read $SUT — nothing was tested"; exit 1; }

ok()  { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }

box=$(mktemp -d); trap 'rm -rf "$box"' EXIT

PREFIX=plugins/agent-verification-kit/hooks

# A hook that sources a sibling the way every hook in this kit does. The idiom is
# reproduced EXACTLY, quoting included: the check reads real files, so a fixture
# written in a near-miss dialect would test a parser nothing in this kit feeds.
sourcing_hook() {
    printf '%s\n' '#!/bin/bash' \
        "LIB=\"\$(dirname \"\$(readlink -f \"\${BASH_SOURCE[0]}\")\")/$1\"" \
        '[ -r "$LIB" ] && . "$LIB"' \
        'exit 0'
}

# new_kit <name> — a git repo holding the kit's hooks at PREFIX, committed on main,
# with check-deployment.sh copied in so it resolves ITS OWN repo, as in real use.
new_kit() {
    local d="$box/$1"
    mkdir -p "$d/$PREFIX"
    cp "$SUT" "$d/$PREFIX/check-deployment.sh"
    sourcing_hook announce.sh > "$d/$PREFIX/verify-gate.sh"
    printf '%s\n' '#!/bin/bash' 'announce() { :; }' > "$d/$PREFIX/announce.sh"
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$d/$PREFIX/stamp-path.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'echo controls' > "$d/$PREFIX/test-verify-gate.sh"
    git -C "$d" init -q -b main 2>/dev/null
    git -C "$d" add -A 2>/dev/null
    git -C "$d" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
    printf '%s\n' "$d"
}

# deploy <kit> <dir> <file...> — copy named hooks out of the kit into a deploy dir
deploy() {
    local kit="$1" dir="$2"; shift 2
    mkdir -p "$dir"
    local f
    for f in "$@"; do cp "$kit/$PREFIX/$f" "$dir/$f"; done
}

run() { OUT=$(bash "$KIT/$PREFIX/check-deployment.sh" "$@" 2>&1); RC=$?; }

# ---------------------------------------------------------------------------
echo "0. NOT VACUOUS — a correct deployment passes, and says what it checked:"
KIT=$(new_kit clean); D="$box/clean-deploy"
deploy "$KIT" "$D" verify-gate.sh announce.sh
run "$D"
[ "$RC" = 0 ] && ok "a matching deployment exits 0" \
              || bad "a matching deployment exits 0" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "check" \
    && ok "and it reports that it checked, rather than staying silent" \
    || bad "and it reports that it checked, rather than staying silent" "$OUT"
printf '%s' "$OUT" | grep -q "2" \
    && ok "and it names how many deployed files it compared" \
    || bad "and it names how many deployed files it compared" "$OUT"

echo
echo "1. DRIFT — the ten-day failure, caught:"
KIT=$(new_kit drifted); D="$box/drifted-deploy"
deploy "$KIT" "$D" verify-gate.sh announce.sh
printf '%s\n' '#!/bin/bash' '# an older copy, from another lineage' > "$D/verify-gate.sh"
run "$D"
[ "$RC" = 1 ] && ok "a deployed file differing from the ref exits 1" \
              || bad "a deployed file differing from the ref exits 1" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q "verify-gate.sh" \
    && ok "and it names the file that drifted" \
    || bad "and it names the file that drifted" "$OUT"

echo
echo "2. ABSENCE — a sourced library that was never deployed degrades in silence:"
KIT=$(new_kit orphan); D="$box/orphan-deploy"
deploy "$KIT" "$D" verify-gate.sh          # announce.sh deliberately NOT deployed
run "$D"
[ "$RC" = 1 ] && ok "a deployed hook whose sibling is absent exits 1" \
              || bad "a deployed hook whose sibling is absent exits 1" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q "announce.sh" \
    && ok "and it names the missing sibling" \
    || bad "and it names the missing sibling" "$OUT"
printf '%s' "$OUT" | grep -qi "silent\|degrad\|fall" \
    && ok "and it says the failure is silent, not loud" \
    || bad "and it says the failure is silent, not loud" "$OUT"

echo
echo "3. NOT OURS — other tools' hooks share the directory and are not ours to judge:"
KIT=$(new_kit foreign); D="$box/foreign-deploy"
deploy "$KIT" "$D" verify-gate.sh announce.sh
printf '%s\n' '#!/bin/bash' 'echo not from this kit' > "$D/git-safety.sh"
run "$D"
[ "$RC" = 0 ] && ok "a file the kit does not ship is ignored, not flagged" \
              || bad "a file the kit does not ship is ignored, not flagged" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q "git-safety.sh" \
    && bad "and it is not named in the output" "$OUT" \
    || ok "and it is not named in the output"

echo
echo "4. NOT DEPLOYED IS NOT DRIFT — partial adoption is a choice, not a defect:"
KIT=$(new_kit partial); D="$box/partial-deploy"
deploy "$KIT" "$D" verify-gate.sh announce.sh   # stamp-path.sh shipped, not deployed
run "$D"
[ "$RC" = 0 ] && ok "a kit hook nothing deployed depends on may be absent" \
              || bad "a kit hook nothing deployed depends on may be absent" "exit $RC: $OUT"

echo
echo "5. TEST SUITES ARE NOT DEPLOYED ARTEFACTS — their absence is never a finding:"
#
# THE FIXTURE MUST GIVE THE EXCLUSION SOMETHING TO EXCLUDE.
#
# This control used to deploy only verify-gate.sh and announce.sh and then assert
# that test-verify-gate.sh was absent from the output. It could not fail. The file
# it grepped for was never deployed, so the drift loop skipped it at
# `[ -e "$live" ] || continue` and nothing sourced it — the assertion checked for a
# string the fixture gave the code no way to emit, whether the exclusion worked,
# was broken, or was deleted outright. Adjudication deleted `grep -vE '^test-'`
# from the implementation and the suite still reported 18 passed, 0 failed.
#
# So the suite is now DEPLOYED, and deployed DRIFTED — its bytes differ from the
# ref. With the exclusion present it is never compared and never named. Remove the
# exclusion and it is compared, it differs, and it is reported as DRIFT — which
# fails this control. That is the mutation the old fixture survived.
KIT=$(new_kit suites); D="$box/suites-deploy"
deploy "$KIT" "$D" verify-gate.sh announce.sh test-verify-gate.sh
printf '%s\n' '#!/usr/bin/env bash' 'echo a DIFFERENT control suite' > "$D/test-verify-gate.sh"
run "$D"
printf '%s' "$OUT" | grep -q "test-verify-gate.sh" \
    && bad "a deployed, drifted test-*.sh is excluded from the comparison" "$OUT" \
    || ok "a deployed, drifted test-*.sh is excluded from the comparison"
[ "$RC" = 0 ] && ok "and its drift does not fail the run" \
              || bad "and its drift does not fail the run" "exit $RC: $OUT"

echo
echo "6. NO DEPLOYMENT — an adopter who deploys nothing is not broken:"
KIT=$(new_kit none)
run "$box/does-not-exist"
[ "$RC" = 0 ] && ok "a missing deploy directory exits 0" \
              || bad "a missing deploy directory exits 0" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "no deployment\|nothing" \
    && ok "and it says so rather than reporting a clean check it never ran" \
    || bad "and it says so rather than reporting a clean check it never ran" "$OUT"

echo
echo "7. COULD NOT CHECK IS NOT CLEAN — the INC-0006 shape, in both directions:"
KIT=$(new_kit badref); D="$box/badref-deploy"
deploy "$KIT" "$D" verify-gate.sh announce.sh
run "$D" no-such-ref
[ "$RC" = 3 ] && ok "a ref that does not resolve exits 3, not 0" \
              || bad "a ref that does not resolve exits 3, not 0" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "could not\|cannot" \
    && ok "and it says it could not check" \
    || bad "and it says it could not check" "$OUT"

KIT=$(new_kit empty); D="$box/empty-deploy"
deploy "$KIT" "$D" verify-gate.sh announce.sh
git -C "$KIT" rm -rq "$PREFIX" 2>/dev/null
git -C "$KIT" -c user.email=t@t -c user.name=t commit -qm "remove hooks" 2>/dev/null
# git rm takes the working tree with it, including the script under test. Put it
# back UNTRACKED: the ref must ship no hooks while the script still exists to run.
mkdir -p "$KIT/$PREFIX"; cp "$SUT" "$KIT/$PREFIX/check-deployment.sh"
run "$D"
[ "$RC" = 3 ] && ok "a ref shipping NO hooks exits 3 — a check of nothing is not a pass" \
              || bad "a ref shipping NO hooks exits 3 — a check of nothing is not a pass" "exit $RC: $OUT"

echo
echo "7b. AN UNREADABLE SHIPPED COPY IS NOT A MATCH:"
#
# THE BLOCKER THIS SUITE DID NOT HOLD. The guard for this path existed but could
# never fire: it tested `[ -n "$ship_sum" ]`, and sha1sum of EMPTY input is
# da39a3ee5e6b4b0d3255bfef95601890afd80709 — fixed and non-empty — so a failed
# `git show` still produced a respectable-looking hash.
#
# The fixture reproduces the case that makes it dangerous rather than merely wrong:
# the shipped blob is removed from the object store AND the deployed file is
# ZERO BYTES. Both sides then hash to that same constant, they compare equal, and
# the unfixed script reports "all match" at exit 0 on a file it never read.
#
# A drifted deployed file would NOT catch this — the hashes would differ and it
# would be reported as DRIFT, a wrong diagnosis that still fails the run. The empty
# deployed file is what turns a failed read into a green one, so that is what this
# control deploys.
KIT=$(new_kit unreadable); D="$box/unreadable-deploy"
deploy "$KIT" "$D" verify-gate.sh announce.sh
: > "$D/verify-gate.sh"                       # zero bytes, hashes to the empty-input constant
blob=$(git -C "$KIT" rev-parse "main:$PREFIX/verify-gate.sh" 2>/dev/null)
rm -f "$KIT/.git/objects/${blob:0:2}/${blob:2}"
run "$D"
if [ "$RC" -ne 0 ]; then
    ok "an unreadable shipped copy FAILS rather than reporting a match"
else
    bad "an unreadable shipped copy FAILS rather than reporting a match" "exit $RC: $OUT"
fi
printf '%s' "$OUT" | grep -qi "could not read" \
    && ok "and it says it could not READ it, not that it drifted" \
    || bad "and it says it could not READ it, not that it drifted" "$OUT"

echo
echo "8. THE SOURCE IS THE REF, NOT THE WORKING TREE:"
KIT=$(new_kit wt); D="$box/wt-deploy"
deploy "$KIT" "$D" verify-gate.sh announce.sh
printf '%s\n' '#!/bin/bash' '# uncommitted work in progress' >> "$KIT/$PREFIX/verify-gate.sh"
run "$D"
[ "$RC" = 0 ] && ok "an uncommitted edit does not make a matching deployment fail" \
              || bad "an uncommitted edit does not make a matching deployment fail" "exit $RC: $OUT"

echo
echo "9. SYMLINKS — the deployment shape this kit actually uses:"
#
# THREE CONTROLS, BECAUSE SYMLINKS FAIL IN THREE DIRECTIONS AND THE SUITE COVERED
# NONE OF THEM. `deploy()` only ever cp'd, so the one mechanism check-deployment.sh
# documents as deliberate — "check-models.sh is deployed as one" — had no fixture
# at all. Breaking dereference for symlinks only left the suite at 21 passed,
# 0 failed.
#
# 9a and 9b pin the WORKING path in both directions: an intact symlink must be
# compared by the content at the far end, and must be seen to drift when that
# content drifts. 9b is the one that kills a mutant hashing the link's target
# PATH instead of its contents — 9a alone would survive it.
#
# 9c is the High. A dangling link used to take the same `continue` as a file that
# was never deployed, so the run reported all-match at exit 0 with the hook
# physically present and unrunnable. That is INC-0014's shape.

# 9a — an intact symlink whose target matches the ref is clean.
KIT=$(new_kit symlink); D="$box/symlink-deploy"
deploy "$KIT" "$D" announce.sh
mkdir -p "$box/symlink-far"
cp "$KIT/$PREFIX/verify-gate.sh" "$box/symlink-far/verify-gate.sh"
ln -s "$box/symlink-far/verify-gate.sh" "$D/verify-gate.sh"
run "$D"
[ "$RC" = 0 ] && ok "an intact symlink is read through to its target and matches" \
              || bad "an intact symlink is read through to its target and matches" "exit $RC: $OUT"

# 9b — the same symlink, target content changed. Must be caught as drift.
printf '%s\n' '#!/bin/bash' '# a different file at the far end' > "$box/symlink-far/verify-gate.sh"
run "$D"
[ "$RC" = 1 ] && ok "a symlink whose TARGET drifts is caught — the far end is what is hashed" \
              || bad "a symlink whose TARGET drifts is caught — the far end is what is hashed" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q "verify-gate.sh" \
    && ok "and it names the symlinked file" \
    || bad "and it names the symlinked file" "$OUT"

# 9c — THE HIGH. A dangling symlink is deployed-and-broken, not absent.
KIT=$(new_kit dangling); D="$box/dangling-deploy"
deploy "$KIT" "$D" verify-gate.sh announce.sh
rm -f "$D/verify-gate.sh"
ln -s "$box/no-such-target-anywhere.sh" "$D/verify-gate.sh"
[ -L "$D/verify-gate.sh" ] && [ ! -e "$D/verify-gate.sh" ] \
    || bad "FIXTURE BROKEN: the link is not dangling, so 9c tests nothing" "$(ls -l "$D")"
run "$D"
[ "$RC" = 1 ] && ok "a dangling symlink FAILS the run rather than reading as 'not deployed'" \
              || bad "a dangling symlink FAILS the run rather than reading as 'not deployed'" "exit $RC: $OUT"
# ANCHORED TO THE MESSAGE, NOT TO THE WORD.
#
# This first read `grep -qi "dangling"`, and it PASSED against a mutant with the
# fix reverted — because the fixture path is `.../dangling-deploy`, which appears
# in the output, so the assertion matched the directory name rather than any
# message. Caught by running the mutation rather than by reading it back, and it
# is the same defect the adjudicator rated Medium for `grep -q "2"` matching the
# random mktemp path — reintroduced here by the person who had just read that
# finding. Match the literal phrase the script emits, case-sensitively.
printf '%s' "$OUT" | grep -q "DANGLING SYMLINK" \
    && ok "and it says DANGLING SYMLINK, not 'missing' and not 'drift'" \
    || bad "and it says DANGLING SYMLINK, not 'missing' and not 'drift'" "$OUT"
printf '%s' "$OUT" | grep -qi "all match" \
    && bad "and it never reports a match for a hook it could not read" "$OUT" \
    || ok "and it never reports a match for a hook it could not read"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Controls for check-flaky-trailers.sh — Stage 3's CI half.
#
# WHAT THIS HALF CAN AND CANNOT DO, stated first because the asymmetry with
# Stage 2 is real and easy to overclaim.
#
# check-test-changes.sh reads the branch DIFF, so it can see an UNDECLARED test
# change — the thing itself is in the diff. This checker cannot do the equivalent.
# By the time CI runs, the verification stamp that knew a run was flaky is gone,
# so nothing in the repository records that a commit was made under one. Only
# verify-gate could require the trailer, and it does.
#
# So this half validates the trailers it FINDS, and makes them visible in the
# pull request. That is worth having — a flake declaration otherwise lives in a
# gitignored file that expires in thirty minutes — but it is NOT the same
# guarantee, and the README must not say it is.
#
# The one fail-open it DOES close is the trailer-that-is-not-a-trailer: git parses
# trailers only from the final paragraph, so a `Flaky:` line in the message body
# records as zero trailers while looking perfect in `git log`. A checker reading
# only parsed trailers would report that commit clean.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
SUT="$HOOKS/check-flaky-trailers.sh"
pass=0; fail=0

[ -r "$SUT" ] || { echo "FAIL  cannot read $SUT — nothing was tested"; exit 1; }

ok()  { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }

box=$(mktemp -d); trap 'rm -rf "$box"' EXIT

# new_repo — a repository with one commit on `main` and a branch off it.
new_repo() {
    local d="$box/$1"; mkdir -p "$d"; cd "$d" || return 1
    git init -q -b main
    git config user.email a@b.c; git config user.name A
    git config commit.gpgsign false
    echo base > base.txt; git add -A; git commit -q -m "base"
    git checkout -q -b work
    printf '%s\n' "$d"
}
# commit_with <subject> [--trailer ...]
commit_with() {
    local subj="$1"; shift
    echo "$RANDOM" > "change-$RANDOM.txt"; git add -A
    git commit -q -m "$subj" "$@"
}
run() { OUT=$(bash "$SUT" "${1:-main}" 2>&1); RC=$?; }

echo "0. the suite is not vacuous — a branch with no Flaky: trailers is clean:"
d=$(new_repo none); cd "$d" || exit 1
commit_with "fix: something ordinary"
run main
[ "$RC" = 0 ] && ok "a branch with no flaky trailers exits 0" \
              || bad "a branch with no flaky trailers exits 0" "exit $RC: $OUT"
# It must say it CHECKED. An empty report and a skipped run must not look alike —
# every failure mode of a log-reading checker produces no findings.
printf '%s' "$OUT" | grep -qi "checked" \
    && ok "and it says it checked, rather than printing nothing" \
    || bad "and it says it checked, rather than printing nothing" "$OUT"

echo
echo "1. a well-formed trailer passes, and is REPORTED:"
d=$(new_repo good); cd "$d" || exit 1
commit_with "fix: retries" --trailer "Flaky: npm test #412 races on the token clock"
run main
[ "$RC" = 0 ] && ok "a well-formed Flaky trailer exits 0" \
              || bad "a well-formed Flaky trailer exits 0" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q "npm test" \
    && ok "and the command is reported so a reviewer sees it" \
    || bad "and the command is reported so a reviewer sees it" "$OUT"
printf '%s' "$OUT" | grep -q "#412" \
    && ok "and the issue is reported with it" \
    || bad "and the issue is reported with it" "$OUT"

echo
echo "2. a trailer with no issue number is refused:"
d=$(new_repo noissue); cd "$d" || exit 1
commit_with "fix: retries" --trailer "Flaky: npm test it is just flaky sometimes"
run main
[ "$RC" = 1 ] && ok "a Flaky trailer with no #issue exits 1" \
              || bad "a Flaky trailer with no #issue exits 1" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "issue" \
    && ok "and it says an issue number is what is missing" \
    || bad "and it says an issue number is what is missing" "$OUT"

echo
echo "3. a trailer with an issue but no command is refused:"
d=$(new_repo nocmd); cd "$d" || exit 1
commit_with "fix: retries" --trailer "Flaky: #412"
run main
[ "$RC" = 1 ] && ok "a Flaky trailer naming no command exits 1" \
              || bad "a Flaky trailer naming no command exits 1" "exit $RC: $OUT"

echo
echo "4. THE TRAILER THAT IS NOT A TRAILER — the fail-open this half closes:"
# Git parses trailers only from the FINAL paragraph. A Flaky: line above a
# Signed-off-by is zero trailers, and a checker reading only parsed trailers
# would call this commit clean while `git log` shows the line plainly.
d=$(new_repo body); cd "$d" || exit 1
echo x > x.txt; git add -A
git commit -q -s -m "fix: retries

Flaky: npm test #412 races on the token clock

Some closing paragraph that pushes the line out of the trailer block."
run main
[ "$RC" = 1 ] && ok "a Flaky: line git did NOT parse as a trailer exits 1" \
              || bad "a Flaky: line git did NOT parse as a trailer exits 1" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi -e "final paragraph" -e "not parsed" -e "--trailer" \
    && ok "and it names the real cause rather than reporting nothing found" \
    || bad "and it names the real cause rather than reporting nothing found" "$OUT"

echo
echo "5. several commits, one bad — the bad one is named and the good one is not:"
d=$(new_repo mixed); cd "$d" || exit 1
commit_with "good" --trailer "Flaky: pytest #1 a real issue"
commit_with "bad"  --trailer "Flaky: npm test no issue here"
run main
[ "$RC" = 1 ] && ok "one malformed trailer among several exits 1" \
              || bad "one malformed trailer among several exits 1" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q "npm test" \
    && ok "and the malformed one is named" \
    || bad "and the malformed one is named" "$OUT"

echo
echo "6. COULD NOT CHECK must exit 3, never 0 — the INC-0006 rule:"
d=$(new_repo badref); cd "$d" || exit 1
commit_with "fix: x"
run no-such-ref-anywhere
[ "$RC" = 3 ] && ok "an unresolvable base ref exits 3, not 0" \
              || bad "an unresolvable base ref exits 3, not 0" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi -e "could not" -e "cannot" \
    && ok "and it says it could not check" \
    || bad "and it says it could not check" "$OUT"

mkdir -p "$box/notarepo"; cd "$box/notarepo" || exit 1
run main
[ "$RC" = 3 ] && ok "running outside a git repository exits 3" \
              || bad "running outside a git repository exits 3" "exit $RC: $OUT"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

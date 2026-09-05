#!/usr/bin/env bash
# Controls for check-controls.sh.
#
# Written before the runner existed and run against nothing, so the first run
# failed on the missing file. A control suite that has never been red has not
# been shown to be capable of failing.
#
# WHY THE RUNNER EXISTS. This kit had ten control suites and no single command
# that ran them all. That gap bit from both sides on 2026-09-04 and 09-05: once
# when earning a verification stamp (a suite had to be picked arbitrarily, so the
# stamp attested to one suite rather than the set), and once when review-final's
# verdict.sh refused to record READY because it could not find a test command.
#
# WHY IT OWNS THE LIST. Before this, .github/workflows/verification.yml carried
# the suite list TWICE — once in the staleness guard and once in the run step.
# Two copies of one list in one file is the drift this repository's own README
# names as its most recurrent defect. The list now lives in controls.list and
# the workflow calls the runner, so there is one copy.
#
# Every case here runs the runner against a FIXTURE directory, never against the
# real hooks directory, so these controls cannot pass or fail because of the
# repository's actual state.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
RUNNER="$HOOKS/check-controls.sh"
pass=0; fail=0

if [ ! -r "$RUNNER" ]; then
    echo "FAIL  cannot read $RUNNER — nothing was tested"; exit 1
fi

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT

ok()  { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }

# fixture <name> — a directory with a controls.list and whatever suites are asked
# for afterwards. Returns the path on stdout.
fixture() {
    local d="$box/$1"
    mkdir -p "$d"
    printf '%s\n' "$d"
}

# a suite that passes, and RECORDS that it ran — so "the runner reported PASS"
# can be told apart from "the runner never invoked it".
passing_suite() {
    printf '#!/usr/bin/env bash\necho ran >> "%s/ran.log"\nexit 0\n' "$1" > "$1/$2"
}
failing_suite() {
    printf '#!/usr/bin/env bash\necho ran >> "%s/ran.log"\necho "a control failed"\nexit 1\n' "$1" > "$1/$2"
}

echo "0. the suite is not vacuous — a correct directory must PASS:"
d=$(fixture ok1)
printf 'test-a.sh\ntest-b.sh\n' > "$d/controls.list"
passing_suite "$d" test-a.sh
passing_suite "$d" test-b.sh
out=$(bash "$RUNNER" "$d" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a listed, present, passing set exits 0" \
              || bad "a listed, present, passing set exits 0" "exit $rc: $out"

echo "1. it actually RUNS them, rather than only checking the list:"
[ "$(wc -l < "$d/ran.log" 2>/dev/null)" = 2 ] \
    && ok "both suites were really invoked" \
    || bad "both suites were really invoked" "ran.log: $(cat "$d/ran.log" 2>/dev/null)"

echo
echo "2. an UNLISTED test-*.sh fails, and is named:"
d=$(fixture unlisted)
printf 'test-a.sh\n' > "$d/controls.list"
passing_suite "$d" test-a.sh
passing_suite "$d" test-sneaky.sh          # present, passing, and NOT in the list
out=$(bash "$RUNNER" "$d" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "an unlisted suite fails the run" \
               || bad "an unlisted suite fails the run" "exit $rc — a new suite could go unrun forever"
printf '%s' "$out" | grep -q "test-sneaky.sh" \
    && ok "and the unlisted suite is named" \
    || bad "and the unlisted suite is named" "$out"

echo
echo "3. a LISTED but MISSING suite fails, and is named:"
d=$(fixture missing)
printf 'test-a.sh\ntest-gone.sh\n' > "$d/controls.list"
passing_suite "$d" test-a.sh
out=$(bash "$RUNNER" "$d" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "a listed suite that does not exist fails the run" \
               || bad "a listed suite that does not exist fails the run" "exit $rc"
printf '%s' "$out" | grep -q "test-gone.sh" \
    && ok "and the missing suite is named" \
    || bad "and the missing suite is named" "$out"

echo
echo "4. a FAILING suite fails the run, and is named:"
d=$(fixture failing)
printf 'test-a.sh\ntest-bad.sh\n' > "$d/controls.list"
passing_suite "$d" test-a.sh
failing_suite "$d" test-bad.sh
out=$(bash "$RUNNER" "$d" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "a failing suite fails the run" \
               || bad "a failing suite fails the run" "exit $rc"
printf '%s' "$out" | grep -q "test-bad.sh" \
    && ok "and the failing suite is named" \
    || bad "and the failing suite is named" "$out"

echo
echo "5. ONE failure does not stop the others — a run reports the whole picture:"
[ "$(wc -l < "$d/ran.log" 2>/dev/null)" = 2 ] \
    && ok "both suites ran even though one failed" \
    || bad "both suites ran even though one failed" "ran.log: $(cat "$d/ran.log" 2>/dev/null)"

echo
echo "6. could-not-check is not a pass:"
d=$(fixture nolist)
passing_suite "$d" test-a.sh               # suites present, but no controls.list
out=$(bash "$RUNNER" "$d" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "a missing controls.list fails rather than running nothing" \
               || bad "a missing controls.list fails rather than running nothing" "exit $rc — an absent list would silently run zero suites"

d=$(fixture emptylist)
: > "$d/controls.list"
out=$(bash "$RUNNER" "$d" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "an EMPTY controls.list fails rather than reporting success" \
               || bad "an EMPTY controls.list fails rather than reporting success" "exit $rc — zero suites run must never read as green"

echo
echo "7. comments and blank lines in the list are ignored, not treated as suites:"
d=$(fixture comments)
printf '# the kit does not run this line\n\ntest-a.sh\n' > "$d/controls.list"
passing_suite "$d" test-a.sh
out=$(bash "$RUNNER" "$d" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a comment and a blank line do not become missing suites" \
              || bad "a comment and a blank line do not become missing suites" "exit $rc: $out"

echo
echo "8. the REAL hooks directory is listed correctly:"
real="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
if [ -f "$real/controls.list" ]; then
    st=0
    for f in "$real"/test-*.sh; do
        b=$(basename "$f")
        grep -qxF "$b" "$real/controls.list" || { echo "        unlisted: $b"; st=1; }
    done
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        [ -f "$real/$line" ] || { echo "        listed but absent: $line"; st=1; }
    done < "$real/controls.list"
    [ "$st" = 0 ] && ok "every test-*.sh in this repository is listed, and every listed file exists" \
                  || bad "every test-*.sh in this repository is listed, and every listed file exists" "see above"
else
    bad "every test-*.sh in this repository is listed, and every listed file exists" "no controls.list in $real"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

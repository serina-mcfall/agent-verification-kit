#!/usr/bin/env bash
# Controls for flake-ledger.sh — Stage 3, flake-triage.
#
# Written before the library existed and run against nothing, so the first run
# failed on the missing file.
#
# WHAT THE LEDGER IS FOR, MEASURED RATHER THAN ASSERTED.
#
# On 2026-09-04 a suite that FAILED and was then re-run until it PASSED, with no
# code change between, wrote a verification stamp and unlocked a commit. Both
# shipped stages miss it, and for different reasons: Stage 1 sees only the final
# pass, and Stage 2 never fires because no test file was touched. Run-until-green
# costs an agent one extra tool call and defeats both.
#
# The ledger is the memory that makes the second run distinguishable from the
# first. A failing test command records itself; an EDIT clears the record; a
# later pass of the SAME command with the record still present is a flake.
#
# WHY CLEARING ON EDIT IS LOAD-BEARING AND NOT AN OPTIMISATION.
# Write failing test -> implement -> pass is ALSO fail-then-pass. Without
# clearing, this fires on every legitimate red-green cycle, and the kit's own
# false-positive rule says a mechanism that cries wolf is `fix` or `drop`
# however correct it is in principle.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
LIB="$HOOKS/flake-ledger.sh"
pass=0; fail=0

if [ ! -r "$LIB" ]; then
    echo "FAIL  cannot read $LIB — nothing was tested"; exit 1
fi
# shellcheck source=/dev/null
. "$LIB"

ok()  { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi }

box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT
REPO="$box/proj"; mkdir -p "$REPO/.claude"
OTHER="$box/other"; mkdir -p "$OTHER/.claude"

fresh() { rm -f "$REPO/.claude/.failed-runs" "$OTHER/.claude/.failed-runs"; }

echo "0. the suite is not vacuous — a command never recorded is NOT a flake:"
fresh
is "an unrecorded command is not a flake" "no" "$(flake_seen "$REPO" 'npm test' && echo yes || echo no)"
is "and the ledger file is not created by asking" "absent" \
   "$([ -f "$REPO/.claude/.failed-runs" ] && echo present || echo absent)"

echo
echo "1. record then recognise — the core of the mechanism:"
fresh
flake_record "$REPO" 'npm test'
is "a recorded command is recognised" "yes" "$(flake_seen "$REPO" 'npm test' && echo yes || echo no)"

echo
echo "2. a DIFFERENT command is not the same command:"
fresh
flake_record "$REPO" 'npm test'
is "a different command is not recognised" "no" \
   "$(flake_seen "$REPO" 'pytest' && echo yes || echo no)"

# THE KNOWN BYPASS, ASSERTED SO IT IS A DECISION AND NOT A SURPRISE.
#
# Narrowing to the failing test is CORRECT debugging, not evasion: `pytest` fails,
# `pytest -k test_auth` passes, the command string differs, and the flake signal is
# gone. No normalisation fixes this reliably across eight ecosystems, so it is
# pinned here as a known negative rather than pretended away. This is the headline
# limitation of Stage 3 and it belongs in the trial record, not a footnote.
is "NARROWING THE COMMAND IS A KNOWN BYPASS — pinned, not fixed" "no" \
   "$(flake_seen "$REPO" 'npm test -- --grep auth' && echo yes || echo no)"

echo
echo "3. clearing — what an edit does:"
fresh
flake_record "$REPO" 'npm test'
flake_clear "$REPO"
is "clearing removes the record" "no" "$(flake_seen "$REPO" 'npm test' && echo yes || echo no)"
is "clearing a ledger that does not exist is not an error" "0" \
   "$(flake_clear "$OTHER" >/dev/null 2>&1; echo $?)"

echo
echo "4. repository scoping — one repo's failure is not another's:"
fresh
flake_record "$REPO" 'npm test'
is "a failure in one repo is not seen in another" "no" \
   "$(flake_seen "$OTHER" 'npm test' && echo yes || echo no)"

echo
echo "5. the 30-minute TTL:"
fresh
flake_record "$REPO" 'npm test'
# Rewrite the entry with an epoch well past the window. Done by editing the file
# rather than by sleeping, because a control that takes half an hour gets deleted.
awk -F'|' -v OFS='|' '{ $1 = $1 - 5400; print }' "$REPO/.claude/.failed-runs" > "$box/aged"
mv "$box/aged" "$REPO/.claude/.failed-runs"
is "a record older than the TTL is not a flake" "no" \
   "$(flake_seen "$REPO" 'npm test' && echo yes || echo no)"

fresh
flake_record "$REPO" 'npm test'
awk -F'|' -v OFS='|' '{ $1 = $1 - 600; print }' "$REPO/.claude/.failed-runs" > "$box/aged"
mv "$box/aged" "$REPO/.claude/.failed-runs"
is "a record INSIDE the TTL is still a flake" "yes" \
   "$(flake_seen "$REPO" 'npm test' && echo yes || echo no)"

echo
echo "6. commands containing the awkward characters:"
fresh
flake_record "$REPO" 'cd "my dir" && npm test'
is "a command containing spaces and quotes round-trips" "yes" \
   "$(flake_seen "$REPO" 'cd "my dir" && npm test' && echo yes || echo no)"

# PREFIX MATCHING IS WRONG HERE, and this is the control that says so. The
# declaration file in Stage 2 matches a path by prefix because a path is a token.
# A COMMAND IS NOT: `npm test` is a strict prefix of `npm test -- --grep auth`,
# which is precisely the narrowing bypass above. Matching by prefix would make a
# narrowed command silently inherit the broader command's flake record and
# refuse a commit nobody could explain.
fresh
flake_record "$REPO" 'npm test -- --grep auth'
is "a recorded command does not match a shorter PREFIX of itself" "no" \
   "$(flake_seen "$REPO" 'npm test' && echo yes || echo no)"

echo
echo "7. several commands coexist, and recording twice does not duplicate:"
fresh
flake_record "$REPO" 'npm test'
flake_record "$REPO" 'pytest'
is "the first is still recognised" "yes" "$(flake_seen "$REPO" 'npm test' && echo yes || echo no)"
is "the second is recognised too"  "yes" "$(flake_seen "$REPO" 'pytest'   && echo yes || echo no)"
flake_record "$REPO" 'npm test'
is "recording the same command twice keeps one entry" "1" \
   "$(grep -c 'npm test' "$REPO/.claude/.failed-runs")"

echo
echo "8. could-not-check is not a clean answer:"
fresh
printf 'this is not a ledger line\n' > "$REPO/.claude/.failed-runs"
is "a malformed ledger line is ignored, not treated as a match" "no" \
   "$(flake_seen "$REPO" 'this is not a ledger line' && echo yes || echo no)"
fresh
is "an unwritable directory does not abort the caller" "0" \
   "$(flake_record /nonexistent/nowhere 'npm test' >/dev/null 2>&1; echo $?)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

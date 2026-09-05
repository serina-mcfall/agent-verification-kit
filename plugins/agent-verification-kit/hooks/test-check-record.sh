#!/usr/bin/env bash
# Controls for check-record.sh.
#
# WHY THIS EXISTS. On 2026-09-06 three literal conflict-marker lines were committed
# into records/events.jsonl, pushed, marked ready, reviewed and MERGED TO MAIN. The
# file did not parse. Four CI jobs ran green over it.
#
# That is not a typo, it is a missing control. This kit gates commits on a test
# stamp, gates test edits on a declaration, and gates flaky passes on a trailer —
# and the append-only file that every one of those verdicts is recorded in had
# nothing checking it at all.
#
# The record is the only artefact this programme reasons from: every verdict, every
# open incident, every trend across stages. A record that does not parse is worse
# than no record, because its absence is loud and its corruption is silent.

HOOKS="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
SUT="$HOOKS/check-record.sh"
pass=0; fail=0

[ -r "$SUT" ] || { echo "FAIL  cannot read $SUT — nothing was tested"; exit 1; }

ok()  { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; printf '        %s\n' "$2"; fail=$((fail + 1)); }

box=$(mktemp -d); trap 'rm -rf "$box"' EXIT

GOOD1='{"id":"INC-0001","ts":"2026-09-01T00:00:00Z","kind":"incident","summary":"a thing broke","tags":["ci/hooks"],"repo":"r","detected_by":"agent"}'
GOOD2='{"id":"NOTE-0001","ts":"2026-09-02T00:00:00Z","kind":"note","summary":"a thing noted","tags":["ci/hooks"],"repo":"r","detected_by":"human"}'

# new_record <name> <line...> — a git repo with records/events.jsonl
new_record() {
    local d="$box/$1"; shift
    mkdir -p "$d/records"; cd "$d" || return 1
    git init -q -b main 2>/dev/null
    printf '%s\n' "$@" > records/events.jsonl
    printf '%s\n' "$d"
}
run() { OUT=$(bash "$SUT" 2>&1); RC=$?; }

echo "0. NOT VACUOUS — a valid record passes and says so:"
d=$(new_record valid "$GOOD1" "$GOOD2"); cd "$d" || exit 1
run
[ "$RC" = 0 ] && ok "a valid record exits 0" || bad "a valid record exits 0" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "checked\|valid" \
    && ok "and it reports that it checked, not silence" \
    || bad "and it reports that it checked, not silence" "$OUT"
printf '%s' "$OUT" | grep -q "2" \
    && ok "and it reports how many events it read" \
    || bad "and it reports how many events it read" "$OUT"

echo
echo "1. THE INCIDENT — conflict markers are refused and named as such:"
d=$(new_record markers "$GOOD1" "<<<<<<< Updated upstream" "=======" "$GOOD2" ">>>>>>> Stashed changes")
cd "$d" || exit 1
run
[ "$RC" = 1 ] && ok "a record containing conflict markers exits 1" \
              || bad "a record containing conflict markers exits 1" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "conflict" \
    && ok "and it says CONFLICT rather than only 'invalid JSON'" \
    || bad "and it says CONFLICT rather than only 'invalid JSON'" "$OUT"
printf '%s' "$OUT" | grep -q "2" \
    && ok "and it names a line number so the file can be repaired" \
    || bad "and it names a line number so the file can be repaired" "$OUT"

echo
echo "2. any other unparseable line is refused too:"
d=$(new_record badjson "$GOOD1" '{"id":"NOTE-0002", oops' ); cd "$d" || exit 1
run
[ "$RC" = 1 ] && ok "a malformed JSON line exits 1" \
              || bad "a malformed JSON line exits 1" "exit $RC: $OUT"

echo
echo "3. duplicate ids are refused — the parallel-branch collision:"
# Two branches each appending get concatenated safely BY DESIGN. Two branches each
# allocating the same next id do not, because ids are assigned per file.
d=$(new_record dupes "$GOOD1" "$GOOD1"); cd "$d" || exit 1
run
[ "$RC" = 1 ] && ok "a duplicated id exits 1" || bad "a duplicated id exits 1" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q "INC-0001" \
    && ok "and it names the duplicated id" \
    || bad "and it names the duplicated id" "$OUT"

echo
echo "4. a missing core field is refused rather than skipped:"
# The schema says a line missing any core field is malformed and query.sh must
# REPORT it rather than skip it silently. Same rule here.
d=$(new_record missingfield "$GOOD1" '{"id":"NOTE-0002","kind":"note","summary":"no ts","tags":["a"],"repo":"r","detected_by":"agent"}')
cd "$d" || exit 1
run
[ "$RC" = 1 ] && ok "a line missing a core field exits 1" \
              || bad "a line missing a core field exits 1" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "ts" \
    && ok "and it names the field that is missing" \
    || bad "and it names the field that is missing" "$OUT"

echo
echo "5. an id prefix that disagrees with its kind is refused:"
d=$(new_record wrongprefix "$GOOD1" '{"id":"INC-0002","ts":"2026-09-02T00:00:00Z","kind":"note","summary":"mislabelled","tags":["a"],"repo":"r","detected_by":"agent"}')
cd "$d" || exit 1
run
[ "$RC" = 1 ] && ok "kind 'note' under an INC- id exits 1" \
              || bad "kind 'note' under an INC- id exits 1" "exit $RC: $OUT"

echo
echo "6. a supersedes pointing at nothing is refused:"
# Closing an incident works by appending an event that supersedes it. A pointer to
# an id that does not exist means a closure that closes nothing.
d=$(new_record danglingref "$GOOD1" '{"id":"INC-0002","ts":"2026-09-02T00:00:00Z","kind":"incident","summary":"closes a ghost","tags":["a"],"repo":"r","detected_by":"agent","supersedes":"INC-9999"}')
cd "$d" || exit 1
run
[ "$RC" = 1 ] && ok "a supersedes naming a nonexistent id exits 1" \
              || bad "a supersedes naming a nonexistent id exits 1" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q "INC-9999" \
    && ok "and it names the id that does not exist" \
    || bad "and it names the id that does not exist" "$OUT"

echo
echo "7. blank lines are not an error:"
d=$(new_record blanks "$GOOD1" "" "$GOOD2" ""); cd "$d" || exit 1
run
[ "$RC" = 0 ] && ok "blank lines are tolerated" || bad "blank lines are tolerated" "exit $RC: $OUT"

echo
echo "8. no record at all is not a failure, but an unreadable one IS:"
d="$box/norecords"; mkdir -p "$d"; cd "$d" || exit 1; git init -q -b main 2>/dev/null
run
[ "$RC" = 0 ] && ok "a repository with no records/ exits 0" \
              || bad "a repository with no records/ exits 0" "exit $RC: $OUT"

d="$box/emptydir"; mkdir -p "$d/records"; cd "$d" || exit 1; git init -q -b main 2>/dev/null
run
[ "$RC" = 3 ] && ok "a records/ directory with no events.jsonl exits 3, not 0" \
              || bad "a records/ directory with no events.jsonl exits 3, not 0" "exit $RC: $OUT"
printf '%s' "$OUT" | grep -qi "could not\|cannot" \
    && ok "and it says it could not check" \
    || bad "and it says it could not check" "$OUT"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Controls for check-models.sh.
#
# Two questions per control, the pair this repository uses on any check:
#   1. Could the check PASS if the thing it tests did not exist?
#   2. Could the value it asserts occur by accident?
#
# Case B answers the first — an empty agents directory must never read as a clean
# roster, or a wrong path looks like success. Case M answers the second: the first
# draft of the full-ID pattern accepted "claude-opus-5-typo", because every
# character of "-typo" was inside its character class. That is the same shape as
# the bug the script exists to catch, so it gets a control of its own.
#
# Fixtures are SYNTHETIC, never the real roster. A control that reads
# plugins/serina/agents/ would break whenever that roster legitimately changes,
# and would tell you nothing about the check.
#
# Usage:  test-check-models.sh
# Exit:   0 = every control behaved, 1 = at least one did not

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/check-models.sh"
[[ -x "$check" ]] || { echo "FAIL  check-models.sh not found or not executable at $check"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# agent DIR FILE NAME MODEL  — writes a minimal valid agent definition.
# An empty MODEL omits the line entirely, which is Case E's whole point.
agent() {
  local dir="$1" file="$2" name="$3" model="$4"
  mkdir -p "$dir"
  { printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf 'description: A fixture agent.\n'
    printf 'tools: Read, Bash\n'
    [[ -n "$model" ]] && printf 'model: %s\n' "$model"
    printf -- '---\n\nFixture body.\n'
  } > "$dir/$file"
}

expect() {
  local want="$1" label="$2"; shift 2
  local out rc
  out="$("$check" "$@" 2>&1)"; rc=$?
  if [[ "$rc" -eq "$want" ]]; then
    printf 'PASS  %s\n' "$label"
  else
    printf 'FAIL  %s (wanted exit %s, got %s)\n' "$label" "$want" "$rc"
    printf '%s\n' "$out" | sed 's/^/        /'
    fail=1
  fi
}

# A check that fails for the wrong reason is not a working check, so the failing
# controls assert on the message too.
expect_naming() {
  local want="$1" needle="$2" label="$3"; shift 3
  local out rc
  out="$("$check" "$@" 2>&1)"; rc=$?
  if [[ "$rc" -eq "$want" ]] && printf '%s' "$out" | grep -qF -- "$needle"; then
    printf 'PASS  %s\n' "$label"
  else
    printf 'FAIL  %s (wanted exit %s containing %q, got exit %s)\n' "$label" "$want" "$needle" "$rc"
    printf '%s\n' "$out" | sed 's/^/        /'
    fail=1
  fi
}

# ------------------------------------------------------------------ A: clean
d="$tmp/clean"
agent "$d" review-code.md    review-code    sonnet
agent "$d" review-final.md   review-final   opus
agent "$d" review-heavy.md   review-heavy   fable
agent "$d" pinned-exact.md   pinned-exact   claude-opus-5
agent "$d" review-a11y.md    review-a11y    opus
expect 0 "A  a roster of known models, a11y at its floor -> clean" "$d"

# ------------------------------------------------------- B: the vacuity guard
mkdir -p "$tmp/empty"
expect_naming 1 "NO *.md agent files" "B  empty agents dir -> refuses to report clean (vacuity guard)" "$tmp/empty"

expect_naming 1 "not a directory" "C  nonexistent dir -> FAIL, not a silent skip" "$tmp/nope"

# ------------------------------------------- D: the proven fail-open, statically
d="$tmp/typo"
agent "$d" review-code.md review-code sonnet-typo-xyz
expect_naming 1 "sonnet-typo-xyz" "D  the 2026-08-06 fail-open: unknown model named and rejected" "$d"

# --------------------------------------------------------- E: no model at all
d="$tmp/nomodel"
agent "$d" review-code.md review-code ""
expect_naming 1 "has no 'model:'" "E  no model: line -> FAIL (inherits the caller's tier silently)" "$d"

# -------------------------------------------------- F/G/H: the a11y floor
d="$tmp/floor-low"
agent "$d" review-a11y.md review-a11y sonnet
expect_naming 1 "below its floor" "F  review-a11y on sonnet -> FAIL (the non-negotiable, asserted)" "$d"

d="$tmp/floor-ok"
agent "$d" review-a11y.md review-a11y opus
expect 0 "G  review-a11y on opus -> clean" "$d"

d="$tmp/floor-up"
agent "$d" review-a11y.md review-a11y fable
expect 0 "H  review-a11y on fable -> clean (escalating above a floor is allowed)" "$d"

# ------------------------------------- I: prose must not satisfy the check
# The body says the right thing and the frontmatter says nothing. Reading the
# whole file instead of the frontmatter block would pass this.
d="$tmp/prose"; mkdir -p "$d"
printf -- '---\nname: review-code\ndescription: A fixture.\n---\n\nRemember to set model: opus in the frontmatter.\n' > "$d/review-code.md"
expect_naming 1 "has no 'model:'" "I  'model: opus' in the BODY does not count as routing" "$d"

# --------------------------------------------- J: unparseable frontmatter
d="$tmp/unterminated"; mkdir -p "$d"
printf -- '---\nname: review-code\nmodel: opus\n\nno closing fence, so nothing here parses\n' > "$d/review-code.md"
expect_naming 1 "unterminated frontmatter" "J  frontmatter never closed -> FAIL, not parsed-as-clean" "$d"

d="$tmp/nofm"; mkdir -p "$d"
printf 'Just a note file in the agents directory.\n' > "$d/README.md"
expect_naming 1 "no frontmatter" "K  a file with no frontmatter at all -> FAIL" "$d"

d="$tmp/noname"; mkdir -p "$d"
printf -- '---\ndescription: A fixture with no name.\nmodel: opus\n---\n\nBody.\n' > "$d/stray.md"
expect_naming 1 "no 'name:'" "L  frontmatter without name: -> not a dispatchable agent" "$d"

# ------------------------------- M: the near-miss in this script's own pattern
# The first draft's full-ID class accepted this. It must not.
d="$tmp/idtypo"
agent "$d" review-code.md review-code claude-opus-5-typo
expect_naming 1 "claude-opus-5-typo" "M  a typo'd full model ID -> FAIL (the pattern's own near-miss)" "$d"

d="$tmp/idreal"
agent "$d" a.md agent-a claude-haiku-4-5-20251001
agent "$d" b.md agent-b 'claude-opus-5[1m]'
expect 0 "N  real dated ID and the [1m] long-context form -> clean" "$d"

# ------------------------------------------------- O: multiple dirs, one bad
d1="$tmp/multi-ok"; d2="$tmp/multi-bad"
agent "$d1" review-code.md review-code opus
agent "$d2" review-tests.md review-tests nonsense-model
expect_naming 1 "nonsense-model" "O  several dirs, one offender -> FAIL and names it" "$d1" "$d2"

expect 1 "P  no arguments at all -> FAIL"

if [[ $fail -eq 0 ]]; then
  printf '\nall controls behaved\n'
else
  printf '\nSOME CONTROLS FAILED\n'
fi
exit "$fail"

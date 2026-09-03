#!/usr/bin/env bash
# Controls for stamp-path.sh — the shared stamp-location resolver.
#
# THE DEFECT THESE EXIST FOR. Three hooks computed the stamp from
# CLAUDE_PROJECT_DIR. With a container as the session root, every repository
# under it shared one stamp: tests in one unlocked commits in another, and a
# second session's edit cleared the first session's verification. The control
# that would have caught it is "two repositories, two different paths" — so it is
# here, and it is the one to check first if this file ever goes quiet.
#
# Two questions per control, the pair this repository uses:
#   1. Could the check PASS if the thing it tests did not exist?
#   2. Could the value it asserts occur by accident?
#
# Question 1 is answered structurally by control 0: the suite aborts if the
# sourced file is missing or defines nothing, so a deleted stamp-path.sh cannot
# read as 38 quiet passes. Question 2 is answered by asserting on FULL paths
# inside per-test temp repos, never on a substring like ".verified" that every
# possible answer contains.
#
# Usage:  test-stamp-path.sh
# Exit:   0 = every control behaved, 1 = at least one did not

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/stamp-path.sh"

ran=0; failed=0
ok()   { ran=$((ran+1)); printf '  ok      %s\n' "$1"; }
nope() { ran=$((ran+1)); failed=$((failed+1)); printf '  FAILED  %s\n' "$1"; }

# --- 0. the suite is not vacuous ---------------------------------------------
# A missing or empty file must abort here rather than let every control below
# pass by asserting nothing against nothing.
[[ -r "$sut" ]] || { echo "FAIL  stamp-path.sh not found at $sut"; exit 1; }
# shellcheck source=/dev/null
. "$sut"
for fn in stamp_target_dir_from_command stamp_repo_root stamp_path_for; do
  if ! declare -F "$fn" >/dev/null; then
    echo "FAIL  $sut defines no $fn — the rest of this suite would be vacuous"; exit 1
  fi
done
echo "stamp-path.sh sourced; 3 of 3 functions defined."

box="$(mktemp -d)"; trap 'rm -rf "$box"' EXIT
# Two real repositories, because the whole defect was about telling them apart.
for r in alpha beta; do
  mkdir -p "$box/$r"
  git -C "$box/$r" init -q 2>/dev/null
  git -C "$box/$r" commit -q --allow-empty -m init 2>/dev/null
done
mkdir -p "$box/plain"          # deliberately NOT a repository
A=$(cd "$box/alpha" && pwd -P)
B=$(cd "$box/beta"  && pwd -P)

want() {  # want LABEL EXPECTED ACTUAL
  if [[ "$3" == "$2" ]]; then ok "$1"; else nope "$1 — got '$3', wanted '$2'"; fi
}
wantnot() {  # wantnot LABEL FORBIDDEN ACTUAL
  if [[ "$3" != "$2" ]]; then ok "$1"; else nope "$1 — got the forbidden '$2'"; fi
}

echo
echo "stamp_path_for — repository scoping:"
want "hint names alpha, so the stamp is alpha's" \
     "$A/.claude/.verified" "$(cd "$box/plain" && stamp_path_for "$A")"
want "hint names beta, so the stamp is beta's" \
     "$B/.claude/.verified" "$(cd "$box/plain" && stamp_path_for "$B")"
# THE CONTROL FOR THE ORIGINAL DEFECT. Before the fix both of these returned the
# container's single path, and this is the assertion that fails on that.
wantnot "alpha and beta do NOT share one stamp" \
     "$(cd "$box/plain" && stamp_path_for "$A")" "$(cd "$box/plain" && stamp_path_for "$B")"
want "no hint falls back to cwd's repository, not the session root" \
     "$A/.claude/.verified" "$(cd "$box/alpha" && stamp_path_for)"
want "a hint inside a subdirectory still resolves to the repo root" \
     "$A/.claude/.verified" "$(mkdir -p "$A/deep/er" && stamp_path_for "$A/deep/er")"
want "an unresolvable hint falls back to cwd's repo rather than being discarded" \
     "$A/.claude/.verified" "$(cd "$box/alpha" && stamp_path_for "$box/nope-not-here")"
want "outside any repository, the old CLAUDE_PROJECT_DIR path is kept" \
     "$box/plain/.claude/.verified" \
     "$(cd "$box/plain" && CLAUDE_PROJECT_DIR="$box/plain" stamp_path_for)"

echo
echo "stamp_target_dir_from_command — the git -C form (verb bounded):"
want "plain -C" "$A" "$(stamp_target_dir_from_command "git -C $A commit -m x" commit)"
want "-C after other global options" "$A" \
     "$(stamp_target_dir_from_command "git --paginate -C $A commit -m x" commit)"
want "a quoted path containing a space" "/tmp/my repo" \
     "$(stamp_target_dir_from_command "git -C '/tmp/my repo' commit -m x" commit)"
# A commit MESSAGE mentioning -C must not win. Discussing these commands in a
# commit message is routine here, which is what makes this reachable rather than
# theoretical.
want "a decoy -C in the commit message is not extracted" "$A" \
     "$(stamp_target_dir_from_command "git -C $A commit -m \"document -C /decoy repo\"" commit)"
# NO VERB MEANS NO -C BRANCH, on purpose: without a verb the span cannot be
# bounded, and an unbounded match is the decoy bug above.
want "with no verb, the -C form is not used at all" "" \
     "$(stamp_target_dir_from_command "git -C $A commit -m x")"

echo
echo "stamp_target_dir_from_command — the cd form (what a test command uses):"
want "cd then a test runner" "$A" \
     "$(stamp_target_dir_from_command "cd $A && python3 -m unittest")"
want "cd after a semicolon" "$A" \
     "$(stamp_target_dir_from_command "echo hi; cd $A && npm test")"
want "cd with a quoted spaced path" "/tmp/my repo" \
     "$(stamp_target_dir_from_command "cd '/tmp/my repo' && npm test")"
want "a command naming no directory yields nothing" "" \
     "$(stamp_target_dir_from_command "npm test")"

# THE cd FORM'S DECOY CONTROLS. The -C form has had one since it was written
# (above); its twin had none, and was broken the whole time. Confirmed
# 2026-08-10 by an independent reviewer of PR #67:
#
#   cd /realtarget && git commit -m "please cd /decoy first"   ->  /decoy
#
# Two causes: sed's leading `.*` is greedy so it took the LAST cd, and nothing
# excluded the commit message, which in this repository routinely contains paths
# and shell fragments. The -C branch's own header calls that case "routine here",
# which is why THAT branch was bounded — and the reason its twin was not is that
# the fix was applied where the defect was reported rather than everywhere it
# lived. That is the failure this file's header names, occurring inside a single
# function.
#
# It misdirects the WRITER and the READER together: post-bash stamps one
# repository while verify-gate checks another.
want "a decoy cd in the commit message is not extracted" "$A" \
     "$(stamp_target_dir_from_command "cd $A && git commit -m \"please cd /decoy first\"" commit)"
want "a quoted real path survives a decoy in the message" "/tmp/my repo" \
     "$(stamp_target_dir_from_command "cd '/tmp/my repo' && git commit -m \"cd /decoy\"" commit)"
# A cd that exists ONLY inside the message names no directory at all. Returning
# the decoy here would be worse than returning nothing: nothing falls back to
# cwd, which is right, while the decoy points somewhere arbitrary.
want "a cd appearing only in the message yields nothing" "" \
     "$(stamp_target_dir_from_command "git commit -m \"remember to cd /decoy first\"" commit)"
# The FIRST cd is the one that determined the working directory.
want "with two real cds, the first one wins" "$A" \
     "$(stamp_target_dir_from_command "cd $A && cd /second && git commit -m x" commit)"
# NON-VACUITY: the truncation must not eat a legitimate target. A test command
# has no -m at all, so nothing is cut, and this is the shape post-bash sees.
want "a test command with no message is unaffected by the truncation" "$A" \
     "$(stamp_target_dir_from_command "cd $A && npm test -- --verbose")"

echo
echo "stamp_target_dir_from_command — unexpanded payload text:"
# The payload carries raw text: the shell has not run, so these arrive literally.
want "a literal \$HOME is expanded" "$HOME/x" \
     "$(stamp_target_dir_from_command 'cd $HOME/x && npm test')"
want "a literal \${HOME} is expanded" "$HOME/x" \
     "$(stamp_target_dir_from_command 'cd ${HOME}/x && npm test')"
want "a leading ~ is expanded" "$HOME/x" \
     "$(stamp_target_dir_from_command 'cd ~/x && npm test')"
# A tilde that is not a home reference must be left alone rather than mangled.
want "a ~ mid-path is left alone" "/tmp/a~b" \
     "$(stamp_target_dir_from_command 'cd /tmp/a~b && npm test')"

echo
if [ "$failed" -eq 0 ]; then
  echo "$ran controls, 0 failing"
else
  echo "$ran controls, $failed FAILING"
fi
[ "$failed" -eq 0 ]

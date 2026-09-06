#!/usr/bin/env bash
# Which Bash commands count as running a test or build. Sourced, not executed.
#
#   . classify-test-commands.sh      then use "$TEST_PATTERN" with grep -qEi
#
# ---------------------------------------------------------------------------
# WHY THIS IS A LIBRARY AND NOT A LINE IN post-bash.sh
#
# It was a line in post-bash.sh until 2026-09-06. Then `post-bash-failure.sh`
# arrived needing the IDENTICAL question answered — "is this command a test run?" —
# because a failing test must clear the stamp (INC-0025) and a failing test must be
# recorded in the flake ledger (INC-0024), while a failing `grep` must do neither.
#
# Copying the pattern into the second hook would have been the fourth row of this
# kit's own bypass table: *a fix applied to the file where the defect was reported,
# and not to its twin.* Two copies of a regex this long drift the first time a
# runner is added to one of them, and the drift is silent — one hook stamps a suite
# the other does not recognise.
#
# So it moved here, verbatim, comments and all. The 168 controls in
# test-post-bash.sh are what prove the move was faithful: not one of them changed.
#
# ---------------------------------------------------------------------------
# Match common test and build commands.
#
# A SUITE ON A PATH IS STILL A SUITE, and until 2026-08-13 this pattern could not
# say so. Every alternative below names a package manager or a language runner, so
# a repository whose verification is a script — `check-plan.sh`, `test-hooks.sh`,
# the very controls in this directory — had no way to earn a stamp, and was pushed
# down the `touch .claude/.verified` escape hatch instead. That is the one route
# the gate exists to make unnecessary. Measured in launchpad-26/buzz: a plan
# verified by `check-plan.sh` was committed behind a touched stamp because nothing
# here matched it.
#
# THE SIGNAL IS THE BASENAME, and it is the only one available — a script cannot be
# asked whether it verifies anything, and reading it to guess would be worse. So:
# `test-`/`check-` prefixed, or `-test`/`_test(s)` suffixed, with a script
# extension. That is a naming convention doing load-bearing work, which is a real
# cost; it is accepted because the alternative measured worse.
#
# POSITION STILL DECIDES, and that is what keeps this from being a hole. The caller
# anchors the match to the START of the final segment, so `cat test-hooks.sh`,
# `shellcheck test-hooks.sh`, `grep -r test-hooks.sh .` and `echo bash
# check-plan.sh` all name a suite and none of them stamps.
#
# THE EXTENSION MUST END THE TOKEN, and the first version of this line did not say
# so. `grep -E` searches rather than matches, so an extension with no trailing
# boundary matched as a PREFIX of a longer, unrelated one — `.js` inside `.json`,
# `.py` inside `.pyc` and `.pyi`, `.sh` inside `.sh~` and `.sh.bak`, `.rb` inside
# `.rbi`. Measured: `node test-config.json` runs no suite, exits 0 because a JSON
# object is valid JS, and wrote a pass stamp — a 30-minute commit unlock earned by
# reading a fixture. Found by review before it shipped. `([[:space:]"']|$)` is the
# whole fix.
#
# WIDENING STAYS TIGHT because the separator group is optional rather than absent:
# `checkout.sh` and `tester.sh` still do not match, since without a `-`/`_` the
# extension must follow the word immediately. An earlier version demanded a
# separator and so missed `./test.sh`, `./check.sh` and `deploy-check.sh`. Those
# failed closed — they cost reach, not safety — but the branch would have closed
# its driving issue while leaving that issue's own example unmatched.
# ---------------------------------------------------------------------------

SUITE_SCRIPT='((tests?|checks?)([-_][A-Za-z0-9._-]*)?|[A-Za-z0-9._-]*[-_](tests?|checks?))\.(sh|bash|zsh|py|js|mjs|cjs|ts|rb|pl)([[:space:]"'"'"']|$)'
# NO TRAILING BOUNDARY ON THE RUNNER LIST, AND THAT IS A KNOWN DEFECT — not an
# oversight, and not fixed here, because the obvious fix is worse.
#
# `grep -E` searches, so every bare alternative matches as a PREFIX of a longer
# word: `pytest` inside `pytest-other`, `npm test` inside `npm testing`. A
# successful `pytest-other` therefore writes a pass stamp for a command that ran no
# suite. Real, and recorded.
#
# ADDING `([[:space:]"'"'"']|$)` AFTER THE GROUP WAS TRIED ON 2026-09-06 AND
# REVERTED WITHIN THE HOUR. It broke three legitimate forms and did not close the
# hole:
#
#   npm run test:unit   STOPPED MATCHING — a `:` suffix is not a boundary, and this
#                       is one of the most common test commands there is
#   make test-all       STOPPED MATCHING — same shape, a suffixed target
#   pytest>out.log      STOPPED MATCHING — redirection without a space, which
#                       post-bash explicitly supports
#   pytest""-other      STILL MATCHED — the shell concatenates the fragments into
#                       `pytest-other`, and a quote had been put IN the boundary
#                       class, so the very hole being closed stayed open
#
# None of the 168 controls in test-post-bash.sh caught the regression, because none
# of them runs `npm run test:unit`. That gap is the more useful finding.
#
# The correct fix distinguishes a script-name suffix (`test:unit`, `test-all`) from
# an unrelated longer word (`testing`, `pytest-other`), which needs per-alternative
# rules rather than one trailing class. It belongs in its own change with its own
# controls, not bundled into a hook fix. Tracked; the false positive it leaves is a
# command nobody runs by accident.

# WHAT MAY PRECEDE THE SUITE. Env assignments and a small set of wrappers — and
# NO FLAGS. Shared with post-bash.sh from 2026-09-06 so post-bash-failure.sh cannot
# drift from it.
#
# A CROSS-VENDOR REVIEW ASKED FOR A FLAG GROUP HERE AND THE CONTROLS REFUTED IT.
# The observation was correct: `bash -x test-hooks.sh` and `python3 -u test_x.py`
# are real runs this does not match, which is fail-closed for stamping and
# FAIL-OPEN for clearing. The proposed fix — allow `(-[^[:space:]]+[[:space:]]+)*`
# after each wrapper — was tried, and eighteen controls in test-post-bash.sh went
# red at once, by name:
#
#   bash -n syntax-checks, it does not run       ruby -c / perl -c do not run
#   node -e code does not stamp                  command -v is a lookup, not a run
#   sudo -u takes a username                     bash -O takes a shopt name
#
# Two separate reasons, both fatal. Some flags mean DO NOT ACTUALLY RUN (`-n`,
# `-c`, `-e`, `-v`), so admitting them would write a GREEN stamp for a command that
# executed no suite — a false pass, strictly worse than the fail-open it fixes.
# Others CONSUME THE NEXT TOKEN (`-u`, `-O`), so the thing that looks like a suite
# is a flag's argument.
#
# The controls carry "(flag class deleted)" in their names: someone had already
# tried this and written them to stop it returning. They worked.
#
# SO IT STAYS A KNOWN LIMITATION, in both directions and stated in the README: a
# suite run behind a wrapper flag neither stamps nor clears. Telling `-x` from `-n`
# needs per-wrapper flag semantics, and being wrong in the permissive direction
# costs a false green.
RUN_LEAD='^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|env|time|nohup|sudo|command|exec|bash|sh|zsh|python3?|node|bun|deno|ruby|perl)[[:space:]]+)*["'"'"']?([^[:space:]]*/)?'
TEST_PATTERN='(npm\s+(test|run\s+test[s]?|run\s+build|run\s+check|run\s+lint)|npx\s+(vitest|jest|playwright)|pytest|py\.test|python3?\s+-m\s+(unittest|pytest)|go\s+test|cargo\s+test|cargo\s+build|dotnet\s+test|dotnet\s+build|make\s+test|make\s+check|bun\s+test|bun\s+run\s+test|pnpm\s+(test|run\s+test)|yarn\s+test|gradle\s+test|mvn\s+test|'"$SUITE_SCRIPT"')'

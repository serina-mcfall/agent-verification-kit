#!/bin/bash
# PreToolUse hook on Bash: blocks git commit without fresh verification stamp
# The stamp is created by post-bash.sh when a recognized test/build command passes.
# Edits clear the stamp (via edit-tracker.sh), forcing re-verification.

# announce() puts a message on the ONE channel NOTE-0032 observed reaching a
# human. Sourced defensively: if the library is missing this gate keeps working
# and falls back to the old stderr behaviour, because a commit gate that breaks
# over a missing MESSAGE FORMATTER would be a worse defect than the silence.
#
# EVERY REFUSAL IN THIS FILE IS LEFT ALONE. A block is raw text on stderr at
# exit 2, which reaches a human already and is observed doing so. Only the
# ALLOW path and the fail-open warnings are converted — which is the whole of
# INC-0013: "say what authorised it" was being said to nobody.
ANNOUNCE_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/announce.sh"
if [ -r "$ANNOUNCE_LIB" ]; then . "$ANNOUNCE_LIB"; else announce() { printf '%s\n' "$*" >&2; }; fi

INPUT=$(cat)
# Claude Code delivers the hook payload on a SOCKET. `cat /dev/stdin` opens fd 0
# BY PATH, and a socket cannot be opened by path — it fails with ENXIO ("No such
# device or address"), writes to stderr, and $(...) captures only stdout. The
# result was an empty INPUT, which this script's own logic read as "not a git
# command" and allowed. Verified 2026-08-03: /proc/self/fd/0 -> socket:[...].
#
# Plain `cat` reads the already-open descriptor and works on a socket.
#
# The warning below exists because the original failure was SILENT for months.
# An empty payload is never normal; say so on stderr, which is visible without
# blocking the tool.
if [ -z "$INPUT" ]; then
  announce "verify-gate: empty payload — this hook cannot see the tool call and is not enforcing."
fi
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only gate git commit.
#
# THE TRIGGER USED TO BE `git\s+commit\b`, and that let the whole gate — stamp
# check included — be bypassed by any git GLOBAL OPTION sitting between the two
# words. `git -C /path/to/repo commit -m x` does not match `git` followed by
# whitespace followed by `commit`, so the hook exited 0 and enforced nothing.
# Found 2026-08-06 while testing the roster section below, which was silently
# never running for the same reason.
#
# The intervening tokens are enumerated rather than matched loosely (`git.*commit`
# would flag `git log --grep commit`). False positives merely annoy; a false
# negative is a bypass, so the list errs toward catching more.
#
# A VALUE MAY BE QUOTED, AND A QUOTED VALUE MAY CONTAIN SPACES. The first version
# matched a value as `[^[:space:]]+`, which stops at the first space, so the whole
# match failed and the ENTIRE gate — roster check and stamp check both — was
# skipped without a word:
#
#   git -C /tmp/x commit -m x            -> exit 2   blocked
#   git -C '/tmp/my repo' commit -m x    -> exit 0   ALLOWED, silently
#
# THE SIBLING FILE ALREADY FIXED THIS AND THIS ONE DID NOT. `git-safety.sh:64`
# carries the identical `VAL` construct, added the same day, after the same class
# of bypass was found there. That is the pattern worth naming: a fix applied to the
# file where the defect was reported, and not to its twin. When one of these is
# corrected, grep the whole hook layer for the shape before calling it done.
# AND THE ENUMERATION WAS ITSELF THE NEXT BYPASS. Measured 2026-08-06 against the
# exact regex this line used to hold: TEN global options walked straight through it.
#
#   git --paginate commit -m x   -> exit 0  ALLOWED        git --bare
#   git -p commit -m x           -> exit 0  ALLOWED        git --namespace=n
#   git --no-optional-locks      git --glob-pathspecs      git --icase-pathspecs
#   git --no-replace-objects     git --attr-source=x       git --no-advice
#
# `--no-pager` was listed and `--paginate` was not, which is the tell: the list was
# built from the options someone thought of, and git ships more of them than anyone
# recalls. A list of one vendor's option NAMES goes stale every release.
#
# THE COMMENT ABOVE POSED A FALSE CHOICE, and that is the part worth naming. It says
# the tokens are enumerated "rather than matched loosely", as if the alternatives
# were an exact list or `git.*commit`. They are not the same thing:
#
#   git.*commit      matches any text anywhere — it flags `git log --grep commit`
#   --[a-zA-Z-]+     matches the shape of a global option, BETWEEN `git` and the
#                    verb, and cannot reach the verb, because a verb has no dashes
#
# WHAT THAT DOES NOT BUY, stated because an earlier draft of this comment implied it
# did: the pattern is not anchored to a shell command position, so prose naming the
# command still matches. `echo git --paginate commit` is gated. That is UNCHANGED
# behaviour, not a cost of this fix — `echo git commit` was gated identically before
# it, and the only reason the --paginate spelling escaped was the bypass being closed
# here. Distinguishing a real invocation from a sentence about one needs a shell
# parser; see the AST prototype parked at 27/27 against this regex's 18/27.
#
# So the shape is used, and the enumerated long options collapse into it. `-C` and
# `-c` stay explicit because they take a SPACE-separated value the shape would not
# consume; `-p` is spelled out because it is a flag. Git has SIX short global options
# — `-v`, `-h`, `-C`, `-c`, `-p`, `-P` — and `-v`/`-h` print and exit instead of
# running a subcommand, so the four handled here are the four that can precede one.
#
# Verified by running, both directions: 11 block controls including every option
# above, and 9 must-allow controls — `git log --grep commit`, `git log --grep=commit`
# and `git rev-list --count main..head` all still pass through untouched.
# VAL/GITOPT NOW LIVE IN stamp-path.sh, sourced below, because this file defined
# them and the extraction further down re-derived the same thing — the duplication
# this file's own header warns about ("a fix applied to the file where the defect
# was reported, and not to its twin").
#
# SOURCED SOFTLY, AND THE HARD REFUSAL LIVES INSIDE THE COMMIT BRANCH ONLY.
# Measured the hard way on 2026-08-10: an earlier draft put a fail-closed `exit 2`
# for a missing resolver ABOVE this trigger, and it blocked every Bash, Edit,
# Write and MCP call in two live sessions — because it ran before anything had
# decided whether the call was even a commit. A gate for commits must not be
# reachable by an Edit. Fail-closed is right; fail-closed on the wrong scope is a
# lockout with no way back in from inside the session.
#
# BASH_SOURCE[0] IS THE PATH THE HOOK WAS INVOKED BY — the symlink in
# ~/.claude/hooks — not the file it points at. `dirname` of that searched the
# wrong directory entirely. `readlink -f` resolves through the symlink, which is
# how this hook is always reached.
STAMP_LIB="${STAMP_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/stamp-path.sh}"
STAMP_LIB_OK=no
if [ -r "$STAMP_LIB" ]; then
    # shellcheck source=/dev/null
    . "$STAMP_LIB" && STAMP_LIB_OK=yes
fi

if [ "$STAMP_LIB_OK" = yes ]; then
    GITOPT="$STAMP_GITOPT"
    echo "$COMMAND" | grep -qE "git${GITOPT}[[:space:]]+commit\b" || exit 0
else
    # Broken install. This branch decides one thing only: refuse, or stand aside.
    # The pattern is DELIBERATELY LOOSE — without the resolver there is no shared
    # GITOPT to be precise with, and refusing a `git log --grep commit` while the
    # gate is broken costs a re-type, whereas letting a real commit through costs
    # the guarantee. Anything not commit-shaped exits 0, which is what keeps an
    # Edit or an unrelated Bash call out of here.
    if echo "$COMMAND" | grep -qE 'git.*commit'; then
        echo "COMMIT BLOCKED — verify-gate cannot read its stamp resolver at $STAMP_LIB." >&2
        echo "Without it this hook cannot tell which repository's stamp to check, and" >&2
        echo "guessing would be the fail-open this gate exists to close." >&2
        echo "Restore $STAMP_LIB (it lives beside this script), then retry." >&2
        exit 2
    fi
    announce "verify-gate: stamp resolver missing at $STAMP_LIB — this call is not a commit, so it is allowed, but the gate is NOT enforcing."
    exit 0
fi

# ---------------------------------------------------------------------------
# ROSTER GATE — a bad `model:` must not reach a commit.
#
# WHY, measured 2026-08-06. An agent pinned to `model: sonnet-typo-xyz` and
# dispatched from a session pinned `--model sonnet` produced exit 0, an empty
# stderr, and a normal-looking result. The API DID reject it (404
# not_found_error), and Claude Code retried it up to 11 times, absorbed the
# error, and silently fell back to THE SESSION'S model. The only witness was a
# debug log nobody opts into.
#
# The dangerous direction is a typo'd `opus` in a Sonnet session: a review meant
# to be escalated quietly is not, and nothing says so. `review-a11y` is the
# sharpest case, because accessibility judgement is the one tier that is never
# downgraded for cost. The runtime cannot help — by the time it runs it has
# already decided to carry on. The only moment the mistake is visible is before
# it lands, which is here.
#
# PLACED BEFORE THE STAMP CHECK ON PURPOSE. Both can block, and a wrong roster
# is the more specific and more actionable message. It also makes this section
# testable: a control can assert on the marker below instead of on exit 2, which
# the stamp check produces too. A control that cannot tell WHICH rule fired is
# not testing the rule it claims to.
# ---------------------------------------------------------------------------
ROSTER_MARKER="COMMIT BLOCKED — agent roster"
# PORTABILITY FIX, 2026-09-03, on adoption into this plugin.
#
# This defaulted to `$HOME/.claude/hooks/check-models.sh` — the author's personal
# symlink layout. No adopter has that path, and the branch below FAILS CLOSED when
# the checker is missing, so an adopter's first commit touching `.claude/agents/*.md`
# would have been blocked with no way forward and a message naming a file they had
# never heard of.
#
# A gate that cannot be satisfied is not a gate; it is a lockout. Resolving the
# checker as a SIBLING is what the plugin can actually guarantee, and it matches how
# STAMP_LIB above already resolves. `readlink -f` for the same reason given there.
# The env override is kept: a repo that wants its own roster policy still can.
CHECK_MODELS="${CHECK_MODELS:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/check-models.sh}"

# WHICH repository does this commit target? Not necessarily the one the hook is
# standing in. The hook's cwd is the SESSION's, and the two routine ways an agent
# commits both move somewhere else first:
#
#   git -C /path/to/repo commit -m x
#   cd /path/to/repo && git commit -m x
#
# Resolving only from the hook's own cwd left both of those unchecked — a gate
# with two bypasses in its most common invocations. Found by asking how the commit
# would actually be typed rather than by testing the shape already written.
# THE EXTRACTION MOVED TO stamp-path.sh, unchanged in behaviour. It bounds the -C
# search to the `git <options> commit` span (a commit MESSAGE containing the text
# `-C /somewhere` must not be picked up instead — measured, and routine in this
# repository), handles the `cd` form, and expands the `~`/`$HOME`/`${HOME}` that
# arrive LITERALLY because the payload is unexpanded text.
#
# It lives there rather than here because post-bash.sh needs the same answer to
# decide which repository to stamp. Two copies of this parser is precisely the
# twin-file drift this file's header warns about; `test-stamp-path.sh` now holds
# its controls, including the decoy-message case.
TARGET_DIR=$(stamp_target_dir_from_command "$COMMAND" commit)

# Try the path named in the command, then FALL BACK to the hook's own cwd.
# The fallback matters: an unresolvable target (a variable this script does not
# expand, a typo, a path created later in the same command) must not throw away a
# perfectly good repository under cwd. Preferring the named path and falling back
# is strictly better than either alone — the first draft did target-only, which
# was a regression on the original cwd-only behaviour.
REPO_ROOT=""
if [ -n "$TARGET_DIR" ]; then
    REPO_ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$REPO_ROOT" ]; then
        announce "verify-gate: '$TARGET_DIR' (named in the command) is not a git repository — falling back to $(pwd) for the roster check."
    fi
fi
[ -z "$REPO_ROOT" ] && REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

if [ -z "$REPO_ROOT" ]; then
  # Visible non-enforcement, following the empty-payload precedent above: the
  # months-long failure was silent, so a check that cannot run must SAY it did
  # not rather than look like a pass. Not a block — an unrecognised environment
  # is not evidence of a bad roster.
  announce "verify-gate: no git repository resolves from $(pwd) — the agent-roster check did NOT run and is not enforcing here."
else
  # Which files does this commit involve? Staged, plus tracked modifications when
  # -a/--all is used, since those are staged at commit time and are not in the
  # index yet. `--amend` correctly does not match: it begins with two dashes,
  # and the pattern below requires a single-dash short flag.
  #
  # KNOWN LIMIT, stated rather than papered over: the checker reads the WORKING
  # TREE, not the staged blob. Staging a good version and leaving a bad one on
  # disk is not distinguished. That combination is rare; a typo on disk is the
  # realistic failure and it is caught.
  TOUCHED=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null)
  if echo "$COMMAND" | grep -qE '(^|[[:space:]])(-[a-z]*a[a-z]*|--all)([[:space:]]|$)'; then
      TOUCHED="$TOUCHED
$(git -C "$REPO_ROOT" diff --name-only 2>/dev/null)"
  fi

  # sed rather than `xargs -n1 dirname`: xargs splits on whitespace, so a path
  # containing a space would be torn into two nonexistent directories.
  mapfile -t CANDIDATE_DIRS < <(printf '%s\n' "$TOUCHED" \
    | grep -E '(^|/)agents/[^/]+\.md$' | sed 's|/[^/]*$||' | sort -u)

  # A DIRECTORY NAMED agents/ IS NOT NECESSARILY A ROSTER. The pattern above
  # matched any such directory anywhere in the repo, and a corpus taxonomy
  # document at docs/corpus/capabilities/agents/acp.md — no `name:`/`model:`,
  # forbidden by that schema's own `additionalProperties: false` — got the
  # identical "no 'name:' — does not belong in an agents directory" refusal a
  # genuinely broken agent file would. Found 2026-08-31 running launchpad-26/
  # buzz issue #703 through corpus-batch-author.
  #
  # Claude Code loads dispatchable agents from exactly two places: a project or
  # global `.claude/agents/*.md`, or a marketplace plugin's own agents/ dir,
  # named by a plugin's "source" in that repo's `.claude-plugin/marketplace.json`
  # (or the single-plugin `.claude-plugin/plugin.json`, whose implicit source is
  # the repo root). Filtering on THAT distinction — a real load path, not the
  # string "agents" — is what keeps a genuinely broken model caught while an
  # unrelated same-named folder (content taxonomy, a React feature directory, a
  # Rust module) is not.
  is_agent_roster_dir() {
      local rel="$1"
      case "$rel" in
          .claude/agents|*/.claude/agents) return 0 ;;
      esac
      if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ] && [ "$rel" = "agents" ]; then
          return 0
      fi
      local manifest="$REPO_ROOT/.claude-plugin/marketplace.json" src
      if [ -f "$manifest" ] && command -v jq >/dev/null 2>&1; then
          while IFS= read -r src; do
              src="${src#./}"
              [ -n "$src" ] && [ "$rel" = "$src/agents" ] && return 0
          done < <(jq -r '.plugins[]?.source // empty' "$manifest" 2>/dev/null)
      fi
      return 1
  }

  ROSTER_DIRS=()
  for d in "${CANDIDATE_DIRS[@]}"; do
      if is_agent_roster_dir "$d"; then
          ROSTER_DIRS+=("$d")
      else
          echo "verify-gate: '$d' matches an agents/*.md path but is not a known agent-roster location (.claude/agents, or a plugin's declared agents dir) — treating as an unrelated same-named directory, not enforcing the roster check on it." >&2
      fi
  done

  if [ "${#ROSTER_DIRS[@]}" -gt 0 ]; then
      if [ ! -x "$CHECK_MODELS" ]; then
          # FAILS CLOSED. Carrying on because the checker is absent would be the
          # very shape of defect this section was added to close.
          echo "$ROSTER_MARKER cannot be validated: no executable checker at $CHECK_MODELS." >&2
          echo "This commit changes agent definitions, so the check is not optional." >&2
          echo "Restore the symlink, or set CHECK_MODELS to the checker's path." >&2
          exit 2
      fi

      ABS_DIRS=()
      for d in "${ROSTER_DIRS[@]}"; do ABS_DIRS+=("$REPO_ROOT/$d"); done

      ROSTER_OUT=$("$CHECK_MODELS" "${ABS_DIRS[@]}" 2>&1)
      ROSTER_RC=$?
      case "$ROSTER_RC" in
        0) echo "Agent roster checked: ${#ABS_DIRS[@]} dir(s), every model resolves." ;;
        1)
          echo "$ROSTER_MARKER is invalid." >&2
          printf '%s\n' "$ROSTER_OUT" | grep '^FAIL' >&2
          echo "" >&2
          echo "A wrong model: does NOT fail at runtime — it 404s, retries, and silently" >&2
          echo "falls back to the dispatching session's model. Fix the value, or run:" >&2
          echo "  $CHECK_MODELS ${ABS_DIRS[*]}" >&2
          exit 2 ;;
        *)
          # An exit code the checker does not document means its answer is not
          # understood. An answer that is not understood is not a pass. This is
          # the fail-open-on-unknown-exit pattern, closed deliberately.
          echo "$ROSTER_MARKER check exited $ROSTER_RC, which it is not documented to return (0 or 1 only)." >&2
          echo "Treating an unrecognised result as a failure rather than a pass." >&2
          printf '%s\n' "$ROSTER_OUT" | head -20 >&2
          exit 2 ;;
      esac
  fi
fi

# THE STAMP IS THE COMMITTED-TO REPOSITORY'S, NOT THE SESSION ROOT'S.
#
# This read `"${CLAUDE_PROJECT_DIR:-.}/.claude/.verified"` — while REPO_ROOT, the
# correct answer, sat resolved a few lines above and unused. When the session root
# is a CONTAINER of repositories (~/Launchpad holds ten), that is one stamp shared
# by all of them, and it failed in both directions at once:
#
#   fail-open    `npm test` in nextjs-project unlocked a commit in buzz. Nothing
#                had tested buzz. The gate printed "Verified 0m ago" and meant
#                nothing by it — a green light with no measurement behind it.
#   fail-closed  a second concurrent session's Edit ran edit-tracker, deleting the
#                shared stamp mid-commit in the first. Observed 2026-08-10.
#
# REPO_ROOT may be empty (no repository resolved); stamp_path_for then falls back
# to the old CLAUDE_PROJECT_DIR path, so a non-git project keeps the gate it had.
# A `git commit` outside a repository fails on its own regardless.
VERIFIED=$(stamp_path_for "$REPO_ROOT")

# No stamp = no commit
if [ ! -f "$VERIFIED" ]; then
    # This message is the whole user interface of the gate, and #22 measured what
    # its first draft cost: it listed runners this repository does not have, never
    # named the path it checked, never said the stamp expires, and never said the
    # stamp must already exist when the commit call starts — so the documented
    # escape hatch became the trained route. Each line below answers one of those.
    cat >&2 << EOF
COMMIT BLOCKED — no verification stamp at $VERIFIED.

Run the project's test or build command, then commit in a SEPARATE tool call:
the stamp is written by a hook AFTER a successful test call finishes, so a test
chained to its own commit is checked before either has run.
  make test / npm test / npm run build / pytest / go test / cargo test / dotnet test / bun test
A SUITE INVOKED BY PATH ALSO EARNS THE STAMP — bash check-plan.sh <args>,
./test-hooks.sh, python3 test_x.py. Run it as the only command in the call.
The stamp expires 30 minutes after the run, and any file edit clears it.
If you edited files after the last test run, re-run tests.
Only if this project has NO suite at all: touch .claude/.verified — and say in the
commit that the stamp was touched rather than earned, because nothing else records it.
EOF
    exit 2
fi

# Stale stamp (>30 minutes) = no commit
STAMP_AGE=$(( $(date +%s) - $(stat -c %Y "$VERIFIED" 2>/dev/null || echo 0) ))
if [ "$STAMP_AGE" -gt 1800 ]; then
    echo "COMMIT BLOCKED — verification stamp is $(( STAMP_AGE / 60 ))m old (stale after 30m). Re-run tests." >&2
    rm -f "$VERIFIED"
    exit 2
fi

# SAY HOW THE STAMP WAS EARNED, not only when.
#
# post-bash.sh records a third field: `observed` when it read a real exit code,
# `inferred` when the payload carried none and it concluded success from its own
# invocation. The harness currently sends no exit code at all, so in practice this
# reads `inferred` — and that is exactly the fact worth surfacing rather than
# burying, because an inferred stamp rests on a premise (PostToolUse does not fire
# for a non-zero exit) that is tested but not guaranteed for every future shape.
#
# Not a block. An inferred stamp is the normal case today and blocking on it would
# close the gate entirely. This makes the basis visible at the moment it is relied
# upon, so a wrong premise leaves a trail instead of silently unlocking a commit.
#
# Missing third field means a stamp written before this existed, or a hand-written
# one. Reported as `unrecorded` rather than assumed good.
STAMP_BASIS=$(cut -d'|' -f3 "$VERIFIED" 2>/dev/null)
# WHICH SUITE AUTHORISED THIS. Issue #100 asks for the record AND for this
# gate to report it, and says that half matters more than the matcher. The
# field has been written since the provenance change and read by nothing —
# closing #100 with it still unread would repeat #22, which was closed with
# its own stated fix unlanded and is why #100 exists.
STAMP_CMD=$(cut -d'|' -f2 "$VERIFIED" 2>/dev/null)

# ---------------------------------------------------------------------------
# FOURTH FIELD: was this pass a RE-RUN? — Stage 3.
#
# `flaky` means post-bash saw this exact command FAIL within the ledger's window
# with no edit since, so the pass is a re-run rather than a fix. Measured
# 2026-09-04: that sequence used to write an ordinary stamp and unlock a commit,
# and neither shipped stage noticed — Stage 1 sees only the final pass, Stage 2
# never fires because no test file was touched.
#
# A MISSING FOURTH FIELD READS AS CLEAN. Stamps written before this existed have
# three fields, and treating them as flaky would block every commit for thirty
# minutes after an upgrade. It is a fail-open, it is bounded by the TTL, and it
# is asserted in the suite so it stays deliberate.
#
# NO NEW DEPENDENCY. This reads a field and greps a file; it does not source
# flake-ledger.sh. verify-gate is the one hook that can lock a session out, and
# its header records what happened the last time a fail-closed check was placed
# where an unrelated call could reach it.
#
# THE DECLARATION USES ` :: `, AND THAT IS THE OPPOSITE OF STAGE 2 ON PURPOSE.
# guard-test-changes.sh matches declared PATHS by prefix, which is right — a path
# is a token. A COMMAND IS NOT: `npm test` is a strict prefix of
# `npm test -- --grep auth`, so prefix matching would let a declaration for
# either authorise the other. Both directions are asserted as negative controls.
# The delimiter makes the command an exact field. A command containing ` :: `
# literally would be undeclarable; that is the stated limit of this format.
# ---------------------------------------------------------------------------
STAMP_FLAKE=$(cut -d'|' -f4 "$VERIFIED" 2>/dev/null)
if [ "$STAMP_FLAKE" = flaky ]; then
    FLAKY_REPO="${VERIFIED%/.claude/.verified}"
    FLAKY_DECL="$FLAKY_REPO/.claude/.flaky"
    FLAKY_AUTH=""
    if [ -f "$FLAKY_DECL" ]; then
        while IFS= read -r fline || [ -n "$fline" ]; do
            case "$fline" in ''|\#*) continue ;; esac
            case "$fline" in *' :: '*) ;; *) continue ;; esac
            # %% takes the FIRST delimiter, so a reason containing ` :: ` cannot
            # extend the command it claims to declare.
            [ "${fline%% :: *}" = "$STAMP_CMD" ] || continue
            # AN ISSUE NUMBER IS REQUIRED. Without it the declaration is
            # "flaky, will look later", and the risk this mechanism exists to
            # mitigate is a genuine bug quietly refiled as a flake. The kit
            # checks the number is PRESENT; it can never check it is true.
            case "${fline#* :: }" in *'#'[0-9]*) FLAKY_AUTH="${fline#* :: }"; break ;; esac
        done < "$FLAKY_DECL"
    fi

    if [ -z "$FLAKY_AUTH" ]; then
        # WHEN IT FAILED, because the ledger is repository-scoped and several
        # sessions share it. Without the time this reads as "the gate is broken"
        # rather than "that was my other session twenty minutes ago".
        FLAKY_WHEN=""
        if [ -r "$FLAKY_REPO/.claude/.failed-runs" ]; then
            while IFS= read -r lline || [ -n "$lline" ]; do
                [ "${lline#*|}" = "$STAMP_CMD" ] || continue
                FLAKY_WHEN=" It failed at $(date -d "@${lline%%|*}" +%H:%M 2>/dev/null || echo '?') and passed at $(date -d "@$(cut -d'|' -f1 "$VERIFIED")" +%H:%M 2>/dev/null || echo '?'), with no edit between."
                break
            done < "$FLAKY_REPO/.claude/.failed-runs"
        fi
        {
            echo "COMMIT BLOCKED — the suite that unlocked this commit FAILED first and passed on a re-run."
            echo
            echo "  command: $STAMP_CMD"
            [ -n "$FLAKY_WHEN" ] && echo "  ${FLAKY_WHEN# }"
            echo
            echo "A pass that only happens on the second try is not evidence the code works — it is"
            echo "evidence the suite is flaky, or that the failure was real and has been re-rolled"
            echo "away. Re-running until green is the cheapest route to a stamp and the one this"
            echo "check exists to make deliberate."
            echo
            echo "If the test is genuinely flaky, say so — one line, naming this exact command and"
            echo "an issue that keeps it visible:"
            echo
            echo "  mkdir -p \"$FLAKY_REPO/.claude\""
            echo "  echo '$STAMP_CMD :: #<issue> <why it is flaky, not broken>' >> \"$FLAKY_DECL\""
            echo
            echo "Then retry the commit. The declaration names THIS command only; a blanket entry"
            echo "will not match, and the issue number is required so a real bug cannot be quietly"
            echo "refiled as a flake."
            echo
            echo "If the first failure was real, fix the code. Any edit clears the record, and the"
            echo "next pass is an ordinary one."
        } >&2
        exit 2
    fi

    # -----------------------------------------------------------------------
    # THE DECLARATION IS NOT ENOUGH — IT HAS TO REACH THE RECORD.
    #
    # .claude/.flaky is gitignored and expires in thirty minutes. A flake could
    # be declared, committed and forgotten with NO TRACE A REVIEWER WILL EVER
    # SEE. The gate would have made it deliberate without making it visible, and
    # "someone else sees it" is this kit's own criterion for whether a mechanism
    # buys anything at all — the same reasoning that makes Stage 2's commit
    # trailer the half with teeth rather than its hook.
    #
    # This hook is the ONLY place that can require the record, because it is the
    # only place that knows the stamp is flaky. By the time CI runs, the stamp is
    # gone. CI's job is to validate the trailers it finds, not to notice a
    # missing one.
    #
    # `--trailer` SPECIFICALLY, not merely the word Flaky:. Git parses trailers
    # only from the FINAL paragraph, so a `Flaky:` line typed into the message
    # body above a Signed-off-by records ZERO trailers while looking perfect in
    # `git log`. That cost three attempts on one commit in serina-learning and is
    # documented at length in check-test-changes.sh. Requiring the flag is what
    # makes the difference checkable from here.
    #
    # STATED LIMIT: this reads the command string, so `--trailer "Other: x"`
    # alongside a `Flaky:` elsewhere would satisfy the pattern only if the flag
    # itself carries Flaky:, which the regex requires. It cannot verify what git
    # ultimately parsed — that is the CI half's job, and the two are complementary
    # for the same reason Stage 2's are.
    # -----------------------------------------------------------------------
    if ! printf '%s' "$COMMAND" | grep -qE -- '--trailer[[:space:]=]+["'"'"']?Flaky:'; then
        {
            echo "COMMIT BLOCKED — this flake is declared locally but would leave no trace in the record."
            echo
            echo "  command:  $STAMP_CMD"
            echo "  declared: $FLAKY_AUTH"
            echo
            echo "$FLAKY_DECL is gitignored and expires after 30 minutes, so a reviewer"
            echo "would never see that this commit's suite passed only on a re-run. Put it in the"
            echo "commit, where it survives and where a pull request shows it:"
            echo
            echo "  --trailer \"Flaky: $STAMP_CMD $FLAKY_AUTH\""
            echo
            echo "Use --trailer, never a line typed into the message body. Git parses trailers only"
            echo "from the final paragraph, so a Flaky: line above a Signed-off-by records as ZERO"
            echo "trailers while looking perfect in git log."
        } >&2
        exit 2
    fi

    # SAY WHAT AUTHORISED IT, at the moment it is relied upon.
    announce "Verified $(( STAMP_AGE / 60 ))m ago, but FLAKY — '$STAMP_CMD' failed before it passed. Declared: $FLAKY_AUTH, and recorded in the commit. Commit allowed."
    exit 0
fi

[ -n "$STAMP_CMD" ] && STAMP_CMD=" by: $STAMP_CMD"
case "$STAMP_BASIS" in
  observed) announce "Verified $(( STAMP_AGE / 60 ))m ago, exit code observed.${STAMP_CMD} Commit allowed." ;;
  inferred) announce "Verified $(( STAMP_AGE / 60 ))m ago, exit code INFERRED (the payload carried none).${STAMP_CMD} Commit allowed." ;;
  *)        announce "Verified $(( STAMP_AGE / 60 ))m ago, basis unrecorded.${STAMP_CMD} Commit allowed." ;;
esac
exit 0

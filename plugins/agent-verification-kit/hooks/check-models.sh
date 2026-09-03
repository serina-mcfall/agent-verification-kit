#!/usr/bin/env bash
# Does every agent definition name a model that actually resolves?
#
# THE FAILURE THIS EXISTS TO REMOVE — measured 2026-08-06.
#
# An agent pinned to `model: sonnet-typo-xyz`, dispatched from a session pinned
# `--model sonnet`, produced:
#
#   exit 0 · stdout "done" · stderr EMPTY · a normal-looking subagent result
#
# The API did reject it — `404 not_found_error  message: "model: sonnet-typo-xyz"`
# at line 392 of the debug log — and Claude Code then retried it up to 11 times,
# absorbed the error, and fell back to THE SESSION'S model. It also labelled the
# failure a streaming problem, so the log misleads even when you do read it.
#
# So a one-character slip in a `model:` line silently reroutes an agent, and the
# only witness is a debug log nobody opts into. The dangerous direction is a
# typo'd `opus` in a Sonnet session: a review meant to be escalated quietly is
# not, and nothing anywhere says so.
#
# WHY A STATIC CHECK AND NOT A RUNTIME ONE. The runtime cannot help — it has
# already decided to carry on. The only moment the mistake is visible is before
# it runs, by reading the file. That is this script.
#
# WHAT IS ACTUALLY MEASURED, so the allow-list is not folklore: `haiku`, `opus`
# and `fable` were each observed resolving from a `model:` line in agent
# frontmatter (debug log showed claude-haiku-4-5-20251001, claude-opus-5,
# claude-fable-5). `sonnet` was observed as a session model, not at agent level.
# `inherit` is accepted on documentation only and was NOT measured here.
#
# Usage:  check-models.sh AGENTS_DIR [AGENTS_DIR...]
# Exit:   0 = every agent routes to a known model, 1 = anything else
#
# The directory is an ARGUMENT, never discovered. A hardcoded path cannot be
# negative-tested: you could not build a fixture whose agents are wrong and
# watch this fail, so you could never tell a working check from a vacuous one.

set -uo pipefail

fail=0
say()  { printf '%s  %s\n' "$1" "$2"; }
pass() { say "PASS" "$1"; }
bad()  { say "FAIL" "$1"; fail=1; }

# Aliases known to resolve. Deliberately short: an allow-list that accepts
# anything plausible is the fail-open this script exists to close.
known_aliases=(opus sonnet haiku fable inherit)

# Full model IDs, e.g. claude-opus-5, claude-haiku-4-5-20251001, claude-opus-5[1m].
#
# Anchored at BOTH ends, and everything after the version's first digit is digits
# and dashes only. A looser class was the first draft and it had the same shape as
# the bug being hunted: `[0-9a-z.-]*` accepts "claude-opus-5-typo", because every
# character of "-typo" is in the class. Real IDs carry no letters after the
# version, so forbidding them there costs nothing and closes the hole.
#
# The optional bracket group admits the long-context form (claude-opus-5[1m]),
# which is a genuine model ID — rejecting it would make the guard block correct
# work, and a check that cries wolf gets switched off.
full_id_re='^claude-[a-z]+-[0-9][0-9-]*(\[[0-9]+m\])?$'

# Agents whose model has a FLOOR, and why. This encodes a standing decision
# rather than a preference: accessibility judgement — whether an ARIA pattern is
# the semantically right one, whether focus survives a state change, whether a
# live region announces sensibly — is the one tier that is never downgraded for
# cost. Automated tooling catches a minority of real WCAG issues and misses
# exactly these. A silent reroute here breaks a promise to screen-reader users,
# so prose was not enough and it is asserted.
floor_agents=(review-a11y)
floor_allowed=(opus fable)

if [[ $# -eq 0 ]]; then
  bad "no AGENTS_DIR given (usage: check-models.sh AGENTS_DIR [AGENTS_DIR...])"
  exit 1
fi

in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$needle" == "$x" ]] && return 0; done
  return 1
}

# Read one key out of the YAML frontmatter ONLY. Reading the whole file would let
# prose in an agent's body ("set model: opus in the frontmatter") satisfy the
# check while the frontmatter itself says nothing.
fm_key() {
  local file="$1" key="$2" end
  [[ "$(head -1 "$file")" == "---" ]] || return 2          # no frontmatter at all
  end="$(awk 'NR>1 && /^---[[:space:]]*$/{print NR; exit}' "$file")"
  [[ -n "$end" ]] || return 3                              # never terminated
  sed -n "2,$((end-1))p" "$file" \
    | awk -v k="$key" 'tolower($0) ~ "^"k":" {sub(/^[^:]*:[[:space:]]*/,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}'
}

total=0

for dir in "$@"; do
  if [[ ! -d "$dir" ]]; then
    bad "not a directory: $dir"
    continue
  fi

  shopt -s nullglob
  files=("$dir"/*.md)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    # THE VACUITY GUARD. Without it, a wrong path, a renamed directory or a
    # roster that was never checked in all report clean. Zero agents found is a
    # broken input, never a clean result.
    bad "found NO *.md agent files in $dir — wrong path, or the roster is missing. Refusing to report clean on zero agents."
    continue
  fi

  for f in "${files[@]}"; do
    total=$((total + 1))
    base="$(basename "$f")"

    name="$(fm_key "$f" name)"; rc=$?
    if [[ $rc -eq 2 ]]; then
      bad "$base does not begin with '---' — no frontmatter, so nothing routes it."
      continue
    elif [[ $rc -eq 3 ]]; then
      bad "$base has an unterminated frontmatter block — its 'model:' cannot be parsed, and an unparseable field is silently ignored at runtime."
      continue
    fi

    if [[ -z "$name" ]]; then
      bad "$base has no 'name:' in its frontmatter — it is not a dispatchable agent, and does not belong in an agents directory."
      continue
    fi

    model="$(fm_key "$f" model)"

    if [[ -z "$model" ]]; then
      # Not a syntax error, and deliberately still a failure: an agent with no
      # model runs on whatever the dispatching session happens to be. That is
      # the same silent-reroute hazard as a typo, reached by a different route.
      bad "$base ($name) has no 'model:' — it inherits the dispatching session's model, so its tier is whatever the caller happened to be on. Pin it, or set 'model: inherit' to say the inheritance is deliberate."
      continue
    fi

    if in_list "$model" "${known_aliases[@]}" || [[ "$model" =~ $full_id_re ]]; then
      : # resolves
    else
      bad "$base ($name) names model '$model', which is not a known alias or model ID. At runtime this does NOT fail — it 404s, retries, and silently falls back to the session's model. Known aliases: ${known_aliases[*]}"
      continue
    fi

    if in_list "$name" "${floor_agents[@]}"; then
      if in_list "$model" "${floor_allowed[@]}"; then
        pass "$base ($name) -> $model, at or above its floor"
      else
        bad "$base ($name) is pinned to '$model', below its floor. Allowed: ${floor_allowed[*]}. Accessibility judgement is not downgraded for cost — this is the tier that catches what automated tooling cannot."
      fi
    else
      pass "$base ($name) -> $model"
    fi
  done
done

if [[ $total -eq 0 ]]; then
  bad "no agent files were examined at all across ${#@} path(s) — treat this as a broken invocation, not a clean roster."
fi

exit "$fail"

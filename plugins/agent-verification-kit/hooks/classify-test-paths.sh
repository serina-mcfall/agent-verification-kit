#!/usr/bin/env bash
# Sourced library. Classifies a repository path as a test, as test configuration,
# or as neither. NOT a hook — guard-test-changes.sh and check-test-changes.sh both source
# it, for the same reason stamp-path.sh exists: two copies of a classifier is how
# one gets fixed and the other does not.
#
# ---------------------------------------------------------------------------
# WHY THE PATTERN LIST IS GENEROUS, AND WHY THAT IS THE WHOLE DESIGN
#
# The predecessor of this file, in the plan this kit came from, named `crates/**`
# Rust and `.spec.ts` only. An adversarial review counted what that missed in one
# repository: 610 Desktop `.test.mjs`, 156 Flutter `_test.dart`, 100 Tauri Rust,
# and 121 Python test files — including the tests for the very checker the plan
# proposed to modify. A guard matching a fraction of the suites reports success
# while the suites it does not know about are edited freely.
#
# So the bias here is deliberate: match too much rather than too little. A false
# positive costs one declaration line. A false negative is the bypass.
#
# ---------------------------------------------------------------------------
# TWO CLASSES, NOT ONE
#
# `test`         the assertions themselves
# `test-config`  retries, timeouts, reporters, exclusions
#
# The second class exists because "make the failing test pass" has two shapes and
# only one of them touches a test file. Clipboard Health (2026-04-21) recorded
# agents responding to flakes by adding retries and loosening assertions; the
# research this kit rests on names it the worst-behaved failure mode for agents
# specifically. `retries: 2` in a config file silences a real race without editing
# a single assertion, and a guard watching only `*_test.*` never sees it.
#
# They are reported separately because the right response differs. A changed test
# wants a reason. A changed retry policy wants a human.
# ---------------------------------------------------------------------------

# Extension points, in precedence order (later wins):
#   AVK_TEST_EXTRA         extra `test` globs, colon-separated
#   AVK_TEST_CONFIG_EXTRA  extra `test-config` globs, colon-separated
#   AVK_TEST_IGNORE        globs to classify as `other` regardless, colon-separated
#   <repo>/.claude/test-guard.conf   per-repo file, same three keys

avk_default_test_globs() {
    cat <<'GLOBS'
*_test.go
*_test.py
test_*.py
*_test.rs
*_test.dart
*_test.exs
*_test.rb
*_spec.rb
*.test.js
*.test.jsx
*.test.ts
*.test.tsx
*.test.mjs
*.test.cjs
*.spec.js
*.spec.jsx
*.spec.ts
*.spec.tsx
*.spec.mjs
*.spec.cjs
*Test.java
*Tests.java
*Test.kt
*Test.cs
*Tests.cs
*Test.php
*_test.php
test-*.sh
test_*.sh
*-test.sh
*_test.sh
*/tests/*
*/test/*
*/__tests__/*
*/spec/*
*/e2e/*
conftest.py
GLOBS
}

avk_default_test_config_globs() {
    cat <<'GLOBS'
playwright.config.*
jest.config.*
vitest.config.*
karma.conf.*
cypress.config.*
pytest.ini
tox.ini
nextest.toml
.config/nextest.toml
phpunit.xml
phpunit.xml.dist
GLOBS
}

# ---------------------------------------------------------------------------
# Glob matching against a REPO-RELATIVE path.
#
# A pattern with no `/` matches the BASENAME — `test_*.py` should match
# `deep/nested/test_thing.py`, which is how every developer reads that pattern and
# is not what a bare `case` against the full path does.
#
# A pattern containing `/` matches the full relative path, with a leading `*/`
# meaning "at any depth, including the top". `*/tests/*` must match
# `tests/unit/x.py` as well as `pkg/tests/unit/x.py`; without that, a top-level
# tests/ directory — the single most common layout there is — would be missed.
# ---------------------------------------------------------------------------
avk_glob_matches() {
    local pattern="$1" rel="$2"
    case "$pattern" in
        */*)
            # shellcheck disable=SC2254
            case "$rel" in
                $pattern) return 0 ;;
            esac
            # A leading */ also matches at depth zero.
            if [ "${pattern#\*/}" != "$pattern" ]; then
                # shellcheck disable=SC2254
                case "$rel" in
                    ${pattern#\*/}) return 0 ;;
                esac
            fi
            return 1
            ;;
        *)
            # shellcheck disable=SC2254
            case "${rel##*/}" in
                $pattern) return 0 ;;
            esac
            return 1
            ;;
    esac
}

# Splits a colon-separated list into one item per line.
#
# THIS USED `set -- $1` AND THAT WAS A FAIL-OPEN. Found 2026-09-04 by an
# adversarial review of the code.
#
# An unquoted `$1` gets the intended IFS=':' field split AND pathname expansion
# against whatever directory the process happens to be in. So a glob pattern was
# silently replaced by the files matching it at that instant:
#
#   cwd contains checks/a_test.py
#   AVK_TEST_EXTRA="checks/*"  ->  checks/a_test.py    (frozen to one file)
#
# Every test added under checks/ afterwards then classified as `other`, so its
# later modification was neither blocked by guard-test-changes.sh nor flagged by
# check-test-changes.sh — a fail-open in precisely the direction the variable
# exists to widen. AVK_TEST_IGNORE broke the opposite way, over-blocking.
#
# The classifier's job is to read STRINGS. It had no business reading the
# filesystem, and the bug is that one character of quoting let it.
#
# `read -ra` splits on IFS and performs no pathname expansion, so it cannot happen
# again. `set -f`/`set +f` around the old form would also work and was rejected:
# it mutates shell options in a SOURCED library, and restoring them correctly
# depends on inspecting `$-` first — more moving parts than the problem deserves.
#
# KNOWN LIMIT, stated rather than discovered later: `read` consumes one line, so a
# value containing a literal newline is truncated at it. Colon-separated pattern
# lists do not contain newlines, and the per-repo `.claude/test-guard.conf` is the
# supported route for anything more elaborate.
#
# Covered by section 12 of test-classify-test-paths.sh, confirmed red first.
_avk_split_colons() {
    local IFS=':' arr=()
    read -ra arr <<< "$1"
    [ "${#arr[@]}" -gt 0 ] && printf '%s\n' "${arr[@]}"
    return 0
}

# Reads <repo>/.claude/test-guard.conf if present. Lines are `<class> <glob>`,
# blanks and #comments ignored.
#
# AN UNREADABLE OR MALFORMED CONFIG IS ANNOUNCED, NOT ABSORBED. A config file that
# silently fails to load leaves the guard running on defaults while its author
# believes their patterns are in force — the fail-open shape recorded as INC-0003,
# where an absent directory produced empty output that was read as a pass. It is
# not fatal: defaults are a safe fallback for a CLASSIFIER, and refusing every edit
# because a config line was mistyped is the lockout regression. It must be loud.
#
# The third argument suppresses the warnings. This function is called once per
# class, and a malformed line should be reported ONCE, not three times — but the
# suppression is on the repeat calls, never on the first, so the report cannot be
# lost. Silencing all three is what an earlier draft of this file did, via a
# `2>/dev/null` on the caller, and it would have hidden every warning above while
# the comment on this function claimed they were loud.
_avk_read_conf() {
    local repo="$1" want="$2" quiet="${3:-}" conf="$repo/.claude/test-guard.conf"
    [ -n "$repo" ] || return 0
    [ -e "$conf" ] || return 0
    if [ ! -r "$conf" ]; then
        [ -z "$quiet" ] && echo "test-patterns: $conf exists but is not readable — using built-in patterns only. Your configured globs are NOT in force." >&2
        return 0
    fi
    local lineno=0 cls glob
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        case "$line" in ''|\#*) continue ;; esac
        cls=${line%%[[:space:]]*}
        glob=${line#*[[:space:]]}
        glob=${glob#"${glob%%[![:space:]]*}"}
        if [ "$cls" = "$line" ] || [ -z "$glob" ]; then
            [ -z "$quiet" ] && echo "test-patterns: $conf line $lineno is not '<class> <glob>' — ignoring it: $line" >&2
            continue
        fi
        case "$cls" in
            test|test-config|ignore) ;;
            *)
                [ -z "$quiet" ] && echo "test-patterns: $conf line $lineno has unknown class '$cls' (want test, test-config or ignore) — ignoring it." >&2
                continue
                ;;
        esac
        [ "$cls" = "$want" ] && printf '%s\n' "$glob"
    done < "$conf"
    return 0
}

# avk_classify_path <repo-relative-path> [repo-root]
#   prints: test | test-config | other
#
# `ignore` is checked FIRST and wins over everything. A repository that vendors a
# dependency's test suite, or generates fixtures into a tests/ directory, needs a
# way to say so — and a guard it cannot narrow is a guard it will disable wholesale.
avk_classify_path() {
    local rel="$1" repo="${2:-}" g
    rel="${rel#./}"
    [ -n "$rel" ] || { printf 'other\n'; return 0; }

    # The `ignore` pass runs first and is the ONLY one that reports config
    # problems, so each malformed line is named exactly once per classification.
    while IFS= read -r g; do
        [ -n "$g" ] && avk_glob_matches "$g" "$rel" && { printf 'other\n'; return 0; }
    done < <( [ -n "${AVK_TEST_IGNORE:-}" ] && _avk_split_colons "$AVK_TEST_IGNORE"; _avk_read_conf "$repo" ignore )

    while IFS= read -r g; do
        [ -n "$g" ] && avk_glob_matches "$g" "$rel" && { printf 'test\n'; return 0; }
    done < <( avk_default_test_globs; [ -n "${AVK_TEST_EXTRA:-}" ] && _avk_split_colons "$AVK_TEST_EXTRA"; _avk_read_conf "$repo" test quiet )

    while IFS= read -r g; do
        [ -n "$g" ] && avk_glob_matches "$g" "$rel" && { printf 'test-config\n'; return 0; }
    done < <( avk_default_test_config_globs; [ -n "${AVK_TEST_CONFIG_EXTRA:-}" ] && _avk_split_colons "$AVK_TEST_CONFIG_EXTRA"; _avk_read_conf "$repo" test-config quiet )

    printf 'other\n'
}

# Turn an absolute path into a repo-relative one, given the repo root.
# Returns the input unchanged when it is already relative or lies outside.
avk_relativise() {
    local path="$1" repo="${2:-}"
    [ -n "$repo" ] || { printf '%s\n' "$path"; return 0; }
    case "$path" in
        "$repo"/*) printf '%s\n' "${path#"$repo"/}" ;;
        "$repo")   printf '%s\n' "." ;;
        *)         printf '%s\n' "$path" ;;
    esac
}

#!/usr/bin/env bash
# Controls for test-patterns.sh — the classifier test-guard.sh and
# check-test-changes.sh both depend on.
#
# The classifier is where this mechanism succeeds or fails. A guard cannot protect
# a file it does not recognise as a test, and the defect that motivated this whole
# stage was a pattern list that missed most of a repository's suites. So the bulk
# of these controls are ecosystem coverage, and an equal number are NEAR MISSES —
# names that look like tests and are not. A classifier that says `test` to
# everything would pass coverage controls and be useless.

LIB="${1:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/test-patterns.sh}"
pass=0; fail=0

if [ ! -r "$LIB" ]; then
    echo "FAIL  cannot read $LIB — nothing was tested"
    exit 1
fi
# shellcheck source=/dev/null
. "$LIB"

for fn in avk_classify_path avk_glob_matches avk_relativise; do
    if declare -F "$fn" >/dev/null; then
        echo "ok    $fn is defined"; pass=$((pass + 1))
    else
        echo "FAIL  $fn is NOT defined"; fail=$((fail + 1))
    fi
done
echo

want() {
    local expect="$1" path="$2" repo="${3:-}" got
    got=$(avk_classify_path "$path" "$repo" 2>/dev/null)
    if [ "$got" = "$expect" ]; then
        printf 'ok    %-46s -> %s\n' "$path" "$got"; pass=$((pass + 1))
    else
        printf 'FAIL  %-46s -> %s (wanted %s)\n' "$path" "$got" "$expect"; fail=$((fail + 1))
    fi
}

echo "0. the suite is not vacuous — ordinary source must NOT be a test:"
want other src/main.py
want other src/index.ts
want other README.md
want other Cargo.toml
echo

echo "1. Python:"
want test test_thing.py
want test thing_test.py
want test conftest.py
want test deep/nested/test_thing.py
echo

echo "2. JavaScript and TypeScript:"
want test app.test.ts
want test app.test.tsx
want test app.spec.mjs
want test desktop/src/features/chat/Message.test.jsx
echo

echo "3. Other ecosystems:"
want test handler_test.go
want test parser_test.rs
want test widget_test.dart
want test MessageTest.java
want test MessageTests.cs
want test message_spec.rb
echo

echo "4. Shell suites:"
want test test-hooks.sh
want test test_hooks.sh
want test hooks-test.sh
want test hooks_test.sh
echo

echo "5. Directory conventions — the layout that a basename-only match misses:"
want test tests/unit/thing.py
want test test/unit/thing.js
want test pkg/tests/unit/thing.py
want test src/__tests__/Button.jsx
want test desktop/tests/e2e/stream.spec.ts
echo

echo "6. NEAR MISSES — names that look like tests and are not:"
want other testing.sh
want other checkout.sh
want other contest.py
want other latest.py
want other tester.sh
want other protester.go
want other attestation.rs
want other manifest.json
echo

echo "7. test-config — the retry-and-timeout attack surface:"
want test-config playwright.config.ts
want test-config jest.config.js
want test-config vitest.config.mjs
want test-config pytest.ini
want test-config nextest.toml
want test-config phpunit.xml
echo

echo "8. classification precedence:"
AVK_TEST_IGNORE='vendor/*' want other vendor/tests/thing.py
AVK_TEST_IGNORE='*/fixtures/*' want other tests/fixtures/generated_test.py
AVK_TEST_EXTRA='*.feature' want test login.feature
AVK_TEST_CONFIG_EXTRA='ci.yml' want test-config ci.yml
unset AVK_TEST_IGNORE AVK_TEST_EXTRA AVK_TEST_CONFIG_EXTRA
echo

echo "9. per-repo .claude/test-guard.conf:"
box=$(mktemp -d)
trap 'rm -rf "$box"' EXIT
mkdir -p "$box/.claude"

cat > "$box/.claude/test-guard.conf" <<'CONF'
# a comment, and a blank line follow

test *.feature
test-config ci.yml
ignore vendor/*
CONF
want test        login.feature   "$box"
want test-config ci.yml          "$box"
want other       vendor/x_test.go "$box"
want other       src/main.py     "$box"

# A malformed line must be NAMED and skipped, not absorbed, and not fatal.
cat > "$box/.claude/test-guard.conf" <<'CONF'
test *.feature
thisisnotaclass
test-confg typo.yml
CONF
err=$(avk_classify_path login.feature "$box" 2>&1 >/dev/null)
if printf '%s' "$err" | grep -q 'is not .<class> <glob>.'; then
    echo "ok    a line with no glob is named on stderr"; pass=$((pass + 1))
else
    echo "FAIL  a line with no glob was absorbed silently"; fail=$((fail + 1))
fi
if printf '%s' "$err" | grep -q "unknown class 'test-confg'"; then
    echo "ok    a misspelled class is named on stderr"; pass=$((pass + 1))
else
    echo "FAIL  a misspelled class was absorbed silently"; fail=$((fail + 1))
fi
# REPORTED ONCE, not once per class pass. Three copies of every warning trains
# people to stop reading stderr, which is where every message in this kit lives.
n=$(printf '%s\n' "$err" | grep -c 'unknown class')
if [ "$n" -eq 1 ]; then
    echo "ok    each config problem is reported exactly once (got $n)"; pass=$((pass + 1))
else
    echo "FAIL  config problem reported $n times, wanted 1"; fail=$((fail + 1))
fi
# And the valid line in a partly-broken file still applies.
want test login.feature "$box"

# An unreadable config announces that the configured globs are NOT in force.
cat > "$box/.claude/test-guard.conf" <<'CONF'
test *.feature
CONF
chmod 000 "$box/.claude/test-guard.conf"
if [ -r "$box/.claude/test-guard.conf" ]; then
    echo "skip  unreadable-config control (running as a user that can read 000)"
else
    err=$(avk_classify_path login.feature "$box" 2>&1 >/dev/null)
    if printf '%s' "$err" | grep -q 'NOT in force'; then
        echo "ok    an unreadable config says the configured globs are not in force"; pass=$((pass + 1))
    else
        echo "FAIL  an unreadable config was absorbed silently"; fail=$((fail + 1))
    fi
fi
chmod 644 "$box/.claude/test-guard.conf"
rm -f "$box/.claude/test-guard.conf"
echo

echo "10. avk_relativise:"
rel_want() {
    local expect="$1" path="$2" repo="$3" got
    got=$(avk_relativise "$path" "$repo")
    if [ "$got" = "$expect" ]; then
        printf 'ok    %-40s -> %s\n' "$path" "$got"; pass=$((pass + 1))
    else
        printf 'FAIL  %-40s -> %s (wanted %s)\n' "$path" "$got" "$expect"; fail=$((fail + 1))
    fi
}
rel_want "tests/x.py"        "/repo/tests/x.py"  "/repo"
rel_want "."                 "/repo"             "/repo"
rel_want "/elsewhere/x.py"   "/elsewhere/x.py"   "/repo"
rel_want "tests/x.py"        "tests/x.py"        ""
# A repo path that is a string prefix of another must not be treated as the parent.
rel_want "/repo2/tests/x.py" "/repo2/tests/x.py" "/repo"
echo

echo "11. a KNOWN false positive, asserted so it is a decision and not a surprise:"
# `*/spec/*` is in the default list for RSpec, and it also catches a docs
# directory named spec/. That is the generous-bias trade stated in the library
# header: a false positive costs one declaration, a false negative is the bypass.
# It is asserted here so nobody 'fixes' it without seeing the trade, and the
# escape is shown on the next line.
want test docs/spec/api.md
AVK_TEST_IGNORE='docs/*' want other docs/spec/api.md
unset AVK_TEST_IGNORE
echo

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

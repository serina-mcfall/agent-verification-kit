# Trial fixture — a `Flaky:` line git never parsed as a trailer

**This branch must never be merged.**

This is the fail-open that `check-flaky-trailers.sh` uniquely closes, and the more valuable of the
two fixtures on this branch.

Git parses trailers **only from the final paragraph** of a commit message. The commit adding this
file writes a perfectly-formed `Flaky:` line into the message *body*, with a paragraph after it:

```
Flaky: pytest tests/test_auth.py #99 races on the token clock

<a closing paragraph, which pushes the line out of the trailer block>
```

`git log` displays that line plainly, and an author reading it would reasonably believe they had
declared the flake. **Git parsed zero trailers.** A checker that read only parsed trailers would
report this commit clean.

So the script compares what git PARSED against what is literally WRITTEN, and fails on a
discrepancy rather than reporting nothing found.

Expected: the `declared flakes` job fails with **exit 1**, and its message names the final-paragraph
rule rather than saying no flakes were declared.

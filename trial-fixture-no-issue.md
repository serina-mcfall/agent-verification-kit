# Trial fixture — a `Flaky:` trailer with no issue number

**This branch must never be merged.** It exists so that `check-flaky-trailers.sh` can be observed
FAILING a real pull request, which is the only evidence that it refuses anything.

The commit that adds this file carries:

```
--trailer "Flaky: npm test it is just flaky sometimes"
```

A well-formed trailer is `Flaky: <command> #<issue> <reason>`. This one names a command and gives a
reason but **no issue number** — a flake nobody has agreed to fix, which is the state the mechanism
exists to make impossible to reach quietly.

Expected: the `declared flakes` job fails with **exit 1**, naming this commit and this trailer.
Expected specifically *not*: exit 3, which would mean the check could not determine anything and
would be a could-not-check dressed up as a refusal.

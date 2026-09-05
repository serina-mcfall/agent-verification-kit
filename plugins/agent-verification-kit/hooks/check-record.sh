#!/usr/bin/env bash
# Validates records/events.jsonl — the append-only event record.
#
#   bash check-record.sh [RECORD_FILE]     default: <repo root>/records/events.jsonl
#
# ---------------------------------------------------------------------------
# WHY. On 2026-09-06 three literal conflict-marker lines were committed into this
# repository's own record, pushed, marked ready, reviewed and MERGED TO MAIN. The
# file did not parse. Four CI jobs ran green over it, because not one of them
# looks at the record.
#
# That is a missing control, not a typo. This kit gates a commit on a test stamp,
# gates a test edit on a declaration, and gates a flaky pass on a commit trailer.
# The file every one of those verdicts is written into had nothing checking it.
#
# A record that does not parse is worse than no record. A missing record is loud.
# A corrupt one is silent, and everything downstream — every verdict, every open
# incident, every trend across stages — is read from it.
#
# ---------------------------------------------------------------------------
# WHAT IT CHECKS, AND WHY EACH ONE IS HERE
#
#   conflict markers      the incident above. Reported by NAME rather than as
#                         "invalid JSON", because the remedy is completely
#                         different and the cause is worth recognising instantly.
#   valid JSON            every non-blank line.
#   core fields           the schema's seven. It says a line missing any of them
#                         is malformed and must be REPORTED rather than skipped.
#   unique ids            ids are allocated per file, so two branches working in
#                         parallel can each allocate the same next id. Appends
#                         concatenate safely; identical ids do not.
#   id prefix vs kind     an INC- line with kind "note" breaks every query that
#                         filters on one and reports the other.
#   supersedes resolves   closing an incident works by appending an event that
#                         supersedes it. A pointer to an id that does not exist
#                         is a closure that closes nothing.
#
# ---------------------------------------------------------------------------
# THREE EXIT CODES, NEVER TWO
#
#   0  the record is valid, or this repository keeps no record
#   1  the record is invalid — every problem is listed, not just the first
#   3  could not check
#
# The distinction in exit 0 matters. A repository with no records/ directory has
# nothing to validate and that is fine. A records/ directory with no events.jsonl
# is a broken layout or a wrong path, and reporting that as clean would be the
# INC-0006 mistake: could-not-check quietly becoming it-is-fine.
# ---------------------------------------------------------------------------

set -u

die() { printf 'check-record: CANNOT DETERMINE — %s\n' "$1" >&2; exit 3; }

if [ $# -ge 1 ]; then
    RECORD="$1"
else
    ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=""
    [ -n "$ROOT" ] || ROOT=$(pwd)
    # No records/ at all: this repository does not keep one. Nothing to check.
    if [ ! -d "$ROOT/records" ]; then
        printf 'check-record: no records/ directory in %s — nothing to check.\n' "$ROOT"
        exit 0
    fi
    RECORD="$ROOT/records/events.jsonl"
fi

[ -e "$RECORD" ] || die "$RECORD does not exist, but a records/ directory does. Either the layout changed or this is the wrong path — and reporting a clean record because the file is missing is exactly the failure this script exists to prevent."
[ -r "$RECORD" ] || die "$RECORD exists but is not readable."

command -v python3 >/dev/null 2>&1 \
    || die "python3 not found. The record is JSON and cannot be validated by pattern matching without producing false confidence."

python3 - "$RECORD" <<'PY'
import json, sys, re

path = sys.argv[1]
problems, ids, seen, n = [], [], {}, 0

PREFIX = {"incident": "INC", "toil": "TOIL", "postmortem": "PM",
          "change": "CHG", "review": "REV", "note": "NOTE"}
CORE = ["id", "ts", "kind", "summary", "tags", "repo", "detected_by"]

with open(path, encoding="utf-8") as fh:
    lines = fh.readlines()

records = []
for lineno, raw in enumerate(lines, 1):
    line = raw.strip()
    if not line:
        continue                                    # blank lines are not an error
    if re.match(r"^(<{7}|={7}|>{7})", line):
        problems.append(
            f"line {lineno}: GIT CONFLICT MARKER — {line[:40]!r}\n"
            f"        A merge was resolved by committing the conflict rather than "
            f"settling it.\n"
            f"        Repair by PARSING every line and dropping what is not valid "
            f"JSON, not by\n"
            f"        deleting the markers you can see — a bad resolution usually "
            f"loses events too.")
        continue
    try:
        obj = json.loads(line)
    except Exception as exc:
        problems.append(f"line {lineno}: not valid JSON — {exc}")
        continue
    if not isinstance(obj, dict):
        problems.append(f"line {lineno}: not a JSON object")
        continue
    n += 1
    records.append((lineno, obj))

for lineno, obj in records:
    eid = obj.get("id")
    missing = [f for f in CORE if f not in obj or obj[f] in (None, "")]
    if missing:
        problems.append(
            f"line {lineno} ({eid or 'no id'}): missing core field(s): "
            f"{', '.join(missing)}")
    if eid:
        if eid in seen:
            problems.append(
                f"line {lineno}: DUPLICATE id {eid}, first seen at line {seen[eid]}. "
                f"Ids are allocated per file, so two branches\n"
                f"        working in parallel can each take the same next number. "
                f"Renumber one of them.")
        else:
            seen[eid] = lineno
        ids.append(eid)
    kind = obj.get("kind")
    if eid and kind in PREFIX and not eid.startswith(PREFIX[kind] + "-"):
        problems.append(
            f"line {lineno}: id {eid} does not match kind '{kind}' "
            f"(expected prefix {PREFIX[kind]}-)")

known = set(ids)
for lineno, obj in records:
    sup = obj.get("supersedes")
    if sup and sup not in known:
        problems.append(
            f"line {lineno} ({obj.get('id')}): supersedes {sup}, which is not in "
            f"this record. A closure that closes nothing.")

if problems:
    print(f"RECORD INVALID — {path}", file=sys.stderr)
    print(f"  {len(problems)} problem(s) across {len(lines)} line(s):\n",
          file=sys.stderr)
    for p in problems:
        print(f"  {p}", file=sys.stderr)
    print("\n  This file is the only artefact the verification programme reasons "
          "from.\n  Every verdict, every open incident and every trend is read out "
          "of it.\n", file=sys.stderr)
    sys.exit(1)

print(f"check-record: checked {path} — {n} event(s), all valid.")
sys.exit(0)
PY

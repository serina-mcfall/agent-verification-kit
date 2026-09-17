# The kit's entry points.
#
# `make test` exists because this repository had ten control suites and no single
# command that ran them — a gap that bit twice in two days: once when earning a
# verification stamp (one suite had to be picked, so the stamp attested to less
# than it appeared to) and once when review-final's verdict.sh refused to record
# READY because it could not resolve a test command here.
#
# The list of suites is NOT here. It lives in controls.list beside the runner,
# so this file, CI and a local run cannot disagree about what "the tests" means.
#
# check-deployment.sh runs AFTER the suites, and only here. That is not the
# duplication the paragraph above warns about — that warning is about the list of
# suites, and this is a different question entirely: are the copies enforcing on
# THIS machine the ones the kit ships? A CI runner deploys nothing, so there is
# nothing there for it to answer; it would exit 0 on an empty answer every time and
# read as coverage it does not have.
#
# It runs last on purpose. A red suite is about the code; a drifted deployment is
# about the machine, and reading the second before the first invites fixing the
# wrong one. It fails the target rather than warning: a merged fix that governs
# nothing is the ten-day failure in designs/hook-deployment-lineage.md, and a
# warning goes to the channel NOTE-0032 measured as reaching nobody.

.PHONY: test
test:
	@bash plugins/agent-verification-kit/hooks/check-controls.sh
	@bash plugins/agent-verification-kit/hooks/check-deployment.sh

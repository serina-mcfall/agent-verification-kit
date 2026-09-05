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

.PHONY: test
test:
	@bash plugins/agent-verification-kit/hooks/check-controls.sh

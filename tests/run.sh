#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for test_script in \
	"${repo_root}/tests/test-finalize-kernel.sh" \
	"${repo_root}/tests/test-readiness-attestation.sh" \
	"${repo_root}/tests/test-queue-finalization.sh" \
	"${repo_root}/tests/test-finalize-pending.sh" \
	"${repo_root}/tests/test-finalizer-transaction.sh" \
	"${repo_root}/tests/test-kmod-lifecycle-lock.sh" \
	"${repo_root}/tests/test-kmodtool-queue-only-filter.sh" \
	"${repo_root}/tests/test-mixed-version-solver.sh" \
	"${repo_root}/tests/test-rpm-read-lock.sh" \
	"${repo_root}/tests/test-lifecycle-lock.sh" \
	"${repo_root}/tests/test-rpm6-locking.sh" \
	"${repo_root}/tests/test-migrate-legacy-config.sh" \
	"${repo_root}/tests/test-cleanup-stale-modules.sh" \
	"${repo_root}/tests/test-packaging-contract.sh"
do
	"$test_script"
done

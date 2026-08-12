#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for test_script in \
	"${repo_root}/tests/test-finalize-kernel.sh" \
	"${repo_root}/tests/test-migrate-legacy-config.sh" \
	"${repo_root}/tests/test-cleanup-stale-modules.sh" \
	"${repo_root}/tests/test-packaging-contract.sh"
do
	"$test_script"
done

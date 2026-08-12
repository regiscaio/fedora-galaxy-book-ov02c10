#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/ov02c10-cleanup-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

kernel="7.1.8-test.x86_64"
mkdir -p "${test_root}/${kernel}/updates"
touch "${test_root}/${kernel}/updates/ov02c10.ko.gz"

output="$("${repo_root}/scripts/cleanup-stale-modules.sh" \
	--module-root "$test_root" --kernel "$kernel")"
[[ "$output" == *"${test_root}/${kernel}/updates/ov02c10.ko.gz"* ]]
[[ -e "${test_root}/${kernel}/updates/ov02c10.ko.gz" ]]

if "${repo_root}/scripts/cleanup-stale-modules.sh" \
	--module-root "$test_root" --kernel '../unsafe' >/dev/null 2>&1
then
	printf 'cleanup-stale-modules accepted an unsafe kernel version\n' >&2
	exit 1
fi

printf 'test-cleanup-stale-modules: ok\n'

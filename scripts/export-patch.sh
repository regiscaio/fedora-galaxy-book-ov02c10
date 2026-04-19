#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${ROOT_DIR}/sources/intel-ipu6/ov02c10.c"
PATCH_FILE="${ROOT_DIR}/patches/0001-galaxy-book-ov02c10-downstream.patch"
WORKTREE="${ROOT_DIR}/module/ov02c10.c"

mkdir -p "$(dirname "${PATCH_FILE}")"

if cmp -s "${UPSTREAM}" "${WORKTREE}"; then
	rm -f "${PATCH_FILE}"
	printf 'No downstream delta found; removed %s\n' "${PATCH_FILE}"
	exit 0
fi

diff_rc=0
diff -u \
	--label a/sources/intel-ipu6/ov02c10.c "${UPSTREAM}" \
	--label b/module/ov02c10.c "${WORKTREE}" \
	> "${PATCH_FILE}" || diff_rc=$?

if [[ ${diff_rc:-0} -gt 1 ]]; then
	exit "${diff_rc}"
fi

printf 'Wrote %s\n' "${PATCH_FILE}"

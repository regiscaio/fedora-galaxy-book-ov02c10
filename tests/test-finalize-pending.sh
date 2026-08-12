#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/finalize-pending.sh
source "${repo_root}/scripts/finalize-pending.sh"

test_root="$(mktemp -d /tmp/ov02c10-pending-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

kernel="7.1.8-test.x86_64"
state_root="${test_root}/state"
pending_dir="${state_root}/pending"
mkdir -p "$pending_dir"

write_marker() {
	local request="$1"
	local marker_directory="${2:-$pending_dir}"
	local temporary
	temporary="$(mktemp --tmpdir="$marker_directory" ".${request}.XXXXXX")"
	printf '%s\nrequest=%s\n' "$marker_version" "$request" \
		> "$temporary"
	chmod 0644 "$temporary"
	mv -fT "$temporary" "${marker_directory}/${request}.pending"
}

finalize_calls=0
finalize_result=0
fake_finalize() {
	[[ "$*" == "--kernel ${kernel}" ]]
	((finalize_calls += 1))
	if [[ "${replace_during_finalize:-0}" -eq 1 ]]; then
		write_marker "$kernel"
		replace_during_finalize=0
	fi
	return "$finalize_result"
}

finalize_command=fake_finalize

write_marker migration "$state_root"
process_pending
[[ "$finalize_calls" -eq 0 ]]
[[ -e "${state_root}/migration.pending" ]]

write_marker "$kernel"
process_pending
[[ "$finalize_calls" -eq 1 ]]
[[ ! -e "${state_root}/migration.pending" ]]
[[ ! -e "${pending_dir}/${kernel}.pending" ]]

write_marker "$kernel"
replace_during_finalize=1
process_pending
[[ -e "${pending_dir}/${kernel}.pending" ]]
process_pending
[[ ! -e "${pending_dir}/${kernel}.pending" ]]

write_marker "$kernel"
finalize_result=1
if process_pending >/dev/null 2>&1; then
	printf 'pending worker hid a finalization failure\n' >&2
	exit 1
fi
[[ -e "${pending_dir}/${kernel}.pending" ]]

finalize_result=0
process_pending
[[ ! -e "${pending_dir}/${kernel}.pending" ]]

write_marker "$kernel"
printf 'tampered\n' > "${pending_dir}/${kernel}.pending"
if process_pending >/dev/null 2>&1; then
	printf 'pending worker accepted a malformed marker\n' >&2
	exit 1
fi
[[ -e "${pending_dir}/${kernel}.pending" ]]

lock_order=()
acquire_lifecycle_lock() {
	lock_order+=(lifecycle)
}
acquire_rpm_read_lock() {
	[[ "${lock_order[*]}" == "lifecycle" ]]
	lock_order+=(rpm)
}
process_pending() {
	[[ "${lock_order[*]}" == "lifecycle rpm" ]]
	lock_order+=(process)
}
run_pending_lifecycle
[[ "${lock_order[*]}" == "lifecycle rpm process" ]]

printf 'test-finalize-pending: ok\n'

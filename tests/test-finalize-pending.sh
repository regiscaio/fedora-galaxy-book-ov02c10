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
chmod 0755 "$state_root" "$pending_dir"

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

if [[ "$EUID" -eq 0 ]]; then
	unsafe_finalize_calls="$finalize_calls"
	chmod 0777 "$pending_dir"
	if process_pending >/dev/null 2>&1; then
		printf 'pending worker accepted a world-writable pending directory\n' >&2
		exit 1
	fi
	chmod 0755 "$pending_dir"

	chgrp 1 "$pending_dir"
	if process_pending >/dev/null 2>&1; then
		printf 'pending worker accepted pending directory with wrong owner\n' >&2
		exit 1
	fi
	chgrp 0 "$pending_dir"

	chmod 2755 "$pending_dir"
	if process_pending >/dev/null 2>&1; then
		printf 'pending worker accepted pending directory with special mode\n' >&2
		exit 1
	fi
	chmod 00755 "$pending_dir"

	real_state_root="$state_root"
	mv "$state_root" "${state_root}.regular"
	ln -s "${state_root}.regular" "$state_root"
	if process_pending >/dev/null 2>&1; then
		printf 'pending worker accepted a state-root symlink\n' >&2
		exit 1
	fi
	unlink "$state_root"
	mv "${state_root}.regular" "$state_root"
	state_root="$real_state_root"

	ancestry_root="${test_root}/ancestry"
	ancestry_var="${ancestry_root}/var"
	ancestry_lib="${ancestry_var}/lib"
	mkdir -p "$ancestry_lib"
	chmod 0755 "$ancestry_root" "$ancestry_var" "$ancestry_lib"
	state_directory_ancestry=("$ancestry_var" "$ancestry_lib")
	chmod 0775 "$ancestry_lib"
	if process_pending >/dev/null 2>&1; then
		printf 'pending worker accepted a group-writable ancestry directory\n' >&2
		exit 1
	fi
	chmod 0755 "$ancestry_lib"
	mv "$ancestry_lib" "${ancestry_lib}.regular"
	ln -s "${ancestry_lib}.regular" "$ancestry_lib"
	if process_pending >/dev/null 2>&1; then
		printf 'pending worker accepted an ancestry symlink\n' >&2
		exit 1
	fi
	unlink "$ancestry_lib"
	mv "${ancestry_lib}.regular" "$ancestry_lib"
	state_directory_ancestry=(/var /var/lib)
	[[ "$finalize_calls" -eq "$unsafe_finalize_calls" ]]
fi

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
acquire_kmod_lifecycle_lock() {
	lock_order+=(global)
}
acquire_lifecycle_lock() {
	[[ "${lock_order[*]}" == "global" ]]
	lock_order+=(lifecycle)
}
acquire_rpm_read_lock() {
	[[ "${lock_order[*]}" == "global lifecycle" ]]
	lock_order+=(rpm)
}
process_pending() {
	[[ "${lock_order[*]}" == "global lifecycle rpm" ]]
	lock_order+=(process)
}
run_pending_lifecycle
[[ "${lock_order[*]}" == "global lifecycle rpm process" ]]

process_after_global_failure=0
acquire_kmod_lifecycle_lock() { return 1; }
acquire_lifecycle_lock() {
	printf 'private lock called after global-lock failure\n' >&2
	return 1
}
acquire_rpm_read_lock() {
	printf 'RPM lock called after global-lock failure\n' >&2
	return 1
}
process_pending() {
	process_after_global_failure=1
}
if run_pending_lifecycle >/dev/null 2>&1; then
	printf 'pending worker ignored a global lifecycle lock failure\n' >&2
	exit 1
fi
[[ "$process_after_global_failure" -eq 0 ]]

printf 'test-finalize-pending: ok\n'

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/finalize-pending.sh
source "${repo_root}/scripts/finalize-pending.sh"

# Independent Bash process: putting process_pending directly in an "if"
# disables errexit throughout the function and can hide service-only bugs.
if [[ "${1:-}" == --service-fixture ]]; then
	state_root="$2/state"
	module_root="$2/modules"
	boot_root="$2/boot"
	rpm_command="$2/rpm"
	uname_command="$2/uname"
	finalize_command="$2/finalize"
	process_pending
	exit
fi

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
# These test requests target an installed fake kernel, never the host rpmdb.
module_root="$test_root/modules"
boot_root="$test_root/boot"
mkdir -p "$boot_root" "$module_root/$kernel/kernel"

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

(
	fixture="$test_root/service"
	export fixture
	state_root="$fixture/state"
	pending_dir="$state_root/pending"
	mkdir -p "$pending_dir" "$fixture/boot" "$fixture/modules/7.3.3-test/updates"
	chmod 0755 "$state_root" "$pending_dir"
	printf 'manual data\n' > "$fixture/modules/7.3.3-test/updates/unowned"
	cat > "$fixture/uname" <<'MOCK'
#!/usr/bin/bash
[[ "$*" == "-r" ]] && echo 7.3.5-test
MOCK
	cat > "$fixture/rpm" <<'MOCK'
#!/usr/bin/bash
set -eu
case "$*" in
	'-q --whatprovides kernel-uname-r --provides')
		cat "$fixture/providers"
		[[ ! -e "$fixture/rpm-warning" ]] || echo 'rpmdb warning' >&2
		[[ ! -e "$fixture/rpm-error" ]]
		;;
	'-q -- kmod-galaxybook-ov02c10-'*)
		if [[ -f "$fixture/installed-kmod" && "$3" == "kmod-galaxybook-ov02c10-7.3.3-test" ]]; then
			echo "$3-1.00.26-1.fc44.x86_64"; exit 0
		fi
		echo "package $3 is not installed" >&2; exit 1
		;;
	*) exit 2 ;;
esac
MOCK
	cat > "$fixture/finalize" <<'MOCK'
#!/usr/bin/bash
set -eu
[[ "$1" == --kernel ]]
echo "$2" >> "$fixture/calls"
[[ ! -f "$fixture/fail-$2" ]]
MOCK
	chmod +x "$fixture/rpm" "$fixture/finalize" "$fixture/uname"

	run_worker() { /usr/bin/bash "$0" --service-fixture "$fixture"; }
	configure_inventory() {
		printf 'kernel-uname-r = 7.3.4-test\nkernel-uname-r = 7.3.5-test\n' > "$fixture/providers"
	}
	configure_inventory

	write_marker migration "$state_root"
	write_marker 7.3.3-test
	run_worker
	[[ ! -e "$pending_dir/7.3.3-test.pending" && -e "$state_root/migration.pending" ]]
	[[ ! -e "$fixture/calls" && "$(<"$fixture/modules/7.3.3-test/updates/unowned")" == 'manual data' ]]

	write_marker 7.3.3-test
	write_marker 7.3.4-test
	write_marker 7.3.5-test
	touch "$fixture/fail-7.3.4-test"
	if run_worker; then echo 'installed kernel failure was swallowed' >&2; exit 1; fi
	[[ ! -e "$pending_dir/7.3.3-test.pending" && -e "$pending_dir/7.3.4-test.pending" ]]
	[[ ! -e "$pending_dir/7.3.5-test.pending" && ! -e "$state_root/migration.pending" ]]
	[[ "$(<"$fixture/calls")" == $'7.3.4-test\n7.3.5-test' ]]
	rm "$fixture/fail-7.3.4-test"
	run_worker
	[[ ! -e "$pending_dir/7.3.4-test.pending" ]]

	# Each ambiguous or non-RPM boot case must keep the failed request alive.
	touch "$fixture/fail-7.3.3-test"
	write_marker 7.3.3-test
	for reason in boot module-tree installed-kmod rpm-warning rpm-error no-running malformed-provider; do
		case "$reason" in
			boot) ln -s absent "$fixture/boot/vmlinuz-7.3.3-test" ;;
			module-tree) mkdir "$fixture/modules/7.3.3-test/kernel" ;;
			no-running) printf 'kernel-uname-r = 7.3.4-test\n' > "$fixture/providers" ;;
			malformed-provider) echo 'kernel-uname-r =>' >> "$fixture/providers" ;;
			*) touch "$fixture/$reason" ;;
		esac
		if run_worker > /dev/null 2>&1; then echo "ambiguous removal accepted: $reason" >&2; exit 1; fi
		[[ -f "$pending_dir/7.3.3-test.pending" ]]
		case "$reason" in
			boot) unlink "$fixture/boot/vmlinuz-7.3.3-test" ;;
			module-tree) rmdir "$fixture/modules/7.3.3-test/kernel" ;;
			no-running|malformed-provider) configure_inventory ;;
			*) rm "$fixture/$reason" ;;
		esac
	done
	# A superficially matching marker with trailing extra bytes is not ours.
	printf '\n' >> "$pending_dir/7.3.3-test.pending"
	if run_worker >/dev/null 2>&1; then echo 'foreign marker retired' >&2; exit 1; fi
	[[ -e "$pending_dir/7.3.3-test.pending" ]]
)

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

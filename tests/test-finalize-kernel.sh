#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/finalize-kernel.sh
source "${repo_root}/scripts/finalize-kernel.sh"

test_root="$(mktemp -d /tmp/ov02c10-finalize-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

kernel="7.1.8-test.x86_64"
module_root="${test_root}/modules"
lock_parent="${test_root}/lock"
expected_dir="${module_root}/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c"
mkdir -p "$expected_dir" "$lock_parent"
touch "${expected_dir}/ov02c10.ko.xz"

depmod_args=()
dracut_args=()
migrate_calls=0
cleanup_args=()
owner_mode="expected"
common_evr_mode="expected"
fake_payload_evr="0:1.00.25-1.fc44"
fake_common_evr="0:1.00.25-1.fc44"
fake_name="ov02c10"
fake_vermagic_kernel="$kernel"
fake_resolved_module="${expected_dir}/ov02c10.ko.xz"
legacy_config=""
legacy_module=""

fake_depmod() {
	depmod_args=("$@")
}

fake_rpm() {
	local path="${*: -1}"

	case "$owner_mode" in
		expected)
			printf '%s\n' "kmod-galaxybook-ov02c10-${kernel}"
			;;
		wrong)
			printf '%s\n' "unrelated-kmod"
			;;
		unowned)
			printf 'file %s is not owned by any package\n' "$path" >&2
			return 1
			;;
		error)
			printf 'rpm database failure\n' >&2
			return 1
			;;
	esac
}

rpm_file_owner_evr() {
	rpm_file_owner_result=""
	rpm_file_owner_evr_result=""
	case "$owner_mode" in
		expected)
			rpm_file_owner_result="kmod-galaxybook-ov02c10-${kernel}"
			rpm_file_owner_evr_result="$fake_payload_evr"
			;;
		wrong)
			rpm_file_owner_result="unrelated-kmod"
			rpm_file_owner_evr_result="$fake_payload_evr"
			;;
		unowned) return 1 ;;
		error) return 2 ;;
	esac
}

rpm_package_evr() {
	[[ "$1" == galaxybook-ov02c10-kmod-common ]] || return 2
	rpm_package_evr_result=""
	[[ "$common_evr_mode" == expected ]] || return 2
	rpm_package_evr_result="$fake_common_evr"
}

fake_modinfo() {
	if [[ "$1" == "-F" && "$2" == "name" ]]; then
		printf '%s\n' "$fake_name"
		return
	fi
	if [[ "$1" == "-F" && "$2" == "vermagic" ]]; then
		printf '%s SMP preempt mod_unload\n' "$fake_vermagic_kernel"
		return
	fi
	printf '%s\n' "$fake_resolved_module"
}

fake_dracut() {
	dracut_args=("$@")
}

fake_lsinitrd() {
	[[ "$fake_lsinitrd_mode" != "fail" ]] || return 1
	printf '%s\n' \
		"-rw-r--r-- 1 root root 1 Jan 1 00:00 usr/lib/modules/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko.xz"
}

fake_flock() {
	return 0
}

fake_publish_attestation() {
	[[ "$1" == "$kernel" ]]
	[[ "$2" == "${expected_dir}/ov02c10.ko.xz" ]]
	((attestation_calls += 1))
}

fake_migrate() {
	((migrate_calls += 1))
	[[ -z "$legacy_config" ]] || /usr/bin/rm -f -- "$legacy_config"
}

fake_cleanup() {
	cleanup_args=("$@")
	[[ -z "$legacy_module" ]] || /usr/bin/rm -f -- "$legacy_module"
}

assert_legacy_preserved() {
	[[ -f "$legacy_config" && "$(<"$legacy_config")" == "legacy load rule" ]]
	[[ -f "$legacy_module" && "$(<"$legacy_module")" == "stale module" ]]
}

lock_order=()
acquire_kmod_lifecycle_lock() {
	[[ "${#lock_order[@]}" -eq 0 ]]
	lock_order+=(global)
}

acquire_lifecycle_lock() {
	[[ "${lock_order[*]}" == "global" ]]
	lock_order+=(private)
}

acquire_rpm_read_lock() {
	[[ "${lock_order[*]}" == "global private" ]]
	lock_order+=(rpm)
}

depmod_command=fake_depmod
modinfo_command=fake_modinfo
rpm_command=fake_rpm
dracut_command=fake_dracut
lsinitrd_command=fake_lsinitrd
flock_command=fake_flock
migrate_command=fake_migrate
cleanup_command=fake_cleanup
attestation_calls=0
fake_lsinitrd_mode="ok"
publish_readiness_attestation() {
	fake_publish_attestation "$@"
}

reconcile_kernel "$kernel"
[[ "${lock_order[*]}" == "global private rpm" ]]
[[ "$migrate_calls" -eq 1 ]]
[[ "${cleanup_args[*]}" == "--apply --kernel ${kernel}" ]]
[[ "${depmod_args[*]}" == "-a ${kernel}" ]]
[[ "${dracut_args[*]}" == "--force --kver ${kernel} --add-drivers ov02c10" ]]
[[ "$attestation_calls" -eq 1 ]]

acquire_kmod_lifecycle_lock() {
	return 1
}
acquire_lifecycle_lock() {
	printf 'private lock called after global-lock failure\n' >&2
	return 1
}
acquire_rpm_read_lock() {
	printf 'RPM lock called after global-lock failure\n' >&2
	return 1
}
if reconcile_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel ignored a global lifecycle lock failure\n' >&2
	exit 1
fi
[[ "$migrate_calls" -eq 1 && "${#cleanup_args[@]}" -eq 3 ]]
[[ "${depmod_args[*]}" == "-a ${kernel}" ]]
[[ "$attestation_calls" -eq 1 ]]

acquire_kmod_lifecycle_lock() { return 0; }
acquire_lifecycle_lock() { return 0; }
acquire_rpm_read_lock() { return 0; }

fake_lsinitrd_mode="fail"
if finalize_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted an unreadable initramfs\n' >&2
	exit 1
fi
[[ "$attestation_calls" -eq 1 ]]
fake_lsinitrd_mode="ok"

legacy_config="${test_root}/legacy-modules-load.conf"
legacy_module="${test_root}/updates-ov02c10.ko"
printf 'legacy load rule\n' > "$legacy_config"
printf 'stale module\n' > "$legacy_module"

owner_mode="wrong"
depmod_args=()
migrate_calls=0
cleanup_args=()
if reconcile_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted a payload owned by another package\n' >&2
	exit 1
fi
[[ "${#depmod_args[@]}" -eq 0 ]]
[[ "$migrate_calls" -eq 0 && "${#cleanup_args[@]}" -eq 0 ]]
assert_legacy_preserved

owner_mode="error"
if reconcile_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel treated an RPM database failure as unowned\n' >&2
	exit 1
fi
[[ "$migrate_calls" -eq 0 && "${#cleanup_args[@]}" -eq 0 ]]
assert_legacy_preserved

owner_mode="expected"
fake_payload_evr="0:1.00.24-1.fc44"
if reconcile_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted a payload older than the common package\n' >&2
	exit 1
fi
[[ "${#depmod_args[@]}" -eq 0 ]]
[[ "$migrate_calls" -eq 0 && "${#cleanup_args[@]}" -eq 0 ]]
assert_legacy_preserved

fake_payload_evr="$fake_common_evr"
fake_name="not-ov02c10"
if reconcile_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted the wrong module name\n' >&2
	exit 1
fi
[[ "$migrate_calls" -eq 0 && "${#cleanup_args[@]}" -eq 0 ]]
assert_legacy_preserved

fake_name="ov02c10"
fake_vermagic_kernel="7.1.7-wrong.x86_64"
if reconcile_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted a payload for another kernel\n' >&2
	exit 1
fi
[[ "${#depmod_args[@]}" -eq 0 ]]
[[ "$migrate_calls" -eq 0 && "${#cleanup_args[@]}" -eq 0 ]]
assert_legacy_preserved

fake_vermagic_kernel="$kernel"
touch "${expected_dir}/ov02c10.ko.zst"
if reconcile_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted duplicate external payloads\n' >&2
	exit 1
fi
[[ "$migrate_calls" -eq 0 && "${#cleanup_args[@]}" -eq 0 ]]
assert_legacy_preserved
rm -f -- "${expected_dir}/ov02c10.ko.zst"

fake_resolved_module="${module_root}/${kernel}/kernel/drivers/media/i2c/ov02c10.ko.xz"
validated_replacement="${expected_dir}/ov02c10.ko.xz"
if finalize_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted an in-tree module resolution\n' >&2
	exit 1
fi

fake_resolved_module="${expected_dir}/ov02c10.ko"
touch "$fake_resolved_module"
if finalize_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted a different external module than the validated payload\n' >&2
	exit 1
fi
rm -f -- "$fake_resolved_module"

fake_resolved_module="${expected_dir}/ov02c10.ko.xz"
fake_lsinitrd() {
	[[ "$fake_lsinitrd_mode" != "fail" ]] || return 1
	printf '%s\n' \
		"-rw-r--r-- 1 root root 1 Jan 1 00:00 usr/lib/modules/${kernel}/kernel/drivers/media/i2c/ov02c10.ko.xz"
}
if finalize_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted an in-tree initramfs payload\n' >&2
	exit 1
fi

printf 'test-finalize-kernel: ok\n'

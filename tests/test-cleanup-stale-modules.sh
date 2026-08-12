#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/cleanup-stale-modules.sh
source "${repo_root}/scripts/cleanup-stale-modules.sh"

lock_order=()
acquire_kmod_lifecycle_lock() {
	lock_order=(global)
}

acquire_lifecycle_lock() {
	[[ "${lock_order[*]}" == "global" ]]
	lock_order+=(private)
}

acquire_rpm_read_lock() {
	[[ "${lock_order[*]}" == "global private" ]]
	lock_order+=(rpm)
}

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

fake_id() {
	printf '0\n'
}

fake_rpm() {
	local path="${*: -1}"

	case "$path" in
		*/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko.xz)
			printf '%s\n' "$fake_owner"
			;;
		*)
			printf 'file %s is not owned by any package\n' "$path" >&2
			return 1
			;;
	esac
}

fake_modinfo() {
	if [[ "$1" == "-F" && "$2" == "name" ]]; then
		printf 'ov02c10\n'
		return
	fi
	printf '%s SMP preempt mod_unload\n' "$fake_vermagic_kernel"
}

fake_owner="kmod-galaxybook-ov02c10-${kernel}"
fake_vermagic_kernel="$kernel"
id_command=fake_id
rpm_command=fake_rpm
modinfo_command=fake_modinfo

if main --apply --module-root "$test_root" --kernel "$kernel" >/dev/null 2>&1
then
	printf 'cleanup-stale-modules removed a stale copy without a replacement\n' >&2
	exit 1
fi
[[ -e "${test_root}/${kernel}/updates/ov02c10.ko.gz" ]]

replacement_dir="${test_root}/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c"
mkdir -p "$replacement_dir"
touch "${replacement_dir}/ov02c10.ko.xz"

fake_owner="unrelated-kmod"
if main --apply --module-root "$test_root" --kernel "$kernel" >/dev/null 2>&1; then
	printf 'cleanup-stale-modules accepted a replacement owned by another package\n' >&2
	exit 1
fi
[[ -e "${test_root}/${kernel}/updates/ov02c10.ko.gz" ]]

fake_owner="kmod-galaxybook-ov02c10-${kernel}"
fake_vermagic_kernel="7.1.7-wrong.x86_64"
if main --apply --module-root "$test_root" --kernel "$kernel" >/dev/null 2>&1; then
	printf 'cleanup-stale-modules accepted a replacement for another kernel\n' >&2
	exit 1
fi
[[ -e "${test_root}/${kernel}/updates/ov02c10.ko.gz" ]]

fake_vermagic_kernel="$kernel"
main --apply --module-root "$test_root" --kernel "$kernel" >/dev/null
[[ "${lock_order[*]}" == "global private rpm" ]]
[[ ! -e "${test_root}/${kernel}/updates/ov02c10.ko.gz" ]]
[[ -e "${replacement_dir}/ov02c10.ko.xz" ]]

printf 'stale module\n' > "${test_root}/${kernel}/updates/ov02c10.ko.gz"
acquire_kmod_lifecycle_lock() { return 1; }
acquire_lifecycle_lock() {
	printf 'private lock called after global-lock failure\n' >&2
	return 1
}
acquire_rpm_read_lock() {
	printf 'RPM lock called after global-lock failure\n' >&2
	return 1
}
if main --apply --module-root "$test_root" --kernel "$kernel" >/dev/null 2>&1; then
	printf 'cleanup-stale-modules ignored a global lifecycle lock failure\n' >&2
	exit 1
fi
[[ -e "${test_root}/${kernel}/updates/ov02c10.ko.gz" ]]

printf 'test-cleanup-stale-modules: ok\n'

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/migrate-legacy-config.sh
source "${repo_root}/scripts/migrate-legacy-config.sh"

test_root="$(mktemp -d /tmp/ov02c10-migration-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

etc_root="${test_root}/etc"
mkdir -p "${etc_root}/modules-load.d" "${etc_root}/modprobe.d" "${etc_root}/depmod.d"

fake_unowned_rpm() {
	local path="${*: -1}"
	printf 'file %s is not owned by any package\n' "$path" >&2
	return 1
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

rpm_command=fake_unowned_rpm
printf 'ov02c10\n' > "${etc_root}/modules-load.d/galaxybook-ov02c10.conf"
printf 'softdep intel_ipu6_isys pre: ov02c10\n' > "${etc_root}/modprobe.d/galaxybook-ov02c10.conf"
printf '# Prefer the packaged Galaxy Book OV02C10 module over Fedora\x27s in-tree copy.\noverride ov02c10 * extra/galaxybook-ov02c10/drivers/media/i2c\n' \
	> "${etc_root}/depmod.d/galaxybook-ov02c10.conf"

main --etc-root "$etc_root"
[[ "${lock_order[*]}" == "global private rpm" ]]
[[ ! -e "${etc_root}/modules-load.d/galaxybook-ov02c10.conf" ]]
[[ ! -e "${etc_root}/modprobe.d/galaxybook-ov02c10.conf" ]]
[[ ! -e "${etc_root}/depmod.d/galaxybook-ov02c10.conf" ]]

printf 'ov02c10\n' > "${etc_root}/modules-load.d/galaxybook-ov02c10.conf"
acquire_kmod_lifecycle_lock() { return 1; }
acquire_lifecycle_lock() {
	printf 'private lock called after global-lock failure\n' >&2
	return 1
}
acquire_rpm_read_lock() {
	printf 'RPM lock called after global-lock failure\n' >&2
	return 1
}
if main --etc-root "$etc_root" >/dev/null 2>&1; then
	printf 'migration ignored a global lifecycle lock failure\n' >&2
	exit 1
fi
[[ -e "${etc_root}/modules-load.d/galaxybook-ov02c10.conf" ]]

acquire_kmod_lifecycle_lock() { return 0; }
acquire_lifecycle_lock() { return 0; }
acquire_rpm_read_lock() { return 0; }

printf '# local policy\noverride ov02c10 * extra/galaxybook-ov02c10/drivers/media/i2c\n' \
	> "${etc_root}/depmod.d/galaxybook-ov02c10.conf"
main --etc-root "$etc_root"
[[ -e "${etc_root}/depmod.d/galaxybook-ov02c10.conf" ]]

printf 'ov02c10\n' > "${etc_root}/modules-load.d/galaxybook-ov02c10.conf"
dry_run=0
main --dry-run --etc-root "$etc_root"
[[ -e "${etc_root}/modules-load.d/galaxybook-ov02c10.conf" ]]

fake_owned_rpm() {
	printf 'owned-package\n'
	return 0
}

rpm_command=fake_owned_rpm
dry_run=0
main --etc-root "$etc_root"
[[ -e "${etc_root}/modules-load.d/galaxybook-ov02c10.conf" ]]
[[ -e "${etc_root}/depmod.d/galaxybook-ov02c10.conf" ]]

fake_error_rpm() {
	printf 'rpm database failure\n' >&2
	return 1
}

rpm_command=fake_error_rpm
if main --etc-root "$etc_root" >/dev/null 2>&1; then
	printf 'migration treated an RPM database error as an unowned file\n' >&2
	exit 1
fi
[[ -e "${etc_root}/depmod.d/galaxybook-ov02c10.conf" ]]

printf 'test-migrate-legacy-config: ok\n'

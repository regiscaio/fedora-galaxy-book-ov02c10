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
	return 1
}

rpm_command=fake_unowned_rpm
printf 'ov02c10\n' > "${etc_root}/modules-load.d/galaxybook-ov02c10.conf"
printf 'softdep intel_ipu6_isys pre: ov02c10\n' > "${etc_root}/modprobe.d/galaxybook-ov02c10.conf"
printf '# local policy\noverride ov02c10 * extra/galaxybook-ov02c10/drivers/media/i2c\n' \
	> "${etc_root}/depmod.d/galaxybook-ov02c10.conf"

main --etc-root "$etc_root"
[[ ! -e "${etc_root}/modules-load.d/galaxybook-ov02c10.conf" ]]
[[ ! -e "${etc_root}/modprobe.d/galaxybook-ov02c10.conf" ]]
[[ -e "${etc_root}/depmod.d/galaxybook-ov02c10.conf" ]]

printf 'ov02c10\n' > "${etc_root}/modules-load.d/galaxybook-ov02c10.conf"
dry_run=0
main --dry-run --etc-root "$etc_root"
[[ -e "${etc_root}/modules-load.d/galaxybook-ov02c10.conf" ]]

fake_owned_rpm() {
	return 0
}

rpm_command=fake_owned_rpm
dry_run=0
main --etc-root "$etc_root"
[[ -e "${etc_root}/modules-load.d/galaxybook-ov02c10.conf" ]]

printf 'test-migrate-legacy-config: ok\n'

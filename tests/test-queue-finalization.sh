#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/queue-finalization.sh
source "${repo_root}/scripts/queue-finalization.sh"

test_root="$(mktemp -d /tmp/ov02c10-queue-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

kernel="7.1.8-test.x86_64"
module_root="${test_root}/modules"
state_root="${test_root}/state"
expected_dir="${module_root}/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c"
payload="${expected_dir}/ov02c10.ko.zst"
mkdir -p "$expected_dir"
touch "$payload"

fake_modinfo() {
	if [[ "$1" == "-F" && "$2" == "name" ]]; then
		printf '%s\n' "$fake_name"
		return
	fi
	printf '%s SMP preempt mod_unload\n' "$fake_vermagic"
}

worker_starts=0
fake_systemctl() {
	[[ "$*" == "start --no-block galaxybook-ov02c10-finalize.service" ]]
	((worker_starts += 1))
}

fake_name="ov02c10"
fake_vermagic="$kernel"
modinfo_command=fake_modinfo
systemctl_command=fake_systemctl

queue_from_rpm_trigger <<EOF
${payload}
${payload}
${module_root}/${kernel}/kernel/drivers/media/i2c/ov02c10.ko.zst
EOF

marker="${state_root}/pending/${kernel}.pending"
[[ -f "$marker" && ! -L "$marker" ]]
[[ "$(<"$marker")" == $'GALAXYBOOK_OV02C10_FINALIZATION_V1\nrequest='"${kernel}" ]]
[[ "$worker_starts" -eq 1 ]]

queue_marker migration "$state_root"
migration_marker="${state_root}/migration.pending"
[[ -f "$migration_marker" && ! -L "$migration_marker" ]]
[[ "$(stat -c '%a:%h' "$migration_marker")" == "644:1" ]]
[[ "$(<"$migration_marker")" == \
	$'GALAXYBOOK_OV02C10_FINALIZATION_V1\nrequest=migration' ]]
[[ ! -e "${state_root}/pending/migration.pending" ]]
if [[ "$EUID" -eq 0 ]]; then
	[[ "$(stat -c '%u:%g' "$migration_marker")" == "0:0" ]]
fi

# Trigger mode must never have an RPM command to call. Its only trust inputs
# are the exact trigger path plus the payload name and vermagic from modinfo.
if rg -q 'rpm_command|/usr/bin/rpm|rpm -q' scripts/queue-finalization.sh; then
	printf 'queue-finalization contains an RPM database query\n' >&2
	exit 1
fi

fake_name="not-ov02c10"
if queue_from_rpm_trigger <<< "$payload" >/dev/null 2>&1; then
	printf 'queue-finalization accepted the wrong module name\n' >&2
	exit 1
fi

fake_name="ov02c10"
fake_vermagic="7.1.7-wrong.x86_64"
if queue_from_rpm_trigger <<< "$payload" >/dev/null 2>&1; then
	printf 'queue-finalization accepted the wrong vermagic\n' >&2
	exit 1
fi

fake_vermagic="$kernel"
ln -s "$payload" "${expected_dir}/ov02c10.ko"
if queue_from_rpm_trigger <<< "${expected_dir}/ov02c10.ko" >/dev/null 2>&1; then
	printf 'queue-finalization accepted a symlink payload\n' >&2
	exit 1
fi

printf 'test-queue-finalization: ok\n'

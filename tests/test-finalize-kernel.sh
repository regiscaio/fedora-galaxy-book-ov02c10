#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/finalize-kernel.sh
source "${repo_root}/scripts/finalize-kernel.sh"

test_root="$(mktemp -d /tmp/ov02c10-finalize-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

kernel="7.1.8-test.x86_64"
module_root="${test_root}/modules"
lock_root="${test_root}/lock"
expected_dir="${module_root}/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c"
mkdir -p "$expected_dir"
touch "${expected_dir}/ov02c10.ko.xz"

depmod_args=()
dracut_args=()

fake_depmod() {
	depmod_args=("$@")
}

fake_rpm() {
	printf '%s\n' "kmod-galaxybook-ov02c10-${kernel}"
}

fake_modinfo() {
	if [[ "$1" == "-F" && "$2" == "vermagic" ]]; then
		printf '%s SMP preempt mod_unload\n' "$kernel"
		return
	fi
	printf '%s\n' "${expected_dir}/ov02c10.ko.xz"
}

fake_dracut() {
	dracut_args=("$@")
}

fake_lsinitrd() {
	printf '%s\n' \
		"-rw-r--r-- 1 root root 1 Jan 1 00:00 usr/lib/modules/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko.xz"
}

fake_flock() {
	return 0
}

depmod_command=fake_depmod
modinfo_command=fake_modinfo
rpm_command=fake_rpm
dracut_command=fake_dracut
lsinitrd_command=fake_lsinitrd
flock_command=fake_flock

finalize_kernel "$kernel"
[[ "${depmod_args[*]}" == "-a ${kernel}" ]]
[[ "${dracut_args[*]}" == "--force --kver ${kernel} --add-drivers ov02c10" ]]

fake_rpm() {
	printf '%s\n' "unrelated-kmod"
}
depmod_args=()
if finalize_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted a payload owned by another package\n' >&2
	exit 1
fi
[[ "${#depmod_args[@]}" -eq 0 ]]

fake_rpm() {
	printf '%s\n' "kmod-galaxybook-ov02c10-${kernel}"
}
fake_modinfo() {
	if [[ "$1" == "-F" && "$2" == "vermagic" ]]; then
		printf '7.1.7-wrong.x86_64 SMP preempt mod_unload\n'
		return
	fi
	printf '%s\n' "${expected_dir}/ov02c10.ko.xz"
}
if finalize_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted a payload for another kernel\n' >&2
	exit 1
fi
[[ "${#depmod_args[@]}" -eq 0 ]]

fake_modinfo() {
	if [[ "$1" == "-F" && "$2" == "vermagic" ]]; then
		printf '%s SMP preempt mod_unload\n' "$kernel"
		return
	fi
	printf '%s\n' "${module_root}/${kernel}/kernel/drivers/media/i2c/ov02c10.ko.xz"
}
if finalize_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted an in-tree module resolution\n' >&2
	exit 1
fi

fake_modinfo() {
	if [[ "$1" == "-F" && "$2" == "vermagic" ]]; then
		printf '%s SMP preempt mod_unload\n' "$kernel"
		return
	fi
	printf '%s\n' "${expected_dir}/ov02c10.ko.xz"
}
fake_lsinitrd() {
	printf '%s\n' \
		"-rw-r--r-- 1 root root 1 Jan 1 00:00 usr/lib/modules/${kernel}/kernel/drivers/media/i2c/ov02c10.ko.xz"
}
if finalize_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalize-kernel accepted an in-tree initramfs payload\n' >&2
	exit 1
fi

triggered_kernels=()
finalize_kernel() {
	triggered_kernels+=("$1")
}

finalize_from_rpm_trigger <<EOF
${module_root}/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko.xz
${module_root}/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko.xz
${module_root}/${kernel}/kernel/drivers/media/i2c/ov02c10.ko.xz
/usr/lib/modules/7.1.6-test.x86_64/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko.zst
/lib/modules/ignored/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko.backup
EOF

[[ "${#triggered_kernels[@]}" -eq 2 ]]
[[ " ${triggered_kernels[*]} " == *" ${kernel} "* ]]
[[ " ${triggered_kernels[*]} " == *" 7.1.6-test.x86_64 "* ]]

printf 'test-finalize-kernel: ok\n'

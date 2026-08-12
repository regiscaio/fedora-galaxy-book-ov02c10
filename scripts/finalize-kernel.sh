#!/usr/bin/env bash
set -euo pipefail

module_root="/lib/modules"
lock_root="/run/lock"
depmod_command="/usr/bin/depmod"
modinfo_command="/usr/bin/modinfo"
rpm_command="/usr/bin/rpm"
dracut_command="/usr/bin/dracut"
lsinitrd_command="/usr/bin/lsinitrd"
flock_command="/usr/bin/flock"

usage() {
	cat <<'USAGE'
Usage: finalize-kernel --kernel KERNEL
       finalize-kernel --from-rpm-trigger

Finalize an installed Galaxy Book OV02C10 module for one kernel. The command
refreshes that kernel's dependency index, verifies that modprobe resolves the
external Galaxy Book module, rebuilds the same kernel's initramfs, and verifies
that the initramfs contains the external module rather than an in-tree copy.

--from-rpm-trigger is an internal mode that reads RPM-triggered paths from
standard input and finalizes each matching kernel once.
USAGE
}

fail() {
	printf 'galaxybook-ov02c10: %s\n' "$*" >&2
	return 1
}

validate_kernel_name() {
	local kernel="$1"

	if [[ ! "$kernel" =~ ^[[:alnum:]][[:alnum:].+_-]*$ ]]; then
		fail "invalid kernel version: ${kernel}"
		return 1
	fi
}

validate_initramfs_module() {
	local kernel="$1"
	local expected_fragment="lib/modules/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko"
	local found_expected=0
	local initramfs_listing line module_path

	if ! initramfs_listing="$("$lsinitrd_command" --kver "$kernel")"; then
		fail "could not inspect the initramfs for ${kernel}"
		return 1
	fi

	while IFS= read -r line; do
		[[ "$line" == *"ov02c10.ko"* ]] || continue
		module_path="${line##* }"
		case "$module_path" in
			*"${expected_fragment}"|*"${expected_fragment}.xz"|*"${expected_fragment}.zst"|*"${expected_fragment}.gz")
				found_expected=1
				;;
			*)
				fail "initramfs for ${kernel} contains an unexpected OV02C10 module: ${module_path}"
				return 1
				;;
		esac
	done <<< "$initramfs_listing"

	if [[ "$found_expected" -ne 1 ]]; then
		fail "initramfs for ${kernel} does not contain the external Galaxy Book OV02C10 module"
		return 1
	fi
}

finalize_kernel() {
	local kernel="$1"
	local expected_dir expected_owner resolved_module lock_file candidate payload
	local payload_owner payload_vermagic vermagic_kernel
	local -a payloads=()
	local lock_fd

	validate_kernel_name "$kernel" || return 1

	if [[ ! -d "${module_root}/${kernel}" ]]; then
		fail "kernel module directory not found: ${module_root}/${kernel}"
		return 1
	fi

	if ! mkdir -p -- "$lock_root"; then
		fail "could not create lock directory: ${lock_root}"
		return 1
	fi
	lock_file="${lock_root}/galaxybook-ov02c10-${kernel}.lock"
	if ! exec {lock_fd}>"$lock_file"; then
		fail "could not open kernel finalization lock: ${lock_file}"
		return 1
	fi
	if ! "$flock_command" -x "$lock_fd"; then
		fail "could not lock kernel finalization for ${kernel}"
		return 1
	fi

	expected_dir="${module_root}/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c"
	for candidate in \
		"${expected_dir}/ov02c10.ko" \
		"${expected_dir}/ov02c10.ko.xz" \
		"${expected_dir}/ov02c10.ko.zst" \
		"${expected_dir}/ov02c10.ko.gz"
	do
		[[ -f "$candidate" && ! -L "$candidate" ]] && payloads+=("$candidate")
	done

	if [[ "${#payloads[@]}" -ne 1 ]]; then
		fail "expected exactly one external OV02C10 payload for ${kernel}, found ${#payloads[@]}"
		return 1
	fi
	payload="${payloads[0]}"
	expected_owner="kmod-galaxybook-ov02c10-${kernel}"
	if ! payload_owner="$("$rpm_command" -qf --qf '%{NAME}\n' -- "$payload")"; then
		fail "external OV02C10 payload is not owned by an installed RPM: ${payload}"
		return 1
	fi
	if [[ "$payload_owner" != "$expected_owner" ]]; then
		fail "external OV02C10 payload for ${kernel} is owned by ${payload_owner}, expected ${expected_owner}"
		return 1
	fi
	if ! payload_vermagic="$("$modinfo_command" -F vermagic -- "$payload")"; then
		fail "could not read vermagic from the external OV02C10 payload for ${kernel}"
		return 1
	fi
	vermagic_kernel=""
	read -r vermagic_kernel _ <<< "$payload_vermagic" || true
	if [[ "$vermagic_kernel" != "$kernel" ]]; then
		fail "external OV02C10 payload vermagic targets ${vermagic_kernel:-unknown}, expected ${kernel}"
		return 1
	fi

	printf 'Refreshing module dependencies for %s\n' "$kernel"
	if ! "$depmod_command" -a "$kernel"; then
		fail "depmod failed for ${kernel}"
		return 1
	fi

	if ! resolved_module="$("$modinfo_command" -k "$kernel" -n ov02c10)"; then
		fail "modinfo could not resolve ov02c10 for ${kernel}"
		return 1
	fi

	case "$resolved_module" in
		"${expected_dir}/ov02c10.ko"|"${expected_dir}/ov02c10.ko.xz"|"${expected_dir}/ov02c10.ko.zst"|"${expected_dir}/ov02c10.ko.gz")
			;;
		*)
			fail "ov02c10 for ${kernel} resolves outside the Galaxy Book package: ${resolved_module}"
			return 1
			;;
	esac

	if [[ ! -f "$resolved_module" ]]; then
		fail "resolved OV02C10 module is missing: ${resolved_module}"
		return 1
	fi

	printf 'Rebuilding initramfs for %s\n' "$kernel"
	if ! "$dracut_command" --force --kver "$kernel" \
		--add-drivers ov02c10
	then
		fail "dracut failed for ${kernel}"
		return 1
	fi
	validate_initramfs_module "$kernel" || return 1

	printf 'OV02C10 kernel finalization completed for %s\n' "$kernel"
}

finalize_from_rpm_trigger() {
	local path trigger_root relative kernel
	declare -A kernels=()

	while IFS= read -r path; do
		case "$path" in
			"${module_root}"/*/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko*)
				trigger_root="$module_root"
				;;
			/usr/lib/modules/*/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko*)
				trigger_root="/usr/lib/modules"
				;;
			*)
				continue
				;;
		esac

		case "$path" in
			*.ko|*.ko.xz|*.ko.zst|*.ko.gz)
				relative="${path#"${trigger_root}/"}"
				kernel="${relative%%/*}"
				kernels["$kernel"]=1
				;;
		esac
	done

	for kernel in "${!kernels[@]}"; do
		finalize_kernel "$kernel" || return 1
	done
}

main() {
	local trigger_mode=0
	local -a kernels=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--kernel)
				if [[ $# -lt 2 ]]; then
					fail "missing value for --kernel"
					usage >&2
					return 2
				fi
				kernels+=("$2")
				shift 2
				;;
			--from-rpm-trigger)
				trigger_mode=1
				shift
				;;
			-h|--help)
				usage
				return 0
				;;
			*)
				fail "unknown argument: $1"
				usage >&2
				return 2
				;;
		esac
	done

	if [[ "$EUID" -ne 0 ]]; then
		fail "kernel finalization must run as root"
		return 1
	fi

	if [[ "$trigger_mode" -eq 1 ]]; then
		if [[ "${#kernels[@]}" -ne 0 ]]; then
			fail "--from-rpm-trigger cannot be combined with --kernel"
			return 2
		fi
		finalize_from_rpm_trigger
		return
	fi

	if [[ "${#kernels[@]}" -eq 0 ]]; then
		fail "at least one --kernel argument is required"
		usage >&2
		return 2
	fi

	local kernel
	for kernel in "${kernels[@]}"; do
		finalize_kernel "$kernel" || return 1
	done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

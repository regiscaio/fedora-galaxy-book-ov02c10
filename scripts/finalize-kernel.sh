#!/usr/bin/env bash
set -euo pipefail

module_root="/lib/modules"
depmod_command="/usr/bin/depmod"
modinfo_command="/usr/bin/modinfo"
rpm_command="/usr/bin/rpm"
dracut_command="/usr/bin/dracut"
lsinitrd_command="/usr/bin/lsinitrd"
find_command="/usr/bin/find"
install_command="/usr/bin/install"
stat_command="/usr/bin/stat"
mktemp_command="/usr/bin/mktemp"
mv_command="/usr/bin/mv"
rm_command="/usr/bin/rm"
chmod_command="/usr/bin/chmod"
chown_command="/usr/bin/chown"
state_root="/var/lib/galaxybook-ov02c10"
ready_root="${state_root}/ready"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
migrate_command="${script_dir}/migrate-legacy-config"
cleanup_command="${script_dir}/cleanup-stale-modules"
# shellcheck source=rpm-file-owner.sh
source "${script_dir}/rpm-file-owner.sh"
# shellcheck source=rpm-read-lock.sh
source "${script_dir}/rpm-read-lock.sh"
# shellcheck source=lifecycle-lock.sh
source "${script_dir}/lifecycle-lock.sh"

usage() {
	cat <<'USAGE'
Usage: finalize-kernel --kernel KERNEL

Reconcile and finalize an installed Galaxy Book OV02C10 module for one kernel.
Under one exclusive lifecycle lock and one shared RPM transaction lock, the
command first validates RPM ownership, module name and vermagic, then migrates
exact legacy configuration, cleans safe unowned module shadows, refreshes that
kernel's dependency index, rebuilds the same kernel's initramfs, and verifies
that it contains the external module rather than an in-tree copy.
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

trusted_root_directory() {
	local directory="$1"
	local metadata mode

	[[ -d "$directory" && ! -L "$directory" ]] || return 1
	metadata="$("$stat_command" -Lc '%u:%g:%a' -- "$directory")" || return 1
	[[ "$metadata" =~ ^0:0:([0-7]{3,4})$ ]] || return 1
	mode="${BASH_REMATCH[1]}"
	(( (8#${mode} & 8#022) == 0 ))
}

ensure_ready_directory() {
	local directory metadata

	trusted_root_directory /var && trusted_root_directory /var/lib || {
		fail "the /var/lib hierarchy is not trusted for readiness attestations"
		return 1
	}
	for directory in "$state_root" "$ready_root"; do
		[[ ! -L "$directory" ]] || {
			fail "readiness directory must not be a symlink: ${directory}"
			return 1
		}
		"$install_command" -d -o root -g root -m 0755 -- "$directory" || return 1
		"$chmod_command" 00755 -- "$directory" || return 1
		metadata="$("$stat_command" -Lc '%u:%g:%a' -- "$directory")" || return 1
		[[ "$metadata" == "0:0:755" ]] || {
			fail "readiness directory has unsafe metadata: ${directory} (${metadata})"
			return 1
		}
	done
}

file_fingerprint() {
	local path="$1"
	local fingerprint

	[[ -f "$path" && ! -L "$path" ]] || {
		fail "cannot attest missing or unsafe file: ${path}"
		return 1
	}
	fingerprint="$("$find_command" -L "$path" -maxdepth 0 -type f \
		-printf '%D|%i|%s|%T@|%C@\n')"
	[[ -n "$fingerprint" && "$fingerprint" != *$'\n'* ]] || {
		fail "could not obtain one fingerprint for ${path}"
		return 1
	}
	printf '%s\n' "$fingerprint"
}

readiness_target_is_safe() {
	local marker="$1"
	local metadata

	[[ -e "$marker" || -L "$marker" ]] || return 0
	[[ -f "$marker" && ! -L "$marker" ]] || return 1
	metadata="$("$stat_command" -Lc '%u:%g:%a:%h' -- "$marker")" || return 1
	[[ "$metadata" == "0:0:644:1" ]]
}

publish_readiness_attestation() {
	local kernel="$1"
	local module_path="$2"
	local initramfs_path="/boot/initramfs-${kernel}.img"
	local module_before initramfs_before module_after initramfs_after
	local marker temporary="" expected_content published_content
	local output_status=0

	module_before="$(file_fingerprint "$module_path")" || return 1
	initramfs_before="$(file_fingerprint "$initramfs_path")" || return 1
	expected_content="$(printf '%s\n' \
		'version=1' \
		"initramfs=${initramfs_before}" \
		"module=${module_before}")"

	ensure_ready_directory || return 1
	marker="${ready_root}/${kernel}.state"
	readiness_target_is_safe "$marker" || {
		fail "readiness destination is not a safe root-owned regular file: ${marker}"
		return 1
	}
	temporary="$("$mktemp_command" "${ready_root}/.${kernel}.XXXXXX")" || return 1
	if ! printf '%s\n' "$expected_content" > "$temporary" \
		|| ! "$chown_command" root:root -- "$temporary" \
		|| ! "$chmod_command" 0644 -- "$temporary"
	then
		"$rm_command" -f -- "$temporary"
		fail "could not write readiness attestation for ${kernel}"
		return 1
	fi
	if module_after="$(file_fingerprint "$module_path")"; then
		:
	else
		output_status=$?
		"$rm_command" -f -- "$temporary"
		return "$output_status"
	fi
	if initramfs_after="$(file_fingerprint "$initramfs_path")"; then
		:
	else
		output_status=$?
		"$rm_command" -f -- "$temporary"
		return "$output_status"
	fi
	if [[ "$module_before" != "$module_after" || \
		"$initramfs_before" != "$initramfs_after" ]]
	then
		"$rm_command" -f -- "$temporary"
		fail "module or initramfs changed while attesting ${kernel}"
		return 1
	fi
	if ! "$mv_command" -fT -- "$temporary" "$marker"; then
		"$rm_command" -f -- "$temporary"
		fail "could not publish readiness attestation for ${kernel}"
		return 1
	fi
	temporary=""
	if ! readiness_target_is_safe "$marker"; then
		"$rm_command" -f -- "$marker"
		return 1
	fi
	published_content="$(<"$marker")"
	[[ "$published_content" == "$expected_content" ]] || {
		"$rm_command" -f -- "$marker"
		fail "published readiness attestation is inconsistent for ${kernel}"
		return 1
	}
	if ! module_after="$(file_fingerprint "$module_path")"; then
		"$rm_command" -f -- "$marker"
		return 1
	fi
	if ! initramfs_after="$(file_fingerprint "$initramfs_path")"; then
		"$rm_command" -f -- "$marker"
		return 1
	fi
	[[ "$module_before" == "$module_after" && \
		"$initramfs_before" == "$initramfs_after" ]] || {
		"$rm_command" -f -- "$marker"
		fail "module or initramfs changed after attesting ${kernel}"
		return 1
	}
}

validate_replacement() {
	local kernel="$1"
	local expected_dir expected_owner candidate payload
	local payload_owner payload_name payload_vermagic vermagic_kernel owner_status
	local -a payloads=()

	validate_kernel_name "$kernel" || return 1

	if [[ ! -d "${module_root}/${kernel}" ]]; then
		fail "kernel module directory not found: ${module_root}/${kernel}"
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
	if rpm_file_owner "$payload"; then
		payload_owner="$rpm_file_owner_result"
	else
		owner_status=$?
		if [[ "$owner_status" -eq 1 ]]; then
			fail "external OV02C10 payload is not owned by an installed RPM: ${payload}"
		fi
		return 1
	fi
	if [[ "$payload_owner" != "$expected_owner" ]]; then
		fail "external OV02C10 payload for ${kernel} is owned by ${payload_owner}, expected ${expected_owner}"
		return 1
	fi
	if ! payload_name="$("$modinfo_command" -F name -- "$payload")"; then
		fail "could not read the module name from the external OV02C10 payload for ${kernel}"
		return 1
	fi
	if [[ "$payload_name" != "ov02c10" ]]; then
		fail "external payload for ${kernel} has module name ${payload_name:-unknown}, expected ov02c10"
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

	validated_replacement="$payload"
}

validated_replacement=""

finalize_kernel() {
	local kernel="$1"
	local expected_dir resolved_module payload="$validated_replacement"

	expected_dir="${module_root}/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c"

	printf 'Refreshing module dependencies for %s\n' "$kernel"
	if ! "$depmod_command" -a "$kernel"; then
		fail "depmod failed for ${kernel}"
		return 1
	fi

	if ! resolved_module="$("$modinfo_command" -k "$kernel" -n ov02c10)"; then
		fail "modinfo could not resolve ov02c10 for ${kernel}"
		return 1
	fi

	if [[ "$resolved_module" != "$payload" ]]; then
		fail "ov02c10 for ${kernel} resolves to ${resolved_module}, expected validated payload ${payload}"
		return 1
	fi
	if [[ ! -f "$resolved_module" || -L "$resolved_module" ]]; then
		fail "resolved OV02C10 module is missing or unsafe: ${resolved_module}"
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
	publish_readiness_attestation "$kernel" "$payload" || return 1

	printf 'OV02C10 kernel finalization completed for %s\n' "$kernel"
}

reconcile_kernel() {
	local kernel="$1"

	acquire_lifecycle_lock || return 1
	acquire_rpm_read_lock --kernel "$kernel" || return 1
	validated_replacement=""
	validate_replacement "$kernel" || return 1
	"$migrate_command" || return 1
	"$cleanup_command" --apply --kernel "$kernel" || return 1
	finalize_kernel "$kernel"
}

main() {
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

	if [[ "${#kernels[@]}" -eq 0 ]]; then
		fail "at least one --kernel argument is required"
		usage >&2
		return 2
	fi

	local kernel
	for kernel in "${kernels[@]}"; do
		reconcile_kernel "$kernel" || return 1
	done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

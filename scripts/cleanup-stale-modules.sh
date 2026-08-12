#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: cleanup-stale-modules.sh [--apply] [--module-root PATH] [--kernel KERNEL]

Detect stale, unowned ov02c10 module copies left by older manual or broken
installs. By default this is a dry run. Use --apply as root to remove the stale
files and refresh depmod for the affected kernels.

Only legacy direct overrides are considered:
  /lib/modules/<kernel>/updates/ov02c10.ko*
  /lib/modules/<kernel>/extra/ov02c10.ko*

Packaged modules, the in-tree Fedora module, and Intel IPU6-owned modules are
left untouched. Removal is refused unless the same kernel already has exactly
one RPM-owned Galaxy Book replacement with matching vermagic.
USAGE
}

rpm_command="/usr/bin/rpm"
modinfo_command="/usr/bin/modinfo"
depmod_command="/usr/bin/depmod"
id_command="/usr/bin/id"
rm_command="/usr/bin/rm"
find_command="/usr/bin/find"
sort_command="/usr/bin/sort"
basename_command="/usr/bin/basename"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kmod-lifecycle-lock.sh
source "${script_dir}/kmod-lifecycle-lock.sh"
# shellcheck source=rpm-file-owner.sh
source "${script_dir}/rpm-file-owner.sh"
# shellcheck source=rpm-read-lock.sh
source "${script_dir}/rpm-read-lock.sh"
# shellcheck source=lifecycle-lock.sh
source "${script_dir}/lifecycle-lock.sh"

main() {
	local apply=0
	local module_root="/lib/modules"
	local kernel kernel_dir candidate stale_file replacement_dir replacement
	local expected_owner replacement_owner replacement_name replacement_vermagic vermagic_kernel
	local owner_status
	local -a kernels=()
	local -a stale_files=()
	local -a affected_kernels=()
	local -a replacements=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--apply)
				apply=1
				shift
				;;
			--module-root)
				if [[ $# -lt 2 ]]; then
					printf 'Missing value for --module-root\n' >&2
					return 2
				fi
				module_root="$2"
				shift 2
				;;
			--kernel)
				if [[ $# -lt 2 ]]; then
					printf 'Missing value for --kernel\n' >&2
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
				printf 'Unknown argument: %s\n' "$1" >&2
				usage >&2
				return 2
				;;
		esac
	done

	if [[ ! -d "$module_root" ]]; then
		printf 'Module root not found: %s\n' "$module_root" >&2
		return 1
	fi

	if [[ "$apply" -eq 1 && "$("$id_command" -u)" -ne 0 ]]; then
		printf 'Removing stale modules requires root. Re-run with sudo.\n' >&2
		return 1
	fi
	if [[ "$apply" -eq 1 ]]; then
		acquire_kmod_lifecycle_lock || return 1
		acquire_lifecycle_lock || return 1
		acquire_rpm_read_lock "$@" || return 1
	fi

	if [[ "${#kernels[@]}" -eq 0 ]]; then
		while IFS= read -r -d '' kernel_dir; do
			kernels+=("$("$basename_command" "$kernel_dir")")
		done < <("$find_command" "$module_root" \
			-mindepth 1 -maxdepth 1 -type d -print0 | "$sort_command" -z)
	fi

	for kernel in "${kernels[@]}"; do
		if [[ ! "$kernel" =~ ^[[:alnum:]][[:alnum:].+_-]*$ ]]; then
			printf 'Invalid kernel version: %s\n' "$kernel" >&2
			return 2
		fi

		kernel_dir="${module_root}/${kernel}"
		if [[ ! -d "$kernel_dir" ]]; then
			printf 'Skipping missing kernel module directory: %s\n' "$kernel_dir" >&2
			continue
		fi

		for candidate in \
			"${kernel_dir}"/updates/ov02c10.ko \
			"${kernel_dir}"/updates/ov02c10.ko.gz \
			"${kernel_dir}"/updates/ov02c10.ko.xz \
			"${kernel_dir}"/updates/ov02c10.ko.zst \
			"${kernel_dir}"/extra/ov02c10.ko \
			"${kernel_dir}"/extra/ov02c10.ko.gz \
			"${kernel_dir}"/extra/ov02c10.ko.xz \
			"${kernel_dir}"/extra/ov02c10.ko.zst
		do
			[[ -e "$candidate" ]] || continue

			if [[ -L "$candidate" || ! -f "$candidate" ]]; then
				printf 'Refusing unsafe legacy module path: %s\n' "$candidate" >&2
				return 1
			fi

			if rpm_file_owner "$candidate"; then
				printf 'Keeping packaged module: %s\n' "$candidate"
				continue
			else
				owner_status=$?
				if [[ "$owner_status" -ne 1 ]]; then
					printf 'Could not prove that legacy module is unowned: %s\n' \
						"$candidate" >&2
					return 1
				fi
			fi

			stale_files+=("$candidate")
			affected_kernels+=("$kernel")
		done
	done

	if [[ "${#stale_files[@]}" -eq 0 ]]; then
		printf 'No stale unowned ov02c10 module copies found under %s\n' "$module_root"
		return 0
	fi

	if [[ "$apply" -eq 0 ]]; then
		printf 'Stale unowned ov02c10 module copies found:\n'
		for stale_file in "${stale_files[@]}"; do
			printf '  %s\n' "$stale_file"
		done
		printf '\nDry run only. Re-run with --apply as root to remove them and refresh depmod.\n'
		return 0
	fi

	mapfile -t affected_kernels < <(printf '%s\n' "${affected_kernels[@]}" | "$sort_command" -u)

	for kernel in "${affected_kernels[@]}"; do
		replacement_dir="${module_root}/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c"
		replacements=()
		for candidate in \
			"${replacement_dir}/ov02c10.ko" \
			"${replacement_dir}/ov02c10.ko.gz" \
			"${replacement_dir}/ov02c10.ko.xz" \
			"${replacement_dir}/ov02c10.ko.zst"
		do
			[[ -f "$candidate" && ! -L "$candidate" ]] && replacements+=("$candidate")
		done

		if [[ "${#replacements[@]}" -ne 1 ]]; then
			printf 'Refusing cleanup for %s: expected exactly one external replacement, found %s.\n' \
				"$kernel" "${#replacements[@]}" >&2
			return 1
		fi

		replacement="${replacements[0]}"
		expected_owner="kmod-galaxybook-ov02c10-${kernel}"
		if rpm_file_owner "$replacement"; then
			replacement_owner="$rpm_file_owner_result"
		else
			owner_status=$?
			if [[ "$owner_status" -eq 1 ]]; then
				printf 'Refusing cleanup for %s: replacement is not owned by an installed RPM.\n' \
					"$kernel" >&2
			fi
			return 1
		fi
		if [[ "$replacement_owner" != "$expected_owner" ]]; then
			printf 'Refusing cleanup for %s: replacement owner is %s, expected %s.\n' \
				"$kernel" "$replacement_owner" "$expected_owner" >&2
			return 1
		fi
		if ! replacement_name="$("$modinfo_command" -F name -- "$replacement")"; then
			printf 'Refusing cleanup for %s: replacement module name is unreadable.\n' \
				"$kernel" >&2
			return 1
		fi
		if [[ "$replacement_name" != "ov02c10" ]]; then
			printf 'Refusing cleanup for %s: replacement module name is %s.\n' \
				"$kernel" "${replacement_name:-unknown}" >&2
			return 1
		fi
		if ! replacement_vermagic="$("$modinfo_command" -F vermagic -- "$replacement")"; then
			printf 'Refusing cleanup for %s: replacement vermagic is unreadable.\n' \
				"$kernel" >&2
			return 1
		fi
		vermagic_kernel=""
		read -r vermagic_kernel _ <<< "$replacement_vermagic" || true
		if [[ "$vermagic_kernel" != "$kernel" ]]; then
			printf 'Refusing cleanup for %s: replacement vermagic targets %s.\n' \
				"$kernel" "${vermagic_kernel:-unknown}" >&2
			return 1
		fi
	done

	printf 'Removing stale unowned ov02c10 module copies:\n'
	for stale_file in "${stale_files[@]}"; do
		printf '  %s\n' "$stale_file"
		if ! "$rm_command" -f -- "$stale_file"; then
			printf 'Could not remove stale module: %s\n' "$stale_file" >&2
			return 1
		fi
	done

	if [[ "$module_root" == "/lib/modules" || "$module_root" == "/usr/lib/modules" ]]; then
		for kernel in "${affected_kernels[@]}"; do
			printf 'Refreshing module dependencies for %s\n' "$kernel"
			if ! "$depmod_command" -a "$kernel"; then
				printf 'depmod failed for %s\n' "$kernel" >&2
				return 1
			fi
		done
	else
		printf 'Skipped depmod because module root is not a system module root: %s\n' \
			"$module_root"
	fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

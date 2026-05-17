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
left untouched.
USAGE
}

apply=0
module_root="/lib/modules"
kernels=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--apply)
			apply=1
			shift
			;;
		--module-root)
			if [[ $# -lt 2 ]]; then
				printf 'Missing value for --module-root\n' >&2
				exit 2
			fi
			module_root="$2"
			shift 2
			;;
		--kernel)
			if [[ $# -lt 2 ]]; then
				printf 'Missing value for --kernel\n' >&2
				exit 2
			fi
			kernels+=("$2")
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
done

if [[ ! -d "$module_root" ]]; then
	printf 'Module root not found: %s\n' "$module_root" >&2
	exit 1
fi

if [[ "$apply" -eq 1 && "$(id -u)" -ne 0 ]]; then
	printf 'Removing stale modules requires root. Re-run with sudo.\n' >&2
	exit 1
fi

if [[ "${#kernels[@]}" -eq 0 ]]; then
	while IFS= read -r -d '' kernel_dir; do
		kernels+=("$(basename "$kernel_dir")")
	done < <(find "$module_root" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
fi

stale_files=()
affected_kernels=()

for kernel in "${kernels[@]}"; do
	kernel_dir="${module_root}/${kernel}"
	if [[ ! -d "$kernel_dir" ]]; then
		printf 'Skipping missing kernel module directory: %s\n' "$kernel_dir" >&2
		continue
	fi

	for candidate in \
		"${kernel_dir}"/updates/ov02c10.ko \
		"${kernel_dir}"/updates/ov02c10.ko.xz \
		"${kernel_dir}"/updates/ov02c10.ko.zst \
		"${kernel_dir}"/extra/ov02c10.ko \
		"${kernel_dir}"/extra/ov02c10.ko.xz \
		"${kernel_dir}"/extra/ov02c10.ko.zst
	do
		[[ -e "$candidate" ]] || continue

		if rpm -qf -- "$candidate" >/dev/null 2>&1; then
			printf 'Keeping packaged module: %s\n' "$candidate"
			continue
		fi

		stale_files+=("$candidate")
		affected_kernels+=("$kernel")
	done
done

if [[ "${#stale_files[@]}" -eq 0 ]]; then
	printf 'No stale unowned ov02c10 module copies found under %s\n' "$module_root"
	exit 0
fi

if [[ "$apply" -eq 0 ]]; then
	printf 'Stale unowned ov02c10 module copies found:\n'
	for stale_file in "${stale_files[@]}"; do
		printf '  %s\n' "$stale_file"
	done
	printf '\nDry run only. Re-run with --apply as root to remove them and refresh depmod.\n'
	exit 0
fi

printf 'Removing stale unowned ov02c10 module copies:\n'
for stale_file in "${stale_files[@]}"; do
	printf '  %s\n' "$stale_file"
	rm -f -- "$stale_file"
done

mapfile -t affected_kernels < <(printf '%s\n' "${affected_kernels[@]}" | sort -u)

if [[ "$module_root" == "/lib/modules" ]]; then
	for kernel in "${affected_kernels[@]}"; do
		printf 'Refreshing module dependencies for %s\n' "$kernel"
		depmod -a "$kernel"
	done
else
	printf 'Skipped depmod because module root is not /lib/modules: %s\n' "$module_root"
fi

#!/usr/bin/env bash
set -euo pipefail

module_root="/lib/modules"
state_root="/var/lib/galaxybook-ov02c10"
modinfo_command="/usr/bin/modinfo"
install_command="/usr/bin/install"
mktemp_command="/usr/bin/mktemp"
mv_command="/usr/bin/mv"
chmod_command="/usr/bin/chmod"
stat_command="/usr/bin/stat"
systemctl_command="/usr/bin/systemctl"
rm_command="/usr/bin/rm"
service_unit="galaxybook-ov02c10-finalize.service"
marker_version="GALAXYBOOK_OV02C10_FINALIZATION_V1"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=state-directory.sh
source "${script_dir}/state-directory.sh"

usage() {
	cat <<'USAGE'
Usage: queue-finalization --from-rpm-trigger
       queue-finalization --migration

Internal package helper. RPM file-trigger mode reads candidate payload paths
from standard input, validates them without opening the RPM database, and
queues their kernels for post-transaction finalization. Migration mode queues
legacy-configuration migration for the same post-transaction worker.
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

ensure_state_directory() {
	local pending_dir="${state_root}/pending"
	local directory

	for directory in "$state_root" "$pending_dir"; do
		if [[ -L "$directory" ]]; then
			fail "state directory must not be a symlink: ${directory}"
			return 1
		fi
	done

	state_directory_stat_command="$stat_command"
	validate_state_ancestry || {
		fail "state hierarchy is missing or unsafe"
		return 1
	}

	if [[ "$EUID" -eq 0 ]]; then
		"$install_command" -d -o root -g root -m 0755 -- \
			"$state_root" "$pending_dir" || {
			fail "could not create durable finalization state under ${state_root}"
			return 1
		}
		"$chmod_command" 00755 -- "$state_root" "$pending_dir" || return 1
	else
		"$install_command" -d -m 0755 -- "$state_root" "$pending_dir" || {
			fail "could not create durable finalization state under ${state_root}"
			return 1
		}
	fi
	validate_state_hierarchy "$state_root" || {
		fail "unsafe durable finalization state under ${state_root}"
		return 1
	}
}

queue_marker() {
	local marker_name="$1"
	local marker_directory="${2:-${state_root}/pending}"
	local marker="${marker_directory}/${marker_name}.pending"
	local temporary=""
	local temporary_identity marker_identity owner mode links content expected_content

	ensure_state_directory || return 1
	temporary="$("$mktemp_command" --tmpdir="$marker_directory" ".${marker_name}.pending.XXXXXX")" || {
		fail "could not allocate a temporary finalization marker for ${marker_name}"
		return 1
	}
	if ! printf '%s\nrequest=%s\n' "$marker_version" "$marker_name" > "$temporary"; then
		"$rm_command" -f -- "$temporary"
		fail "could not write finalization marker for ${marker_name}"
		return 1
	fi
	if ! "$chmod_command" 0644 -- "$temporary"; then
		"$rm_command" -f -- "$temporary"
		return 1
	fi
	temporary_identity="$("$stat_command" -Lc '%d:%i' -- "$temporary")" || {
		"$rm_command" -f -- "$temporary"
		return 1
	}
	if ! "$mv_command" -fT -- "$temporary" "$marker"; then
		"$rm_command" -f -- "$temporary"
		fail "could not publish finalization marker: ${marker}"
		return 1
	fi
	temporary=""
	if [[ ! -f "$marker" || -L "$marker" ]]; then
		fail "published finalization marker is not a regular file: ${marker}"
		return 1
	fi
	marker_identity="$("$stat_command" -Lc '%d:%i' -- "$marker")" || return 1
	owner="$("$stat_command" -c '%u:%g' -- "$marker")" || return 1
	mode="$("$stat_command" -c '%a' -- "$marker")" || return 1
	links="$("$stat_command" -c '%h' -- "$marker")" || return 1
	content="$(<"$marker")"
	expected_content="${marker_version}"$'\n'"request=${marker_name}"
	if [[ "$marker_identity" != "$temporary_identity" || \
		( "$EUID" -eq 0 && "$owner" != "0:0" ) || \
		"$mode" != "644" || "$links" != "1" || \
		"$content" != "$expected_content" ]]
	then
		# Remove only the inode written by this invocation; a newer request must
		# remain durable for the worker.
		if [[ "$marker_identity" == "$temporary_identity" ]]; then
			"$rm_command" -f -- "$marker"
		fi
		fail "published finalization marker has unsafe metadata or content: ${marker}"
		return 1
	fi
}

request_worker_start() {
	if ! "$systemctl_command" start --no-block "$service_unit"; then
		printf 'galaxybook-ov02c10: queued durable finalization; systemd will retry it at boot\n' >&2
	fi
}

validate_trigger_payload() {
	local path="$1"
	local trigger_root="$2"
	local relative kernel expected_dir candidate payload name vermagic vermagic_kernel
	local -a payloads=()

	relative="${path#"${trigger_root}/"}"
	kernel="${relative%%/*}"
	validate_kernel_name "$kernel" || return 1
	expected_dir="${trigger_root}/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c"

	case "$path" in
		"${expected_dir}/ov02c10.ko"|"${expected_dir}/ov02c10.ko.xz"|"${expected_dir}/ov02c10.ko.zst"|"${expected_dir}/ov02c10.ko.gz")
			;;
		*)
			fail "RPM trigger supplied an unexpected OV02C10 payload path: ${path}"
			return 1
			;;
	esac

	for candidate in \
		"${expected_dir}/ov02c10.ko" \
		"${expected_dir}/ov02c10.ko.xz" \
		"${expected_dir}/ov02c10.ko.zst" \
		"${expected_dir}/ov02c10.ko.gz"
	do
		[[ -f "$candidate" && ! -L "$candidate" ]] && payloads+=("$candidate")
	done

	if [[ "${#payloads[@]}" -ne 1 ]]; then
		fail "expected exactly one regular external OV02C10 payload for ${kernel}, found ${#payloads[@]}"
		return 1
	fi
	payload="${payloads[0]}"
	if [[ "$payload" != "$path" ]]; then
		fail "RPM trigger path does not match the unique external OV02C10 payload for ${kernel}"
		return 1
	fi

	if ! name="$("$modinfo_command" -F name -- "$payload")"; then
		fail "could not read the module name from the external OV02C10 payload for ${kernel}"
		return 1
	fi
	if [[ "$name" != "ov02c10" ]]; then
		fail "external payload for ${kernel} has module name ${name:-unknown}, expected ov02c10"
		return 1
	fi
	if ! vermagic="$("$modinfo_command" -F vermagic -- "$payload")"; then
		fail "could not read vermagic from the external OV02C10 payload for ${kernel}"
		return 1
	fi
	vermagic_kernel=""
	read -r vermagic_kernel _ <<< "$vermagic" || true
	if [[ "$vermagic_kernel" != "$kernel" ]]; then
		fail "external OV02C10 payload vermagic targets ${vermagic_kernel:-unknown}, expected ${kernel}"
		return 1
	fi

	printf '%s\n' "$kernel"
}

queue_from_rpm_trigger() {
	local path trigger_root kernel
	local -a paths=()
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
				paths+=("${trigger_root}"$'\t'"${path}")
				;;
		esac
	done

	for path in "${paths[@]}"; do
		trigger_root="${path%%$'\t'*}"
		path="${path#*$'\t'}"
		kernel="$(validate_trigger_payload "$path" "$trigger_root")" || return 1
		kernels["$kernel"]=1
	done

	if [[ "${#kernels[@]}" -eq 0 ]]; then
		return 0
	fi
	for kernel in "${!kernels[@]}"; do
		queue_marker "$kernel" || return 1
	done
	request_worker_start
}

main() {
	local mode=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--from-rpm-trigger|--migration)
				if [[ -n "$mode" ]]; then
					fail "queue mode may be specified only once"
					return 2
				fi
				mode="$1"
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
		fail "queuing kernel finalization must run as root"
		return 1
	fi

	case "$mode" in
		--from-rpm-trigger)
			queue_from_rpm_trigger
			;;
		--migration)
			# A common-only transaction must preserve the old load rule until a
			# validated kernel reconciliation succeeds. Keep this marker outside
			# the watched kernel queue so it cannot cause idle periodic retries.
			queue_marker migration "$state_root"
			request_worker_start
			;;
		*)
			fail "one queue mode is required"
			usage >&2
			return 2
			;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

#!/usr/bin/env bash
set -euo pipefail

state_root="/var/lib/galaxybook-ov02c10"
finalize_command="/usr/libexec/galaxybook-ov02c10/finalize-kernel"
find_command="/usr/bin/find"
sort_command="/usr/bin/sort"
basename_command="/usr/bin/basename"
rm_command="/usr/bin/rm"
stat_command="/usr/bin/stat"
marker_version="GALAXYBOOK_OV02C10_FINALIZATION_V1"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kmod-lifecycle-lock.sh
source "${script_dir}/kmod-lifecycle-lock.sh"
# shellcheck source=rpm-read-lock.sh
source "${script_dir}/rpm-read-lock.sh"
# shellcheck source=lifecycle-lock.sh
source "${script_dir}/lifecycle-lock.sh"
# shellcheck source=state-directory.sh
source "${script_dir}/state-directory.sh"

fail() {
	printf 'galaxybook-ov02c10: %s\n' "$*" >&2
	return 1
}

validate_kernel_name() {
	local kernel="$1"

	if [[ ! "$kernel" =~ ^[[:alnum:]][[:alnum:].+_-]*$ ]]; then
		fail "invalid queued kernel version: ${kernel}"
		return 1
	fi
}

process_pending() {
	local pending_dir="${state_root}/pending"
	local migration_marker="${state_root}/migration.pending"
	local marker name kernel owner mode links content expected_content
	local marker_identity current_identity migration_identity=""
	local migration_completed=0
	local result=0
	local -a markers=()
	local -a validation_markers=()

	state_directory_stat_command="$stat_command"
	if ! validate_state_hierarchy "$state_root"; then
		fail "durable finalization state is missing or unsafe: ${state_root}"
		return 1
	fi

	while IFS= read -r -d '' marker; do
		markers+=("$marker")
	done < <("$find_command" "$pending_dir" -mindepth 1 -maxdepth 1 \
		-name '*.pending' -print0 | "$sort_command" -z)

	if [[ "${#markers[@]}" -eq 0 ]]; then
		printf 'No pending Galaxy Book OV02C10 finalization requests\n'
		return 0
	fi
	validation_markers=("${markers[@]}")
	if [[ -e "$migration_marker" || -L "$migration_marker" ]]; then
		validation_markers+=("$migration_marker")
	fi

	for marker in "${validation_markers[@]}"; do
		if [[ -L "$marker" || ! -f "$marker" ]]; then
			fail "refusing unsafe finalization marker: ${marker}"
			return 1
		fi
		owner="$("$stat_command" -c '%u:%g' -- "$marker")" || return 1
		mode="$("$stat_command" -c '%a' -- "$marker")" || return 1
		links="$("$stat_command" -c '%h' -- "$marker")" || return 1
		if [[ "$EUID" -eq 0 && "$owner" != "0:0" ]]; then
			fail "refusing finalization marker with unexpected owner: ${marker}"
			return 1
		fi
		if [[ "$mode" != "644" || "$links" != "1" ]]; then
			fail "refusing finalization marker with unsafe metadata: ${marker}"
			return 1
		fi
		name="$("$basename_command" "$marker")"
		content="$(<"$marker")"
		expected_content="${marker_version}"$'\n'"request=${name%.pending}"
		if [[ "$content" != "$expected_content" ]]; then
			fail "refusing malformed finalization marker: ${marker}"
			return 1
		fi
	done

	# Never migrate configuration for a common-only transaction. A successful
	# kernel reconciliation validates its replacement before migration and is
	# therefore the only safe proof that the legacy load rule can be retired.
	# Keep this marker durable until such a reconciliation succeeds.
	if [[ -f "$migration_marker" && ! -L "$migration_marker" ]]; then
		migration_identity="$("$stat_command" -Lc '%d:%i' -- "$migration_marker")" || return 1
		printf 'Legacy migration remains queued until a validated kernel reconciliation succeeds\n'
	fi

	for marker in "${markers[@]}"; do
		name="$("$basename_command" "$marker")"
		kernel="${name%.pending}"
		validate_kernel_name "$kernel" || {
			result=1
			continue
		}
		marker_identity="$("$stat_command" -Lc '%d:%i' -- "$marker")" || {
			result=1
			continue
		}

		if ! "$finalize_command" --kernel "$kernel"; then
			fail "kernel finalization failed for queued kernel ${kernel}"
			result=1
			continue
		fi
		migration_completed=1
		if ! current_identity="$("$stat_command" -Lc '%d:%i' -- "$marker" 2>/dev/null)"; then
			continue
		fi
		if [[ "$current_identity" != "$marker_identity" ]]; then
			printf 'A newer finalization request replaced %s; leaving it queued\n' "$marker"
			continue
		fi
		"$rm_command" -- "$marker" || {
			fail "could not clear completed finalization marker: ${marker}"
			result=1
		}
	done

	if [[ -n "$migration_identity" && "$migration_completed" -eq 1 ]]; then
		if current_identity="$("$stat_command" -Lc '%d:%i' -- "$migration_marker" 2>/dev/null)"; then
			if [[ "$current_identity" == "$migration_identity" ]]; then
				"$rm_command" -- "$migration_marker" || return 1
			else
				printf 'A newer migration request replaced %s; leaving it queued\n' \
					"$migration_marker"
			fi
		fi
	fi

	return "$result"
}

run_pending_lifecycle() {
	acquire_kmod_lifecycle_lock || return 1
	acquire_lifecycle_lock || return 1
	acquire_rpm_read_lock "$@" || return 1
	process_pending
}

main() {
	if [[ "$EUID" -ne 0 ]]; then
		fail "pending kernel finalization must run as root"
		return 1
	fi

	run_pending_lifecycle "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

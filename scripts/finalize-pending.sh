#!/usr/bin/env bash
set -euo pipefail

state_root="/var/lib/galaxybook-ov02c10"
finalize_command="/usr/libexec/galaxybook-ov02c10/finalize-kernel"
find_command="/usr/bin/find"
sort_command="/usr/bin/sort"
basename_command="/usr/bin/basename"
rm_command="/usr/bin/rm"
stat_command="/usr/bin/stat"
rpm_command="/usr/bin/rpm"
uname_command="/usr/bin/uname"
module_root="/usr/lib/modules"
boot_root="/boot"
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

# Called under the lifecycle and RPM read locks. A leftover updates/ directory
# is common after kernel removal and may contain files we do not own. Retire
# only our authenticated request, never the module tree or a readiness record.
queued_kernel_is_retired() {
	local kernel="$1" running path result status=0
	local package="kmod-galaxybook-ov02c10-${1}"

	running="$("$uname_command" -r)" && validate_kernel_name "$running" || return 1
	[[ "$kernel" != "$running" && -d "$boot_root" && -d "$module_root" ]] || return 1
	for path in "$boot_root/vmlinuz-$kernel" "$boot_root/initramfs-$kernel.img" \
		"$module_root/$kernel/vmlinuz" "$module_root/$kernel/kernel" \
		"$module_root/$kernel/modules.builtin" "$module_root/$kernel/extra/galaxybook-ov02c10"; do
		[[ ! -e "$path" && ! -L "$path" ]] || return 1
	done

	result="$(LC_ALL=C "$rpm_command" -q -- "$package" 2>&1)" || status=$?
	[[ "$status" -eq 1 && "$result" == "package $package is not installed" ]] || return 1
	# Enumerate actual provided uname-r values (not RPM names or EVRs). Seeing
	# the running kernel is a positive control for a usable rpmdb. Any rpm/awk
	# error, extra diagnostic, or malformed provider leaves the marker live.
	result="$({ LC_ALL=C "$rpm_command" -q --whatprovides kernel-uname-r --provides |
		LC_ALL=C /usr/bin/awk -v target="$kernel" -v running="$running" '
			$1 == "kernel-uname-r" {
				if (NF != 3 || $2 != "=" || $3 !~ /^[[:alnum:]][[:alnum:].+_-]*$/) bad=1
				if ($3 == target) present=1
				if ($3 == running) witness=1
			}
			END { if (!bad && witness && !present) print "retired" }
		'; } 2>&1)" || return 1
	[[ "$result" == retired ]]
}

process_pending() {
	local pending_dir="${state_root}/pending"
	local migration_marker="${state_root}/migration.pending"
	local marker name kernel owner mode links
	local marker_identity current_identity migration_identity=""
	local migration_completed=0
	local result=0
	local -a markers=()
	local -a validation_markers=()
	local -A identities=()

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
		identities["$marker"]="$("$stat_command" -Lc '%d:%i' -- "$marker")" || return 1
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
		if ! printf '%s\nrequest=%s\n' "$marker_version" "${name%.pending}" | /usr/bin/cmp -s - "$marker"; then
			fail "refusing malformed finalization marker: ${marker}"
			return 1
		fi
	done

	# Never migrate configuration for a common-only transaction. A successful
	# kernel reconciliation validates its replacement before migration and is
	# therefore the only safe proof that the legacy load rule can be retired.
	# Keep this marker durable until such a reconciliation succeeds.
	if [[ -n "${identities[$migration_marker]:-}" ]]; then
		migration_identity="${identities[$migration_marker]}"
		printf 'Legacy migration remains queued until a validated kernel reconciliation succeeds\n'
	fi

	for marker in "${markers[@]}"; do
		name="$("$basename_command" "$marker")"
		kernel="${name%.pending}"
		validate_kernel_name "$kernel" || {
			result=1
			continue
		}
		marker_identity="${identities[$marker]}"

		if queued_kernel_is_retired "$kernel"; then
			printf 'Retiring finalization request for removed kernel %s\n' "$kernel"
		elif "$finalize_command" --kernel "$kernel"; then
			migration_completed=1
		else
			# A failure remains retryable, but must not starve later kernels
			# under the service's set -e execution.
			printf 'galaxybook-ov02c10: kernel finalization failed for queued kernel %s\n' "$kernel" >&2
			result=1
			continue
		fi
		if ! current_identity="$("$stat_command" -Lc '%d:%i' -- "$marker" 2>/dev/null)"; then
			continue
		fi
		if [[ "$current_identity" != "$marker_identity" ]]; then
			printf 'A newer finalization request replaced %s; leaving it queued\n' "$marker"
			continue
		fi
		"$rm_command" -- "$marker" || {
			printf 'galaxybook-ov02c10: could not clear finalization marker: %s\n' "$marker" >&2
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

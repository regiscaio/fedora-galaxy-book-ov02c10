#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper_path="${repo_root}/scripts/finalizer-transaction.sh"
if [[ "$(<"$helper_path")" == *'%{'* ]]; then
	printf 'test-finalizer-transaction: helper contains an RPM macro token\n' >&2
	exit 1
fi
# shellcheck source=../scripts/finalizer-transaction.sh
source "$helper_path"
[[ "$finalizer_transaction_rpm_nevr_query_format" == \
	$'%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\n' ]] || {
	printf 'test-finalizer-transaction: runtime RPM query format is invalid\n' >&2
	exit 1
}

clone_production_function() {
	local source_name="$1" target_name="$2" definition

	definition="$(declare -f "$source_name")" || return 1
	definition="${definition/#${source_name} ()/${target_name} ()}"
	eval "$definition"
}

clone_production_function finalizer_transaction_publish_ready \
	finalizer_transaction_publish_ready_original
clone_production_function finalizer_transaction_query_package \
	finalizer_transaction_query_package_original
clone_production_function finalizer_transaction_query_unit_file_owner \
	finalizer_transaction_query_unit_file_owner_original
clone_production_function finalizer_transaction_copy_helper \
	finalizer_transaction_copy_helper_original
clone_production_function finalizer_transaction_cleanup_state \
	finalizer_transaction_cleanup_state_original
clone_production_function finalizer_transaction_verify_common_package \
	finalizer_transaction_verify_common_package_original
clone_production_function finalizer_transaction_run_systemctl \
	finalizer_transaction_run_systemctl_original
clone_production_function finalizer_transaction_run_worker_systemctl \
	finalizer_transaction_run_worker_systemctl_original
clone_production_function finalizer_transaction_run_systemd_run \
	finalizer_transaction_run_systemd_run_original

export PATH=/usr/bin:/usr/sbin
export GALAXYBOOK_FINALIZER_FAMILY=ov02c10
export GALAXYBOOK_FINALIZER_COMMON_PACKAGE=galaxybook-ov02c10-kmod-common
export GALAXYBOOK_FINALIZER_OWN_FLOOR=0:1.00.25-0
export GALAXYBOOK_FINALIZER_PEER_PACKAGE=galaxybook-max98390-kmod-common
export GALAXYBOOK_FINALIZER_PEER_FLOOR=0:1.00.12-0
export GALAXYBOOK_FINALIZER_SETUP_PACKAGE=galaxybook-setup
export GALAXYBOOK_FINALIZER_SETUP_FLOOR=0:1.00.48-0
export GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS=galaxybook-ov02c10-finalize.path:galaxybook-ov02c10-finalize.timer
export GALAXYBOOK_FINALIZER_DEPENDENT_UNITS=-
export GALAXYBOOK_FINALIZER_SERVICE_UNIT=galaxybook-ov02c10-finalize.service
export GALAXYBOOK_FINALIZER_PENDING_DIRECTORY=/var/lib/galaxybook-ov02c10/pending
export GALAXYBOOK_FINALIZER_RECOVERY_UNIT=galaxybook-ov02c10-finalizer-transaction-recovery.service
export GALAXYBOOK_FINALIZER_STATE_DIRECTORY=/run/galaxybook-ov02c10-finalizer-transaction
export GALAXYBOOK_FINALIZER_SERVICE_CGROUP=/sys/fs/cgroup/system.slice/galaxybook-ov02c10-finalize.service/cgroup.procs

# Load and validate the production allowlist before applying any test-only
# path or command overrides.
finalizer_transaction_load_config
[[ "$finalizer_transaction_command_timeout_seconds" -eq 120 && \
	"$finalizer_transaction_worker_timeout_seconds" -ge 1260 ]] || {
	printf 'test-finalizer-transaction: quick/worker timeout split is invalid\n' >&2
	exit 1
}

ov_config_environment=(
	PATH=/usr/bin:/usr/sbin
	GALAXYBOOK_FINALIZER_FAMILY=ov02c10
	GALAXYBOOK_FINALIZER_COMMON_PACKAGE=galaxybook-ov02c10-kmod-common
	GALAXYBOOK_FINALIZER_OWN_FLOOR=0:1.00.25-0
	GALAXYBOOK_FINALIZER_PEER_PACKAGE=galaxybook-max98390-kmod-common
	GALAXYBOOK_FINALIZER_PEER_FLOOR=0:1.00.12-0
	GALAXYBOOK_FINALIZER_SETUP_PACKAGE=galaxybook-setup
	GALAXYBOOK_FINALIZER_SETUP_FLOOR=0:1.00.48-0
	GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS=galaxybook-ov02c10-finalize.path:galaxybook-ov02c10-finalize.timer
	GALAXYBOOK_FINALIZER_DEPENDENT_UNITS=-
	GALAXYBOOK_FINALIZER_SERVICE_UNIT=galaxybook-ov02c10-finalize.service
	GALAXYBOOK_FINALIZER_PENDING_DIRECTORY=/var/lib/galaxybook-ov02c10/pending
	GALAXYBOOK_FINALIZER_RECOVERY_UNIT=galaxybook-ov02c10-finalizer-transaction-recovery.service
	GALAXYBOOK_FINALIZER_STATE_DIRECTORY=/run/galaxybook-ov02c10-finalizer-transaction
	GALAXYBOOK_FINALIZER_SERVICE_CGROUP=/sys/fs/cgroup/system.slice/galaxybook-ov02c10-finalize.service/cgroup.procs
)
if /usr/bin/env -i "${ov_config_environment[@]}" \
	GALAXYBOOK_FINALIZER_UNEXPECTED=1 \
	/usr/bin/bash --noprofile --norc -c \
	'source "$1"; finalizer_transaction_load_config' \
	config-check "${repo_root}/scripts/finalizer-transaction.sh" \
	>/dev/null 2>&1; then
	printf 'test-finalizer-transaction: unexpected finalizer environment was accepted\n' >&2
	exit 1
fi
for invalid_config_bytes in $'invalid\rvalue' $'invalid\tvalue' $'invalid\nvalue'; do
	if /usr/bin/env -i "${ov_config_environment[@]}" \
		"GALAXYBOOK_FINALIZER_DEPENDENT_UNITS=${invalid_config_bytes}" \
		/usr/bin/bash --noprofile --norc -c \
		'source "$1"; finalizer_transaction_load_config' \
		config-check "${repo_root}/scripts/finalizer-transaction.sh" \
		>/dev/null 2>&1; then
		printf 'test-finalizer-transaction: invalid configuration bytes were accepted\n' >&2
		exit 1
	fi
done

# The exact same helper bytes also enforce the MAX98390 path-only contract.
/usr/bin/env -i PATH=/usr/bin:/usr/sbin \
	GALAXYBOOK_FINALIZER_FAMILY=max98390 \
	GALAXYBOOK_FINALIZER_COMMON_PACKAGE=galaxybook-max98390-kmod-common \
	GALAXYBOOK_FINALIZER_OWN_FLOOR=0:1.00.12-0 \
	GALAXYBOOK_FINALIZER_PEER_PACKAGE=galaxybook-ov02c10-kmod-common \
	GALAXYBOOK_FINALIZER_PEER_FLOOR=0:1.00.25-0 \
	GALAXYBOOK_FINALIZER_SETUP_PACKAGE=galaxybook-setup \
	GALAXYBOOK_FINALIZER_SETUP_FLOOR=0:1.00.48-0 \
	GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS=max98390-kmod-finalize.path \
	GALAXYBOOK_FINALIZER_DEPENDENT_UNITS=max98390-hda-i2c-setup.service \
	GALAXYBOOK_FINALIZER_SERVICE_UNIT=max98390-kmod-finalize.service \
	GALAXYBOOK_FINALIZER_PENDING_DIRECTORY=/var/lib/galaxybook-max98390/pending \
	GALAXYBOOK_FINALIZER_RECOVERY_UNIT=galaxybook-max98390-finalizer-transaction-recovery.service \
	GALAXYBOOK_FINALIZER_STATE_DIRECTORY=/run/galaxybook-max98390-finalizer-transaction \
	GALAXYBOOK_FINALIZER_SERVICE_CGROUP=/sys/fs/cgroup/system.slice/max98390-kmod-finalize.service/cgroup.procs \
	/usr/bin/bash --noprofile --norc -c '
		set -euo pipefail
		trap "printf \"max98390 matrix failed at line %s\\n\" \"\$LINENO\" >&2" ERR
		source "$1"
		finalizer_transaction_load_config
		[[ "${#finalizer_transaction_activator_units[@]}" -eq 1 ]]
		[[ "${finalizer_transaction_activator_units[0]}" == max98390-kmod-finalize.path ]]
		[[ "${#finalizer_transaction_dependent_units[@]}" -eq 1 ]]
		[[ "${finalizer_transaction_dependent_units[0]}" == max98390-hda-i2c-setup.service ]]
		[[ "${#finalizer_transaction_all_units[@]}" -eq 3 ]]
		[[ " ${finalizer_transaction_all_units[*]} " != *" sound.target "* ]]
		max_root="$(mktemp -d /tmp/max98390-finalizer-transaction.XXXXXX)"
		[[ "$max_root" == /tmp/max98390-finalizer-transaction.* ]]
		max_cleanup() { rm -rf -- "$max_root"; }
		trap max_cleanup EXIT
		max_runtime="${max_root}/run/systemd/system"
		max_state="${max_root}/run/galaxybook-max98390-finalizer-transaction"
		max_pending="${max_root}/var/lib/galaxybook-max98390/pending"
		max_units="${max_root}/usr/lib/systemd/system"
		max_cgroup="${max_root}/cgroup/service/cgroup.procs"
		max_dependent_cgroup="${max_root}/cgroup/dependent/cgroup.procs"
		mkdir -p -- "$max_runtime" "$max_pending" "$max_units" \
			"${max_cgroup%/*}" "${max_dependent_cgroup%/*}"
		chmod 0700 -- "$max_root" "${max_root}/run" "$max_pending"
		: > "${max_pending}/kernel.pending"
		chmod 0644 -- "${max_pending}/kernel.pending"
		: > "$max_cgroup"
		printf "populated 0\nfrozen 0\n" > "${max_cgroup%/cgroup.procs}/cgroup.events"
		: > "$max_dependent_cgroup"
		printf "populated 1\nfrozen 0\n" > \
			"${max_dependent_cgroup%/cgroup.procs}/cgroup.events"
		chmod 0644 -- "$max_cgroup" "${max_cgroup%/cgroup.procs}/cgroup.events" \
			"$max_dependent_cgroup" \
			"${max_dependent_cgroup%/cgroup.procs}/cgroup.events"
		finalizer_transaction_expected_euid="$EUID"
		finalizer_transaction_systemd_runtime_directory="$max_runtime"
		finalizer_transaction_state_directory="$max_state"
		finalizer_transaction_state_path="${max_state}/current.state"
		finalizer_transaction_ready_path="${max_state}/recovery.ready"
		finalizer_transaction_helper_copy_path="${max_state}/recovery-helper"
		finalizer_transaction_pending_directory="$max_pending"
		finalizer_transaction_unit_directory="$max_units"
		finalizer_transaction_service_cgroup="$max_cgroup"
		max_path=max98390-kmod-finalize.path
		max_dependent=max98390-hda-i2c-setup.service
		max_service=max98390-kmod-finalize.service
		finalizer_transaction_dependent_cgroup["$max_dependent"]="$max_dependent_cgroup"
		declare -A max_load=() max_persistent=() max_mask=() max_active=()
		for unit in "${finalizer_transaction_all_units[@]}"; do
			max_load["$unit"]=loaded
			max_mask["$unit"]=0
			max_active["$unit"]=inactive
			printf "[Unit]\nDescription=%s\n" "$unit" > "${max_units}/${unit}"
			chmod 0644 -- "${max_units}/${unit}"
		done
		max_active["$max_path"]=active
		max_active["$max_dependent"]=active
		max_persistent["$max_path"]=enabled
		max_persistent["$max_dependent"]=enabled
		max_persistent["$max_service"]=enabled
		max_mask_seen=0
		max_stop_stage=0
		max_unmask_stage=0
		max_start_stage=0
		max_worker_starts=0
		max_concurrent_rejected=0
		finalizer_transaction_run_quiet() { "$@"; }
		finalizer_transaction_systemd_property() {
			local output_variable="$1" unit="$2" property="$3" value
			case "$property" in
				LoadState) value="${max_load[$unit]:-not-found}" ;;
					UnitFileState)
						if [[ "${max_mask[$unit]:-0}" -eq 1 ]]; then
							value=masked-runtime
						elif [[ "${max_load[$unit]:-not-found}" == not-found ]]; then
							value=""
						else
						value="${max_persistent[$unit]:-disabled}"
					fi
					;;
				ActiveState) value="${max_active[$unit]:-inactive}" ;;
				*) return 1 ;;
			esac
			printf -v "$output_variable" "%s" "$value"
		}
		max_join_units() {
			local output_variable="$1" argument serialized=""
			shift
			for argument in "$@"; do
				[[ "$argument" == -* ]] || serialized+="${serialized:+ }${argument}"
			done
			printf -v "$output_variable" "%s" "$serialized"
		}
		finalizer_transaction_run_systemctl() {
			local command="${1:-}" joined="" unit
			shift || :
			case "$command" in
				mask)
					[[ " $* " == *" --runtime "* && " $* " == *" --no-reload "* ]]
					max_join_units joined "$@"
					[[ "$joined" == "max98390-kmod-finalize.path max98390-hda-i2c-setup.service max98390-kmod-finalize.service" ]]
					[[ "$joined" != *sound.target* ]]
					for unit in $joined; do max_mask["$unit"]=1; done
					max_mask_seen=1
					;;
				daemon-reload) ;;
				stop)
					max_join_units joined "$@"
					((max_stop_stage += 1))
					case "$max_stop_stage" in
						1) [[ "$joined" == "$max_path" ]] ;;
						2) [[ "$joined" == "$max_dependent" ]] ;;
						3) [[ "$joined" == "$max_service" ]] ;;
						*) return 1 ;;
					esac
					for unit in $joined; do
						max_active["$unit"]=inactive
						if [[ "$unit" == "$max_dependent" ]]; then
							: > "$max_dependent_cgroup"
							printf "populated 0\nfrozen 0\n" > \
								"${max_dependent_cgroup%/cgroup.procs}/cgroup.events"
						fi
					done
					;;
				unmask)
					[[ " $* " == *" --runtime "* && " $* " == *" --no-reload "* ]]
					max_join_units joined "$@"
					((max_unmask_stage += 1))
					case "$max_unmask_stage" in
						1)
							[[ "$joined" == "$max_path $max_dependent" ]]
							for unit in $joined; do max_mask["$unit"]=0; done
							if finalizer_transaction_run_systemctl start "$max_service"; then
								return 1
							fi
							max_concurrent_rejected=1
							;;
						2)
							[[ "$joined" == "$max_service" ]]
							max_mask["$max_service"]=0
							;;
						*) return 1 ;;
					esac
					;;
				start)
					max_join_units joined "$@"
					for unit in $joined; do
						[[ "${max_mask[$unit]:-0}" -eq 0 ]] || return 73
						[[ " $* " == *" --no-block "* ]] || return 74
						((max_start_stage += 1))
						case "$max_start_stage" in
							1) [[ "$unit" == "$max_service" ]]; max_active["$unit"]=inactive ;;
							2) [[ "$unit" == "$max_dependent" ]]; max_active["$unit"]=active ;;
							3) [[ "$unit" == "$max_path" ]]; max_active["$unit"]=active ;;
							*) return 1 ;;
						esac
					done
					;;
				reset-failed) ;;
				enable|disable) return 72 ;;
				*) return 1 ;;
			esac
		}
		finalizer_transaction_run_worker_systemctl() {
			[[ "$finalizer_transaction_worker_timeout_seconds" -ge 1260 ]]
			((max_worker_starts += 1))
			finalizer_transaction_run_systemctl "$@"
		}
		finalizer_transaction_validate_new_unit_graph() { return 0; }
		finalizer_transaction_ensure_state_directory
		finalizer_transaction_snapshot_units
		finalizer_transaction_nonce=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
		finalizer_transaction_write_new_state
		finalizer_transaction_parse_state "$finalizer_transaction_nonce"
		[[ "${finalizer_transaction_snapshot_unit_active[$max_dependent]}" == active ]]
		finalizer_transaction_mask_and_drain
		[[ "$max_mask_seen" -eq 1 && "$max_stop_stage" -eq 3 ]] || {
			printf "max98390 mask/stop mismatch: mask=%s stop=%s\n" \
				"$max_mask_seen" "$max_stop_stage" >&2
			exit 1
		}
		finalizer_transaction_rearm_graph new
		[[ "$max_unmask_stage" -eq 2 && "$max_concurrent_rejected" -eq 1 ]]
		[[ "$max_start_stage" -eq 3 && "$max_worker_starts" -eq 2 ]]
		[[ "${max_active[$max_path]}" == active ]]
		[[ "${max_active[$max_dependent]}" == active ]]
		[[ "${max_persistent[$max_path]}" == enabled ]]
		[[ "${max_persistent[$max_dependent]}" == enabled ]]
		[[ "${max_persistent[$max_service]}" == enabled ]]
		finalizer_transaction_publish_ready() { return 0; }
		finalizer_transaction_acquire_rpm_lock() { return 0; }
		finalizer_transaction_snapshot_current_packages() { return 0; }
		finalizer_transaction_packages_are_all_old() { return 0; }
		finalizer_transaction_validate_old_unit_graph() { return 0; }
		finalizer_transaction_verify_common_package() { return 0; }
		max_stop_stage=0
		max_old_status=0
		finalizer_transaction_recover AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
			>/dev/null 2>&1 || max_old_status=$?
		[[ "$max_old_status" -eq 75 ]]
		[[ "$max_unmask_stage" -eq 2 && "$max_worker_starts" -eq 2 ]]
		for unit in "${finalizer_transaction_all_units[@]}"; do
			[[ "${max_mask[$unit]}" -eq 1 ]]
		done
		[[ -f "$finalizer_transaction_state_path" ]]
	' bash "${repo_root}/scripts/finalizer-transaction.sh"

test_root="$(mktemp -d /tmp/ov02c10-finalizer-transaction.XXXXXX)"
runtime_directory="${test_root}/run/systemd/system"
state_directory="${test_root}/run/galaxybook-ov02c10-finalizer-transaction"
pending_directory="${test_root}/var/lib/galaxybook-ov02c10/pending"
unit_directory="${test_root}/usr/lib/systemd/system"
rpm_directory="${test_root}/usr/lib/sysimage/rpm"
rpm_lock="${rpm_directory}/.rpm.lock"
service_cgroup="${test_root}/cgroup/service/cgroup.procs"
recovery_cgroup="${test_root}/cgroup/recovery/cgroup.procs"
service_cgroup_events="${service_cgroup%/cgroup.procs}/cgroup.events"
event_log="${test_root}/events"
call_log="${test_root}/systemctl.calls"
holder_ready="${test_root}/holder.ready"
ofd_acquired="${test_root}/ofd.acquired"
ofd_attempted="${test_root}/ofd.attempted"
ofd_result="${test_root}/ofd.result"
recovery_gate="${test_root}/recovery.release"
handoff_hook="${test_root}/recovery-handoff.bashenv"
lock_cycle_global="${test_root}/global.lock"
lock_cycle_setup_ready="${test_root}/lock-cycle.setup-ready"
lock_cycle_setup_gate="${test_root}/lock-cycle.setup-gate"
lock_cycle_setup_attempt="${test_root}/lock-cycle.setup-attempt"
lock_cycle_setup_acquired="${test_root}/lock-cycle.setup-acquired"
lock_cycle_worker_attempt="${test_root}/lock-cycle.worker-attempt"
lock_cycle_worker_acquired="${test_root}/lock-cycle.worker-acquired"
lock_cycle_worker_status="${test_root}/lock-cycle.worker-status"
lock_cycle_recovery_status="${test_root}/lock-cycle.recovery-status"
lock_cycle_order="${test_root}/lock-cycle.order"
holder_pid=""
ofd_pid=""
mock_recovery_pid=""
lock_cycle_setup_pid=""
lock_cycle_recovery_pid=""

fixture_stop_recovery_process() {
	local pid="${mock_recovery_pid:-}"

	if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
		kill -TERM "$pid" 2>/dev/null || :
		wait "$pid" 2>/dev/null || :
	fi
	mock_recovery_pid=""
	mock_recovery_active=inactive
}

cleanup() {
	fixture_stop_recovery_process
	if [[ -n "$ofd_pid" ]]; then
		kill "$ofd_pid" 2>/dev/null || :
		wait "$ofd_pid" 2>/dev/null || :
	fi
	if [[ -n "$holder_pid" ]]; then
		kill "$holder_pid" 2>/dev/null || :
		wait "$holder_pid" 2>/dev/null || :
	fi
	if [[ -n "$lock_cycle_setup_pid" ]]; then
		kill "$lock_cycle_setup_pid" 2>/dev/null || :
		wait "$lock_cycle_setup_pid" 2>/dev/null || :
	fi
	if [[ -n "$lock_cycle_recovery_pid" ]]; then
		kill "$lock_cycle_recovery_pid" 2>/dev/null || :
		wait "$lock_cycle_recovery_pid" 2>/dev/null || :
	fi
	rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
	printf 'test-finalizer-transaction: %s\n' "$*" >&2
	exit 1
}

assert_equal() {
	local expected="$1" actual="$2" description="$3"

	[[ "$actual" == "$expected" ]] || \
		fail "${description}: expected '${expected}', got '${actual}'"
}

assert_exists() {
	[[ -e "$1" && ! -L "$1" ]] || fail "$2"
}

assert_absent() {
	[[ ! -e "$1" && ! -L "$1" ]] || fail "$2"
}

event_line() {
	local pattern="$1" line number=0

	while IFS= read -r line; do
		((number += 1))
		if [[ "$line" == "$pattern" || "$line" == "$pattern "* ]]; then
			printf '%s\n' "$number"
			return 0
		fi
	done < "$event_log"
	return 1
}

last_event_line() {
	local pattern="$1" line number=0 matched=0

	while IFS= read -r line; do
		((number += 1))
		if [[ "$line" == "$pattern" || "$line" == "$pattern "* ]]; then
			matched="$number"
		fi
	done < "$event_log"
	((matched > 0)) || return 1
	printf '%s\n' "$matched"
}

lock_cycle_line() {
	local pattern="$1" line number=0

	while IFS= read -r line; do
		((number += 1))
		if [[ "$line" == "$pattern" ]]; then
			printf '%s\n' "$number"
			return 0
		fi
	done < "$lock_cycle_order"
	return 1
}

wait_for_file() {
	local path="$1" attempt

	for ((attempt = 0; attempt < 200; attempt++)); do
		[[ -e "$path" ]] && return 0
		/usr/bin/sleep 0.01
	done
	return 1
}

mkdir -p -- "$runtime_directory" "$pending_directory" "$unit_directory" \
	"$rpm_directory" "${service_cgroup%/*}"
chmod 0700 -- "$test_root" "${test_root}/run" "$rpm_directory"
: > "$rpm_lock"
chmod 0600 -- "$rpm_lock"
: > "$event_log"
: > "$call_log"
: > "$service_cgroup"
printf 'populated 0\nfrozen 0\n' > "$service_cgroup_events"
chmod 0644 -- "$service_cgroup" "$service_cgroup_events"

# The systemd-run mock executes the copied helper as the command actually
# serialized by production.  A mock-only BASH_ENV trap waits until the helper
# has entered its real CLI and validated the canonical ABI, then redirects
# absolute runtime paths to this fixture before the first filesystem action.
cat > "$handoff_hook" <<'RECOVERY_HANDOFF_HOOK'
set -T

finalizer_test_apply_overrides() {
	local definition

	trap - DEBUG
	finalizer_transaction_expected_euid="$EUID"
	finalizer_transaction_systemd_runtime_directory="$TEST_FINALIZER_RUNTIME"
	finalizer_transaction_state_directory="$TEST_FINALIZER_STATE"
	finalizer_transaction_state_path="${TEST_FINALIZER_STATE}/current.state"
	finalizer_transaction_ready_path="${TEST_FINALIZER_STATE}/recovery.ready"
	finalizer_transaction_helper_copy_path="${TEST_FINALIZER_STATE}/recovery-helper"
	finalizer_transaction_pending_directory="$TEST_FINALIZER_PENDING"
	finalizer_transaction_unit_directory="$TEST_FINALIZER_UNITS"
	finalizer_transaction_service_cgroup="$TEST_FINALIZER_SERVICE_CGROUP"
	finalizer_transaction_recovery_cgroup="$TEST_FINALIZER_RECOVERY_CGROUP"
	finalizer_transaction_rpm_lock_path="$TEST_FINALIZER_RPM_LOCK"
	finalizer_transaction_rpm_lock_ancestry=(
		"$TEST_FINALIZER_ROOT"
		"$TEST_FINALIZER_ROOT/usr"
		"$TEST_FINALIZER_ROOT/usr/lib"
		"$TEST_FINALIZER_ROOT/usr/lib/sysimage"
		"$TEST_FINALIZER_ROOT/usr/lib/sysimage/rpm"
	)
	definition="$(declare -f finalizer_transaction_publish_ready)"
	definition="${definition/#finalizer_transaction_publish_ready ()/finalizer_transaction_publish_ready_handoff_original ()}"
	eval "$definition"
	finalizer_transaction_publish_ready() {
		[[ "$TEST_FINALIZER_PUBLISH_READY" == 1 ]] || return 1
		finalizer_transaction_publish_ready_handoff_original || return 1
		printf 'RECOVERY-READY\n' >> "$TEST_FINALIZER_EVENT_LOG"
		printf 'copy-cli-env-i\n' > "${TEST_FINALIZER_ROOT}/handoff.executed"
	}
	finalizer_transaction_acquire_rpm_lock() {
		printf 'RECOVERY-LOCK-ATTEMPT\n' >> "$TEST_FINALIZER_EVENT_LOG"
		while [[ ! -e "$TEST_FINALIZER_GATE" ]]; do
			/usr/bin/sleep 0.01
		done
		return 1
	}
}

trap 'if [[ "${BASH_COMMAND:-}" == finalizer_transaction_main* ]] && \
	declare -F finalizer_transaction_main >/dev/null; then \
	finalizer_transaction_expected_euid="$EUID"; \
elif [[ "${BASH_COMMAND:-}" == finalizer_transaction_ensure_state_directory* ]] && \
	declare -F finalizer_transaction_ensure_state_directory >/dev/null; then \
	finalizer_test_apply_overrides; fi' DEBUG
RECOVERY_HANDOFF_HOOK
chmod 0600 -- "$handoff_hook"

finalizer_transaction_expected_euid="$EUID"
finalizer_transaction_systemd_runtime_directory="$runtime_directory"
finalizer_transaction_state_directory="$state_directory"
finalizer_transaction_state_path="${state_directory}/current.state"
finalizer_transaction_ready_path="${state_directory}/recovery.ready"
finalizer_transaction_helper_copy_path="${state_directory}/recovery-helper"
finalizer_transaction_pending_directory="$pending_directory"
finalizer_transaction_unit_directory="$unit_directory"
finalizer_transaction_service_cgroup="$service_cgroup"
finalizer_transaction_recovery_cgroup="$recovery_cgroup"
finalizer_transaction_rpm_lock_path="$rpm_lock"
finalizer_transaction_rpm_lock_ancestry=("$test_root" "${test_root}/usr" \
	"${test_root}/usr/lib" "${test_root}/usr/lib/sysimage" "$rpm_directory")
finalizer_transaction_script_path="${repo_root}/scripts/finalizer-transaction.sh"
finalizer_transaction_ready_timeout_seconds=2
finalizer_transaction_rpm_lock_timeout_seconds=5
finalizer_transaction_cgroup_drain_attempts=4

for confined_path in \
	"$runtime_directory" "$state_directory" "$pending_directory" \
	"$unit_directory" "$rpm_lock" "$service_cgroup" "$recovery_cgroup"; do
	[[ "$confined_path" == "${test_root}/"* ]] || \
		fail 'test fixture path escaped /tmp root'
done

path_unit="${finalizer_transaction_activator_units[0]}"
timer_unit="${finalizer_transaction_activator_units[1]}"
service_unit="$finalizer_transaction_service_unit"
recovery_unit="$finalizer_transaction_recovery_unit"

declare -A mock_load=()
declare -A mock_persistent=()
declare -A mock_runtime_mask=()
declare -A mock_active=()
declare -A mock_package_present=()
declare -A mock_package_evr=()
mock_manager_available=1
mock_recovery_load=not-found
mock_recovery_active=inactive
mock_daemon_reload_count=0
mock_fail_daemon_reload_at=0
mock_systemd_run_status=0
mock_recovery_stop_status=0
mock_package_query_count=0
mock_owner_query_count=0
mock_verify_count=0
mock_verify_status=0
mock_publish_ready=1
mock_worker_enqueue_status=0
mock_lock_cycle_mode=0
mock_signal_after_graph_reload=0
mock_graph_opened=0
mock_worker_start_count=0
mock_mask_warning_mode=none
mock_preset_count=0
declare -A mock_preset_state=()

fixture_set_cgroup() {
	local procs="$1" populated="$2" directory="${1%/cgroup.procs}"
	local events="${directory}/cgroup.events"

	[[ "$procs" == "${test_root}/"* && "$directory" != "$procs" ]] || \
		fail 'cgroup fixture escaped test root'
	mkdir -p -- "$directory"
	if [[ "$populated" == 1 ]]; then
		printf '424242\n' > "$procs"
	else
		: > "$procs"
	fi
	printf 'populated %s\nfrozen 0\n' "$populated" > "$events"
	chmod 0644 -- "$procs" "$events"
}

fixture_remove_cgroup() {
	local procs="$1" directory="${1%/cgroup.procs}"

	[[ "$directory" == "${test_root}/"* && "$directory" != "$test_root" ]] || \
		fail 'cgroup removal escaped test root'
	if [[ -d "$directory" && ! -L "$directory" ]]; then
		find "$directory" -mindepth 1 -maxdepth 1 -delete
		rmdir "$directory"
	fi
}

fixture_prepare_direct_recovery() {
	fixture_stop_recovery_process
	fixture_set_cgroup "$recovery_cgroup" 0
}

fixture_clear_state() {
	if [[ -d "$state_directory" && ! -L "$state_directory" ]]; then
		find "$state_directory" -mindepth 1 -maxdepth 1 -delete
		rmdir "$state_directory"
	fi
}

fixture_write_units() {
	local generation="$1" unit

	for unit in "${finalizer_transaction_all_units[@]}"; do
		printf '[Unit]\nDescription=%s %s\n' "$generation" "$unit" \
			> "${unit_directory}/${unit}"
		chmod 0644 -- "${unit_directory}/${unit}"
	done
}

fixture_old_packages() {
	mock_package_present["$finalizer_transaction_common_package"]=1
	mock_package_evr["$finalizer_transaction_common_package"]='0:1.00.23-1'
	mock_package_present["$finalizer_transaction_peer_package"]=1
	mock_package_evr["$finalizer_transaction_peer_package"]='0:1.00.10-1'
	mock_package_present["$finalizer_transaction_setup_package"]=1
	mock_package_evr["$finalizer_transaction_setup_package"]='0:1.00.47-1'
}

fixture_new_packages() {
	mock_package_present["$finalizer_transaction_common_package"]=1
	mock_package_evr["$finalizer_transaction_common_package"]='0:1.00.25-0'
	mock_package_present["$finalizer_transaction_peer_package"]=1
	mock_package_evr["$finalizer_transaction_peer_package"]='0:1.00.12-0'
	mock_package_present["$finalizer_transaction_setup_package"]=1
	mock_package_evr["$finalizer_transaction_setup_package"]='0:1.00.48-0'
}

fixture_reset() {
	local unit

	fixture_stop_recovery_process
	fixture_clear_state
	fixture_remove_cgroup "$recovery_cgroup"
	mkdir -p -- "$runtime_directory" "$pending_directory" "$unit_directory" \
		"${service_cgroup%/*}"
	find "$pending_directory" -mindepth 1 -maxdepth 1 -delete
	find "$unit_directory" -mindepth 1 -maxdepth 1 -delete
	: > "$event_log"
	: > "$call_log"
	rm -f -- "$recovery_gate" "$ofd_attempted" "$ofd_result" "$ofd_acquired" "$holder_ready" \
		"$lock_cycle_setup_ready" "$lock_cycle_setup_gate" \
		"$lock_cycle_setup_attempt" "$lock_cycle_setup_acquired" \
		"$lock_cycle_worker_attempt" "$lock_cycle_worker_acquired" \
		"$lock_cycle_worker_status" \
		"$lock_cycle_recovery_status" "$lock_cycle_order" \
		"${test_root}/handoff.executed"
	fixture_set_cgroup "$service_cgroup" 0
	mock_manager_available=1
	mock_recovery_load=not-found
	mock_recovery_active=inactive
	mock_daemon_reload_count=0
	mock_fail_daemon_reload_at=0
	mock_systemd_run_status=0
	mock_recovery_stop_status=0
	mock_package_query_count=0
	mock_owner_query_count=0
	mock_verify_count=0
	mock_verify_status=0
	mock_publish_ready=1
	mock_worker_enqueue_status=0
	mock_lock_cycle_mode=0
	mock_signal_after_graph_reload=0
	mock_graph_opened=0
	mock_worker_start_count=0
	mock_mask_warning_mode=none
	mock_preset_count=0
	mock_preset_state=()
	for unit in "${finalizer_transaction_all_units[@]}"; do
		mock_load["$unit"]=loaded
		mock_runtime_mask["$unit"]=0
		mock_active["$unit"]=active
	done
	mock_active["$service_unit"]=active
	mock_persistent["$path_unit"]=enabled
	mock_persistent["$timer_unit"]=enabled
	mock_persistent["$service_unit"]=static
	fixture_write_units old
	fixture_old_packages
	finalizer_transaction_nonce=""
	finalizer_transaction_rpm_lock_fd=""
	finalizer_transaction_phase="idle"
}

mock_unit_arguments() {
	local output_variable="$1"
	shift
	local argument
	local -a result=()

	for argument in "$@"; do
		[[ "$argument" == -* ]] && continue
		result+=("$argument")
	done
	local serialized_units="${result[*]}"
	printf -v "$output_variable" '%s' "$serialized_units"
}

finalizer_transaction_run_systemctl() {
	local command="${1:-}" property unit units joined runtime=0
	shift || :
	printf '%s\n' "${command} $*" >> "$call_log"
	case "$command" in
		show)
			property="${1#--property=}"
			if [[ "$property" == Version ]]; then
				((mock_manager_available == 1)) || return 69
				printf '258\n'
				return 0
			fi
			unit="${*: -1}"
			case "$property" in
				LoadState)
					if [[ "$unit" == "$recovery_unit" ]]; then
						printf '%s\n' "$mock_recovery_load"
					else
						printf '%s\n' "${mock_load[$unit]:-not-found}"
					fi
					;;
				UnitFileState)
					if [[ "${mock_runtime_mask[$unit]:-0}" -eq 1 ]]; then
						printf 'masked-runtime\n'
					elif [[ "${mock_load[$unit]:-not-found}" == not-found ]]; then
						# systemd 259 emits exactly one empty line here.
						printf '\n'
					else
						printf '%s\n' "${mock_persistent[$unit]:-disabled}"
					fi
					;;
				ActiveState)
					if [[ "$unit" == "$recovery_unit" ]]; then
						printf '%s\n' "$mock_recovery_active"
					else
						printf '%s\n' "${mock_active[$unit]:-inactive}"
					fi
					;;
				*) return 64 ;;
			esac
			;;
		mask)
			[[ " $* " == *' --runtime '* && " $* " == *' --no-reload '* && \
				" $* " != *' sound.target '* ]] || return 66
			[[ "${LC_ALL:-}" == C ]] || return 67
			mock_unit_arguments joined "$@"
			printf 'MASK %s\n' "$joined" >> "$event_log"
			for unit in $joined; do mock_runtime_mask["$unit"]=1; done
			case "$mock_mask_warning_mode" in
				none) ;;
				expected)
					for unit in $joined; do
						if [[ "${finalizer_transaction_snapshot_unit_load[$unit]:-}" == not-found ]]; then
							printf 'Unit %s does not exist, proceeding anyway.\n' "$unit" >&2
						fi
					done
					;;
				unexpected)
					printf 'unexpected manager warning\n' >&2
					;;
				wrong-unit)
					printf 'Unit unrelated.service does not exist, proceeding anyway.\n' >&2
					;;
				missing-newline)
					printf 'Unit %s does not exist, proceeding anyway.' "$path_unit" >&2
					;;
				duplicate)
					printf 'Unit %s does not exist, proceeding anyway.\n' "$path_unit" >&2
					printf 'Unit %s does not exist, proceeding anyway.\n' "$path_unit" >&2
					;;
				status)
					printf 'Unit %s does not exist, proceeding anyway.\n' "$path_unit" >&2
					return 73
					;;
				stdout)
					printf 'unexpected mask output\n'
					;;
				*) return 68 ;;
			esac
			;;
		unmask)
			[[ " $* " == *' --runtime '* && " $* " == *' --no-reload '* && \
				" $* " != *' sound.target '* ]] || return 66
			mock_unit_arguments joined "$@"
			printf 'UNMASK %s\n' "$joined" >> "$event_log"
			for unit in $joined; do mock_runtime_mask["$unit"]=0; done
			if [[ "$joined" == "$service_unit" ]]; then
				mock_graph_opened=1
			fi
			;;
		preset)
			[[ " $* " == *' --no-reload '* && " $* " == *' --quiet '* && \
				" $* " != *' --runtime '* ]] || return 66
			[[ "${LC_ALL:-}" == C ]] || return 67
			mock_unit_arguments joined "$@"
			[[ -n "$joined" && "$joined" != *' '* ]] || return 68
			unit="$joined"
			[[ "${finalizer_transaction_snapshot_unit_load[$unit]:-}" == not-found && \
				"${finalizer_transaction_snapshot_unit_file_state[$unit]:-}" == not-found && \
				"${finalizer_transaction_snapshot_unit_active[$unit]:-}" == not-found && \
				"${finalizer_transaction_snapshot_unit_present[$unit]:-}" == 0 && \
				"${mock_load[$unit]:-}" == loaded ]] || return 69
			((mock_preset_count += 1))
			mock_persistent["$unit"]="${mock_preset_state[$unit]:-${finalizer_transaction_new_unit_file_state[$unit]}}"
			printf 'PRESET %s\n' "$unit" >> "$event_log"
			;;
		daemon-reload)
			((mock_daemon_reload_count += 1))
			printf 'DAEMON-RELOAD %s\n' "$mock_daemon_reload_count" >> "$event_log"
			if [[ "$mock_fail_daemon_reload_at" -eq "$mock_daemon_reload_count" ]]; then
				return 71
			fi
			if [[ "$mock_signal_after_graph_reload" -eq 1 && \
				"$mock_graph_opened" -eq 1 ]]; then
				mock_signal_after_graph_reload=0
				kill -TERM "$BASHPID"
				/usr/bin/sleep 1
			fi
			;;
		stop)
			mock_unit_arguments joined "$@"
			if [[ "$joined" == "$recovery_unit" ]]; then
				printf 'STOP-RECOVERY\n' >> "$event_log"
				if [[ "$mock_recovery_stop_status" -ne 0 ]]; then
					return "$mock_recovery_stop_status"
				fi
				fixture_stop_recovery_process
				mock_recovery_active=inactive
				fixture_set_cgroup "$recovery_cgroup" 0
			elif [[ "$joined" == "$service_unit" ]]; then
				printf 'STOP-SERVICE\n' >> "$event_log"
				mock_active["$service_unit"]=inactive
				fixture_set_cgroup "$service_cgroup" 0
			else
				printf 'STOP-ACTIVATORS %s\n' "$joined" >> "$event_log"
				for unit in $joined; do mock_active["$unit"]=inactive; done
			fi
			;;
		start)
			mock_unit_arguments joined "$@"
			for unit in $joined; do
				[[ "${mock_runtime_mask[$unit]:-0}" -eq 0 ]] || {
					printf 'REJECTED-START %s\n' "$unit" >> "$event_log"
					return 73
				}
				[[ " $* " == *' --no-block '* ]] || return 74
				if [[ "$unit" == "$service_unit" ]]; then
					mock_active["$unit"]=inactive
					printf 'START-SERVICE\n' >> "$event_log"
				else
					mock_active["$unit"]=active
					printf 'START-ACTIVATOR %s\n' "$unit" >> "$event_log"
				fi
			done
			;;
		--no-block) return 64 ;;
		reset-failed)
			unit="${1:-}"
			if [[ "$unit" == "$recovery_unit" ]]; then
				mock_recovery_load=not-found
				mock_recovery_active=inactive
				fixture_remove_cgroup "$recovery_cgroup"
			fi
			;;
		enable|disable)
			return 72
			;;
		*) return 64 ;;
	esac
}

finalizer_transaction_run_worker_systemctl() {
	local inherited_rpm_fd worker_global_fd worker_status=0

	((finalizer_transaction_worker_timeout_seconds >= 1260)) || return 70
	((mock_worker_start_count += 1))
	printf 'WORKER-TIMEOUT %s\n' "$finalizer_transaction_worker_timeout_seconds" >> "$event_log"
	((mock_worker_enqueue_status == 0)) || return "$mock_worker_enqueue_status"
	if [[ "$mock_lock_cycle_mode" -eq 1 && " $* " == *" $service_unit "* ]]; then
		[[ " $* " == *' --no-block '* ]] || return 74
		printf 'go\n' > "$lock_cycle_setup_gate"
		wait_for_file "$lock_cycle_setup_attempt" || return 75
		inherited_rpm_fd="${finalizer_transaction_rpm_lock_fd:-}"
		(
			if [[ "$inherited_rpm_fd" =~ ^[0-9]+$ ]]; then
				exec {inherited_rpm_fd}<&-
			fi
			exec {worker_global_fd}<>"$lock_cycle_global"
			printf 'attempt\n' > "$lock_cycle_worker_attempt"
			printf 'WORKER-GLOBAL-ATTEMPT\n' >> "$lock_cycle_order"
			/usr/bin/flock --exclusive --timeout 5 "$worker_global_fd" || worker_status=$?
			if [[ "$worker_status" -eq 0 ]]; then
				printf 'WORKER-GLOBAL-ACQUIRED\n' >> "$lock_cycle_order"
				printf 'acquired\n' > "$lock_cycle_worker_acquired"
			fi
			printf '%s\n' "$worker_status" > "$lock_cycle_worker_status"
			exit "$worker_status"
		) >/dev/null 2>&1 &
		wait_for_file "$lock_cycle_worker_attempt" || return 76
	fi
	finalizer_transaction_run_systemctl "$@"
}

finalizer_transaction_run_systemd_run() {
	local index env_index=-1 command_index=-1
	local child_stdout child_stderr
	local -a arguments=("$@") handoff_environment=() expected_environment=()
	local -a expected_prefix=(
		--quiet
		--no-block
		--collect
		"--unit=${finalizer_transaction_recovery_unit}"
		--service-type=exec
		--property=KillMode=control-group
		--property=TimeoutStopSec=15s
		--property=Restart=on-failure
		--property=RestartSec=5s
		--property=StartLimitIntervalSec=0
		--property=RestartPreventExitStatus=75
		--expand-environment=no
	)

	for ((index = 0; index < ${#arguments[@]}; index++)); do
		if [[ "${arguments[index]}" == "$finalizer_transaction_env_command" ]]; then
			env_index="$index"
			break
		fi
	done
	[[ "$env_index" -eq "${#expected_prefix[@]}" ]] || return 65
	for ((index = 0; index < ${#expected_prefix[@]}; index++)); do
		[[ "${arguments[index]}" == "${expected_prefix[index]}" ]] || return 65
	done
	((env_index + 2 < ${#arguments[@]})) || return 65
	[[ "${arguments[env_index + 1]}" == -i ]] || return 65
	for ((index = env_index + 2; index < ${#arguments[@]}; index++)); do
		[[ "${arguments[index]}" != "$finalizer_transaction_bash_command" ]] || break
		[[ "${arguments[index]}" == [A-Z_]*=* ]] || return 65
		handoff_environment+=("${arguments[index]}")
	done
	[[ "$index" -eq $((${#arguments[@]} - 6)) && \
		"${arguments[index]}" == "$finalizer_transaction_bash_command" && \
		"${arguments[index + 1]}" == --noprofile && \
		"${arguments[index + 2]}" == --norc && \
		"${arguments[index + 3]}" == "$finalizer_transaction_helper_copy_path" && \
		"${arguments[index + 4]}" == --recover && \
		"${arguments[index + 5]}" == "$finalizer_transaction_nonce" ]] || return 65
	command_index="$index"
	expected_environment=(
		PATH=/usr/bin:/usr/sbin
		"GALAXYBOOK_FINALIZER_FAMILY=${finalizer_transaction_config_value[family]}"
		"GALAXYBOOK_FINALIZER_COMMON_PACKAGE=${finalizer_transaction_config_value[common]}"
		"GALAXYBOOK_FINALIZER_OWN_FLOOR=${finalizer_transaction_config_value[own_floor]}"
		"GALAXYBOOK_FINALIZER_PEER_PACKAGE=${finalizer_transaction_config_value[peer]}"
		"GALAXYBOOK_FINALIZER_PEER_FLOOR=${finalizer_transaction_config_value[peer_floor]}"
		"GALAXYBOOK_FINALIZER_SETUP_PACKAGE=${finalizer_transaction_config_value[setup]}"
		"GALAXYBOOK_FINALIZER_SETUP_FLOOR=${finalizer_transaction_config_value[setup_floor]}"
		"GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS=${finalizer_transaction_config_value[activators]}"
		"GALAXYBOOK_FINALIZER_DEPENDENT_UNITS=${finalizer_transaction_config_value[dependents]}"
		"GALAXYBOOK_FINALIZER_SERVICE_UNIT=${finalizer_transaction_config_value[service]}"
		"GALAXYBOOK_FINALIZER_PENDING_DIRECTORY=${finalizer_transaction_config_value[pending]}"
		"GALAXYBOOK_FINALIZER_RECOVERY_UNIT=${finalizer_transaction_config_value[recovery]}"
		"GALAXYBOOK_FINALIZER_STATE_DIRECTORY=${finalizer_transaction_config_value[state_directory]}"
		"GALAXYBOOK_FINALIZER_SERVICE_CGROUP=${finalizer_transaction_config_value[service_cgroup]}"
	)
	[[ "${#handoff_environment[@]}" -eq "${#expected_environment[@]}" ]] || return 65
	for ((index = 0; index < ${#expected_environment[@]}; index++)); do
		[[ "${handoff_environment[index]}" == "${expected_environment[index]}" ]] || return 65
	done
	printf 'ARM\n' >> "$event_log"
	mock_recovery_load=loaded
	mock_recovery_active=activating
	fixture_set_cgroup "$recovery_cgroup" 1
	((mock_systemd_run_status == 0)) || return "$mock_systemd_run_status"
	child_stdout="${test_root}/handoff-${finalizer_transaction_nonce}.out"
	child_stderr="${test_root}/handoff-${finalizer_transaction_nonce}.err"
	/usr/bin/env -i "${handoff_environment[@]}" \
		"TEST_FINALIZER_ROOT=${test_root}" \
		"TEST_FINALIZER_RUNTIME=${runtime_directory}" \
		"TEST_FINALIZER_STATE=${state_directory}" \
		"TEST_FINALIZER_PENDING=${pending_directory}" \
		"TEST_FINALIZER_UNITS=${unit_directory}" \
		"TEST_FINALIZER_SERVICE_CGROUP=${service_cgroup}" \
		"TEST_FINALIZER_RECOVERY_CGROUP=${recovery_cgroup}" \
		"TEST_FINALIZER_RPM_LOCK=${rpm_lock}" \
		"TEST_FINALIZER_EVENT_LOG=${event_log}" \
		"TEST_FINALIZER_GATE=${recovery_gate}" \
		"TEST_FINALIZER_PUBLISH_READY=${mock_publish_ready}" \
		"BASH_ENV=${handoff_hook}" \
		"${arguments[@]:command_index:6}" >"$child_stdout" 2>"$child_stderr" &
	mock_recovery_pid=$!
}

finalizer_transaction_publish_ready() {
	finalizer_transaction_publish_ready_original || return 1
	printf 'RECOVERY-READY\n' >> "$event_log"
}

finalizer_transaction_query_package() {
	local package="$1" require_lock="${2:-0}"

	((mock_package_query_count += 1))
	[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock || return 1
	finalizer_transaction_package_query_present="${mock_package_present[$package]:-0}"
	if [[ "$finalizer_transaction_package_query_present" -eq 1 ]]; then
		finalizer_transaction_package_query_evr="${mock_package_evr[$package]:-}"
		finalizer_transaction_evr_is_safe "$finalizer_transaction_package_query_evr" || return 1
	else
		finalizer_transaction_package_query_evr=""
	fi
	[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock
}

finalizer_transaction_query_unit_file_owner() {
	local path="$1" require_lock="${2:-1}"

	((mock_owner_query_count += 1))
	finalizer_transaction_file_metadata_is_safe "$path" || return 1
	[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock || return 1
	finalizer_transaction_unit_file_owner_evr="${mock_package_evr[$finalizer_transaction_common_package]}"
	[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock
}

finalizer_transaction_verify_common_package() {
	((mock_verify_count += 1))
	printf 'RPM-VERIFY\n' >> "$event_log"
	finalizer_transaction_validate_rpm_lock || return 1
	((mock_verify_status == 0)) || return "$mock_verify_status"
	finalizer_transaction_validate_rpm_lock
}

close_recovery_lock() {
	local fd="${finalizer_transaction_rpm_lock_fd:-}"

	if [[ "$fd" =~ ^[0-9]+$ ]]; then
		exec {fd}<&-
	fi
	finalizer_transaction_rpm_lock_fd=""
}

emit_stderr_with_success() {
	printf 'value\n'
	printf 'warning\n' >&2
}

emit_two_lines() {
	printf 'one\ntwo\n'
}

emit_without_newline() {
	printf 'value'
}

# CLI bytes and strict command-capture semantics.
fixture_reset
finalizer_transaction_ensure_state_directory
set +e
(finalizer_transaction_main) >"${test_root}/cli.out" 2>"${test_root}/cli.err"
cli_status=$?
set -e
assert_equal 2 "$cli_status" 'zero-argument CLI status'
[[ ! -s "${test_root}/cli.out" ]] || fail 'usage leaked to stdout'
[[ "$(wc -l < "${test_root}/cli.err")" -eq 3 ]] || fail 'usage stderr was not exact'
if finalizer_transaction_capture_one_line captured emit_stderr_with_success; then
	fail 'strict capture accepted stderr with status zero'
fi
if finalizer_transaction_capture_one_line captured emit_two_lines; then
	fail 'strict capture accepted multiple stdout lines'
fi
if finalizer_transaction_capture_one_line captured emit_without_newline; then
	fail 'strict capture accepted stdout without a terminal newline'
fi

# Production wrappers keep quick manager calls at 120s while allowing the
# 20-minute worker/dependent units one additional minute of client-side margin.
timeout_command_fixture="${test_root}/timeout-command-fixture"
cat > "$timeout_command_fixture" <<'TIMEOUT_COMMAND_FIXTURE'
#!/usr/bin/bash
set -euo pipefail

{
	printf '%s' "${SYSTEMD_BUS_TIMEOUT:?}"
	for argument in "$@"; do printf '\t%s' "$argument"; done
	printf '\n'
} > "${TEST_TIMEOUT_LOG:?}"
TIMEOUT_COMMAND_FIXTURE
chmod 0700 -- "$timeout_command_fixture"
saved_timeout_command="$finalizer_transaction_timeout_command"
finalizer_transaction_timeout_command="$timeout_command_fixture"
export TEST_TIMEOUT_LOG="${test_root}/quick-timeout.args"
finalizer_transaction_run_systemctl_original show --property=Version --value
printf '%s\n' $'15s\t--foreground\t--signal=TERM\t--kill-after=5s\t120s\t/usr/bin/systemctl\t--no-ask-password\tshow\t--property=Version\t--value' \
	> "${test_root}/quick-timeout.expected"
cmp --silent -- "${test_root}/quick-timeout.expected" "$TEST_TIMEOUT_LOG" || \
	fail 'quick systemctl timeout arguments changed'
export TEST_TIMEOUT_LOG="${test_root}/worker-timeout.args"
finalizer_transaction_run_worker_systemctl_original start "$service_unit"
printf '%s\n' $'1260s\t--foreground\t--signal=TERM\t--kill-after=5s\t1260s\t/usr/bin/systemctl\t--no-ask-password\tstart\tgalaxybook-ov02c10-finalize.service' \
	> "${test_root}/worker-timeout.expected"
cmp --silent -- "${test_root}/worker-timeout.expected" "$TEST_TIMEOUT_LOG" || \
	fail 'worker systemctl timeout arguments changed'
export TEST_TIMEOUT_LOG="${test_root}/systemd-run-timeout.args"
finalizer_transaction_run_systemd_run_original --quiet --unit=fixture.service /usr/bin/true
printf '%s\n' $'15s\t--foreground\t--signal=TERM\t--kill-after=5s\t120s\t/usr/bin/systemd-run\t--no-ask-password\t--quiet\t--unit=fixture.service\t/usr/bin/true' \
	> "${test_root}/systemd-run-timeout.expected"
cmp --silent -- "${test_root}/systemd-run-timeout.expected" "$TEST_TIMEOUT_LOG" || \
	fail 'systemd-run timeout arguments changed'
unset TEST_TIMEOUT_LOG
finalizer_transaction_timeout_command="$saved_timeout_command"

# systemd emits one documented warning for each nonexistent unit that it masks.
# Accept only exact C-locale lines for units whose authenticated snapshot proved
# absence; every other status, stream or byte sequence remains fail-closed.
fixture_reset
for unit in "$path_unit" "$service_unit"; do
	rm -f -- "${unit_directory}/${unit}"
	mock_load["$unit"]=not-found
	mock_persistent["$unit"]=not-found
	mock_active["$unit"]=not-found
done
finalizer_transaction_ensure_state_directory
finalizer_transaction_snapshot_units
mock_mask_warning_mode=expected
finalizer_transaction_mask_units
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" \
		"expected-warning mask state for ${unit}"
done
for invalid_mask_warning_mode in unexpected wrong-unit missing-newline duplicate status stdout; do
	mock_mask_warning_mode="$invalid_mask_warning_mode"
	if finalizer_transaction_mask_units; then
		fail "mask parser accepted ${invalid_mask_warning_mode} output"
	fi
done
fixture_reset
finalizer_transaction_ensure_state_directory

# Recursive cgroup.events, not an empty root cgroup.procs, is the drain proof.
: > "$service_cgroup"
printf 'populated 1\nfrozen 0\n' > "$service_cgroup_events"
finalizer_transaction_cgroup_state cgroup_state "$service_cgroup"
assert_equal populated "$cgroup_state" 'descendant-only cgroup population'
(
	/usr/bin/sleep 0.08
	printf 'populated 0\nfrozen 0\n' > "$service_cgroup_events"
) &
drain_writer_pid=$!
finalizer_transaction_assert_cgroup_empty "$service_cgroup"
wait "$drain_writer_pid"
printf 'populated 0' > "$service_cgroup_events"
if finalizer_transaction_cgroup_state cgroup_state "$service_cgroup"; then
	fail 'cgroup.events without terminal newline was accepted'
fi
fixture_set_cgroup "$service_cgroup" 0

# Pending-path classification is fail-closed.  Only a trusted directory with
# no markers means "empty" (status 1); every missing or unsafe pathname is an
# operational failure (status 2), never authority to commit.
pending_status=0
finalizer_transaction_has_pending_marker || pending_status=$?
assert_equal 1 "$pending_status" 'trusted empty pending-directory status'
rmdir "$pending_directory"
pending_status=0
finalizer_transaction_has_pending_marker || pending_status=$?
assert_equal 2 "$pending_status" 'missing pending-directory status'
ln -s -- "$test_root" "$pending_directory"
pending_status=0
finalizer_transaction_has_pending_marker || pending_status=$?
assert_equal 2 "$pending_status" 'symlinked pending-directory status'
unlink "$pending_directory"
: > "$pending_directory"
pending_status=0
finalizer_transaction_has_pending_marker || pending_status=$?
assert_equal 2 "$pending_status" 'non-directory pending pathname status'
unlink "$pending_directory"
mkdir -m 0777 -- "$pending_directory"
pending_status=0
finalizer_transaction_has_pending_marker || pending_status=$?
assert_equal 2 "$pending_status" 'unsafe pending-directory metadata status'
chmod 0700 -- "$pending_directory"

# Exercise the production rpm parsers themselves against a confined command
# fixture.  Status, stderr, record count, fields and terminal newline are all
# authoritative; the higher-level recovery mocks below do not replace this
# byte-level matrix.
rpm_command_fixture="${test_root}/rpm-command-fixture"
cat > "$rpm_command_fixture" <<'RPM_COMMAND_FIXTURE'
#!/usr/bin/bash
set -euo pipefail

mode="${MOCK_RPM_MODE:?}"
operation=""
package="${!#}"
actual=("$@")
query_format=$'%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\n'
case "${1:-}" in
	--verify)
		operation=verify
		expected=(--verify --nodeps --noscripts --nomtime --nosize -- \
			"$GALAXYBOOK_FINALIZER_COMMON_PACKAGE")
		;;
	-qf)
		operation=owner
		expected=(-qf --qf "$query_format" -- "$package")
		;;
	-q)
		if [[ "${2:-}" == --quiet ]]; then
			operation=quiet
			expected=(-q --quiet -- "$package")
		else
			operation=package
			expected=(-q --qf "$query_format" -- "$package")
		fi
		;;
	*) exit 63 ;;
esac
[[ "$#" -eq "${#expected[@]}" ]] || exit 63
for ((argument_index = 0; argument_index < ${#expected[@]}; argument_index++)); do
	[[ "${actual[argument_index]}" == "${expected[argument_index]}" ]] || exit 63
done
if [[ "${MOCK_RPM_REPLACE_LOCK:-0}" == 1 ]]; then
	lock_path="${TEST_RPM_LOCK_PATH:?}"
	[[ "$lock_path" == /tmp/ov02c10-finalizer-transaction.* ]] || exit 63
	/usr/bin/rm -- "$lock_path"
	(umask 077; : > "$lock_path")
fi
if [[ "$operation" == verify ]]; then
	case "$mode" in
		verify-output) printf 'S.5....T. /owned/unit\n' ;;
		verify-stderr) printf 'verify warning\n' >&2 ;;
		verify-status) exit 2 ;;
	esac
	exit 0
fi
if [[ "$operation" == quiet ]]; then
	case "$mode" in
		absent) exit 1 ;;
		quiet-stderr) printf 'lock warning\n' >&2; exit 0 ;;
		quiet-status) exit 2 ;;
	esac
	exit 0
fi
name="$package"
[[ "$operation" == package ]] || name="$GALAXYBOOK_FINALIZER_COMMON_PACKAGE"
case "$mode" in
	query-stderr|owner-stderr)
		printf '%s\t0\t1.00.25\t0\n' "$name"
		printf 'unexpected warning\n' >&2
		;;
	query-missing-newline|owner-missing-newline)
		printf '%s\t0\t1.00.25\t0' "$name"
		;;
	query-duplicate)
		printf '%s\t0\t1.00.25\t0\n%s\t0\t1.00.25\t0\n' "$name" "$name"
		;;
	query-extra-field)
		printf '%s\t0\t1.00.25\t0\textra\n' "$name"
		;;
	query-status|owner-status)
		exit 2
		;;
	owner-wrong)
		printf 'unrelated-package\t0\t1.00.25\t0\n'
		;;
	*)
		printf '%s\t0\t1.00.25\t0\n' "$name"
		;;
esac
RPM_COMMAND_FIXTURE
chmod 0700 -- "$rpm_command_fixture"
saved_rpm_command="$finalizer_transaction_rpm_command"
finalizer_transaction_rpm_command="$rpm_command_fixture"
export TEST_RPM_LOCK_PATH="$rpm_lock"
export MOCK_RPM_MODE=canonical
finalizer_transaction_query_package_original \
	"$finalizer_transaction_common_package" 0
assert_equal 1 "$finalizer_transaction_package_query_present" 'canonical package presence'
assert_equal 0:1.00.25-0 "$finalizer_transaction_package_query_evr" 'canonical package EVR'
export MOCK_RPM_MODE=absent
finalizer_transaction_query_package_original \
	"$finalizer_transaction_common_package" 0
assert_equal 0 "$finalizer_transaction_package_query_present" 'absent package presence'
for invalid_mode in quiet-stderr quiet-status query-stderr query-missing-newline \
	query-duplicate query-extra-field query-status; do
	export MOCK_RPM_MODE="$invalid_mode"
	if finalizer_transaction_query_package_original \
		"$finalizer_transaction_common_package" 0; then
		fail "package parser accepted ${invalid_mode}"
	fi
done
export MOCK_RPM_MODE=owner-canonical
finalizer_transaction_query_unit_file_owner_original \
	"${unit_directory}/${path_unit}" 0
assert_equal 0:1.00.25-0 "$finalizer_transaction_unit_file_owner_evr" \
	'canonical unit owner EVR'
for invalid_mode in owner-stderr owner-missing-newline owner-status owner-wrong; do
	export MOCK_RPM_MODE="$invalid_mode"
	if finalizer_transaction_query_unit_file_owner_original \
		"${unit_directory}/${path_unit}" 0; then
		fail "unit-owner parser accepted ${invalid_mode}"
	fi
done
for verify_mode in canonical verify-output verify-stderr verify-status; do
	export MOCK_RPM_MODE="$verify_mode"
	verify_status=0
	finalizer_transaction_verify_common_package_original 0 || verify_status=$?
	if [[ "$verify_mode" == canonical ]]; then
		assert_equal 0 "$verify_status" 'canonical rpm verify status'
	else
		[[ "$verify_status" -ne 0 ]] || fail "rpm verify accepted ${verify_mode}"
	fi
done

open_parser_lock() {
	local fd

	[[ -f "$rpm_lock" && ! -L "$rpm_lock" ]] || {
		(umask 077; : > "$rpm_lock")
	}
	chmod 0600 -- "$rpm_lock"
	exec {fd}<"$rpm_lock"
	/usr/bin/flock --fcntl --shared "$fd"
	finalizer_transaction_rpm_lock_fd="$fd"
}

close_parser_lock() {
	close_recovery_lock
	/usr/bin/rm -f -- "$rpm_lock"
	(umask 077; : > "$rpm_lock")
}

# The production parsers and verifier must remain coupled to the same shared
# OFD/inode before and after every strict RPM operation.
export MOCK_RPM_MODE=canonical
open_parser_lock
finalizer_transaction_query_package_original \
	"$finalizer_transaction_common_package" 1
finalizer_transaction_query_unit_file_owner_original \
	"${unit_directory}/${path_unit}" 1
finalizer_transaction_verify_common_package_original 1
close_parser_lock
for locked_operation in package owner verify; do
	export MOCK_RPM_MODE=canonical MOCK_RPM_REPLACE_LOCK=1
	open_parser_lock
	locked_status=0
	case "$locked_operation" in
		package)
			finalizer_transaction_query_package_original \
				"$finalizer_transaction_common_package" 1 || locked_status=$?
			;;
		owner)
			finalizer_transaction_query_unit_file_owner_original \
				"${unit_directory}/${path_unit}" 1 || locked_status=$?
			;;
		verify)
			finalizer_transaction_verify_common_package_original 1 || locked_status=$?
			;;
	esac
	[[ "$locked_status" -ne 0 ]] || \
		fail "${locked_operation} accepted a replaced RPM lock inode"
	unset MOCK_RPM_REPLACE_LOCK
	close_parser_lock
done
unset MOCK_RPM_MODE
unset TEST_RPM_LOCK_PATH
finalizer_transaction_rpm_command="$saved_rpm_command"

# Production TERM/EXIT traps preserve the phase invariant.  Before READY they
# retire/clean partial authority; during rearm they re-mask and drain while the
# still-present state remains restartable.
fixture_reset
finalizer_transaction_copy_helper() {
	kill -TERM "$BASHPID"
	/usr/bin/sleep 1
}
set +e
(finalizer_transaction_main 2) \
	>"${test_root}/trap-building.out" 2>"${test_root}/trap-building.err"
trap_status=$?
set -e
assert_equal 143 "$trap_status" 'pre-READY TERM status'
assert_absent "$finalizer_transaction_state_path" 'pre-READY TERM retained state'
assert_absent "$finalizer_transaction_helper_copy_path" 'pre-READY TERM retained helper'
if event_line ARM >/dev/null 2>&1 || event_line MASK >/dev/null 2>&1; then
	fail 'pre-READY TERM armed or opened transaction fencing'
fi
finalizer_transaction_copy_helper() {
	finalizer_transaction_copy_helper_original "$@"
}

fixture_reset
finalizer_transaction_pretrans 2
trap_recovery_nonce="$finalizer_transaction_nonce"
fixture_stop_recovery_process
fixture_set_cgroup "$recovery_cgroup" 0
fixture_new_packages
fixture_write_units new
: > "$event_log"
mock_signal_after_graph_reload=1
set +e
(finalizer_transaction_main --recover "$trap_recovery_nonce") \
	>"${test_root}/trap-rearm.out" 2>"${test_root}/trap-rearm.err"
trap_status=$?
set -e
assert_equal 143 "$trap_status" 'rearm TERM status'
unmask_line="$(last_event_line UNMASK)"
mask_line="$(last_event_line MASK)"
[[ "$unmask_line" -lt "$mask_line" ]] || fail 'rearm TERM did not restore runtime mask'
assert_exists "$finalizer_transaction_state_path" 'rearm TERM removed restart state'
activator_stop_line="$(last_event_line STOP-ACTIVATORS)"
service_stop_line="$(last_event_line STOP-SERVICE)"
[[ "$mask_line" -lt "$activator_stop_line" && \
	"$activator_stop_line" -lt "$service_stop_line" ]] || \
	fail 'rearm TERM did not complete mask/stop rollback'
assert_equal empty "$(finalizer_transaction_cgroup_state cgroup_state "$service_cgroup"; printf '%s' "$cgroup_state")" \
	'rearm TERM did not drain the worker cgroup'

# First installation and offline roots are literal no-ops.
fixture_reset
finalizer_transaction_pretrans 1
finalizer_transaction_posttrans 1
[[ ! -s "$event_log" && ! -s "$call_log" ]] || fail 'first install contacted systemd'
assert_absent "$state_directory" 'first install created runtime state'
ln -s -- "$test_root" "$state_directory"
if finalizer_transaction_posttrans 1 >/dev/null 2>&1; then
	fail 'posttrans treated unsafe state-directory symlink as absent'
fi
unlink "$state_directory"
rmdir "$runtime_directory"
finalizer_transaction_pretrans 2
[[ ! -s "$event_log" && ! -s "$call_log" ]] || fail 'offline root contacted systemd'
assert_absent "$state_directory" 'offline root created runtime state'
ln -s -- "$test_root" "$runtime_directory"
if finalizer_transaction_pretrans 2 >/dev/null 2>&1; then
	fail 'symlinked systemd runtime was treated as offline'
fi
unlink "$runtime_directory"
mkdir -p -- "$runtime_directory"
mock_manager_available=0
if finalizer_transaction_pretrans 2 >/dev/null 2>&1; then
	fail 'unreachable live systemd manager was treated as offline'
fi
assert_absent "$state_directory" 'unreachable manager created runtime state'

# An upgrade from a legacy package with no managed unit graph still needs a
# transaction fence.  RPM's systemd macros do not preset newly introduced units
# on an upgrade, so all-new recovery presets only authenticated snapshot
# absences before it reloads and rearms the graph.
fixture_reset
find "$unit_directory" -mindepth 1 -maxdepth 1 -delete
for unit in "${finalizer_transaction_all_units[@]}"; do
	mock_load["$unit"]=not-found
	mock_persistent["$unit"]=not-found
	mock_active["$unit"]=not-found
done
mock_mask_warning_mode=expected
finalizer_transaction_pretrans 2
assert_equal 0 "$mock_package_query_count" 'legacy no-unit pretrans queried rpmdb'
assert_exists "$finalizer_transaction_state_path" 'legacy no-unit pretrans omitted state'
event_line ARM >/dev/null || fail 'legacy no-unit pretrans did not arm recovery'
event_line MASK >/dev/null || fail 'legacy no-unit pretrans did not fence unit names'
legacy_no_unit_nonce="$finalizer_transaction_nonce"
fixture_new_packages
fixture_write_units new
for unit in "${finalizer_transaction_all_units[@]}"; do
	mock_load["$unit"]=loaded
	mock_persistent["$unit"]=disabled
	mock_active["$unit"]=inactive
done
mock_mask_warning_mode=none
fixture_prepare_direct_recovery
: > "$event_log"
finalizer_transaction_recover "$legacy_no_unit_nonce"
close_recovery_lock
assert_equal 3 "$mock_preset_count" 'legacy no-unit preset count'
first_unmask_line="$(event_line "UNMASK ${path_unit} ${timer_unit}")"
path_preset_line="$(event_line "PRESET ${path_unit}")"
timer_preset_line="$(event_line "PRESET ${timer_unit}")"
service_unmask_line="$(event_line "UNMASK ${service_unit}")"
service_preset_line="$(event_line "PRESET ${service_unit}")"
reload_line="$(last_event_line DAEMON-RELOAD)"
[[ "$first_unmask_line" -lt "$path_preset_line" && \
	"$path_preset_line" -lt "$timer_preset_line" && \
	"$timer_preset_line" -lt "$service_unmask_line" && \
	"$service_unmask_line" -lt "$service_preset_line" && \
	"$service_preset_line" -lt "$reload_line" ]] || \
	fail 'legacy no-unit unmask/preset/reload ordering was not strict'
assert_equal enabled "${mock_persistent[$path_unit]}" 'legacy path preset result'
assert_equal enabled "${mock_persistent[$timer_unit]}" 'legacy timer preset result'
assert_equal static "${mock_persistent[$service_unit]}" 'legacy service preset result'
assert_equal active "${mock_active[$path_unit]}" 'legacy path activation'
assert_equal active "${mock_active[$timer_unit]}" 'legacy timer activation'
assert_equal inactive "${mock_active[$service_unit]}" 'legacy worker activation'
assert_absent "$finalizer_transaction_state_path" 'legacy no-unit recovery retained state'

# Administrator presets override vendor defaults without allowing RPM scriptlets
# to call enable/disable.  Recovery records the effective state and does not
# activate disabled units when no durable marker needs retry coverage.
fixture_reset
find "$unit_directory" -mindepth 1 -maxdepth 1 -delete
for unit in "${finalizer_transaction_all_units[@]}"; do
	mock_load["$unit"]=not-found
	mock_persistent["$unit"]=not-found
	mock_active["$unit"]=not-found
done
finalizer_transaction_pretrans 2
admin_preset_nonce="$finalizer_transaction_nonce"
fixture_new_packages
fixture_write_units new
for unit in "${finalizer_transaction_all_units[@]}"; do
	mock_load["$unit"]=loaded
	mock_persistent["$unit"]=disabled
	mock_active["$unit"]=inactive
done
mock_preset_state["$path_unit"]=disabled
mock_preset_state["$timer_unit"]=disabled
mock_preset_state["$service_unit"]=static
fixture_prepare_direct_recovery
: > "$event_log"
finalizer_transaction_recover "$admin_preset_nonce"
close_recovery_lock
assert_equal 3 "$mock_preset_count" 'administrator preset count'
assert_equal disabled "${mock_persistent[$path_unit]}" 'administrator path preset'
assert_equal disabled "${mock_persistent[$timer_unit]}" 'administrator timer preset'
assert_equal inactive "${mock_active[$path_unit]}" 'administrator path activation'
assert_equal inactive "${mock_active[$timer_unit]}" 'administrator timer activation'
if event_line START-ACTIVATOR >/dev/null 2>&1; then
	fail 'administrator-disabled activator was started'
fi
assert_absent "$finalizer_transaction_state_path" \
	'administrator preset recovery retained state'

# A public legacy installation can expose old activators while lacking the
# managed worker entirely.  If an upgrade rolls back to that authenticated
# graph, recovery restores the original worker absence and commits; it must not
# leave unrelated legacy operation permanently fenced.
fixture_reset
rm -f -- "${unit_directory}/${service_unit}"
mock_load["$service_unit"]=not-found
mock_persistent["$service_unit"]=not-found
mock_active["$service_unit"]=not-found
finalizer_transaction_pretrans 2
legacy_absent_nonce="$finalizer_transaction_nonce"
finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600
fixture_prepare_direct_recovery
legacy_absent_status=0
finalizer_transaction_recover "$legacy_absent_nonce" \
	>/dev/null 2>&1 || legacy_absent_status=$?
close_recovery_lock
assert_equal 0 "$legacy_absent_status" 'legacy worker-absent rollback status'
assert_absent "$finalizer_transaction_state_path" \
	'legacy worker-absent rollback retained state'
assert_equal not-found "${mock_load[$service_unit]}" \
	'legacy rollback manufactured a worker unit'
if event_line START-SERVICE >/dev/null 2>&1; then
	fail 'legacy worker-absent rollback started a worker'
fi
for unit in "$path_unit" "$timer_unit"; do
	assert_equal 0 "${mock_runtime_mask[$unit]}" "legacy rollback mask for ${unit}"
done

# Transitional/failed unit states are not normalized into a false "exact"
# snapshot.  The upgrade must retry once the managed graph is stable.
fixture_reset
mock_active["$service_unit"]=activating
if finalizer_transaction_pretrans 2 >/dev/null 2>&1; then
	fail 'pretrans accepted transitional ActiveState'
fi
assert_absent "$finalizer_transaction_state_path" 'transitional state created authority'
if event_line ARM >/dev/null 2>&1; then
	fail 'transitional state armed recovery'
fi

# systemd-run success is not READY.  If the exec'ed copy never authenticates
# itself, pretrans retires the transient and never reaches mask/stop.
fixture_reset
mock_publish_ready=0
finalizer_transaction_ready_timeout_seconds=1
if finalizer_transaction_pretrans 2 >/dev/null 2>&1; then
	fail 'pretrans accepted a transient that never published READY'
fi
finalizer_transaction_ready_timeout_seconds=2
if event_line MASK >/dev/null 2>&1 || \
	event_line STOP-ACTIVATORS >/dev/null 2>&1 || \
	event_line STOP-SERVICE >/dev/null 2>&1; then
	fail 'pretrans fenced the graph before authenticated READY'
fi
assert_absent "$finalizer_transaction_state_path" 'no-READY failure retained state'
assert_absent "$finalizer_transaction_helper_copy_path" 'no-READY failure retained helper'

# Fresh upgrade: authenticated READY must precede every mask/stop, and the
# service itself must be fenced before activators are drained.
fixture_reset
marker="${pending_directory}/6.12.9-200.fc43.x86_64.pending"
printf 'GALAXYBOOK_OV02C10_FINALIZATION_V1\nrequest=6.12.9-200.fc43.x86_64\n' > "$marker"
chmod 0644 -- "$marker"
marker_sha="$(sha256sum "$marker" | { read -r hash _; printf '%s' "$hash"; })"
marker_inode="$(stat -c '%d:%i' "$marker")"
saved_rpm_command="$finalizer_transaction_rpm_command"
finalizer_transaction_rpm_command=/usr/bin/false
finalizer_transaction_pretrans 2
finalizer_transaction_rpm_command="$saved_rpm_command"
assert_equal 0 "$mock_package_query_count" 'pretrans queried rpmdb under writer lock'
assert_exists "${test_root}/handoff.executed" \
	'recovery copy was not executed through env-i/CLI'
assert_equal copy-cli-env-i "$(<"${test_root}/handoff.executed")" \
	'recovery handoff marker bytes'
ready_line="$(event_line RECOVERY-READY)"
mask_line="$(event_line MASK)"
activator_stop_line="$(event_line STOP-ACTIVATORS)"
service_stop_line="$(event_line STOP-SERVICE)"
[[ "$ready_line" -lt "$mask_line" && "$mask_line" -lt "$activator_stop_line" && \
	"$activator_stop_line" -lt "$service_stop_line" ]] || \
	fail 'READY/mask/activator/service ordering was not strict'
first_mask="$(sed -n "${mask_line}p" "$event_log")"
[[ "$first_mask" == *"$path_unit"* && "$first_mask" == *"$timer_unit"* && \
	"$first_mask" == *"$service_unit"* && "$first_mask" != *sound.target* ]] || \
	fail 'runtime fence did not cover exactly activators and service'
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "runtime mask for ${unit}"
	assert_equal inactive "${mock_active[$unit]}" "drained state for ${unit}"
done
assert_exists "$finalizer_transaction_state_path" 'upgrade state is absent'
assert_exists "$finalizer_transaction_helper_copy_path" 'recovery copy is absent'
assert_exists "$finalizer_transaction_ready_path" 'authenticated READY is absent'
assert_equal 600 "$(stat -c '%a' "$finalizer_transaction_state_path")" 'state mode'
assert_equal 700 "$(stat -c '%a' "$finalizer_transaction_helper_copy_path")" 'helper-copy mode'
cmp --silent -- "$finalizer_transaction_script_path" \
	"$finalizer_transaction_helper_copy_path" || fail 'recovery helper copy changed bytes'
finalizer_transaction_parse_state
finalizer_transaction_ready_is_authentic || fail 'READY/state/nonce binding failed'
finalizer_transaction_helper_copy_is_authentic || fail 'helper-copy byte binding failed'
while IFS= read -r state_line; do
	[[ "$state_line" != package_count=* && "$state_line" != package$'\t'* ]] || \
		fail 'pretrans persisted an rpmdb package snapshot'
done < "$finalizer_transaction_state_path"
assert_equal "$marker_sha" "$(sha256sum "$marker" | { read -r hash _; printf '%s' "$hash"; })" \
	'marker content changed during quiescence'
assert_equal "$marker_inode" "$(stat -c '%d:%i' "$marker")" \
	'marker inode changed during quiescence'

# The state grammar is canonical byte-for-byte, including its final newline.
canonical_state_path="$finalizer_transaction_state_path"
cp -- "$canonical_state_path" "${state_directory}/bad.state"
truncate -s -1 -- "${state_directory}/bad.state"
finalizer_transaction_state_path="${state_directory}/bad.state"
if finalizer_transaction_parse_state >/dev/null 2>&1; then
	fail 'state without a terminal newline was accepted'
fi
finalizer_transaction_state_path="$canonical_state_path"
unlink "${state_directory}/bad.state"
finalizer_transaction_parse_state

# Posttrans never treats its position inside the RPM writer as all-new
# authority.  It proves the authenticated recovery remains live and leaves the
# managed graph fenced without querying rpmdb, rearming, or cancelling it.
fixture_new_packages
fixture_write_units new
package_queries_before_post="$mock_package_query_count"
owner_queries_before_post="$mock_owner_query_count"
verify_before_post="$mock_verify_count"
: > "$event_log"
saved_rpm_command="$finalizer_transaction_rpm_command"
finalizer_transaction_rpm_command=/usr/bin/false
finalizer_transaction_posttrans 1
finalizer_transaction_rpm_command="$saved_rpm_command"
assert_equal "$package_queries_before_post" "$mock_package_query_count" \
	'posttrans queried rpmdb under the POSIX writer lock'
assert_equal "$owner_queries_before_post" "$mock_owner_query_count" \
	'posttrans queried rpm ownership under the POSIX writer lock'
assert_equal "$verify_before_post" "$mock_verify_count" \
	'posttrans ran rpm verify under the POSIX writer lock'
if event_line UNMASK >/dev/null 2>&1 || \
	event_line START-SERVICE >/dev/null 2>&1 || \
	event_line STOP-RECOVERY >/dev/null 2>&1; then
	fail 'posttrans opened the graph or cancelled recovery'
fi
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "posttrans mask for ${unit}"
done
assert_exists "$finalizer_transaction_state_path" 'posttrans removed recovery state'
assert_exists "$finalizer_transaction_ready_path" 'posttrans removed READY'
assert_exists "$finalizer_transaction_helper_copy_path" 'posttrans removed helper'
finalizer_transaction_recovery_is_live || fail 'posttrans did not prove live recovery'

# Only recovery, after the shared F_OFD bridge is held, may classify all-new,
# restore the graph, synchronously complete pending work, and commit cleanup.
recovery_nonce="$finalizer_transaction_nonce"
fixture_prepare_direct_recovery
[[ ! -s "${test_root}/handoff-${recovery_nonce}.out" && \
	! -s "${test_root}/handoff-${recovery_nonce}.err" ]] || \
	fail 'recovery-copy env-i/CLI handoff emitted output'
package_queries_before_recovery="$mock_package_query_count"
owner_queries_before_recovery="$mock_owner_query_count"
verify_before_recovery="$mock_verify_count"
: > "$event_log"
finalizer_transaction_recover "$recovery_nonce"
close_recovery_lock
assert_equal 0 "$mock_preset_count" 'pre-existing units were preset'
ready_line="$(event_line RECOVERY-READY)"
mask_line="$(event_line MASK)"
unmask_line="$(event_line UNMASK)"
start_service_line="$(event_line START-SERVICE)"
[[ "$ready_line" -lt "$mask_line" && "$mask_line" -lt "$unmask_line" && \
	"$unmask_line" -lt "$start_service_line" ]] || \
	fail 'recovery READY/fence/rearm/service ordering was not strict'
[[ "$mock_package_query_count" -ge $((package_queries_before_recovery + 3)) ]] || \
	fail 'all-new recovery skipped strict package queries'
[[ "$mock_owner_query_count" -ge $((owner_queries_before_recovery + 3)) ]] || \
	fail 'all-new recovery skipped strict unit-owner queries'
assert_equal $((verify_before_recovery + 1)) "$mock_verify_count" \
	'all-new recovery skipped strict rpm verify'
event_line 'WORKER-TIMEOUT 1260' >/dev/null || \
	fail 'queue worker did not use the 1260-second timeout'
if event_line STOP-RECOVERY >/dev/null 2>&1; then
	fail 'recovery tried to cancel its own transient'
fi
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 0 "${mock_runtime_mask[$unit]}" "recovery unmask for ${unit}"
done
assert_equal enabled "${mock_persistent[$path_unit]}" 'path enablement preservation'
assert_equal enabled "${mock_persistent[$timer_unit]}" 'timer enablement preservation'
assert_equal static "${mock_persistent[$service_unit]}" 'service enablement preservation'
assert_absent "$finalizer_transaction_state_path" 'successful recovery retained state'
assert_absent "$finalizer_transaction_ready_path" 'successful recovery retained READY'
assert_absent "$finalizer_transaction_helper_copy_path" 'successful recovery retained helper'
assert_equal "$marker_sha" "$(sha256sum "$marker" | { read -r hash _; printf '%s' "$hash"; })" \
	'recovery mutated the durable marker'

# State unlink is the commit point.  A late catchable signal must exit zero so
# Restart=on-failure cannot loop after the graph is already authoritative.
fixture_reset
finalizer_transaction_pretrans 2
postcommit_nonce="$finalizer_transaction_nonce"
fixture_new_packages
fixture_write_units new
fixture_prepare_direct_recovery
finalizer_transaction_cleanup_state() {
	finalizer_transaction_cleanup_state_original "$@" || return 1
	kill -TERM "$BASHPID"
	/usr/bin/sleep 1
}
: > "$event_log"
set +e
(
	set -e
	finalizer_transaction_main --recover "$postcommit_nonce"
) >"${test_root}/postcommit-term.out" 2>"${test_root}/postcommit-term.err"
postcommit_status=$?
set -e
finalizer_transaction_cleanup_state() {
	finalizer_transaction_cleanup_state_original "$@"
}
assert_equal 0 "$postcommit_status" 'post-commit TERM status'
[[ ! -s "${test_root}/postcommit-term.out" && \
	! -s "${test_root}/postcommit-term.err" ]] || \
	fail 'post-commit TERM emitted output'
assert_absent "$finalizer_transaction_state_path" 'post-commit TERM retained state'
assert_absent "$finalizer_transaction_ready_path" 'post-commit TERM retained READY'
assert_absent "$finalizer_transaction_helper_copy_path" 'post-commit TERM retained helper'
mask_line="$(last_event_line MASK)"
unmask_line="$(last_event_line UNMASK)"
[[ "$mask_line" -lt "$unmask_line" ]] || \
	fail 'post-commit TERM re-masked an authoritative graph'

# An originally inactive/disabled graph remains inactive and migration.pending
# alone never starts the finalizer service.
fixture_reset
mock_active["$path_unit"]=inactive
mock_active["$timer_unit"]=inactive
mock_active["$service_unit"]=inactive
mock_persistent["$path_unit"]=disabled
mock_persistent["$timer_unit"]=enabled-runtime
: > "${test_root}/migration.pending"
finalizer_transaction_pretrans 2
inactive_nonce="$finalizer_transaction_nonce"
fixture_new_packages
fixture_write_units new
finalizer_transaction_posttrans 1
fixture_prepare_direct_recovery
finalizer_transaction_recover "$inactive_nonce"
close_recovery_lock
assert_equal disabled "${mock_persistent[$path_unit]}" 'disabled path preservation'
assert_equal enabled-runtime "${mock_persistent[$timer_unit]}" 'runtime timer preservation'
assert_equal inactive "${mock_active[$path_unit]}" 'inactive path restoration'
assert_equal inactive "${mock_active[$timer_unit]}" 'inactive timer restoration'
if event_line START-SERVICE >/dev/null 2>&1; then
	fail 'migration-only inactive transaction started the service'
fi

# Recovery never waits for a worker that needs the global lifecycle lock, but
# systemd must accept the asynchronous job.  A failed enqueue rolls the graph
# back and retains repair authority.
fixture_reset
finalizer_transaction_pretrans 2
enqueue_failure_nonce="$finalizer_transaction_nonce"
fixture_new_packages
fixture_write_units new
mock_worker_enqueue_status=74
fixture_prepare_direct_recovery
if finalizer_transaction_recover "$enqueue_failure_nonce" >/dev/null 2>&1; then
	fail 'recovery accepted a failed asynchronous worker enqueue'
fi
close_recovery_lock
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "enqueue-failure mask for ${unit}"
done
assert_exists "$finalizer_transaction_state_path" 'enqueue failure removed repair state'

# A failed or noisy package-integrity verification is terminal unknown state,
# never authority to open the unit graph.
fixture_reset
finalizer_transaction_pretrans 2
verify_failure_nonce="$finalizer_transaction_nonce"
fixture_new_packages
fixture_write_units new
mock_verify_status=74
fixture_prepare_direct_recovery
: > "$event_log"
set +e
(
	set -e
	finalizer_transaction_main --recover "$verify_failure_nonce"
) >"${test_root}/verify-failure.out" 2>"${test_root}/verify-failure.err"
verify_failure_status=$?
set -e
assert_equal 75 "$verify_failure_status" 'rpm verify failure terminal status'
event_line RPM-VERIFY >/dev/null || fail 'rpm verify failure path skipped verification'
if event_line UNMASK >/dev/null 2>&1; then
	fail 'rpm verify failure opened the graph'
fi
assert_exists "$finalizer_transaction_state_path" \
	'rpm verify failure removed repair state'

# If a successful worker leaves a durable marker behind, at least one restored
# activator must be active to cover retry; otherwise recovery stays fenced.
fixture_reset
mock_active["$path_unit"]=inactive
mock_active["$timer_unit"]=inactive
mock_active["$service_unit"]=inactive
retry_marker="${pending_directory}/retry.pending"
printf 'retry\n' > "$retry_marker"
chmod 0644 -- "$retry_marker"
finalizer_transaction_pretrans 2
uncovered_marker_nonce="$finalizer_transaction_nonce"
fixture_new_packages
fixture_write_units new
fixture_prepare_direct_recovery
if finalizer_transaction_recover "$uncovered_marker_nonce" >/dev/null 2>&1; then
	fail 'recovery accepted an uncovered pending marker'
fi
close_recovery_lock
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "uncovered-marker mask for ${unit}"
done
assert_exists "$retry_marker" 'coordinator consumed durable retry marker'

# An unsafe pending pathname is never equivalent to an empty queue.  Recovery
# must roll back and retain authority instead of starting or committing.
fixture_reset
finalizer_transaction_pretrans 2
unsafe_pending_nonce="$finalizer_transaction_nonce"
fixture_new_packages
fixture_write_units new
fixture_prepare_direct_recovery
find "$pending_directory" -mindepth 1 -maxdepth 1 -delete
rmdir "$pending_directory"
ln -s -- "$test_root" "$pending_directory"
: > "$event_log"
if finalizer_transaction_recover "$unsafe_pending_nonce" >/dev/null 2>&1; then
	fail 'recovery accepted an unsafe pending-directory symlink'
fi
close_recovery_lock
assert_exists "$finalizer_transaction_state_path" \
	'unsafe pending pathname removed repair state'
if event_line START-SERVICE >/dev/null 2>&1; then
	fail 'unsafe pending pathname started the worker'
fi
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "unsafe-pending mask for ${unit}"
done
unlink "$pending_directory"
mkdir -m 0700 -- "$pending_directory"

# If the transient dies before posttrans, posttrans retires the dead unit and
# restarts the byte-authenticated copy without opening the managed graph.
fixture_reset
finalizer_transaction_pretrans 2
fixture_new_packages
fixture_write_units new
fixture_stop_recovery_process
mock_recovery_active=failed
fixture_set_cgroup "$recovery_cgroup" 0
: > "$event_log"
finalizer_transaction_posttrans 1
arm_line="$(event_line ARM)"
ready_line="$(event_line RECOVERY-READY)"
[[ "$arm_line" -lt "$ready_line" ]] || fail 'dead recovery was not restarted before READY'
if event_line UNMASK >/dev/null 2>&1 || event_line START-SERVICE >/dev/null 2>&1; then
	fail 'dead-recovery replacement opened the managed graph'
fi
finalizer_transaction_recovery_is_live || fail 'replacement recovery is not live'
finalizer_transaction_ready_is_authentic || fail 'replacement READY is not authentic'
finalizer_transaction_helper_copy_is_authentic || fail 'stale helper was not byte-identical'
assert_exists "$finalizer_transaction_state_path" 'replacement removed state authority'

# A replacement failure is fail-closed: posttrans reports failure but never
# opens units or discards the authenticated repair state/copy.
fixture_reset
finalizer_transaction_pretrans 2
fixture_stop_recovery_process
mock_recovery_active=failed
fixture_set_cgroup "$recovery_cgroup" 0
mock_systemd_run_status=74
: > "$event_log"
if finalizer_transaction_posttrans 1 >/dev/null 2>&1; then
	fail 'posttrans ignored recovery replacement failure'
fi
if event_line UNMASK >/dev/null 2>&1 || event_line START-SERVICE >/dev/null 2>&1; then
	fail 'failed recovery replacement opened the graph'
fi
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "replacement-failure mask for ${unit}"
done
assert_exists "$finalizer_transaction_state_path" 'replacement failure removed state'
assert_exists "$finalizer_transaction_helper_copy_path" 'replacement failure removed helper'

# Stale retirement cannot discard authority while a failed stop leaves any
# process in the recovery cgroup tree.
fixture_reset
finalizer_transaction_pretrans 2
mock_recovery_stop_status=74
if finalizer_transaction_pretrans 2 >/dev/null 2>&1; then
	fail 'stale adoption ignored populated recovery cgroup after stop failure'
fi
assert_exists "$finalizer_transaction_state_path" 'failed retirement removed state'
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "retirement-failure mask for ${unit}"
done

# A loaded recovery in a terminal state may still own descendants.  Retirement
# must issue an idempotent stop before trusting recursive cgroup emptiness.
for terminal_recovery_state in failed inactive; do
	fixture_reset
	finalizer_transaction_pretrans 2
	fixture_stop_recovery_process
	mock_recovery_load=loaded
	mock_recovery_active="$terminal_recovery_state"
	fixture_set_cgroup "$recovery_cgroup" 1
	: > "$event_log"
	finalizer_transaction_pretrans 2
	stop_recovery_line="$(event_line STOP-RECOVERY)"
	arm_line="$(event_line ARM)"
	[[ "$stop_recovery_line" -lt "$arm_line" ]] || \
		fail "${terminal_recovery_state} recovery was not stopped before replacement"
	finalizer_transaction_recovery_is_live || \
		fail "${terminal_recovery_state} recovery replacement is not live"
done

# A failure after runtime unmask is rolled back to a masked, drained graph and
# the authenticated recovery/state remain available.
fixture_reset
finalizer_transaction_pretrans 2
snapshot_nonce="$finalizer_transaction_nonce"
snapshot_sha="$(sha256sum "$finalizer_transaction_state_path" | { read -r hash _; printf '%s' "$hash"; })"
fixture_new_packages
fixture_write_units new
mock_fail_daemon_reload_at=$((mock_daemon_reload_count + 2))
: > "$event_log"
fixture_prepare_direct_recovery
if finalizer_transaction_recover "$snapshot_nonce" >/dev/null 2>&1; then
	fail 'recovery reload failure was ignored'
fi
close_recovery_lock
assert_exists "$finalizer_transaction_state_path" 'failed recovery removed state'
assert_exists "$finalizer_transaction_ready_path" 'failed recovery removed READY'
assert_exists "$finalizer_transaction_helper_copy_path" 'failed recovery removed helper copy'
if event_line STOP-RECOVERY >/dev/null 2>&1; then
	fail 'failed recovery cancelled its own transient'
fi
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "rollback mask for ${unit}"
	assert_equal inactive "${mock_active[$unit]}" "rollback drain for ${unit}"
done

# A repair transaction adopts the original snapshot, drains/cancels the stale
# transient, replaces helper/READY, and never opens the graph.
mock_fail_daemon_reload_at=0
mock_recovery_active=active
fixture_set_cgroup "$recovery_cgroup" 1
: > "$event_log"
finalizer_transaction_pretrans 2
assert_equal "$snapshot_sha" \
	"$(sha256sum "$finalizer_transaction_state_path" | { read -r hash _; printf '%s' "$hash"; })" \
	'stale adoption rewrote the original snapshot'
assert_equal "$snapshot_nonce" "$finalizer_transaction_nonce" \
	'stale adoption changed the state nonce'
stop_recovery_line="$(event_line STOP-RECOVERY)"
arm_line="$(event_line ARM)"
ready_line="$(event_line RECOVERY-READY)"
[[ "$stop_recovery_line" -lt "$arm_line" && "$arm_line" -lt "$ready_line" ]] || \
	fail 'stale recovery was not drained before replacement'
if event_line UNMASK >/dev/null 2>&1; then
	fail 'stale repair transaction opened the graph'
fi
finalizer_transaction_helper_copy_is_authentic || \
	fail 'stale adoption did not recreate byte-identical helper'
finalizer_transaction_ready_is_authentic || \
	fail 'stale adoption did not recreate authenticated READY'

# Mixed package state after RPM unlock is classified fail-closed.  The
# recovery itself reasserts masks/drain before querying the file-backed state.
mock_package_evr["$finalizer_transaction_common_package"]='0:1.00.25-0'
mock_package_evr["$finalizer_transaction_peer_package"]='0:1.00.10-1'
mock_package_evr["$finalizer_transaction_setup_package"]='0:1.00.48-0'
finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600
: > "$event_log"
mixed_status=0
fixture_prepare_direct_recovery
set +e
(
	set -e
	finalizer_transaction_main --recover "$snapshot_nonce"
) >"${test_root}/mixed.out" 2>"${test_root}/mixed.err"
mixed_status=$?
set -e
assert_equal 75 "$mixed_status" 'mixed recovery terminal status'
[[ ! -s "${test_root}/mixed.out" ]] || fail 'mixed recovery leaked stdout'
printf '%s\n' \
	'galaxybook-finalizer-transaction: package or unit-file state is mixed or unknown; finalizers remain quiescent' \
	> "${test_root}/mixed.expected"
cmp --silent -- "${test_root}/mixed.expected" "${test_root}/mixed.err" || \
	fail 'mixed recovery stderr bytes were not exact'
close_recovery_lock
assert_exists "$finalizer_transaction_state_path" 'mixed recovery removed repair state'
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "mixed fail-close mask for ${unit}"
	assert_equal inactive "${mock_active[$unit]}" "mixed fail-close drain for ${unit}"
done
if event_line UNMASK >/dev/null 2>&1; then
	fail 'mixed recovery transiently opened the graph'
fi

# The next serialized upgrade can adopt a terminal mixed state without
# replacing its original snapshot or opening activation.
mixed_snapshot_sha="$(sha256sum "$finalizer_transaction_state_path" | \
	{ read -r hash _; printf '%s' "$hash"; })"
mock_recovery_active=failed
fixture_set_cgroup "$recovery_cgroup" 0
: > "$event_log"
finalizer_transaction_pretrans 2
assert_equal "$mixed_snapshot_sha" \
	"$(sha256sum "$finalizer_transaction_state_path" | { read -r hash _; printf '%s' "$hash"; })" \
	'mixed stale adoption replaced its original snapshot'
if event_line UNMASK >/dev/null 2>&1; then
	fail 'mixed stale adoption opened activation'
fi

# Runtime masking must not rewrite persistent enablement.  If the underlying
# UnitFileState changed during RPM, opening is rolled back instead of calling
# enable/disable to normalize it.
fixture_reset
finalizer_transaction_pretrans 2
unit_state_mismatch_nonce="$finalizer_transaction_nonce"
fixture_new_packages
fixture_write_units new
mock_persistent["$path_unit"]=disabled
fixture_prepare_direct_recovery
: > "$event_log"
if finalizer_transaction_recover "$unit_state_mismatch_nonce" >/dev/null 2>&1; then
	fail 'recovery normalized a mismatched persistent UnitFileState'
fi
close_recovery_lock
assert_equal disabled "${mock_persistent[$path_unit]}" \
	'mismatched UnitFileState was mutated'
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "UnitFileState-mismatch mask for ${unit}"
	assert_equal inactive "${mock_active[$unit]}" "UnitFileState-mismatch drain for ${unit}"
done
assert_exists "$finalizer_transaction_state_path" \
	'UnitFileState mismatch removed repair state'

# A coherent all-old graph is authenticated, but workers below the compatibility
# floor are not trusted to mutate module indexes or initramfs.  Recovery exits
# terminal 75 with state and masks intact until a later transaction adopts it.
fixture_reset
finalizer_transaction_pretrans 2
clean_old_nonce="$finalizer_transaction_nonce"
finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600
package_queries_before_recovery="$mock_package_query_count"
owner_queries_before_recovery="$mock_owner_query_count"
verify_before_recovery="$mock_verify_count"
fixture_prepare_direct_recovery
clean_old_status=0
finalizer_transaction_recover "$clean_old_nonce" \
	>/dev/null 2>&1 || clean_old_status=$?
close_recovery_lock
assert_equal 75 "$clean_old_status" 'all-old recovery terminal status'
[[ "$mock_package_query_count" -ge $((package_queries_before_recovery + 3)) ]] || \
	fail 'all-old recovery skipped strict package queries'
[[ "$mock_owner_query_count" -ge $((owner_queries_before_recovery + 3)) ]] || \
	fail 'all-old recovery skipped strict unit-owner queries'
assert_equal $((verify_before_recovery + 1)) "$mock_verify_count" \
	'all-old recovery skipped strict rpm verify'
assert_exists "$finalizer_transaction_state_path" 'all-old recovery removed repair state'
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "all-old terminal mask for ${unit}"
done
if event_line UNMASK >/dev/null 2>&1 || event_line START-SERVICE >/dev/null 2>&1; then
	fail 'all-old recovery reopened a pre-compatibility worker graph'
fi

# A later compatible upgrade adopts the preserved authority before RPM writes,
# then its all-new recovery is the only path allowed to reopen and commit.
: > "$event_log"
finalizer_transaction_pretrans 2
resumed_nonce="$finalizer_transaction_nonce"
assert_equal "$clean_old_nonce" "$resumed_nonce" 'stale recovery nonce changed on adoption'
fixture_new_packages
fixture_write_units new
finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600
fixture_prepare_direct_recovery
finalizer_transaction_recover "$resumed_nonce"
close_recovery_lock
assert_absent "$finalizer_transaction_state_path" \
	'compatible retry did not commit adopted recovery state'
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 0 "${mock_runtime_mask[$unit]}" "compatible retry unmask for ${unit}"
done

# A coherent all-new RPM/file graph rearms, but only after strict package
# and unit-owner queries while the real shared OFD lock is held.
fixture_reset
finalizer_transaction_pretrans 2
all_new_nonce="$finalizer_transaction_nonce"
finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600
fixture_new_packages
fixture_write_units new
package_queries_before_recovery="$mock_package_query_count"
owner_queries_before_recovery="$mock_owner_query_count"
fixture_prepare_direct_recovery
finalizer_transaction_recover "$all_new_nonce"
close_recovery_lock
[[ "$mock_package_query_count" -ge $((package_queries_before_recovery + 3)) ]] || \
	fail 'all-new recovery skipped strict package queries'
[[ "$mock_owner_query_count" -ge $((owner_queries_before_recovery + 3)) ]] || \
	fail 'all-new recovery skipped strict unit-owner queries'
assert_absent "$finalizer_transaction_state_path" 'all-new recovery retained state'

# Peer/setup packages are optional, but whenever present their floors remain
# mandatory.  Their absence is a coherent all-new graph, not mixed state.
fixture_reset
finalizer_transaction_pretrans 2
optional_new_nonce="$finalizer_transaction_nonce"
finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600
fixture_new_packages
mock_package_present["$finalizer_transaction_peer_package"]=0
mock_package_present["$finalizer_transaction_setup_package"]=0
fixture_write_units new
fixture_prepare_direct_recovery
finalizer_transaction_recover "$optional_new_nonce"
close_recovery_lock
assert_absent "$finalizer_transaction_state_path" 'optional all-new graph retained state'

# The family common package is mandatory in both coherent terminal graphs.
fixture_reset
finalizer_transaction_pretrans 2
missing_own_nonce="$finalizer_transaction_nonce"
finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600
mock_package_present["$finalizer_transaction_common_package"]=0
missing_own_status=0
fixture_prepare_direct_recovery
finalizer_transaction_recover "$missing_own_nonce" \
	>/dev/null 2>&1 || missing_own_status=$?
close_recovery_lock
assert_equal 75 "$missing_own_status" 'missing-own terminal status'
assert_exists "$finalizer_transaction_state_path" 'missing-own graph removed repair state'
for unit in "${finalizer_transaction_all_units[@]}"; do
	assert_equal 1 "${mock_runtime_mask[$unit]}" "missing-own mask for ${unit}"
done

# Real cross-lock concurrency: Setup owns GLOBAL and then attempts a classic
# POSIX RPM writer while recovery still holds its shared OFD classification
# fence.  The systemd worker is queued asynchronously and blocks on GLOBAL in
# an independent process.  Recovery must commit and exit without waiting for
# that worker; its exit releases OFD, which lets Setup finish the writer and
# release GLOBAL, and only then may the worker acquire GLOBAL.
fixture_reset
cycle_marker="${pending_directory}/lock-cycle.pending"
printf 'GALAXYBOOK_OV02C10_FINALIZATION_V1\nrequest=lock-cycle\n' > "$cycle_marker"
chmod 0644 -- "$cycle_marker"
finalizer_transaction_pretrans 2
lock_cycle_nonce="$finalizer_transaction_nonce"
finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600
fixture_new_packages
fixture_write_units new
fixture_prepare_direct_recovery
: > "$lock_cycle_global"
: > "$lock_cycle_order"
chmod 0600 -- "$lock_cycle_global" "$lock_cycle_order"
/usr/bin/python3 -c '
import fcntl
import os
import sys
import time

global_path, ready_path, gate_path, attempt_path, rpm_path, acquired_path, order_path = sys.argv[1:]

def marker(path, content):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, content.encode("ascii"))
    os.close(fd)

def event(content):
    fd = os.open(order_path, os.O_WRONLY | os.O_APPEND)
    os.write(fd, (content + "\n").encode("ascii"))
    os.close(fd)

global_fd = os.open(global_path, os.O_RDWR)
fcntl.flock(global_fd, fcntl.LOCK_EX)
event("SETUP-GLOBAL-ACQUIRED")
marker(ready_path, "ready\n")
deadline = time.monotonic() + 10
while not os.path.exists(gate_path):
    if time.monotonic() >= deadline:
        raise TimeoutError("recovery never queued the worker")
    time.sleep(0.01)
event("SETUP-RPM-ATTEMPT")
marker(attempt_path, "attempt\n")
rpm_fd = os.open(rpm_path, os.O_RDWR)
fcntl.lockf(rpm_fd, fcntl.LOCK_EX)
event("SETUP-RPM-ACQUIRED")
marker(acquired_path, "acquired\n")
os.close(rpm_fd)
event("SETUP-GLOBAL-RELEASE")
os.close(global_fd)
' "$lock_cycle_global" "$lock_cycle_setup_ready" "$lock_cycle_setup_gate" \
	"$lock_cycle_setup_attempt" "$rpm_lock" "$lock_cycle_setup_acquired" \
	"$lock_cycle_order" >"${test_root}/lock-cycle-setup.out" \
	2>"${test_root}/lock-cycle-setup.err" &
lock_cycle_setup_pid=$!
wait_for_file "$lock_cycle_setup_ready" || fail 'Setup did not acquire GLOBAL'
mock_lock_cycle_mode=1
(
	set +e
	finalizer_transaction_main --recover "$lock_cycle_nonce"
	recovery_status=$?
	printf 'RECOVERY-EXIT\n' >> "$lock_cycle_order"
	printf '%s\n' "$recovery_status" > "$lock_cycle_recovery_status"
	exit "$recovery_status"
) >"${test_root}/lock-cycle-recovery.out" \
	2>"${test_root}/lock-cycle-recovery.err" &
lock_cycle_recovery_pid=$!
wait_for_file "$lock_cycle_setup_attempt" || \
	fail 'Setup never attempted its POSIX RPM writer'
wait_for_file "$lock_cycle_worker_attempt" || \
	fail 'asynchronous worker never attempted GLOBAL'
set +e
wait "$lock_cycle_recovery_pid"
lock_cycle_recovery_wait_status=$?
set -e
lock_cycle_recovery_pid=""
assert_equal 0 "$lock_cycle_recovery_wait_status" \
	'recovery waited for the GLOBAL-blocked worker'
assert_equal 0 "$(<"$lock_cycle_recovery_status")" \
	'cross-lock recovery status'
set +e
wait "$lock_cycle_setup_pid"
lock_cycle_setup_status=$?
set -e
lock_cycle_setup_pid=""
assert_equal 0 "$lock_cycle_setup_status" 'Setup writer did not finish after recovery exit'
[[ ! -s "${test_root}/lock-cycle-setup.err" ]] || \
	fail 'Setup lock-cycle process emitted stderr'
wait_for_file "$lock_cycle_worker_status" || \
	fail 'GLOBAL-blocked worker did not finish after Setup'
assert_equal 0 "$(<"$lock_cycle_worker_status")" \
	'worker did not acquire GLOBAL after Setup released it'
assert_exists "$lock_cycle_setup_acquired" \
	'Setup writer never acquired RPM after recovery exit'
assert_exists "$lock_cycle_worker_acquired" \
	'worker never acquired GLOBAL after Setup release'
setup_global_line="$(lock_cycle_line SETUP-GLOBAL-ACQUIRED)"
setup_attempt_line="$(lock_cycle_line SETUP-RPM-ATTEMPT)"
worker_attempt_line="$(lock_cycle_line WORKER-GLOBAL-ATTEMPT)"
recovery_exit_line="$(lock_cycle_line RECOVERY-EXIT)"
setup_rpm_line="$(lock_cycle_line SETUP-RPM-ACQUIRED)"
setup_release_line="$(lock_cycle_line SETUP-GLOBAL-RELEASE)"
worker_acquired_line="$(lock_cycle_line WORKER-GLOBAL-ACQUIRED)"
[[ "$setup_global_line" -lt "$setup_attempt_line" && \
	"$setup_attempt_line" -lt "$worker_attempt_line" && \
	"$worker_attempt_line" -lt "$recovery_exit_line" && \
	"$recovery_exit_line" -lt "$setup_rpm_line" && \
	"$setup_rpm_line" -lt "$setup_release_line" && \
	"$setup_release_line" -lt "$worker_acquired_line" ]] || \
	fail 'GLOBAL/RPM/worker concurrency ordering was not strict'
assert_absent "$finalizer_transaction_state_path" \
	'cross-lock recovery retained transaction state'

# Actual Linux lock interoperability: an independent classic POSIX F_SETLK
# writer models RPM 6.  Recovery publishes READY, but its shared F_OFD bridge
# cannot pass that writer or touch the graph until the writer process exits.
fixture_reset
finalizer_transaction_pretrans 2
ofd_nonce="$finalizer_transaction_nonce"
finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600
fixture_new_packages
mock_package_evr["$finalizer_transaction_peer_package"]='0:1.00.10-1'
fixture_write_units new
fixture_prepare_direct_recovery
flock_command_fixture="${test_root}/flock-command-fixture"
cat > "$flock_command_fixture" <<'FLOCK_COMMAND_FIXTURE'
#!/usr/bin/bash
set -euo pipefail

[[ -f "${TEST_FLOCK_READY:?}" && ! -L "$TEST_FLOCK_READY" ]]
printf 'attempt\n' > "${TEST_FLOCK_ATTEMPT:?}"
status=0
/usr/bin/flock "$@" || status=$?
printf '%s\n' "$status" > "${TEST_FLOCK_RESULT:?}"
exit "$status"
FLOCK_COMMAND_FIXTURE
chmod 0700 -- "$flock_command_fixture"
saved_flock_command="$finalizer_transaction_flock_command"
finalizer_transaction_flock_command="$flock_command_fixture"
export TEST_FLOCK_ATTEMPT="$ofd_attempted"
export TEST_FLOCK_RESULT="$ofd_result"
export TEST_FLOCK_READY="$finalizer_transaction_ready_path"
finalizer_transaction_rpm_lock_timeout_seconds=1
/usr/bin/python3 -c '
import fcntl
import os
import sys
import time

lock_fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.lockf(lock_fd, fcntl.LOCK_EX)
ready_fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.close(ready_fd)
time.sleep(30)
' "$rpm_lock" "$holder_ready" \
	>"${test_root}/posix-holder.out" 2>"${test_root}/posix-holder.err" &
holder_pid=$!
wait_for_file "$holder_ready" || fail 'POSIX writer holder did not start'
: > "$event_log"
(
	set +e
	finalizer_transaction_recover "$ofd_nonce" \
		>"${test_root}/ofd-recover.out" 2>"${test_root}/ofd-recover.err"
	recover_status=$?
	printf '%s\n' "$recover_status" > "$ofd_acquired"
) &
ofd_pid=$!
wait_for_file "$finalizer_transaction_ready_path" || \
	fail 'recovery did not publish READY before OFD wait'
finalizer_transaction_ready_is_authentic || fail 'OFD fixture READY was not authentic'
wait_for_file "$ofd_attempted" || \
	fail 'shared OFD bridge never attempted the lock while POSIX writer held it'
wait_for_file "$ofd_result" || \
	fail 'shared OFD bridge did not report its bounded conflict result'
[[ "$(<"$ofd_result")" -ne 0 ]] || \
	fail 'shared OFD bridge acquired through the POSIX writer'
event_line RECOVERY-READY >/dev/null || fail 'recovery READY event was not observed'
if event_line MASK >/dev/null 2>&1 || event_line STOP-SERVICE >/dev/null 2>&1; then
	fail 'recovery touched the graph before the POSIX writer released'
fi
wait "$ofd_pid" 2>/dev/null || :
ofd_pid=""
assert_exists "$ofd_acquired" 'blocked OFD recovery did not report status'
[[ "$(<"$ofd_acquired")" -ne 0 ]] || \
	fail 'blocked OFD recovery succeeded before POSIX writer release'
rm -f -- "$ofd_attempted" "$ofd_result" "$ofd_acquired"
kill "$holder_pid"
wait "$holder_pid" 2>/dev/null || :
holder_pid=""
[[ ! -s "${test_root}/posix-holder.err" ]] || fail 'POSIX holder emitted stderr'
: > "$event_log"
set +e
(
	set -e
	finalizer_transaction_main --recover "$ofd_nonce"
) >"${test_root}/ofd-retry.out" 2>"${test_root}/ofd-retry.err"
ofd_retry_status=$?
set -e
assert_equal 75 "$ofd_retry_status" 'mixed OFD recovery terminal status after release'
wait_for_file "$ofd_attempted" || fail 'OFD retry never attempted the shared lock'
wait_for_file "$ofd_result" || fail 'OFD retry never reported lock acquisition'
assert_equal 0 "$(<"$ofd_result")" 'shared OFD lock result after writer release'
event_line MASK >/dev/null || fail 'OFD retry did not fence after writer release'
finalizer_transaction_flock_command="$saved_flock_command"
finalizer_transaction_rpm_lock_timeout_seconds=5
unset TEST_FLOCK_ATTEMPT TEST_FLOCK_RESULT TEST_FLOCK_READY

printf 'test-finalizer-transaction: ok\n'

#!/usr/bin/bash
set -euo pipefail
umask 077

# This file is intentionally driver-neutral.  The OV02C10 and MAX98390 RPMs
# install the same bytes and provide the family-specific values through an
# `env -i` scriptlet interpreter.  Do not add module, private lifecycle-lock,
# or driver-specific mutation logic here: this coordinator only fences the
# finalizer unit graph around an RPM transaction.

finalizer_transaction_systemctl_command="/usr/bin/systemctl"
finalizer_transaction_systemd_run_command="/usr/bin/systemd-run"
finalizer_transaction_timeout_command="/usr/bin/timeout"
finalizer_transaction_rpm_command="/usr/bin/rpm"
finalizer_transaction_flock_command="/usr/bin/flock"
finalizer_transaction_stat_command="/usr/bin/stat"
finalizer_transaction_install_command="/usr/bin/install"
finalizer_transaction_chmod_command="/usr/bin/chmod"
finalizer_transaction_chown_command="/usr/bin/chown"
finalizer_transaction_cat_command="/usr/bin/cat"
finalizer_transaction_rm_command="/usr/bin/rm"
finalizer_transaction_mktemp_command="/usr/bin/mktemp"
finalizer_transaction_sha256sum_command="/usr/bin/sha256sum"
finalizer_transaction_cmp_command="/usr/bin/cmp"
finalizer_transaction_sleep_command="/usr/bin/sleep"
finalizer_transaction_env_command="/usr/bin/env"
finalizer_transaction_bash_command="/usr/bin/bash"
finalizer_transaction_rpm_nevr_query_format=""

# Source2 is macro-expanded when RPM embeds it with a scriptlet `-f` option.
# Construct every RPM query token at shell runtime so the source never contains
# a literal percent-plus-opening-brace sequence that rpmbuild could consume.
printf -v finalizer_transaction_rpm_nevr_query_format \
	'%%%s\t%%%s\t%%%s\t%%%s\n' \
	'{NAME}' '{EPOCHNUM}' '{VERSION}' '{RELEASE}'

finalizer_transaction_expected_euid=0
finalizer_transaction_command_timeout_seconds=120
finalizer_transaction_worker_timeout_seconds=1260
finalizer_transaction_ready_timeout_seconds=20
finalizer_transaction_rpm_lock_timeout_seconds=600
finalizer_transaction_cgroup_drain_attempts=200
finalizer_transaction_systemd_runtime_directory="/run/systemd/system"
finalizer_transaction_unit_directory="/usr/lib/systemd/system"
finalizer_transaction_rpm_lock_path="/usr/lib/sysimage/rpm/.rpm.lock"
finalizer_transaction_rpm_lock_ancestry=(
	/usr
	/usr/lib
	/usr/lib/sysimage
	/usr/lib/sysimage/rpm
)

finalizer_transaction_state_version="GALAXYBOOK_FINALIZER_TRANSACTION_V1"
finalizer_transaction_ready_version="GALAXYBOOK_FINALIZER_RECOVERY_READY_V1"

finalizer_transaction_family=""
finalizer_transaction_common_package=""
finalizer_transaction_own_floor=""
finalizer_transaction_peer_package=""
finalizer_transaction_peer_floor=""
finalizer_transaction_setup_package=""
finalizer_transaction_setup_floor=""
finalizer_transaction_activator_units_value=""
finalizer_transaction_dependent_units_value=""
finalizer_transaction_service_unit=""
finalizer_transaction_pending_directory=""
finalizer_transaction_recovery_unit=""
finalizer_transaction_state_directory=""
finalizer_transaction_service_cgroup=""
finalizer_transaction_recovery_cgroup=""
finalizer_transaction_state_path=""
finalizer_transaction_ready_path=""
finalizer_transaction_helper_copy_path=""
finalizer_transaction_script_path=""
finalizer_transaction_nonce=""
finalizer_transaction_rpm_lock_fd=""
finalizer_transaction_config_loaded=0
finalizer_transaction_phase="idle"
finalizer_transaction_traps_installed=0

# Keep the validated scriptlet configuration immutable across later runtime
# bindings.  A recovery handoff must serialize the exact family ABI that the
# RPM supplied through env -i.
declare -A finalizer_transaction_config_value=()

declare -a finalizer_transaction_activator_units=()
declare -a finalizer_transaction_dependent_units=()
declare -a finalizer_transaction_all_units=()
declare -a finalizer_transaction_package_roles=()
declare -A finalizer_transaction_package_name=()
declare -A finalizer_transaction_current_package_present=()
declare -A finalizer_transaction_current_package_evr=()
declare -A finalizer_transaction_snapshot_unit_load=()
declare -A finalizer_transaction_snapshot_unit_file_state=()
declare -A finalizer_transaction_snapshot_unit_active=()
declare -A finalizer_transaction_snapshot_unit_present=()
declare -A finalizer_transaction_snapshot_unit_sha256=()
declare -A finalizer_transaction_new_unit_file_state=()
declare -A finalizer_transaction_rearmed_unit_file_state=()
declare -A finalizer_transaction_dependent_cgroup=()

finalizer_transaction_observed_load=""
finalizer_transaction_observed_unit_file_state=""
finalizer_transaction_observed_active=""

finalizer_transaction_fail() {
	printf 'galaxybook-finalizer-transaction: %s\n' "$*" >&2
	return 1
}

finalizer_transaction_usage() {
	printf '%s\n' \
		'usage: finalizer-transaction <rpm-instance-count>' \
		'       finalizer-transaction --posttrans <rpm-instance-count>' \
		'       finalizer-transaction --recover <nonce>' >&2
	return 2
}

finalizer_transaction_signal_exit() {
	local signal="$1" status=1

	case "$signal" in
		HUP) status=129 ;;
		INT) status=130 ;;
		TERM) status=143 ;;
	esac
	exit "$status"
}

finalizer_transaction_exit_cleanup() {
	local status="$?"

	trap - EXIT HUP INT TERM
	set +e
	case "$finalizer_transaction_phase" in
		pretrans-building|pretrans-arming)
			# Before READY ownership is handed off, retire any partially created
			# transient and remove only root-safe files.  If retirement cannot be
			# proved, preserve the state for manual/adoptive recovery.
			if [[ -n "$finalizer_transaction_state_path" && \
				( -e "$finalizer_transaction_state_path" || \
				-L "$finalizer_transaction_state_path" ) ]]; then
				if finalizer_transaction_retire_recovery >/dev/null 2>&1; then
					finalizer_transaction_cleanup_state >/dev/null 2>&1 || :
				fi
			fi
			;;
		recovery-rearming)
			# An asynchronous exit after graph opening must close and drain it.
			# Restart=on-failure then retries from the still-authentic state.
			finalizer_transaction_mask_and_drain >/dev/null 2>&1 || :
			;;
		recovery-committing)
			# State unlink is the commit point.  Before it, roll back activation;
			# after it, the successfully rearmed graph is authoritative and must
			# not be re-masked because of a late signal during orphan cleanup.
			if [[ -e "$finalizer_transaction_state_path" || \
				-L "$finalizer_transaction_state_path" ]]; then
				finalizer_transaction_mask_and_drain >/dev/null 2>&1 || :
			else
				# The authority state unlink is the commit point.  A catchable
				# signal after it must terminate successfully so Restart=on-failure
				# cannot wedge the transient around an already-open graph.
				status=0
			fi
			;;
		committed)
			status=0
			;;
		posttrans-maintenance|stale-maintenance)
			# These phases never open the graph.  Best-effort replacement keeps a
			# recovery waiting on RPM; failure still leaves masks and state intact.
			finalizer_transaction_mask_and_drain >/dev/null 2>&1 || :
			if finalizer_transaction_helper_copy_is_authentic >/dev/null 2>&1; then
				finalizer_transaction_retire_recovery >/dev/null 2>&1 || :
				finalizer_transaction_safe_remove \
					"$finalizer_transaction_ready_path" 600 >/dev/null 2>&1 || :
				finalizer_transaction_arm_recovery >/dev/null 2>&1 || :
			fi
			;;
	esac
	exit "$status"
}

finalizer_transaction_install_traps() {
	((finalizer_transaction_traps_installed == 0)) || return 0
	trap finalizer_transaction_exit_cleanup EXIT
	trap 'finalizer_transaction_signal_exit HUP' HUP
	trap 'finalizer_transaction_signal_exit INT' INT
	trap 'finalizer_transaction_signal_exit TERM' TERM
	finalizer_transaction_traps_installed=1
}

finalizer_transaction_value_is_single_line() {
	[[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* ]]
}

finalizer_transaction_unit_is_safe() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]*\.(path|timer|service)$ ]]
}

finalizer_transaction_package_is_safe() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9+_.-]*$ ]]
}

finalizer_transaction_absolute_path_is_safe() {
	local path="$1"

	[[ "$path" == /* && "$path" != *'//'* && "$path" != *'/../'* && \
		"$path" != */.. && "$path" != *'/./'* && "$path" != */. && \
		"$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]]
}

finalizer_transaction_evr_is_safe() {
	[[ "$1" =~ ^[0-9]+:[0-9A-Za-z._+~^]+-[0-9A-Za-z._+~^]+$ ]]
}

finalizer_transaction_nonce_is_safe() {
	[[ "$1" =~ ^[A-F0-9]{32}$ ]]
}

finalizer_transaction_expected_owner() {
	local owner="$1"

	if [[ "$finalizer_transaction_expected_euid" -eq 0 ]]; then
		[[ "$owner" == "0:0" ]]
	else
		[[ "$owner" == "${finalizer_transaction_expected_euid}:$(/usr/bin/id -g)" ]]
	fi
}

finalizer_transaction_validate_environment_names() {
	local entry name

	while IFS= read -r entry; do
		name="${entry%%=*}"
		case "$name" in
			GALAXYBOOK_FINALIZER_FAMILY|GALAXYBOOK_FINALIZER_COMMON_PACKAGE|\
			GALAXYBOOK_FINALIZER_OWN_FLOOR|GALAXYBOOK_FINALIZER_PEER_PACKAGE|\
			GALAXYBOOK_FINALIZER_PEER_FLOOR|GALAXYBOOK_FINALIZER_SETUP_PACKAGE|\
			GALAXYBOOK_FINALIZER_SETUP_FLOOR|GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS|\
			GALAXYBOOK_FINALIZER_DEPENDENT_UNITS|\
			GALAXYBOOK_FINALIZER_SERVICE_UNIT|GALAXYBOOK_FINALIZER_PENDING_DIRECTORY|\
			GALAXYBOOK_FINALIZER_RECOVERY_UNIT|GALAXYBOOK_FINALIZER_STATE_DIRECTORY|\
			GALAXYBOOK_FINALIZER_SERVICE_CGROUP)
				;;
			GALAXYBOOK_FINALIZER_*)
				finalizer_transaction_fail \
					"unexpected configuration variable ${name}"
				return 1
				;;
		esac
	done < <(/usr/bin/env)
}

finalizer_transaction_parse_activators() {
	local value="$1"
	local unit
	declare -A seen=()

	finalizer_transaction_activator_units=()
	IFS=: read -r -a finalizer_transaction_activator_units <<< "$value"
	((${#finalizer_transaction_activator_units[@]} > 0)) || return 1
	for unit in "${finalizer_transaction_activator_units[@]}"; do
		finalizer_transaction_unit_is_safe "$unit" || return 1
		[[ -z "${seen[$unit]:-}" ]] || return 1
		seen["$unit"]=1
	done
}

finalizer_transaction_parse_dependents() {
	local value="$1"
	local unit
	declare -A seen=()

	finalizer_transaction_dependent_units=()
	[[ "$value" != - ]] || return 0
	IFS=: read -r -a finalizer_transaction_dependent_units <<< "$value"
	((${#finalizer_transaction_dependent_units[@]} > 0)) || return 1
	for unit in "${finalizer_transaction_dependent_units[@]}"; do
		finalizer_transaction_unit_is_safe "$unit" || return 1
		[[ -z "${seen[$unit]:-}" ]] || return 1
		seen["$unit"]=1
	done
}

finalizer_transaction_validate_family_contract() {
	local expected_common expected_peer expected_own_floor expected_peer_floor
	local expected_activators expected_dependents expected_service expected_pending expected_cgroup

	case "$finalizer_transaction_family" in
		ov02c10)
			expected_common="galaxybook-ov02c10-kmod-common"
			expected_peer="galaxybook-max98390-kmod-common"
			expected_own_floor="0:1.00.25-0"
			expected_peer_floor="0:1.00.12-0"
			expected_activators="galaxybook-ov02c10-finalize.path:galaxybook-ov02c10-finalize.timer"
			expected_dependents="-"
			expected_service="galaxybook-ov02c10-finalize.service"
			expected_pending="/var/lib/galaxybook-ov02c10/pending"
			expected_cgroup="/sys/fs/cgroup/system.slice/galaxybook-ov02c10-finalize.service/cgroup.procs"
			;;
		max98390)
			expected_common="galaxybook-max98390-kmod-common"
			expected_peer="galaxybook-ov02c10-kmod-common"
			expected_own_floor="0:1.00.12-0"
			expected_peer_floor="0:1.00.25-0"
			expected_activators="max98390-kmod-finalize.path"
			expected_dependents="max98390-hda-i2c-setup.service"
			expected_service="max98390-kmod-finalize.service"
			expected_pending="/var/lib/galaxybook-max98390/pending"
			expected_cgroup="/sys/fs/cgroup/system.slice/max98390-kmod-finalize.service/cgroup.procs"
			;;
		*)
			return 1
			;;
	esac

	[[ "$finalizer_transaction_common_package" == "$expected_common" && \
		"$finalizer_transaction_peer_package" == "$expected_peer" && \
		"$finalizer_transaction_own_floor" == "$expected_own_floor" && \
		"$finalizer_transaction_peer_floor" == "$expected_peer_floor" && \
		"$finalizer_transaction_setup_package" == "galaxybook-setup" && \
		"$finalizer_transaction_setup_floor" == "0:1.00.48-0" && \
		"$finalizer_transaction_activator_units_value" == "$expected_activators" && \
		"$finalizer_transaction_dependent_units_value" == "$expected_dependents" && \
		"$finalizer_transaction_service_unit" == "$expected_service" && \
		"$finalizer_transaction_pending_directory" == "$expected_pending" && \
		"$finalizer_transaction_service_cgroup" == "$expected_cgroup" ]] || return 1

	[[ "$finalizer_transaction_recovery_unit" =~ \
		^galaxybook-${finalizer_transaction_family}-[A-Za-z0-9_.@:-]*recovery\.service$ ]] || return 1
	[[ "$finalizer_transaction_state_directory" =~ \
		^/run/galaxybook-${finalizer_transaction_family}-[A-Za-z0-9_.-]*transaction$ ]] || return 1
}

finalizer_transaction_initialize_family_policy() {
	local unit

	finalizer_transaction_new_unit_file_state=()
	finalizer_transaction_dependent_cgroup=()
	case "$finalizer_transaction_family" in
		ov02c10)
			finalizer_transaction_new_unit_file_state[galaxybook-ov02c10-finalize.path]=enabled
			finalizer_transaction_new_unit_file_state[galaxybook-ov02c10-finalize.timer]=enabled
			finalizer_transaction_new_unit_file_state[galaxybook-ov02c10-finalize.service]=static
			;;
		max98390)
			finalizer_transaction_new_unit_file_state[max98390-kmod-finalize.path]=enabled
			finalizer_transaction_new_unit_file_state[max98390-hda-i2c-setup.service]=enabled
			finalizer_transaction_new_unit_file_state[max98390-kmod-finalize.service]=enabled
			;;
		*) return 1 ;;
	esac
	for unit in "${finalizer_transaction_all_units[@]}"; do
		[[ -n "${finalizer_transaction_new_unit_file_state[$unit]:-}" ]] || return 1
	done
	for unit in "${finalizer_transaction_dependent_units[@]}"; do
		# The family allowlist contains only ordinary system services in
		# system.slice.  Derive their cgroups from the authenticated unit names;
		# do not accept a scriptlet-supplied filesystem path for this proof.
		finalizer_transaction_dependent_cgroup["$unit"]="/sys/fs/cgroup/system.slice/${unit}/cgroup.procs"
	done
}

finalizer_transaction_load_config() {
	local variable value unit

	((finalizer_transaction_config_loaded == 0)) || return 0
	finalizer_transaction_validate_environment_names || return 1
	for variable in \
		GALAXYBOOK_FINALIZER_FAMILY \
		GALAXYBOOK_FINALIZER_COMMON_PACKAGE \
		GALAXYBOOK_FINALIZER_OWN_FLOOR \
		GALAXYBOOK_FINALIZER_PEER_PACKAGE \
		GALAXYBOOK_FINALIZER_PEER_FLOOR \
		GALAXYBOOK_FINALIZER_SETUP_PACKAGE \
		GALAXYBOOK_FINALIZER_SETUP_FLOOR \
		GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS \
		GALAXYBOOK_FINALIZER_DEPENDENT_UNITS \
		GALAXYBOOK_FINALIZER_SERVICE_UNIT \
		GALAXYBOOK_FINALIZER_PENDING_DIRECTORY \
		GALAXYBOOK_FINALIZER_RECOVERY_UNIT \
		GALAXYBOOK_FINALIZER_STATE_DIRECTORY \
		GALAXYBOOK_FINALIZER_SERVICE_CGROUP
	do
		value="${!variable:-}"
		[[ -n "$value" ]] || {
			finalizer_transaction_fail "missing configuration variable ${variable}"
			return 1
		}
		finalizer_transaction_value_is_single_line "$value" || {
			finalizer_transaction_fail "invalid bytes in configuration variable ${variable}"
			return 1
		}
	done
	[[ "${PATH:-}" == "/usr/bin:/usr/sbin" ]] || {
		finalizer_transaction_fail "scriptlet PATH must be /usr/bin:/usr/sbin"
		return 1
	}

	finalizer_transaction_family="$GALAXYBOOK_FINALIZER_FAMILY"
	finalizer_transaction_common_package="$GALAXYBOOK_FINALIZER_COMMON_PACKAGE"
	finalizer_transaction_own_floor="$GALAXYBOOK_FINALIZER_OWN_FLOOR"
	finalizer_transaction_peer_package="$GALAXYBOOK_FINALIZER_PEER_PACKAGE"
	finalizer_transaction_peer_floor="$GALAXYBOOK_FINALIZER_PEER_FLOOR"
	finalizer_transaction_setup_package="$GALAXYBOOK_FINALIZER_SETUP_PACKAGE"
	finalizer_transaction_setup_floor="$GALAXYBOOK_FINALIZER_SETUP_FLOOR"
	finalizer_transaction_activator_units_value="$GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS"
	finalizer_transaction_dependent_units_value="$GALAXYBOOK_FINALIZER_DEPENDENT_UNITS"
	finalizer_transaction_service_unit="$GALAXYBOOK_FINALIZER_SERVICE_UNIT"
	finalizer_transaction_pending_directory="$GALAXYBOOK_FINALIZER_PENDING_DIRECTORY"
	finalizer_transaction_recovery_unit="$GALAXYBOOK_FINALIZER_RECOVERY_UNIT"
	finalizer_transaction_state_directory="$GALAXYBOOK_FINALIZER_STATE_DIRECTORY"
	finalizer_transaction_service_cgroup="$GALAXYBOOK_FINALIZER_SERVICE_CGROUP"

	finalizer_transaction_package_is_safe "$finalizer_transaction_common_package" || return 1
	finalizer_transaction_package_is_safe "$finalizer_transaction_peer_package" || return 1
	finalizer_transaction_package_is_safe "$finalizer_transaction_setup_package" || return 1
	finalizer_transaction_evr_is_safe "$finalizer_transaction_own_floor" || return 1
	finalizer_transaction_evr_is_safe "$finalizer_transaction_peer_floor" || return 1
	finalizer_transaction_evr_is_safe "$finalizer_transaction_setup_floor" || return 1
	finalizer_transaction_unit_is_safe "$finalizer_transaction_service_unit" || return 1
	finalizer_transaction_absolute_path_is_safe "$finalizer_transaction_pending_directory" || return 1
	finalizer_transaction_absolute_path_is_safe "$finalizer_transaction_state_directory" || return 1
	finalizer_transaction_absolute_path_is_safe "$finalizer_transaction_service_cgroup" || return 1
	finalizer_transaction_parse_activators "$finalizer_transaction_activator_units_value" || return 1
	finalizer_transaction_parse_dependents "$finalizer_transaction_dependent_units_value" || return 1
	finalizer_transaction_validate_family_contract || {
		finalizer_transaction_fail "configuration does not match the selected finalizer family"
		return 1
	}

	declare -A seen_units=()
	finalizer_transaction_all_units=()
	for unit in "${finalizer_transaction_activator_units[@]}" \
		"${finalizer_transaction_dependent_units[@]}"; do
		[[ "$unit" != "$finalizer_transaction_service_unit" && \
			-z "${seen_units[$unit]:-}" ]] || return 1
		seen_units["$unit"]=1
		finalizer_transaction_all_units+=("$unit")
	done
	finalizer_transaction_all_units+=("$finalizer_transaction_service_unit")
	finalizer_transaction_initialize_family_policy || return 1
	finalizer_transaction_state_path="${finalizer_transaction_state_directory}/current.state"
	finalizer_transaction_ready_path="${finalizer_transaction_state_directory}/recovery.ready"
	finalizer_transaction_helper_copy_path="${finalizer_transaction_state_directory}/recovery-helper"
	finalizer_transaction_recovery_cgroup="/sys/fs/cgroup/system.slice/${finalizer_transaction_recovery_unit}/cgroup.procs"
	finalizer_transaction_script_path="${BASH_SOURCE[0]}"
	finalizer_transaction_package_roles=(own peer setup)
	finalizer_transaction_package_name[own]="$finalizer_transaction_common_package"
	finalizer_transaction_package_name[peer]="$finalizer_transaction_peer_package"
	finalizer_transaction_package_name[setup]="$finalizer_transaction_setup_package"
	finalizer_transaction_config_value[family]="$finalizer_transaction_family"
	finalizer_transaction_config_value[common]="$finalizer_transaction_common_package"
	finalizer_transaction_config_value[own_floor]="$finalizer_transaction_own_floor"
	finalizer_transaction_config_value[peer]="$finalizer_transaction_peer_package"
	finalizer_transaction_config_value[peer_floor]="$finalizer_transaction_peer_floor"
	finalizer_transaction_config_value[setup]="$finalizer_transaction_setup_package"
	finalizer_transaction_config_value[setup_floor]="$finalizer_transaction_setup_floor"
	finalizer_transaction_config_value[activators]="$finalizer_transaction_activator_units_value"
	finalizer_transaction_config_value[dependents]="$finalizer_transaction_dependent_units_value"
	finalizer_transaction_config_value[service]="$finalizer_transaction_service_unit"
	finalizer_transaction_config_value[pending]="$finalizer_transaction_pending_directory"
	finalizer_transaction_config_value[recovery]="$finalizer_transaction_recovery_unit"
	finalizer_transaction_config_value[state_directory]="$finalizer_transaction_state_directory"
	finalizer_transaction_config_value[service_cgroup]="$finalizer_transaction_service_cgroup"
	finalizer_transaction_config_loaded=1
}

finalizer_transaction_run_systemctl() {
	SYSTEMD_BUS_TIMEOUT=15s \
		"$finalizer_transaction_timeout_command" \
		--foreground --signal=TERM --kill-after=5s \
		"${finalizer_transaction_command_timeout_seconds}s" \
		"$finalizer_transaction_systemctl_command" --no-ask-password "$@"
}

finalizer_transaction_run_worker_systemctl() {
	# Finalizer oneshots declare TimeoutStartSec=20min.  Keep routine manager
	# operations bounded at 120s, but give worker/dependent starts a distinct
	# 21-minute envelope so the client does not time out before systemd does.
	SYSTEMD_BUS_TIMEOUT="${finalizer_transaction_worker_timeout_seconds}s" \
		"$finalizer_transaction_timeout_command" \
		--foreground --signal=TERM --kill-after=5s \
		"${finalizer_transaction_worker_timeout_seconds}s" \
		"$finalizer_transaction_systemctl_command" --no-ask-password "$@"
}

finalizer_transaction_run_systemd_run() {
	SYSTEMD_BUS_TIMEOUT=15s \
		"$finalizer_transaction_timeout_command" \
		--foreground --signal=TERM --kill-after=5s \
		"${finalizer_transaction_command_timeout_seconds}s" \
		"$finalizer_transaction_systemd_run_command" --no-ask-password "$@"
}

finalizer_transaction_ensure_state_directory() {
	local parent owner mode links

	parent="${finalizer_transaction_state_directory%/*}"
	[[ "$parent" != "$finalizer_transaction_state_directory" && \
		-d "$parent" && ! -L "$parent" ]] || {
		finalizer_transaction_fail "state parent is missing or unsafe"
		return 1
	}
	owner="$("$finalizer_transaction_stat_command" -c '%u:%g' -- "$parent")" || return 1
	mode="$("$finalizer_transaction_stat_command" -c '%a' -- "$parent")" || return 1
	finalizer_transaction_expected_owner "$owner" || return 1
	(( (8#${mode}) & 8#022 )) && return 1

	if [[ ! -e "$finalizer_transaction_state_directory" && \
		! -L "$finalizer_transaction_state_directory" ]]; then
		"$finalizer_transaction_install_command" -d -m 0700 -- \
			"$finalizer_transaction_state_directory" || return 1
		if [[ "$finalizer_transaction_expected_euid" -eq 0 ]]; then
			"$finalizer_transaction_chown_command" root:root -- \
				"$finalizer_transaction_state_directory" || return 1
		fi
	fi
	[[ -d "$finalizer_transaction_state_directory" && \
		! -L "$finalizer_transaction_state_directory" ]] || return 1
	owner="$("$finalizer_transaction_stat_command" -c '%u:%g' -- \
		"$finalizer_transaction_state_directory")" || return 1
	mode="$("$finalizer_transaction_stat_command" -c '%a' -- \
		"$finalizer_transaction_state_directory")" || return 1
	links="$("$finalizer_transaction_stat_command" -c '%h' -- \
		"$finalizer_transaction_state_directory")" || return 1
	finalizer_transaction_expected_owner "$owner" || return 1
	[[ "$mode" == 700 && "$links" =~ ^[1-9][0-9]*$ ]]
}

finalizer_transaction_secure_temporary() {
	local output_variable="$1"
	local template="$2"
	local temporary

	temporary="$("$finalizer_transaction_mktemp_command" \
		--tmpdir="$finalizer_transaction_state_directory" "$template")" || return 1
	"$finalizer_transaction_chmod_command" 0600 -- "$temporary" || {
		"$finalizer_transaction_rm_command" -f -- "$temporary"
		return 1
	}
	printf -v "$output_variable" '%s' "$temporary"
}

finalizer_transaction_capture_one_line() {
	local output_variable="$1"
	shift
	local stdout_file stderr_file canonical_file status=0
	local -a lines=()

	finalizer_transaction_secure_temporary stdout_file '.stdout.XXXXXX' || return 1
	finalizer_transaction_secure_temporary stderr_file '.stderr.XXXXXX' || {
		"$finalizer_transaction_rm_command" -f -- "$stdout_file"
		return 1
	}
	"$@" >"$stdout_file" 2>"$stderr_file" || status=$?
	if [[ "$status" -ne 0 || -s "$stderr_file" ]]; then
		"$finalizer_transaction_rm_command" -f -- "$stdout_file" "$stderr_file"
		[[ "$status" -ne 0 ]] && return "$status"
		return 1
	fi
	mapfile -t lines < "$stdout_file"
	if [[ "${#lines[@]}" -ne 1 || -z "${lines[0]}" ]] || \
		! finalizer_transaction_value_is_single_line "${lines[0]}"; then
		"$finalizer_transaction_rm_command" -f -- "$stdout_file" "$stderr_file"
		return 1
	fi
	finalizer_transaction_secure_temporary canonical_file '.canonical.XXXXXX' || {
		"$finalizer_transaction_rm_command" -f -- "$stdout_file" "$stderr_file"
		return 1
	}
	printf '%s\n' "${lines[0]}" > "$canonical_file" || {
		"$finalizer_transaction_rm_command" -f -- \
			"$stdout_file" "$stderr_file" "$canonical_file"
		return 1
	}
	if ! "$finalizer_transaction_cmp_command" --silent -- "$stdout_file" "$canonical_file"; then
		"$finalizer_transaction_rm_command" -f -- \
			"$stdout_file" "$stderr_file" "$canonical_file"
		return 1
	fi
	"$finalizer_transaction_rm_command" -f -- \
		"$stdout_file" "$stderr_file" "$canonical_file"
	printf -v "$output_variable" '%s' "${lines[0]}"
}

finalizer_transaction_run_quiet() {
	local stdout_file stderr_file status=0

	finalizer_transaction_secure_temporary stdout_file '.stdout.XXXXXX' || return 1
	finalizer_transaction_secure_temporary stderr_file '.stderr.XXXXXX' || {
		"$finalizer_transaction_rm_command" -f -- "$stdout_file"
		return 1
	}
	"$@" >"$stdout_file" 2>"$stderr_file" || status=$?
	if [[ "$status" -ne 0 || -s "$stdout_file" || -s "$stderr_file" ]]; then
		"$finalizer_transaction_rm_command" -f -- "$stdout_file" "$stderr_file"
		[[ "$status" -ne 0 ]] && return "$status"
		return 1
	fi
	"$finalizer_transaction_rm_command" -f -- "$stdout_file" "$stderr_file"
}

finalizer_transaction_mask_units() {
	local stdout_file stderr_file canonical_file status=0 valid=1
	local line unit matched
	declare -A seen=()

	finalizer_transaction_secure_temporary stdout_file '.stdout.XXXXXX' || return 1
	finalizer_transaction_secure_temporary stderr_file '.stderr.XXXXXX' || {
		"$finalizer_transaction_rm_command" -f -- "$stdout_file"
		return 1
	}
	finalizer_transaction_secure_temporary canonical_file '.canonical.XXXXXX' || {
		"$finalizer_transaction_rm_command" -f -- "$stdout_file" "$stderr_file"
		return 1
	}
	LC_ALL=C finalizer_transaction_run_systemctl \
		mask --runtime --no-reload --quiet \
		"${finalizer_transaction_all_units[@]}" \
		>"$stdout_file" 2>"$stderr_file" || status=$?
	if [[ "$status" -ne 0 || -s "$stdout_file" ]]; then
		valid=0
	else
		while IFS= read -r line; do
			matched=""
			for unit in "${finalizer_transaction_all_units[@]}"; do
				if [[ "${finalizer_transaction_snapshot_unit_load[$unit]:-}" == not-found && \
					"$line" == "Unit ${unit} does not exist, proceeding anyway." ]]; then
					matched="$unit"
					break
				fi
			done
			if [[ -z "$matched" || -n "${seen[$matched]:-}" ]]; then
				valid=0
				break
			fi
			seen["$matched"]=1
			printf '%s\n' "$line" >> "$canonical_file" || {
				valid=0
				break
			}
		done < "$stderr_file"
		if ((valid == 1)) && \
			! "$finalizer_transaction_cmp_command" --silent -- \
				"$stderr_file" "$canonical_file"; then
			valid=0
		fi
	fi
	"$finalizer_transaction_rm_command" -f -- \
		"$stdout_file" "$stderr_file" "$canonical_file"
	((valid == 1))
}

finalizer_transaction_probe_manager() {
	local status=0 service_cgroup_state recovery_cgroup_state

	if [[ ! -e "$finalizer_transaction_systemd_runtime_directory" && \
		! -L "$finalizer_transaction_systemd_runtime_directory" ]]; then
		return 2
	fi
	[[ -d "$finalizer_transaction_systemd_runtime_directory" && \
		! -L "$finalizer_transaction_systemd_runtime_directory" ]] || return 1
	finalizer_transaction_run_systemctl show --property=Version --value \
		>/dev/null 2>&1 || status=$?
	[[ "$status" -eq 0 ]] && return 0
	finalizer_transaction_cgroup_state service_cgroup_state \
		"$finalizer_transaction_service_cgroup" || return 1
	finalizer_transaction_cgroup_state recovery_cgroup_state \
		"$finalizer_transaction_recovery_cgroup" || return 1
	if [[ "$service_cgroup_state" == populated || \
		"$recovery_cgroup_state" == populated ]]; then
		finalizer_transaction_fail "systemd is unreachable while a finalizer process is visible"
		return 1
	fi
	finalizer_transaction_fail "systemd runtime exists but the manager is unreachable"
	return 1
}

finalizer_transaction_cgroup_state() {
	local output_variable="$1" cgroup="$2" directory events line key value extra
	local owner mode populated="" saw_populated=0
	declare -A seen=()

	directory="${cgroup%/cgroup.procs}"
	events="${directory}/cgroup.events"
	[[ "$directory" != "$cgroup" ]] || return 1
	if [[ ! -e "$directory" && ! -L "$directory" && \
		! -e "$cgroup" && ! -L "$cgroup" && \
		! -e "$events" && ! -L "$events" ]]; then
		printf -v "$output_variable" '%s' absent
		return 0
	fi
	[[ -d "$directory" && ! -L "$directory" ]] || return 1
	owner="$("$finalizer_transaction_stat_command" -c '%u:%g' -- "$directory")" || return 1
	mode="$("$finalizer_transaction_stat_command" -c '%a' -- "$directory")" || return 1
	finalizer_transaction_expected_owner "$owner" || return 1
	(( (8#${mode}) & 8#022 )) && return 1
	finalizer_transaction_file_metadata_is_safe "$cgroup" || return 1
	finalizer_transaction_file_metadata_is_safe "$events" || return 1

	# cgroup.procs only describes the root cgroup.  cgroup.events/populated is
	# recursive and therefore proves that no descendant process survived.
	while :; do
		line=""
		if ! IFS= read -r line; then
			[[ -z "$line" ]] || return 1
			break
		fi
		[[ "$line" =~ ^(populated|frozen)\ [01]$ ]] || return 1
		IFS=' ' read -r key value extra <<< "$line"
		[[ "$key" =~ ^[a-z_]+$ && "$value" =~ ^[01]$ && \
			-z "${extra:-}" && -z "${seen[$key]:-}" ]] || return 1
		seen["$key"]=1
		case "$key" in
			populated)
				populated="$value"
				saw_populated=1
				;;
			frozen) ;;
			*) return 1 ;;
		esac
	done < "$events"
	((saw_populated == 1)) || return 1
	if [[ "$populated" == 1 ]]; then
		printf -v "$output_variable" '%s' populated
	else
		printf -v "$output_variable" '%s' empty
	fi
}

finalizer_transaction_assert_cgroup_empty() {
	local cgroup="$1" attempt state

	for ((attempt = 0; attempt < finalizer_transaction_cgroup_drain_attempts; attempt++)); do
		finalizer_transaction_cgroup_state state "$cgroup" || return 1
		if [[ "$state" == empty || "$state" == absent ]]; then
			return 0
		fi
		"$finalizer_transaction_sleep_command" 0.05
	done
	finalizer_transaction_fail "a finalizer control group did not drain"
}

finalizer_transaction_systemd_property() {
	local output_variable="$1" unit="$2" property="$3" value

	finalizer_transaction_capture_one_line value \
		finalizer_transaction_run_systemctl show \
		"--property=${property}" --value "$unit" || return 1
	printf -v "$output_variable" '%s' "$value"
}

finalizer_transaction_observe_unit_states() {
	local unit="$1" load unit_file_state active

	# systemd 259 reports a canonical empty UnitFileState for an unknown unit.
	# Never accept that empty record as a generic property value: establish
	# LoadState first and synthesize both absent states only for not-found.
	finalizer_transaction_systemd_property load "$unit" LoadState || return 1
	case "$load" in
		loaded)
			finalizer_transaction_systemd_property \
				unit_file_state "$unit" UnitFileState || return 1
			finalizer_transaction_systemd_property active "$unit" ActiveState || return 1
			;;
		not-found)
			unit_file_state=not-found
			active=not-found
			;;
		*) return 1 ;;
	esac
	finalizer_transaction_observed_load="$load"
	finalizer_transaction_observed_unit_file_state="$unit_file_state"
	finalizer_transaction_observed_active="$active"
}

finalizer_transaction_file_metadata_is_safe() {
	local path="$1" expected_mode="${2:-}"
	local owner mode links

	[[ -f "$path" && ! -L "$path" ]] || return 1
	owner="$("$finalizer_transaction_stat_command" -c '%u:%g' -- "$path")" || return 1
	mode="$("$finalizer_transaction_stat_command" -c '%a' -- "$path")" || return 1
	links="$("$finalizer_transaction_stat_command" -c '%h' -- "$path")" || return 1
	finalizer_transaction_expected_owner "$owner" || return 1
	[[ "$links" == 1 ]] || return 1
	if [[ -n "$expected_mode" ]]; then
		[[ "$mode" == "$expected_mode" ]] || return 1
	else
		(( (8#${mode}) & 8#022 )) && return 1
	fi
	return 0
}

finalizer_transaction_hash_open_file() {
	local output_variable="$1" path="$2"
	local fd fd_identity path_identity hash_line computed_hash

	finalizer_transaction_file_metadata_is_safe "$path" || return 1
	exec {fd}<"$path" || return 1
	fd_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "/proc/self/fd/${fd}")" || {
		exec {fd}<&-
		return 1
	}
	path_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "$path")" || {
		exec {fd}<&-
		return 1
	}
	[[ "$fd_identity" == "$path_identity" ]] || {
		exec {fd}<&-
		return 1
	}
	finalizer_transaction_capture_one_line hash_line \
		"$finalizer_transaction_sha256sum_command" -- "/proc/self/fd/${fd}" || {
		exec {fd}<&-
		return 1
	}
	computed_hash="${hash_line%% *}"
	[[ "$computed_hash" =~ ^[a-f0-9]{64}$ ]] || {
		exec {fd}<&-
		return 1
	}
	[[ "$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "$path")" == "$fd_identity" ]] || {
		exec {fd}<&-
		return 1
	}
	exec {fd}<&-
	printf -v "$output_variable" '%s' "$computed_hash"
}

finalizer_transaction_record_is_canonical() {
	local record_path="$1"
	shift
	local canonical_record first=1 field

	finalizer_transaction_secure_temporary canonical_record '.record.XXXXXX' || return 1
	for field in "$@"; do
		if ((first == 1)); then
			printf '%s' "$field" > "$canonical_record" || {
				"$finalizer_transaction_rm_command" -f -- "$canonical_record"
				return 1
			}
			first=0
		else
			printf '\t%s' "$field" >> "$canonical_record" || {
				"$finalizer_transaction_rm_command" -f -- "$canonical_record"
				return 1
			}
		fi
	done
	printf '\n' >> "$canonical_record" || {
		"$finalizer_transaction_rm_command" -f -- "$canonical_record"
		return 1
	}
	if ! "$finalizer_transaction_cmp_command" --silent -- \
		"$record_path" "$canonical_record"; then
		"$finalizer_transaction_rm_command" -f -- "$canonical_record"
		return 1
	fi
	"$finalizer_transaction_rm_command" -f -- "$canonical_record"
}

finalizer_transaction_query_package() {
	local package="$1" require_lock="${2:-0}"
	local quiet_stdout quiet_stderr query_stdout query_stderr status=0 line
	local name epoch version release extra
	local -a lines=()

	finalizer_transaction_package_query_present=0
	finalizer_transaction_package_query_evr=""
	[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock || return 1
	finalizer_transaction_secure_temporary quiet_stdout '.rpm-out.XXXXXX' || return 1
	finalizer_transaction_secure_temporary quiet_stderr '.rpm-err.XXXXXX' || return 1
	"$finalizer_transaction_timeout_command" --foreground --signal=TERM --kill-after=5s \
		"${finalizer_transaction_command_timeout_seconds}s" \
		"$finalizer_transaction_rpm_command" -q --quiet -- "$package" \
		>"$quiet_stdout" 2>"$quiet_stderr" || status=$?
	if [[ -s "$quiet_stdout" || -s "$quiet_stderr" || \
		( "$status" -ne 0 && "$status" -ne 1 ) ]]; then
		"$finalizer_transaction_rm_command" -f -- "$quiet_stdout" "$quiet_stderr"
		return 1
	fi
	"$finalizer_transaction_rm_command" -f -- "$quiet_stdout" "$quiet_stderr"
	[[ "$status" -eq 0 ]] || {
		[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock
		return
	}

	finalizer_transaction_secure_temporary query_stdout '.rpm-out.XXXXXX' || return 1
	finalizer_transaction_secure_temporary query_stderr '.rpm-err.XXXXXX' || return 1
	status=0
	"$finalizer_transaction_timeout_command" --foreground --signal=TERM --kill-after=5s \
		"${finalizer_transaction_command_timeout_seconds}s" \
		"$finalizer_transaction_rpm_command" -q \
		--qf "$finalizer_transaction_rpm_nevr_query_format" -- "$package" \
		>"$query_stdout" 2>"$query_stderr" || status=$?
	mapfile -t lines < "$query_stdout"
	[[ ! -s "$query_stderr" ]] || status=1
	if [[ "$status" -ne 0 || "${#lines[@]}" -ne 1 ]]; then
		"$finalizer_transaction_rm_command" -f -- "$query_stdout" "$query_stderr"
		return 1
	fi
	line="${lines[0]}"
	IFS=$'\t' read -r name epoch version release extra <<< "$line"
	if [[ -n "${extra:-}" || "$name" != "$package" || ! "$epoch" =~ ^[0-9]+$ || \
		! "$version" =~ ^[0-9A-Za-z._+~^]+$ || \
		! "$release" =~ ^[0-9A-Za-z._+~^]+$ ]] || \
		! finalizer_transaction_record_is_canonical "$query_stdout" \
			"$name" "$epoch" "$version" "$release"; then
		"$finalizer_transaction_rm_command" -f -- "$query_stdout" "$query_stderr"
		return 1
	fi
	"$finalizer_transaction_rm_command" -f -- "$query_stdout" "$query_stderr"
	finalizer_transaction_package_query_present=1
	finalizer_transaction_package_query_evr="${epoch}:${version}-${release}"
	[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock
}

finalizer_transaction_snapshot_units() {
	local unit load unit_file_state active path hash="-" present=0

	for unit in "${finalizer_transaction_all_units[@]}"; do
		finalizer_transaction_observe_unit_states "$unit" || return 1
		load="$finalizer_transaction_observed_load"
		unit_file_state="$finalizer_transaction_observed_unit_file_state"
		active="$finalizer_transaction_observed_active"
		[[ "$load" =~ ^(loaded|not-found)$ ]] || return 1
		[[ "$unit_file_state" =~ ^(enabled|enabled-runtime|disabled|static|indirect|generated|not-found)$ ]] || return 1
		# Transitional or failed states cannot be restored exactly.  Abort before
		# creating transaction state and let RPM retry once the graph is stable.
		[[ "$active" =~ ^(active|inactive|not-found)$ ]] || return 1
		path="${finalizer_transaction_unit_directory}/${unit}"
		present=0
		hash="-"
		if [[ -e "$path" || -L "$path" ]]; then
			finalizer_transaction_hash_open_file hash "$path" || return 1
			present=1
		fi
		if [[ "$load" == not-found ]]; then
			[[ "$unit_file_state" == not-found && "$active" == not-found && \
				"$present" == 0 ]] || return 1
		else
			[[ "$unit_file_state" != not-found && "$active" != not-found && \
				"$present" == 1 ]] || return 1
		fi
		finalizer_transaction_snapshot_unit_load["$unit"]="$load"
		finalizer_transaction_snapshot_unit_file_state["$unit"]="$unit_file_state"
		finalizer_transaction_snapshot_unit_active["$unit"]="$active"
		finalizer_transaction_snapshot_unit_present["$unit"]="$present"
		finalizer_transaction_snapshot_unit_sha256["$unit"]="$hash"
	done
}

finalizer_transaction_generate_nonce() {
	local raw

	raw="$(< /proc/sys/kernel/random/uuid)" || return 1
	raw="${raw//-/}"
	raw="${raw^^}"
	finalizer_transaction_nonce_is_safe "$raw" || return 1
	finalizer_transaction_nonce="$raw"
}

finalizer_transaction_open_exclusive_output() {
	local output_variable="$1" path="$2" mode="$3" created_fd
	local restore_noclobber=0

	[[ ! -e "$path" && ! -L "$path" ]] || return 1
	if [[ ! -o noclobber ]]; then
		set -o noclobber
		restore_noclobber=1
	fi
	if ! exec {created_fd}>"$path"; then
		((restore_noclobber == 0)) || set +o noclobber
		return 1
	fi
	((restore_noclobber == 0)) || set +o noclobber
	"$finalizer_transaction_chmod_command" "$mode" -- "/proc/self/fd/${created_fd}" || {
		exec {created_fd}>&-
		return 1
	}
	if [[ "$finalizer_transaction_expected_euid" -eq 0 ]]; then
		"$finalizer_transaction_chown_command" root:root -- "/proc/self/fd/${created_fd}" || {
			exec {created_fd}>&-
			return 1
		}
	fi
	finalizer_transaction_file_metadata_is_safe "$path" "${mode#0}" || {
		exec {created_fd}>&-
		return 1
	}
	[[ "$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "/proc/self/fd/${created_fd}")" == \
		"$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "$path")" ]] || {
		exec {created_fd}>&-
		return 1
	}
	printf -v "$output_variable" '%s' "$created_fd"
}

finalizer_transaction_write_state_payload() {
	local fd="$1" unit

	{
		printf '%s\n' "$finalizer_transaction_state_version"
		printf 'nonce=%s\n' "$finalizer_transaction_nonce"
		printf 'family=%s\n' "$finalizer_transaction_family"
		printf 'common=%s\n' "$finalizer_transaction_common_package"
		printf 'own_floor=%s\n' "$finalizer_transaction_own_floor"
		printf 'peer=%s\n' "$finalizer_transaction_peer_package"
		printf 'peer_floor=%s\n' "$finalizer_transaction_peer_floor"
		printf 'setup=%s\n' "$finalizer_transaction_setup_package"
		printf 'setup_floor=%s\n' "$finalizer_transaction_setup_floor"
		printf 'activators=%s\n' "$finalizer_transaction_activator_units_value"
		printf 'dependents=%s\n' "$finalizer_transaction_dependent_units_value"
		printf 'service=%s\n' "$finalizer_transaction_service_unit"
		printf 'pending=%s\n' "$finalizer_transaction_pending_directory"
		printf 'recovery=%s\n' "$finalizer_transaction_recovery_unit"
		printf 'state_directory=%s\n' "$finalizer_transaction_state_directory"
		printf 'service_cgroup=%s\n' "$finalizer_transaction_service_cgroup"
		printf 'unit_count=%s\n' "${#finalizer_transaction_all_units[@]}"
		for unit in "${finalizer_transaction_all_units[@]}"; do
			printf 'unit\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$unit" "${finalizer_transaction_snapshot_unit_load[$unit]}" \
				"${finalizer_transaction_snapshot_unit_file_state[$unit]}" \
				"${finalizer_transaction_snapshot_unit_active[$unit]}" \
				"${finalizer_transaction_snapshot_unit_present[$unit]}" \
				"${finalizer_transaction_snapshot_unit_sha256[$unit]}"
		done
	} >&"$fd"
}

finalizer_transaction_write_new_state() {
	local fd

	finalizer_transaction_open_exclusive_output fd "$finalizer_transaction_state_path" 0600 || {
		finalizer_transaction_fail "could not create transaction state with O_EXCL"
		return 1
	}
	finalizer_transaction_write_state_payload "$fd" || {
		exec {fd}>&-
		return 1
	}
	exec {fd}>&-
	finalizer_transaction_file_metadata_is_safe "$finalizer_transaction_state_path" 600
}

finalizer_transaction_state_take_line() {
	local output_variable="$1"

	((index < ${#lines[@]})) || return 1
	printf -v "$output_variable" '%s' "${lines[index]}"
	((index += 1))
}

finalizer_transaction_parse_state() {
	local expected_nonce="${1:-}" fd fd_identity path_identity
	local canonical_state
	local -a lines=()
	local index=0 key value present unit load unit_file active hash
	local unit_count
	declare -A seen_units=()

	finalizer_transaction_file_metadata_is_safe "$finalizer_transaction_state_path" 600 || return 1
	exec {fd}<"$finalizer_transaction_state_path" || return 1
	fd_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "/proc/self/fd/${fd}")" || return 1
	path_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "$finalizer_transaction_state_path")" || return 1
	[[ "$fd_identity" == "$path_identity" ]] || return 1
	mapfile -t lines < "/proc/self/fd/${fd}"
	[[ "$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "$finalizer_transaction_state_path")" == "$fd_identity" ]] || return 1
	((${#lines[@]} >= 19)) || return 1
	finalizer_transaction_state_take_line value || return 1
	[[ "$value" == "$finalizer_transaction_state_version" ]] || return 1

	for key in nonce family common own_floor peer peer_floor setup setup_floor \
		activators dependents service pending recovery state_directory service_cgroup; do
		finalizer_transaction_state_take_line value || return 1
		[[ "$value" == "${key}="* ]] || return 1
		value="${value#*=}"
		case "$key" in
			nonce) finalizer_transaction_nonce="$value" ;;
			family) [[ "$value" == "$finalizer_transaction_family" ]] || return 1 ;;
			common) [[ "$value" == "$finalizer_transaction_common_package" ]] || return 1 ;;
			own_floor) [[ "$value" == "$finalizer_transaction_own_floor" ]] || return 1 ;;
			peer) [[ "$value" == "$finalizer_transaction_peer_package" ]] || return 1 ;;
			peer_floor) [[ "$value" == "$finalizer_transaction_peer_floor" ]] || return 1 ;;
			setup) [[ "$value" == "$finalizer_transaction_setup_package" ]] || return 1 ;;
			setup_floor) [[ "$value" == "$finalizer_transaction_setup_floor" ]] || return 1 ;;
			activators) [[ "$value" == "$finalizer_transaction_activator_units_value" ]] || return 1 ;;
			dependents) [[ "$value" == "$finalizer_transaction_dependent_units_value" ]] || return 1 ;;
			service) [[ "$value" == "$finalizer_transaction_service_unit" ]] || return 1 ;;
			pending) [[ "$value" == "$finalizer_transaction_pending_directory" ]] || return 1 ;;
			recovery) [[ "$value" == "$finalizer_transaction_recovery_unit" ]] || return 1 ;;
			state_directory) [[ "$value" == "$finalizer_transaction_state_directory" ]] || return 1 ;;
			service_cgroup) [[ "$value" == "$finalizer_transaction_service_cgroup" ]] || return 1 ;;
		esac
	done
	finalizer_transaction_nonce_is_safe "$finalizer_transaction_nonce" || return 1
	[[ -z "$expected_nonce" || "$expected_nonce" == "$finalizer_transaction_nonce" ]] || return 1

	finalizer_transaction_state_take_line value || return 1
	[[ "$value" == unit_count=* ]] || return 1
	unit_count="${value#*=}"
	[[ "$unit_count" =~ ^[1-9][0-9]*$ && \
		"$unit_count" -eq "${#finalizer_transaction_all_units[@]}" ]] || return 1
	for ((; unit_count > 0; unit_count--)); do
		finalizer_transaction_state_take_line value || return 1
		IFS=$'\t' read -r key unit load unit_file active present hash value <<< "$value"
		[[ "$key" == unit && -z "${value:-}" && -z "${seen_units[$unit]:-}" ]] || return 1
		[[ " ${finalizer_transaction_all_units[*]} " == *" ${unit} "* ]] || return 1
		[[ "$load" =~ ^(loaded|not-found)$ && \
			"$unit_file" =~ ^(enabled|enabled-runtime|disabled|static|indirect|generated|not-found)$ && \
			"$active" =~ ^(active|inactive|not-found)$ && \
			"$present" =~ ^[01]$ ]] || return 1
		if [[ "$load" == not-found ]]; then
			[[ "$unit_file" == not-found && "$active" == not-found && \
				"$present" == 0 && "$hash" == - ]] || return 1
		else
			[[ "$unit_file" != not-found && "$active" != not-found && \
				"$present" == 1 ]] || return 1
			[[ "$hash" =~ ^[a-f0-9]{64}$ ]] || return 1
		fi
		seen_units["$unit"]=1
		finalizer_transaction_snapshot_unit_load["$unit"]="$load"
		finalizer_transaction_snapshot_unit_file_state["$unit"]="$unit_file"
		finalizer_transaction_snapshot_unit_active["$unit"]="$active"
		finalizer_transaction_snapshot_unit_present["$unit"]="$present"
		finalizer_transaction_snapshot_unit_sha256["$unit"]="$hash"
	done
	[[ "$index" -eq "${#lines[@]}" && "${#seen_units[@]}" -eq "${#finalizer_transaction_all_units[@]}" ]] || return 1
	[[ "$finalizer_transaction_nonce" == "${lines[1]#nonce=}" ]] || return 1
	finalizer_transaction_secure_temporary canonical_state '.state-check.XXXXXX' || return 1
	{
		finalizer_transaction_write_state_payload 9
	} 9>"$canonical_state" || {
		"$finalizer_transaction_rm_command" -f -- "$canonical_state"
		return 1
	}
	finalizer_transaction_run_quiet "$finalizer_transaction_cmp_command" --silent -- \
		"/proc/self/fd/${fd}" "$canonical_state" || {
		"$finalizer_transaction_rm_command" -f -- "$canonical_state"
		return 1
	}
	"$finalizer_transaction_rm_command" -f -- "$canonical_state"
	[[ "$finalizer_transaction_state_path" -ef "/proc/self/fd/${fd}" ]] || return 1
	exec {fd}<&-
}

finalizer_transaction_copy_helper() {
	local source_fd output_fd source_identity

	finalizer_transaction_file_metadata_is_safe "$finalizer_transaction_script_path" || return 1
	exec {source_fd}<"$finalizer_transaction_script_path" || return 1
	source_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- \
		"/proc/self/fd/${source_fd}")" || {
		exec {source_fd}<&-
		return 1
	}
	[[ "$source_identity" == "$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- \
		"$finalizer_transaction_script_path")" ]] || {
		exec {source_fd}<&-
		return 1
	}
	finalizer_transaction_open_exclusive_output output_fd \
		"$finalizer_transaction_helper_copy_path" 0700 || {
		exec {source_fd}<&-
		return 1
	}
	"$finalizer_transaction_cat_command" -- "/proc/self/fd/${source_fd}" >&"$output_fd" || {
		exec {source_fd}<&-
		exec {output_fd}>&-
		return 1
	}
	[[ "$source_identity" == "$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- \
		"$finalizer_transaction_script_path")" ]] || {
		exec {source_fd}<&-
		exec {output_fd}>&-
		return 1
	}
	exec {source_fd}<&-
	exec {output_fd}>&-
	finalizer_transaction_file_metadata_is_safe "$finalizer_transaction_helper_copy_path" 700
}

finalizer_transaction_write_ready_payload() {
	local fd="$1" state_identity

	state_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- \
		"$finalizer_transaction_state_path")" || return 1
	{
		printf '%s\n' "$finalizer_transaction_ready_version"
		printf 'nonce=%s\n' "$finalizer_transaction_nonce"
		printf 'state=%s\n' "$state_identity"
	} >&"$fd"
}

finalizer_transaction_publish_ready() {
	local fd

	if [[ -e "$finalizer_transaction_ready_path" || \
		-L "$finalizer_transaction_ready_path" ]]; then
		if finalizer_transaction_ready_is_authentic; then
			return 0
		fi
		# A signal can interrupt the previous generation after O_EXCL creation
		# but before the canonical payload is complete.  Only the exact root-safe
		# 0600 pathname may be retired and recreated for the same parsed nonce.
		finalizer_transaction_safe_remove \
			"$finalizer_transaction_ready_path" 600 || return 1
	fi
	finalizer_transaction_open_exclusive_output fd "$finalizer_transaction_ready_path" 0600 || return 1
	finalizer_transaction_write_ready_payload "$fd" || {
		exec {fd}>&-
		return 1
	}
	exec {fd}>&-
}

finalizer_transaction_ready_is_authentic() {
	local fd fd_identity path_identity
	local canonical_ready

	finalizer_transaction_file_metadata_is_safe "$finalizer_transaction_ready_path" 600 || return 1
	exec {fd}<"$finalizer_transaction_ready_path" || return 1
	fd_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "/proc/self/fd/${fd}")" || return 1
	path_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "$finalizer_transaction_ready_path")" || return 1
	[[ "$fd_identity" == "$path_identity" ]] || return 1
	finalizer_transaction_secure_temporary canonical_ready '.ready-check.XXXXXX' || {
		exec {fd}<&-
		return 1
	}
	{
		finalizer_transaction_write_ready_payload 9
	} 9>"$canonical_ready" || {
		exec {fd}<&-
		"$finalizer_transaction_rm_command" -f -- "$canonical_ready"
		return 1
	}
	finalizer_transaction_run_quiet "$finalizer_transaction_cmp_command" --silent -- \
		"/proc/self/fd/${fd}" "$canonical_ready" || {
		exec {fd}<&-
		"$finalizer_transaction_rm_command" -f -- "$canonical_ready"
		return 1
	}
	"$finalizer_transaction_rm_command" -f -- "$canonical_ready"
	[[ "$finalizer_transaction_ready_path" -ef "/proc/self/fd/${fd}" ]] || {
		exec {fd}<&-
		return 1
	}
	exec {fd}<&-
}

finalizer_transaction_helper_copy_is_authentic() {
	local source_hash copy_hash

	finalizer_transaction_file_metadata_is_safe \
		"$finalizer_transaction_helper_copy_path" 700 || return 1
	finalizer_transaction_hash_open_file source_hash \
		"$finalizer_transaction_script_path" || return 1
	finalizer_transaction_hash_open_file copy_hash \
		"$finalizer_transaction_helper_copy_path" || return 1
	[[ "$source_hash" == "$copy_hash" ]]
}

finalizer_transaction_wait_ready() {
	local attempt

	for ((attempt = 0; attempt < finalizer_transaction_ready_timeout_seconds * 20; attempt++)); do
		if finalizer_transaction_ready_is_authentic; then
			return 0
		fi
		"$finalizer_transaction_sleep_command" 0.05
	done
	finalizer_transaction_fail "transient recovery did not publish authenticated READY state"
}

finalizer_transaction_arm_recovery() {
	local -a command

	command=(
		--quiet --no-block --collect
		"--unit=${finalizer_transaction_recovery_unit}"
		--service-type=exec
		--property=KillMode=control-group
		--property=TimeoutStopSec=15s
		--property=Restart=on-failure
		--property=RestartSec=5s
		--property=StartLimitIntervalSec=0
		--property=RestartPreventExitStatus=75
		--expand-environment=no
		"$finalizer_transaction_env_command" -i
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
		"$finalizer_transaction_bash_command" --noprofile --norc
		"$finalizer_transaction_helper_copy_path" --recover "$finalizer_transaction_nonce"
	)
	finalizer_transaction_run_quiet finalizer_transaction_run_systemd_run \
		"${command[@]}" || return 1
	finalizer_transaction_wait_ready
}

finalizer_transaction_assert_unit_inactive() {
	local unit="$1" active

	finalizer_transaction_systemd_property active "$unit" ActiveState || return 1
	[[ "$active" == inactive || "$active" == failed ]] || {
		finalizer_transaction_fail "unit ${unit} did not become inactive"
		return 1
	}
}

finalizer_transaction_mask_and_drain() {
	local unit file_state

	# Mask the worker together with its activators and dependent services before
	# the first stop.  This closes path/timer, sound.target and manual-start races
	# without ever masking sound.target itself.
	finalizer_transaction_mask_units || return 1
	finalizer_transaction_run_quiet finalizer_transaction_run_systemctl \
		daemon-reload || return 1
	for unit in "${finalizer_transaction_all_units[@]}"; do
		finalizer_transaction_systemd_property file_state "$unit" UnitFileState || return 1
		[[ "$file_state" == masked-runtime || "$file_state" == masked ]] || return 1
	done
	finalizer_transaction_run_quiet finalizer_transaction_run_systemctl \
		stop "${finalizer_transaction_activator_units[@]}" || return 1
	for unit in "${finalizer_transaction_activator_units[@]}"; do
		finalizer_transaction_assert_unit_inactive "$unit" || return 1
	done
	if ((${#finalizer_transaction_dependent_units[@]} > 0)); then
		finalizer_transaction_run_quiet finalizer_transaction_run_systemctl \
			stop "${finalizer_transaction_dependent_units[@]}" || return 1
		for unit in "${finalizer_transaction_dependent_units[@]}"; do
			finalizer_transaction_assert_unit_inactive "$unit" || return 1
			finalizer_transaction_assert_cgroup_empty \
				"${finalizer_transaction_dependent_cgroup[$unit]}" || return 1
		done
	fi
	finalizer_transaction_run_quiet finalizer_transaction_run_systemctl \
		stop "$finalizer_transaction_service_unit" || return 1
	finalizer_transaction_assert_unit_inactive "$finalizer_transaction_service_unit" || return 1
	finalizer_transaction_assert_cgroup_empty "$finalizer_transaction_service_cgroup"
}

finalizer_transaction_validate_runtime_masks() {
	local unit file_state

	for unit in "${finalizer_transaction_all_units[@]}"; do
		finalizer_transaction_systemd_property file_state "$unit" UnitFileState || return 1
		[[ "$file_state" == masked-runtime || "$file_state" == masked ]] || return 1
		finalizer_transaction_assert_unit_inactive "$unit" || return 1
	done
	for unit in "${finalizer_transaction_dependent_units[@]}"; do
		finalizer_transaction_assert_cgroup_empty \
			"${finalizer_transaction_dependent_cgroup[$unit]}" || return 1
	done
	finalizer_transaction_assert_cgroup_empty "$finalizer_transaction_service_cgroup"
}

finalizer_transaction_recovery_preflight() {
	local load_state active_state

	finalizer_transaction_systemd_property load_state \
		"$finalizer_transaction_recovery_unit" LoadState || return 1
	case "$load_state" in
		not-found)
			finalizer_transaction_assert_cgroup_empty \
				"$finalizer_transaction_recovery_cgroup"
			;;
		loaded)
			finalizer_transaction_systemd_property active_state \
				"$finalizer_transaction_recovery_unit" ActiveState || return 1
			[[ "$active_state" == active || "$active_state" == activating || \
				"$active_state" == inactive || "$active_state" == failed ]]
			;;
		*) return 1 ;;
	esac
}

finalizer_transaction_recovery_is_live() {
	local load_state active_state cgroup_state

	finalizer_transaction_systemd_property load_state \
		"$finalizer_transaction_recovery_unit" LoadState || return 1
	[[ "$load_state" == loaded ]] || return 1
	finalizer_transaction_systemd_property active_state \
		"$finalizer_transaction_recovery_unit" ActiveState || return 1
	[[ "$active_state" == active || "$active_state" == activating ]] || return 1
	finalizer_transaction_cgroup_state cgroup_state \
		"$finalizer_transaction_recovery_cgroup" || return 1
	[[ "$cgroup_state" == populated ]]
}

finalizer_transaction_cancel_recovery() {
	local load_state active_state stop_status=0

	finalizer_transaction_recovery_preflight || return 1
	finalizer_transaction_systemd_property load_state \
		"$finalizer_transaction_recovery_unit" LoadState || return 1
	[[ "$load_state" == loaded ]] || return 0
	finalizer_transaction_systemd_property active_state \
		"$finalizer_transaction_recovery_unit" ActiveState || return 1
	[[ "$active_state" == active || "$active_state" == activating || \
		"$active_state" == inactive || "$active_state" == failed ]] || return 1
	# A failed/inactive unit can still retain descendants.  Stop every loaded
	# generation idempotently before accepting the recursive cgroup proof.
	finalizer_transaction_run_quiet finalizer_transaction_run_systemctl \
		stop "$finalizer_transaction_recovery_unit" || stop_status=$?
	# Once stop has been issued, cgroup emptiness is the terminal proof.  A
	# nonzero stop status with an empty cgroup is still a completed cancellation;
	# a populated cgroup means the recovery remains alive and can safely own a
	# returned posttrans failure.
	finalizer_transaction_assert_cgroup_empty \
		"$finalizer_transaction_recovery_cgroup" || return 1
	: "$stop_status"
	return 0
}

finalizer_transaction_retire_recovery() {
	local load_state attempt

	finalizer_transaction_cancel_recovery || return 1
	finalizer_transaction_systemd_property load_state \
		"$finalizer_transaction_recovery_unit" LoadState || return 1
	[[ "$load_state" == not-found ]] && return 0
	[[ "$load_state" == loaded ]] || return 1
	finalizer_transaction_run_quiet finalizer_transaction_run_systemctl \
		reset-failed "$finalizer_transaction_recovery_unit" || return 1
	for ((attempt = 0; attempt < 200; attempt++)); do
		finalizer_transaction_systemd_property load_state \
			"$finalizer_transaction_recovery_unit" LoadState || return 1
		[[ "$load_state" == not-found ]] && return 0
		[[ "$load_state" == loaded ]] || return 1
		"$finalizer_transaction_sleep_command" 0.05
	done
	return 1
}

finalizer_transaction_safe_remove() {
	local path="$1" mode="$2"

	[[ ! -e "$path" && ! -L "$path" ]] && return 0
	finalizer_transaction_file_metadata_is_safe "$path" "$mode" || return 1
	"$finalizer_transaction_rm_command" -- "$path"
}

finalizer_transaction_safe_remove_helper_copy() {
	local path="$finalizer_transaction_helper_copy_path"

	[[ ! -e "$path" && ! -L "$path" ]] && return 0
	# 0600 is the only possible pre-chmod mode under the fixed umask if an
	# asynchronous exit interrupts O_EXCL helper creation.  A complete copy is
	# 0700.  No other metadata is accepted for cleanup or replacement.
	if ! finalizer_transaction_file_metadata_is_safe "$path" 700 && \
		! finalizer_transaction_file_metadata_is_safe "$path" 600; then
		return 1
	fi
	"$finalizer_transaction_rm_command" -- "$path"
}

finalizer_transaction_prepare_fresh_state() {
	# A prior successful recovery may have unlinked its authority state before
	# its executable pathname could be removed.  Such an orphan is inert and is
	# cleaned strictly before creating a new O_EXCL generation.
	finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600 || return 1
	finalizer_transaction_safe_remove_helper_copy || return 1
	finalizer_transaction_snapshot_units || return 1
	finalizer_transaction_generate_nonce || return 1
	finalizer_transaction_phase="pretrans-building"
	finalizer_transaction_write_new_state || {
		if finalizer_transaction_safe_remove "$finalizer_transaction_state_path" 600; then
			finalizer_transaction_phase="idle"
		fi
		return 1
	}
	finalizer_transaction_copy_helper || {
		if finalizer_transaction_safe_remove_helper_copy && \
			finalizer_transaction_safe_remove "$finalizer_transaction_state_path" 600; then
			finalizer_transaction_phase="idle"
		fi
		return 1
	}
	finalizer_transaction_phase="pretrans-arming"
	if ! finalizer_transaction_arm_recovery; then
		# systemd-run may fail after creating the transient.  Only clean files once
		# a strict stop/cgroup proof says that no recovery can still consume them.
		if finalizer_transaction_retire_recovery && \
			finalizer_transaction_cleanup_state; then
			finalizer_transaction_phase="idle"
		fi
		return 1
	fi
	finalizer_transaction_phase="pretrans-armed"
	finalizer_transaction_mask_and_drain || return 1
	finalizer_transaction_phase="idle"
}

finalizer_transaction_adopt_stale_state() {
	finalizer_transaction_parse_state || {
		finalizer_transaction_fail "existing transaction state is not authentic"
		return 1
	}
	finalizer_transaction_validate_runtime_masks || {
		finalizer_transaction_fail "stale transaction state is not safely quiescent"
		return 1
	}
	finalizer_transaction_phase="stale-maintenance"
	finalizer_transaction_retire_recovery || return 1
	finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600 || return 1
	finalizer_transaction_safe_remove_helper_copy || return 1
	finalizer_transaction_copy_helper || return 1
	finalizer_transaction_arm_recovery || return 1
	finalizer_transaction_phase="idle"
}

finalizer_transaction_pretrans() {
	local rpm_instance_count="$1" manager_status=0

	((rpm_instance_count >= 2)) || return 0
	finalizer_transaction_load_config || return 1
	finalizer_transaction_probe_manager || manager_status=$?
	case "$manager_status" in
		0) ;;
		2) return 0 ;;
		*) return 1 ;;
	esac
	finalizer_transaction_ensure_state_directory || return 1
	if [[ -e "$finalizer_transaction_state_path" || -L "$finalizer_transaction_state_path" ]]; then
		finalizer_transaction_adopt_stale_state
	else
		finalizer_transaction_prepare_fresh_state
	fi
}

finalizer_transaction_validate_rpm_lock_ancestry() {
	local directory owner mode

	for directory in "${finalizer_transaction_rpm_lock_ancestry[@]}"; do
		[[ -d "$directory" && ! -L "$directory" ]] || return 1
		owner="$("$finalizer_transaction_stat_command" -c '%u:%g' -- "$directory")" || return 1
		mode="$("$finalizer_transaction_stat_command" -c '%a' -- "$directory")" || return 1
		finalizer_transaction_expected_owner "$owner" || return 1
		(( (8#${mode}) & 8#022 )) && return 1
	done
	return 0
}

finalizer_transaction_validate_rpm_lock() {
	local fd="$finalizer_transaction_rpm_lock_fd" fd_path
	local fd_identity path_identity fd_metadata path_metadata

	[[ "$fd" =~ ^[0-9]+$ ]] || return 1
	fd_path="/proc/self/fd/${fd}"
	[[ -r "$fd_path" && -f "$fd_path" && -f "$finalizer_transaction_rpm_lock_path" && \
		! -L "$finalizer_transaction_rpm_lock_path" ]] || return 1
	fd_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "$fd_path")" || return 1
	path_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- \
		"$finalizer_transaction_rpm_lock_path")" || return 1
	[[ "$fd_identity" == "$path_identity" ]] || return 1
	fd_metadata="$("$finalizer_transaction_stat_command" -Lc '%u:%g:%a:%h' -- "$fd_path")" || return 1
	path_metadata="$("$finalizer_transaction_stat_command" -Lc '%u:%g:%a:%h' -- \
		"$finalizer_transaction_rpm_lock_path")" || return 1
	[[ "$fd_metadata" == "$path_metadata" ]] || return 1
	finalizer_transaction_expected_owner "${path_metadata%:*:*}" || return 1
	local mode_and_links="${path_metadata#*:*:}"
	local mode="${mode_and_links%%:*}" links="${mode_and_links##*:}"
	(( (8#${mode}) & 8#022 )) && return 1
	[[ "$links" == 1 ]] || return 1
	finalizer_transaction_run_quiet "$finalizer_transaction_flock_command" \
		--fcntl --shared --nonblock "$fd"
}

finalizer_transaction_acquire_rpm_lock() {
	local fd

	finalizer_transaction_validate_rpm_lock_ancestry || return 1
	finalizer_transaction_file_metadata_is_safe "$finalizer_transaction_rpm_lock_path" || return 1
	exec {fd}<"$finalizer_transaction_rpm_lock_path" || return 1
	finalizer_transaction_rpm_lock_fd="$fd"
	# A bounded wait prevents the scriptlet-side command from hanging forever;
	# Restart=on-failure retries the recovery indefinitely across long RPM
	# transactions without a RuntimeMaxSec kill window.
	if ! finalizer_transaction_run_quiet "$finalizer_transaction_flock_command" \
		--fcntl --shared \
		--timeout "$finalizer_transaction_rpm_lock_timeout_seconds" "$fd"; then
		exec {fd}<&-
		finalizer_transaction_rpm_lock_fd=""
		return 1
	fi
	if ! finalizer_transaction_validate_rpm_lock_ancestry || \
		! finalizer_transaction_validate_rpm_lock; then
		exec {fd}<&-
		finalizer_transaction_rpm_lock_fd=""
		return 1
	fi
}

finalizer_transaction_rpm_vercmp() {
	local output_variable="$1" left="$2" right="$3" comparison_result
	local rpm_lua_expression

	[[ "$left" =~ ^[0-9A-Za-z._+~^]+$ && "$right" =~ ^[0-9A-Za-z._+~^]+$ ]] || return 1
	printf -v rpm_lua_expression '%%%s' \
		'{lua:io.write(rpm.vercmp(os.getenv("RPMCMP_LEFT"), os.getenv("RPMCMP_RIGHT")), "\n")}'
	finalizer_transaction_capture_one_line comparison_result \
		"$finalizer_transaction_env_command" -i PATH=/usr/bin:/usr/sbin \
		RPMCMP_LEFT="$left" RPMCMP_RIGHT="$right" \
		"$finalizer_transaction_rpm_command" --eval \
		"$rpm_lua_expression" || return 1
	[[ "$comparison_result" =~ ^-?[01]$ ]] || return 1
	printf -v "$output_variable" '%s' "$comparison_result"
}

finalizer_transaction_evr_compare() {
	local output_variable="$1" left="$2" right="$3"
	local left_epoch left_version left_release right_epoch right_version right_release result

	finalizer_transaction_evr_is_safe "$left" || return 1
	finalizer_transaction_evr_is_safe "$right" || return 1
	left_epoch="${left%%:*}"; left="${left#*:}"
	left_version="${left%-*}"; left_release="${left##*-}"
	right_epoch="${right%%:*}"; right="${right#*:}"
	right_version="${right%-*}"; right_release="${right##*-}"
	finalizer_transaction_rpm_vercmp result "$left_epoch" "$right_epoch" || return 1
	if [[ "$result" == 0 ]]; then
		finalizer_transaction_rpm_vercmp result "$left_version" "$right_version" || return 1
	fi
	if [[ "$result" == 0 ]]; then
		finalizer_transaction_rpm_vercmp result "$left_release" "$right_release" || return 1
	fi
	printf -v "$output_variable" '%s' "$result"
}

finalizer_transaction_snapshot_current_packages() {
	local require_lock="${1:-1}" role package

	finalizer_transaction_current_package_present=()
	finalizer_transaction_current_package_evr=()
	for role in "${finalizer_transaction_package_roles[@]}"; do
		package="${finalizer_transaction_package_name[$role]}"
		finalizer_transaction_query_package "$package" "$require_lock" || return 1
		finalizer_transaction_current_package_present["$role"]="$finalizer_transaction_package_query_present"
		finalizer_transaction_current_package_evr["$role"]="${finalizer_transaction_package_query_evr:--}"
	done
}

finalizer_transaction_verify_common_package() {
	local require_lock="${1:-1}"

	[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock || return 1
	finalizer_transaction_run_quiet \
		"$finalizer_transaction_timeout_command" \
		--foreground --signal=TERM --kill-after=5s \
		"${finalizer_transaction_command_timeout_seconds}s" \
		"$finalizer_transaction_rpm_command" \
		--verify --nodeps --noscripts --nomtime --nosize -- \
		"$finalizer_transaction_common_package" || return 1
	[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock
}

finalizer_transaction_package_meets_floor_if_present() {
	local role="$1" floor="$2" mandatory="$3" comparison

	if [[ "${finalizer_transaction_current_package_present[$role]}" == 0 ]]; then
		[[ "$mandatory" == 0 ]]
		return
	fi
	finalizer_transaction_evr_compare comparison \
		"${finalizer_transaction_current_package_evr[$role]}" "$floor" || return 1
	[[ "$comparison" -ge 0 ]]
}

finalizer_transaction_package_is_below_floor_if_present() {
	local role="$1" floor="$2" mandatory="$3" comparison

	if [[ "${finalizer_transaction_current_package_present[$role]}" == 0 ]]; then
		[[ "$mandatory" == 0 ]]
		return
	fi
	finalizer_transaction_evr_compare comparison \
		"${finalizer_transaction_current_package_evr[$role]}" "$floor" || return 1
	[[ "$comparison" -lt 0 ]]
}

finalizer_transaction_packages_are_all_old() {
	finalizer_transaction_package_is_below_floor_if_present \
		own "$finalizer_transaction_own_floor" 1 && \
		finalizer_transaction_package_is_below_floor_if_present \
		peer "$finalizer_transaction_peer_floor" 0 && \
		finalizer_transaction_package_is_below_floor_if_present \
		setup "$finalizer_transaction_setup_floor" 0
}

finalizer_transaction_packages_are_all_new() {
	finalizer_transaction_package_meets_floor_if_present own "$finalizer_transaction_own_floor" 1 && \
		finalizer_transaction_package_meets_floor_if_present peer "$finalizer_transaction_peer_floor" 0 && \
		finalizer_transaction_package_meets_floor_if_present setup "$finalizer_transaction_setup_floor" 0
}

finalizer_transaction_query_unit_file_owner() {
	local path="$1" require_lock="${2:-1}" fd fd_identity line name epoch version release extra status=0
	local stdout_file stderr_file
	local -a lines=()

	finalizer_transaction_file_metadata_is_safe "$path" || return 1
	exec {fd}<"$path" || return 1
	fd_identity="$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "/proc/self/fd/${fd}")" || return 1
	[[ "$fd_identity" == "$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "$path")" ]] || return 1
	[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock || return 1
	finalizer_transaction_secure_temporary stdout_file '.rpm-out.XXXXXX' || return 1
	finalizer_transaction_secure_temporary stderr_file '.rpm-err.XXXXXX' || return 1
	"$finalizer_transaction_timeout_command" --foreground --signal=TERM --kill-after=5s \
		"${finalizer_transaction_command_timeout_seconds}s" \
		"$finalizer_transaction_rpm_command" -qf \
		--qf "$finalizer_transaction_rpm_nevr_query_format" -- "$path" \
		>"$stdout_file" 2>"$stderr_file" || status=$?
	mapfile -t lines < "$stdout_file"
	[[ ! -s "$stderr_file" ]] || status=1
	if [[ "$status" -ne 0 || "${#lines[@]}" -ne 1 ]]; then
		"$finalizer_transaction_rm_command" -f -- "$stdout_file" "$stderr_file"
		exec {fd}<&-
		return 1
	fi
	line="${lines[0]}"
	IFS=$'\t' read -r name epoch version release extra <<< "$line"
	if [[ -n "${extra:-}" || "$name" != "$finalizer_transaction_common_package" || \
		! "$epoch" =~ ^[0-9]+$ || ! "$version" =~ ^[0-9A-Za-z._+~^]+$ || \
		! "$release" =~ ^[0-9A-Za-z._+~^]+$ ]] || \
		! finalizer_transaction_record_is_canonical "$stdout_file" \
			"$name" "$epoch" "$version" "$release"; then
		"$finalizer_transaction_rm_command" -f -- "$stdout_file" "$stderr_file"
		exec {fd}<&-
		return 1
	fi
	"$finalizer_transaction_rm_command" -f -- "$stdout_file" "$stderr_file"
	[[ "$fd_identity" == "$("$finalizer_transaction_stat_command" -Lc '%d:%i' -- "$path")" ]] || return 1
	[[ "$require_lock" -eq 0 ]] || finalizer_transaction_validate_rpm_lock || return 1
	exec {fd}<&-
	finalizer_transaction_unit_file_owner_evr="${epoch}:${version}-${release}"
}

finalizer_transaction_validate_old_unit_graph() {
	local unit path hash

	for unit in "${finalizer_transaction_all_units[@]}"; do
		path="${finalizer_transaction_unit_directory}/${unit}"
		if [[ "${finalizer_transaction_snapshot_unit_present[$unit]}" == 0 ]]; then
			[[ ! -e "$path" && ! -L "$path" ]] || return 1
			continue
		fi
		finalizer_transaction_hash_open_file hash "$path" || return 1
		[[ "$hash" == "${finalizer_transaction_snapshot_unit_sha256[$unit]}" ]] || return 1
		finalizer_transaction_query_unit_file_owner "$path" || return 1
		[[ "$finalizer_transaction_unit_file_owner_evr" == \
			"${finalizer_transaction_current_package_evr[own]}" ]] || return 1
	done
}

finalizer_transaction_validate_new_unit_graph() {
	local require_lock="${1:-1}" unit path comparison

	for unit in "${finalizer_transaction_all_units[@]}"; do
		path="${finalizer_transaction_unit_directory}/${unit}"
		finalizer_transaction_query_unit_file_owner "$path" "$require_lock" || return 1
		[[ "$finalizer_transaction_unit_file_owner_evr" == \
			"${finalizer_transaction_current_package_evr[own]}" ]] || return 1
		finalizer_transaction_evr_compare comparison \
			"$finalizer_transaction_unit_file_owner_evr" "$finalizer_transaction_own_floor" || return 1
		[[ "$comparison" -ge 0 ]] || return 1
	done
}

finalizer_transaction_has_pending_marker() {
	local marker owner mode links saw_marker=0

	[[ -d "$finalizer_transaction_pending_directory" && \
		! -L "$finalizer_transaction_pending_directory" ]] || return 2
	owner="$("$finalizer_transaction_stat_command" -c '%u:%g' -- \
		"$finalizer_transaction_pending_directory")" || return 2
	mode="$("$finalizer_transaction_stat_command" -c '%a' -- \
		"$finalizer_transaction_pending_directory")" || return 2
	finalizer_transaction_expected_owner "$owner" || return 2
	(( (8#${mode}) & 8#022 )) && return 2
	for marker in "$finalizer_transaction_pending_directory"/*.pending; do
		[[ -e "$marker" || -L "$marker" ]] || continue
		[[ -f "$marker" && ! -L "$marker" ]] || return 2
		owner="$("$finalizer_transaction_stat_command" -c '%u:%g' -- "$marker")" || return 2
		mode="$("$finalizer_transaction_stat_command" -c '%a' -- "$marker")" || return 2
		links="$("$finalizer_transaction_stat_command" -c '%h' -- "$marker")" || return 2
		finalizer_transaction_expected_owner "$owner" || return 2
		[[ "$mode" == 644 && "$links" == 1 ]] || return 2
		saw_marker=1
	done
	((saw_marker == 1))
}

finalizer_transaction_restore_failed_quiescent() {
	# Make an immediate bounded attempt while preserving the original error.
	# Returning failure is intentional: the transient's Restart=on-failure then
	# retries from authenticated state until fencing/rearm reaches a terminal
	# result (or mixed exits through RestartPreventExitStatus=75).
	finalizer_transaction_mask_and_drain >/dev/null 2>&1 || :
	return 1
}

finalizer_transaction_rearm_step() {
	"$@" && return 0
	finalizer_transaction_restore_failed_quiescent
}

finalizer_transaction_preset_snapshot_absent_units() {
	local unit

	for unit in "$@"; do
		if [[ "${finalizer_transaction_snapshot_unit_load[$unit]}" != not-found ]]; then
			continue
		fi
		[[ "${finalizer_transaction_snapshot_unit_file_state[$unit]}" == not-found && \
			"${finalizer_transaction_snapshot_unit_active[$unit]}" == not-found && \
			"${finalizer_transaction_snapshot_unit_present[$unit]}" == 0 ]] || return 1
		# RPM's systemd macros do not apply vendor presets when an upgrade adds a
		# unit for the first time.  Preset only authenticated snapshot absences;
		# never rewrite the persistent state of a pre-existing unit.
		LC_ALL=C finalizer_transaction_run_quiet \
			finalizer_transaction_run_systemctl \
			preset --no-reload --quiet "$unit" || return 1
	done
}

finalizer_transaction_verify_restored_unit_file_states() {
	local mode="$1" unit expected

	for unit in "${finalizer_transaction_all_units[@]}"; do
		finalizer_transaction_observe_unit_states "$unit" || return 1
		if [[ "${finalizer_transaction_snapshot_unit_present[$unit]}" == 1 ]]; then
			expected="${finalizer_transaction_snapshot_unit_file_state[$unit]}"
			[[ "$finalizer_transaction_observed_load" == loaded && \
				"$finalizer_transaction_observed_unit_file_state" == "$expected" ]] || return 1
		elif [[ "$mode" == old ]]; then
			[[ "$finalizer_transaction_observed_load" == not-found && \
				"$finalizer_transaction_observed_unit_file_state" == not-found ]] || return 1
		else
			[[ "$finalizer_transaction_observed_load" == loaded && \
				"$finalizer_transaction_observed_unit_file_state" =~ \
				^(enabled|enabled-runtime|disabled|static|indirect|generated)$ ]] || return 1
			# Presets under /etc may intentionally override the vendor default.
			# Preserve that result and use it for activation and retry coverage.
			finalizer_transaction_rearmed_unit_file_state["$unit"]="$finalizer_transaction_observed_unit_file_state"
		fi
	done
}

finalizer_transaction_expected_rearmed_active_state() {
	local output_variable="$1" unit="$2" mode="$3" resolved=inactive activator

	if [[ "${finalizer_transaction_snapshot_unit_present[$unit]}" == 1 ]]; then
		resolved="${finalizer_transaction_snapshot_unit_active[$unit]}"
	elif [[ "$mode" == old ]]; then
		resolved=not-found
	else
		[[ -n "${finalizer_transaction_rearmed_unit_file_state[$unit]:-}" ]] || return 1
		for activator in "${finalizer_transaction_activator_units[@]}"; do
			if [[ "$unit" == "$activator" && \
				"${finalizer_transaction_rearmed_unit_file_state[$unit]}" =~ ^enabled(-runtime)?$ ]]; then
				resolved=active
				break
			fi
		done
	fi
	printf -v "$output_variable" '%s' "$resolved"
}

finalizer_transaction_restore_dependent_active_states() {
	local mode="$1" unit expected

	for unit in "${finalizer_transaction_dependent_units[@]}"; do
		finalizer_transaction_expected_rearmed_active_state expected "$unit" "$mode" || return 1
		if [[ "$expected" == active ]]; then
			finalizer_transaction_run_quiet finalizer_transaction_run_systemctl \
				reset-failed "$unit" || return 1
			finalizer_transaction_run_quiet finalizer_transaction_run_worker_systemctl \
				start --no-block "$unit" || return 1
			continue
		fi
		finalizer_transaction_observe_unit_states "$unit" || return 1
		[[ "$finalizer_transaction_observed_active" == "$expected" ]] || return 1
	done
}

finalizer_transaction_restore_activator_active_states() {
	local mode="$1" unit expected

	for unit in "${finalizer_transaction_activator_units[@]}"; do
		finalizer_transaction_expected_rearmed_active_state expected "$unit" "$mode" || return 1
		if [[ "$expected" == active ]]; then
			finalizer_transaction_run_quiet finalizer_transaction_run_systemctl \
				start --no-block "$unit" || return 1
		fi
	done
	finalizer_transaction_verify_activator_active_states "$mode"
}

finalizer_transaction_verify_activator_active_states() {
	local mode="$1" unit expected

	for unit in "${finalizer_transaction_activator_units[@]}"; do
		finalizer_transaction_expected_rearmed_active_state expected "$unit" "$mode" || return 1
		[[ "$expected" == active ]] && continue
		finalizer_transaction_observe_unit_states "$unit" || return 1
		[[ "$finalizer_transaction_observed_active" == "$expected" ]] || return 1
	done
}

finalizer_transaction_marker_has_retry_coverage() {
	local mode="$1" unit expected

	for unit in "${finalizer_transaction_activator_units[@]}"; do
		finalizer_transaction_expected_rearmed_active_state expected "$unit" "$mode" || return 1
		[[ "$expected" == active ]] && return 0
	done
	return 1
}

finalizer_transaction_rearm_graph() {
	local mode="$1" marker_status=0 service_was_active=0
	local service_expected_active
	local -a first_open_units=()

	case "$mode" in
		old) finalizer_transaction_validate_old_unit_graph || return 1 ;;
		new) finalizer_transaction_validate_new_unit_graph || return 1 ;;
		*) return 1 ;;
	esac
	finalizer_transaction_rearmed_unit_file_state=()
	finalizer_transaction_phase="recovery-rearming"
	finalizer_transaction_rearm_step finalizer_transaction_validate_runtime_masks || return 1
	# A runtime mask is only a fence; it must never be used as a reason to mutate
	# persistent enablement.  Open and preset snapshot-absent activators and
	# dependents first while the worker remains masked, then handle the service
	# last.  One daemon-reload makes the complete graph visible.  Pre-existing
	# units retain their exact UnitFileState; new units retain the effective
	# vendor or administrator preset result.
	first_open_units=("${finalizer_transaction_activator_units[@]}" \
		"${finalizer_transaction_dependent_units[@]}")
	finalizer_transaction_rearm_step finalizer_transaction_run_quiet \
		finalizer_transaction_run_systemctl unmask --runtime --quiet --no-reload \
		"${first_open_units[@]}" || return 1
	if [[ "$mode" == new ]]; then
		finalizer_transaction_rearm_step \
			finalizer_transaction_preset_snapshot_absent_units \
			"${first_open_units[@]}" || return 1
	fi
	finalizer_transaction_rearm_step finalizer_transaction_run_quiet \
		finalizer_transaction_run_systemctl unmask --runtime --quiet --no-reload \
		"$finalizer_transaction_service_unit" || return 1
	if [[ "$mode" == new ]]; then
		finalizer_transaction_rearm_step \
			finalizer_transaction_preset_snapshot_absent_units \
			"$finalizer_transaction_service_unit" || return 1
	fi
	finalizer_transaction_rearm_step finalizer_transaction_run_quiet \
		finalizer_transaction_run_systemctl daemon-reload || return 1
	finalizer_transaction_rearm_step \
		finalizer_transaction_verify_restored_unit_file_states "$mode" || return 1
	[[ "${finalizer_transaction_snapshot_unit_active[$finalizer_transaction_service_unit]}" == active ]] && \
		service_was_active=1
	if [[ "$mode" == old && \
		"${finalizer_transaction_snapshot_unit_load[$finalizer_transaction_service_unit]}" == not-found ]]; then
		# Legacy releases without a worker also had no queue directory.  In an
		# authenticated all-old rollback, that absence is the original state rather
		# than an unsafe disappearance of a managed queue.
		marker_status=1
	else
		finalizer_transaction_has_pending_marker || marker_status=$?
	fi
	if [[ "$marker_status" -eq 2 ]]; then
		finalizer_transaction_restore_failed_quiescent
		return 1
	fi
	if [[ "$marker_status" -eq 0 ]] && \
		! finalizer_transaction_marker_has_retry_coverage "$mode"; then
		# An asynchronously queued worker can fail or hit its restart limit.  A
		# durable marker is safe to leave behind only when this recovery also
		# queues at least one path/timer that will continue to cover retries.
		finalizer_transaction_restore_failed_quiescent
		return 1
	fi
	if [[ "$service_was_active" -eq 1 || "$marker_status" -eq 0 ]]; then
		finalizer_transaction_rearm_step finalizer_transaction_run_quiet \
			finalizer_transaction_run_systemctl reset-failed \
			"$finalizer_transaction_service_unit" || return 1
		# Keep the RPM OFD fence through commit, but never wait for a queue worker
		# that must acquire the cross-driver global lock.  Setup may already hold
		# that global lock while its next RPM writer waits for this OFD.  Enqueueing
		# the job breaks that cycle; the durable marker, service restart policy and
		# active path/timer own asynchronous completion after recovery exits.
		finalizer_transaction_rearm_step finalizer_transaction_run_quiet \
			finalizer_transaction_run_worker_systemctl start --no-block \
			"$finalizer_transaction_service_unit" || return 1
	fi
	# Dependents such as MAX98390's hardware-setup oneshot are queued only after
	# the worker job.  Their Requires=/After= edges preserve execution order
	# without making this RPM-fenced recovery wait for the global lock.
	finalizer_transaction_rearm_step \
		finalizer_transaction_restore_dependent_active_states "$mode" || return 1
	finalizer_transaction_rearm_step \
		finalizer_transaction_restore_activator_active_states "$mode" || return 1
	if [[ "$service_was_active" -eq 0 && "$marker_status" -ne 0 ]]; then
		finalizer_transaction_expected_rearmed_active_state service_expected_active \
			"$finalizer_transaction_service_unit" "$mode" || return 1
		finalizer_transaction_rearm_step finalizer_transaction_observe_unit_states \
			"$finalizer_transaction_service_unit" || return 1
		[[ "$finalizer_transaction_observed_active" == "$service_expected_active" ]] || {
			finalizer_transaction_restore_failed_quiescent
			return 1
		}
	fi
}

finalizer_transaction_cleanup_state() {
	finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600 || return 1
	finalizer_transaction_safe_remove "$finalizer_transaction_state_path" 600 || return 1
	# State removal is the commit point.  The running recovery must retain its
	# executable pathname until then so Restart=on-failure remains possible.
	# Failure to unlink the now-inert copy is non-authoritative; the next fresh
	# pretrans removes it strictly before creating a new O_EXCL generation.
	finalizer_transaction_safe_remove_helper_copy || :
}

finalizer_transaction_posttrans() {
	local rpm_instance_count="$1" manager_status=0

	: "$rpm_instance_count"
	finalizer_transaction_load_config || return 1
	if [[ ! -e "$finalizer_transaction_state_directory" && \
		! -L "$finalizer_transaction_state_directory" ]]; then
		return 0
	fi
	[[ -d "$finalizer_transaction_state_directory" && \
		! -L "$finalizer_transaction_state_directory" ]] || return 1
	finalizer_transaction_ensure_state_directory || return 1
	[[ -e "$finalizer_transaction_state_path" || -L "$finalizer_transaction_state_path" ]] || return 0
	finalizer_transaction_probe_manager || manager_status=$?
	case "$manager_status" in
		0) ;;
		2) return 1 ;;
		*) return 1 ;;
	esac
	finalizer_transaction_parse_state || return 1
	finalizer_transaction_ready_is_authentic || return 1
	finalizer_transaction_helper_copy_is_authentic || return 1
	# Both pretrans and posttrans execute while RPM owns its classic POSIX
	# F_SETLK writer.  Child rpm queries in either slot fail their lock attempt,
	# emit an error and may still return unlocked data, so neither scriptlet may
	# use rpmdb results as rearm authority.  The transient recovery is the sole
	# owner of rearm after its shared F_OFD bridge excludes that writer.
	finalizer_transaction_phase="posttrans-maintenance"
	finalizer_transaction_validate_runtime_masks || \
		finalizer_transaction_mask_and_drain || return 1
	if finalizer_transaction_recovery_is_live; then
		finalizer_transaction_phase="idle"
		return 0
	fi
	# A dead transient is replaced from the byte-authenticated copy without
	# opening the managed graph.  Keep state and masks intact on every failure.
	finalizer_transaction_retire_recovery || return 1
	finalizer_transaction_safe_remove "$finalizer_transaction_ready_path" 600 || return 1
	finalizer_transaction_arm_recovery || return 1
	finalizer_transaction_validate_runtime_masks || return 1
	finalizer_transaction_recovery_is_live || return 1
	finalizer_transaction_phase="idle"
}

finalizer_transaction_rearm_and_commit() {
	local mode="$1"

	finalizer_transaction_rearm_graph "$mode" || return 1
	finalizer_transaction_phase="recovery-committing"
	if ! finalizer_transaction_cleanup_state; then
		finalizer_transaction_restore_failed_quiescent
		return 1
	fi
	finalizer_transaction_phase="committed"
}

finalizer_transaction_recover() {
	local nonce="$1" classification="mixed"

	finalizer_transaction_load_config || return 1
	finalizer_transaction_ensure_state_directory || return 1
	finalizer_transaction_parse_state "$nonce" || return 1
	finalizer_transaction_publish_ready || return 1
	finalizer_transaction_phase="recovery-waiting"
	finalizer_transaction_acquire_rpm_lock || return 1
	# Reassert the fence after the writer is gone.  This covers a pretrans that
	# died before or halfway through its own mask/stop sequence and makes the
	# mixed/unknown terminal state genuinely quiescent.
	finalizer_transaction_mask_and_drain || {
		finalizer_transaction_restore_failed_quiescent
		return 1
	}
	if finalizer_transaction_snapshot_current_packages; then
		if finalizer_transaction_packages_are_all_old && \
			finalizer_transaction_validate_old_unit_graph; then
			classification="old"
		elif finalizer_transaction_packages_are_all_new && \
			finalizer_transaction_validate_new_unit_graph; then
			classification="new"
		fi
	fi
	if [[ "$classification" == old || "$classification" == new ]] && \
		! finalizer_transaction_verify_common_package; then
		classification="mixed"
	fi
	case "$classification" in
		new)
			finalizer_transaction_rearm_and_commit new
			;;
		old)
			if [[ "${finalizer_transaction_snapshot_unit_load[$finalizer_transaction_service_unit]}" == \
				not-found ]]; then
				# The public legacy release had no managed worker.  Restore the
				# authenticated absence rather than manufacturing a terminal mask.
				finalizer_transaction_rearm_and_commit old
				return
			fi
			finalizer_transaction_fail \
				"pre-compatibility package generation remains quiescent until a safe upgrade" || :
			# A local transactional preview can have an older worker whose mutation
			# policy is no longer trusted.  Never reopen that graph after a failed
			# upgrade; preserve state and masks so a later compatible transaction can
			# adopt and complete the recovery.
			return 75
			;;
		*)
			finalizer_transaction_fail \
				"package or unit-file state is mixed or unknown; finalizers remain quiescent" || :
			# RestartPreventExitStatus=75 makes this a terminal, adoptable mixed
			# state.  Operational failures use other nonzero statuses and are
			# retried by the transient recovery.
			return 75
			;;
	esac
}

finalizer_transaction_parse_instance_count() {
	local output_variable="$1" value="$2"

	[[ "$value" =~ ^[0-9]{1,9}$ ]] || return 1
	printf -v "$output_variable" '%d' "$((10#$value))"
}

finalizer_transaction_main() {
	local count

	finalizer_transaction_install_traps
	[[ "$EUID" -eq "$finalizer_transaction_expected_euid" ]] || {
		finalizer_transaction_fail "RPM finalizer coordination must run as root"
		return 1
	}
	if [[ "$#" -eq 1 ]]; then
		finalizer_transaction_parse_instance_count count "$1" || {
			finalizer_transaction_usage
			return
		}
		finalizer_transaction_pretrans "$count"
	elif [[ "$#" -eq 2 && "$1" == --posttrans ]]; then
		finalizer_transaction_parse_instance_count count "$2" || {
			finalizer_transaction_usage
			return
		}
		finalizer_transaction_posttrans "$count"
	elif [[ "$#" -eq 2 && "$1" == --recover ]]; then
		finalizer_transaction_nonce_is_safe "$2" || {
			finalizer_transaction_usage
			return
		}
		finalizer_transaction_recover "$2"
	else
		finalizer_transaction_usage
	fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	finalizer_transaction_main "$@"
fi

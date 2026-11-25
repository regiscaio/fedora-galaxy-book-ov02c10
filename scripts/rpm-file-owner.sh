#!/usr/bin/env bash

# Shared by root-only helpers after acquire_rpm_read_lock has serialized them
# with package transactions. Callers set rpm_command when a test double is
# needed.

rpm_file_owner_result=""
rpm_file_owner_evr_result=""
rpm_package_evr_result=""

rpm_file_owner() {
	local path="$1"
	local output_file error_file output error_output
	local query_status=0
	local expected_unowned="file ${path} is not owned by any package"

	rpm_file_owner_result=""
	output_file="$(mktemp)" || return 2
	error_file="$(mktemp)" || {
		rm -f -- "$output_file"
		return 2
	}
	if LC_ALL=C "$rpm_command" -qf --qf '%{NAME}\n' -- "$path" \
		>"$output_file" 2>"$error_file"
	then
		query_status=0
	else
		query_status=$?
	fi
	output="$(<"$output_file")"
	error_output="$(<"$error_file")"
	rm -f -- "$output_file" "$error_file"

	if [[ "$query_status" -eq 0 ]]; then
		if [[ -n "$error_output" ]]; then
			printf '%s\n' "$error_output" >&2
			printf 'galaxybook-ov02c10: RPM ownership query produced unexpected diagnostics for %s\n' \
				"$path" >&2
			return 2
		fi
		if [[ -z "$output" || "$output" == *$'\n'* ]]; then
			printf 'galaxybook-ov02c10: RPM returned an ambiguous owner for %s\n' \
				"$path" >&2
			return 2
		fi
		rpm_file_owner_result="$output"
		return 0
	fi

	# RPM 5 writes the exact unowned diagnostic to stdout; RPM 6 moved the
	# same diagnostic to stderr. Accept only that one canonical line on exactly
	# one stream, with status 1 and no additional output.
	if [[ "$query_status" -eq 1 && \
		( ( "$output" == "$expected_unowned" && -z "$error_output" ) || \
		  ( "$error_output" == "$expected_unowned" && -z "$output" ) ) ]]
	then
		return 1
	fi
	[[ -z "$output" ]] || printf '%s\n' "$output" >&2
	[[ -z "$error_output" ]] || printf '%s\n' "$error_output" >&2

	printf 'galaxybook-ov02c10: RPM ownership query failed for %s (status %s)\n' \
		"$path" "$query_status" >&2
	return 2
}

rpm_query_nevr_name=""
rpm_query_nevr_evr=""

rpm_query_nevr_record() {
	local query_mode="$1" target="$2"
	local output_file error_file canonical_file record
	local name epoch version release extra query_status=0
	local -a query_arguments=() records=()

	rpm_query_nevr_name=""
	rpm_query_nevr_evr=""
	case "$query_mode" in
		owner) query_arguments=(-qf) ;;
		package) query_arguments=(-q) ;;
		*) return 2 ;;
	esac
	output_file="$(mktemp)" || return 2
	error_file="$(mktemp)" || {
		rm -f -- "$output_file"
		return 2
	}
	canonical_file="$(mktemp)" || {
		rm -f -- "$output_file" "$error_file"
		return 2
	}
	if LC_ALL=C "$rpm_command" "${query_arguments[@]}" \
		--qf '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\n' -- "$target" \
		>"$output_file" 2>"$error_file"
	then
		query_status=0
	else
		query_status=$?
	fi
	if [[ "$query_status" -ne 0 || -s "$error_file" ]]; then
		rm -f -- "$output_file" "$error_file" "$canonical_file"
		return 2
	fi
	mapfile -t records < "$output_file"
	if [[ "${#records[@]}" -ne 1 ]]; then
		rm -f -- "$output_file" "$error_file" "$canonical_file"
		return 2
	fi
	record="${records[0]}"
	IFS=$'\t' read -r name epoch version release extra <<< "$record"
	if [[ -n "$extra" || \
		! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9+_.-]*$ || \
		! "$epoch" =~ ^[0-9]+$ || \
		! "$version" =~ ^[0-9A-Za-z._+~^]+$ || \
		! "$release" =~ ^[0-9A-Za-z._+~^]+$ || \
		"$record" != "${name}"$'\t'"${epoch}"$'\t'"${version}"$'\t'"${release}" ]]
	then
		rm -f -- "$output_file" "$error_file" "$canonical_file"
		return 2
	fi
	printf '%s\t%s\t%s\t%s\n' "$name" "$epoch" "$version" "$release" \
		> "$canonical_file"
	if ! cmp --silent -- "$output_file" "$canonical_file"; then
		rm -f -- "$output_file" "$error_file" "$canonical_file"
		return 2
	fi
	rm -f -- "$output_file" "$error_file" "$canonical_file"
	rpm_query_nevr_name="$name"
	rpm_query_nevr_evr="${epoch}:${version}-${release}"
}

rpm_file_owner_evr() {
	local path="$1" expected_owner owner_status=0

	rpm_file_owner_evr_result=""
	if rpm_file_owner "$path"; then
		expected_owner="$rpm_file_owner_result"
	else
		owner_status=$?
		return "$owner_status"
	fi
	rpm_query_nevr_record owner "$path" || {
		printf 'galaxybook-ov02c10: RPM owner EVR query was not canonical for %s\n' \
			"$path" >&2
		return 2
	}
	[[ "$rpm_query_nevr_name" == "$expected_owner" ]] || {
		printf 'galaxybook-ov02c10: RPM owner changed during EVR validation for %s\n' \
			"$path" >&2
		return 2
	}
	rpm_file_owner_result="$rpm_query_nevr_name"
	rpm_file_owner_evr_result="$rpm_query_nevr_evr"
}

rpm_package_evr() {
	local package="$1"

	rpm_package_evr_result=""
	[[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9+_.-]*$ ]] || return 2
	rpm_query_nevr_record package "$package" || {
		printf 'galaxybook-ov02c10: RPM package EVR query was not canonical for %s\n' \
			"$package" >&2
		return 2
	}
	[[ "$rpm_query_nevr_name" == "$package" ]] || {
		printf 'galaxybook-ov02c10: RPM returned the wrong package record for %s\n' \
			"$package" >&2
		return 2
	}
	rpm_package_evr_result="$rpm_query_nevr_evr"
}

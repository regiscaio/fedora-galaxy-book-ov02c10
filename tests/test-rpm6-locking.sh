#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir="${test_dir}/fixtures/rpm-transaction"
payload_path="/opt/ov02c10-rpm-lock-test/module.ko"
rpm_read_lock_helper="${test_dir}/../scripts/rpm-read-lock.sh"
rpm_file_owner_helper="${test_dir}/../scripts/rpm-file-owner.sh"

if [[ "${OV02C10_RPM6_EPHEMERAL_TEST:-0}" != 1 ]]; then
	printf 'test-rpm6-locking: skipped (requires an explicitly ephemeral root container)\n'
	exit 0
fi
if [[ "$EUID" -ne 0 || ! -e /run/.containerenv ]]; then
	printf 'test-rpm6-locking: refusing to mutate a non-ephemeral RPM database\n' >&2
	exit 1
fi

for command in flock rpm rpmbuild timeout; do
	command -v "$command" >/dev/null 2>&1 || {
		printf 'test-rpm6-locking: missing command %s\n' "$command" >&2
		exit 1
	}
done
[[ "$(rpm --version)" == 'RPM version 6.'* ]]
flock --help | grep -Fq -- '--fcntl'

test_root="$(mktemp -d /tmp/ov02c10-rpm6-locking.XXXXXX)"
topdir="${test_root}/rpmbuild"
mkdir -p "${topdir}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

for fixture in payload writer; do
	rpmbuild -bb "${fixture_dir}/${fixture}.spec" \
		--define "_topdir ${topdir}" > "${test_root}/build-${fixture}.log" 2>&1
done
payload_rpm="$(find "${topdir}/RPMS" -type f -name 'ov02c10-rpm-lock-payload-*.rpm' -print -quit)"
writer_rpm="$(find "${topdir}/RPMS" -type f -name 'ov02c10-rpm-lock-writer-*.rpm' -print -quit)"
[[ -f "$payload_rpm" && -f "$writer_rpm" ]]

rpm --nodeps -i "$payload_rpm"
lock_path="$(rpm --eval '%{_rpmlock_path}')"
[[ "$lock_path" == "/usr/lib/sysimage/rpm/.rpm.lock" ]]

rpm --nodeps --replacepkgs -i "$writer_rpm"

writer_ready="${test_root}/writer-lock.ready"
writer_release="${test_root}/writer-lock.release"
reader_ready="${test_root}/reader-lock.ready"
: > /opt/ov02c10-rpm-lock-test/unowned
OV02C10_WRITER_READY="$writer_ready" OV02C10_WRITER_RELEASE="$writer_release" \
	rpm --nodeps --replacepkgs -i "$writer_rpm" \
	> "${test_root}/writer-lock.out" 2> "${test_root}/writer-lock.err" &
writer_pid=$!
for ((attempt = 1; attempt <= 200; attempt++)); do
	[[ -f "$writer_ready" ]] && break
	/usr/bin/sleep 0.01
done
[[ -f "$writer_ready" ]]
(
	# shellcheck source=../scripts/rpm-read-lock.sh
	source "$rpm_read_lock_helper"
	# shellcheck source=../scripts/rpm-file-owner.sh
	source "$rpm_file_owner_helper"
	rpm_lock_timeout_seconds=10
	rpm_command=/usr/bin/rpm
	acquire_rpm_read_lock
	rpm_file_owner "$payload_path"
	[[ "$rpm_file_owner_result" == ov02c10-rpm-lock-payload ]]
	owner_status=0
	rpm_file_owner /opt/ov02c10-rpm-lock-test/unowned || owner_status=$?
	[[ "$owner_status" -eq 1 ]]
	: > "$reader_ready"
) > "${test_root}/reader-lock.out" 2> "${test_root}/reader-lock.err" &
reader_pid=$!
/usr/bin/sleep 0.2
[[ ! -e "$reader_ready" ]]
: > "$writer_release"
wait "$writer_pid"
reader_status=0
wait "$reader_pid" || reader_status=$?
if [[ "$reader_status" -ne 0 ]]; then
	printf 'test-rpm6-locking: read-lock wrapper failed after writer release (status %s)\n' \
		"$reader_status" >&2
	sed 's/^/  /' "${test_root}/reader-lock.err" >&2
	exit 1
fi
[[ -f "$reader_ready" && ! -s "${test_root}/reader-lock.err" ]]

run_release_case() {
	local mode="$1"
	local ready="${test_root}/${mode}.ready"
	local release="${test_root}/${mode}.release"
	local holder_pid attempt holder_status=0 blocked

	(
		# shellcheck source=../scripts/rpm-read-lock.sh
		source "$rpm_read_lock_helper"
		rpm_lock_timeout_seconds=10
		acquire_rpm_read_lock
		rpm -qf --qf '%{NAME}\n' -- "$payload_path" \
			> "${test_root}/${mode}-owner.out" \
			2> "${test_root}/${mode}-owner.err"
		[[ "$(<"${test_root}/${mode}-owner.out")" == ov02c10-rpm-lock-payload ]]
		[[ ! -s "${test_root}/${mode}-owner.err" ]]
		: > "$ready"
		while [[ ! -f "$release" ]]; do /usr/bin/sleep 0.01; done
		[[ "$mode" == failure ]] && exit 73
		exit 0
	) 2> "${test_root}/${mode}-holder.err" &
	holder_pid=$!
	for ((attempt = 1; attempt <= 200; attempt++)); do
		[[ -f "$ready" ]] && break
		/usr/bin/sleep 0.01
	done
	[[ -f "$ready" ]]

	set +e
	timeout 2 rpm --nodeps --replacepkgs -i "$writer_rpm" \
		> "${test_root}/${mode}-blocked.out" 2>&1
	blocked=$?
	set -e
	(( blocked != 0 ))
	if [[ "$mode" == signal ]]; then kill -TERM "$holder_pid"; else : > "$release"; fi
	set +e
	wait "$holder_pid"
	holder_status=$?
	set -e
	case "$mode" in
		success) [[ "$holder_status" == 0 ]] ;;
		failure) [[ "$holder_status" == 73 ]] ;;
		signal) (( holder_status > 128 )) ;;
	esac
	[[ ! -s "${test_root}/${mode}-holder.err" ]]
	rpm --nodeps --replacepkgs -i "$writer_rpm"
}

run_release_case success
run_release_case failure
run_release_case signal

printf 'test-rpm6-locking: ok (%s)\n' "$(rpm --version)"

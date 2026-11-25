#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$test_dir/.." && pwd)"
spec="$repo_root/packaging/fedora/galaxybook-ov02c10-kmod.spec"
filter="$repo_root/scripts/kmodtool-queue-only-filter.sh"
helper="$repo_root/scripts/finalizer-transaction.sh"
version_script="$repo_root/scripts/package-version.sh"
container_image="${SRPM_BOOTSTRAP_IMAGE:-}"
expected_failure='kmodtool queue-only filtering was deferred; refusing an unverified binary build'
expected_kernel_failure='kmodtool is required to generate a source RPM with explicit kernels'

if [[ -z "$container_image" ]]; then
	printf '%s\n' \
		'test_srpm_bootstrap: skipped (set SRPM_BOOTSTRAP_IMAGE to an rpm-build image without kmodtool)'
	exit 0
fi
if [[ ! "$container_image" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]; then
	printf 'test_srpm_bootstrap: unsafe container image: %s\n' "$container_image" >&2
	exit 1
fi
if ! command -v podman >/dev/null 2>&1; then
	printf '%s\n' 'test_srpm_bootstrap: podman is unavailable' >&2
	exit 1
fi
if ! podman image exists "$container_image"; then
	printf 'test_srpm_bootstrap: container image is unavailable: %s\n' \
		"$container_image" >&2
	exit 1
fi

test_root="$(mktemp -d "${TMPDIR:-/tmp}/ov02c10-srpm-bootstrap.XXXXXX")"
cleanup() {
	case "$test_root" in
		"${TMPDIR:-/tmp}"/ov02c10-srpm-bootstrap.*)
			rm -rf -- "$test_root"
			;;
		*)
			printf 'test_srpm_bootstrap: refusing cleanup outside fixture: %s\n' \
				"$test_root" >&2
			;;
	esac
}
trap cleanup EXIT

version="$($version_script)"
package_name=galaxybook-ov02c10-kmod
topdir="$test_root/rpmbuild"
mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
git -C "$repo_root" archive --format=tar \
	--prefix="${package_name}-${version}/" HEAD | \
	gzip -n > "$topdir/SOURCES/${package_name}-${version}.tar.gz"
cp -- "$filter" "$topdir/SOURCES/kmodtool-queue-only-filter.sh"
cp -- "$helper" "$topdir/SOURCES/finalizer-transaction.sh"
sed 's/%/%%/g' "$helper" \
	> "$topdir/SOURCES/finalizer-transaction-pretrans.sh"
sed \
	-e "s/^Version:[[:space:]].*/Version:        ${version}/" \
	-e 's/^Release:[[:space:]].*/Release:        1%{?dist}/' \
	"$spec" > "$topdir/SPECS/${package_name}.spec"

if ! podman run --rm --pull=never --network=none \
	--volume "$topdir:/work:Z" \
	"$container_image" \
	/usr/bin/bash --noprofile --norc -c '
		set -euo pipefail
		test -x /usr/bin/rpmbuild
		test ! -e /usr/bin/kmodtool
		rpmbuild -bs /work/SPECS/galaxybook-ov02c10-kmod.spec \
			--define "_topdir /work" \
			> /work/buildsrpm.out 2> /work/buildsrpm.err
		srpm="$(find /work/SRPMS -maxdepth 1 -type f \
			-name "galaxybook-ov02c10-kmod-*.src.rpm" -print -quit)"
		test -n "$srpm"
		rpm -qp --requires "$srpm" | grep -Fxq akmods
		rpm -qp --requires "$srpm" | grep -Fxq kmodtool
		mkdir /work/extracted
		(cd /work/extracted && rpm2cpio "$srpm" | cpio -id --quiet)
		for source in \
			galaxybook-ov02c10-kmod-*.tar.gz \
			kmodtool-queue-only-filter.sh \
			finalizer-transaction.sh \
			finalizer-transaction-pretrans.sh \
			galaxybook-ov02c10-kmod.spec
		do
			extracted="$(find /work/extracted -maxdepth 1 -type f \
				-name "$source" -print -quit)"
			staged="$(find /work/SOURCES /work/SPECS -maxdepth 1 -type f \
				-name "$source" -print -quit)"
			test -n "$extracted"
			test -n "$staged"
			cmp -- "$staged" "$extracted"
		done

		set +e
		rpmbuild --rebuild --nodeps "$srpm" \
			--define "_topdir /work" \
			> /work/rebuild.out 2> /work/rebuild.err
		rebuild_status=$?
		rpmbuild -bp --nodeps /work/SPECS/galaxybook-ov02c10-kmod.spec \
			--define "_topdir /work" \
			--define "kmodtool_queue_only_build_verified 1" \
			--define "kmodtool_queue_only_filter_deferred 0" \
			> /work/prep.out 2> /work/prep.err
		prep_status=$?
		source_archive="$(find /work/SOURCES -maxdepth 1 -type f \
			-name "galaxybook-ov02c10-kmod-*.tar.gz" -print -quit)"
		source_directory="${source_archive##*/}"
		source_directory="${source_directory%.tar.gz}"
		build_directory="$(find /work/BUILD -mindepth 1 -maxdepth 1 -type d \
			-name "${source_directory}-build" -print -quit)"
		test -n "$build_directory"
		mkdir -p -- "$build_directory/$source_directory"
		rpmbuild -bc --short-circuit --nodeps \
			/work/SPECS/galaxybook-ov02c10-kmod.spec \
			--define "_topdir /work" \
			--define "kmodtool_queue_only_build_verified 1" \
			--define "kmodtool_queue_only_filter_deferred 0" \
			> /work/build.out 2> /work/build.err
		build_status=$?
		rpmbuild -bs /work/SPECS/galaxybook-ov02c10-kmod.spec \
			--define "_topdir /work" \
			--define "kernels 6.0.0-test.x86_64" \
			> /work/kernels.out 2> /work/kernels.err
		kernels_status=$?
		set -e

		test "$rebuild_status" -ne 0
		test "$prep_status" -ne 0
		test "$build_status" -ne 0
		test "$kernels_status" -ne 0
		grep -Fq -- \
			"kmodtool queue-only filtering was deferred; refusing an unverified binary build" \
			/work/rebuild.err
		grep -Fq -- \
			"kmodtool queue-only filtering was deferred; refusing an unverified binary build" \
			/work/prep.err
		grep -Fq -- \
			"kmodtool queue-only filtering was deferred; refusing an unverified binary build" \
			/work/build.err
		grep -Fq -- \
			"kmodtool is required to generate a source RPM with explicit kernels" \
			/work/kernels.err
		test -z "$(find /work/RPMS -type f -name "*.rpm" -print -quit)"
	'; then
	printf '%s\n' 'test_srpm_bootstrap: container validation failed' >&2
	for error_log in buildsrpm.err rebuild.err prep.err build.err kernels.err; do
		[[ ! -s "$topdir/$error_log" ]] || tail -n 20 "$topdir/$error_log" >&2
	done
	exit 1
fi

grep -Fq -- "$expected_failure" "$topdir/prep.err" || {
	printf '%s\n' 'test_srpm_bootstrap: prep guard diagnostic is missing' >&2
	exit 1
}
grep -Fq -- "$expected_failure" "$topdir/build.err" || {
	printf '%s\n' 'test_srpm_bootstrap: build guard diagnostic is missing' >&2
	exit 1
}
grep -Fq -- "$expected_kernel_failure" "$topdir/kernels.err" || {
	printf '%s\n' 'test_srpm_bootstrap: explicit-kernel diagnostic is missing' >&2
	exit 1
}
printf '%s\n' 'test_srpm_bootstrap: ok'

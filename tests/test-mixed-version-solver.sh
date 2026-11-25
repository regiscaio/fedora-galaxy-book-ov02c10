#!/usr/bin/env bash
set -euo pipefail

fail() {
	printf 'test-mixed-version-solver: %s\n' "$*" >&2
	exit 1
}

for command in dnf5 rpm rpmbuild; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command: ${command}"
done
[[ "$EUID" -eq 0 && -e /run/.containerenv ]] || {
	printf 'test-mixed-version-solver: skipped (requires an ephemeral root container)\n'
	exit 0
}

test_root="$(mktemp -d /tmp/ov02c10-mixed-version-solver.XXXXXX)"
topdir="${test_root}/rpmbuild"
mkdir -p "${topdir}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
trap 'rm -rf -- "$test_root"' EXIT

write_package_spec() {
	local name="$1"
	local version="$2"
	local provides="$3"
	local spec_path="${topdir}/SPECS/${name}-${version}.spec"

	{
		printf 'Name: %s\n' "$name"
		printf 'Version: %s\n' "$version"
		printf 'Release: 1\n'
		printf 'Summary: Mixed-version solver fixture\n'
		printf 'License: MIT\n'
		printf 'BuildArch: noarch\n'
		printf 'AutoReqProv: no\n'
		[[ -z "$provides" ]] || printf 'Provides: %s\n' "$provides"
		printf '%%description\nSolver-only fixture.\n'
		printf '%%files\n'
	} > "$spec_path"
	rpmbuild -bb --quiet --define "_topdir ${topdir}" "$spec_path"
}

write_root_filesystem_spec() {
	local spec_path="${topdir}/SPECS/ov02c10-test-filesystem.spec"

	cat > "$spec_path" <<'EOF'
Name: ov02c10-test-filesystem
Version: 1
Release: 1
Summary: Minimal filesystem fixture for an isolated DNF root
License: MIT
BuildArch: noarch
AutoReqProv: no
Provides: filesystem
%description
Solver-only minimal filesystem fixture.
%install
mkdir -p %{buildroot}/var/empty
%files
%dir /var/empty
EOF
	rpmbuild -bb --quiet --define "_topdir ${topdir}" "$spec_path"
}

write_guard_spec() {
	local spec_path="${topdir}/SPECS/ov02c10-mixed-version-guard.spec"

	cat > "$spec_path" <<'EOF'
Name: ov02c10-mixed-version-guard
Version: 1.00.25
Release: 1
Summary: OV02C10 mixed-version solver guard fixture
License: MIT
BuildArch: noarch
AutoReqProv: no
Requires: (galaxybook-max98390-kmod-common >= 1.00.12 if galaxybook-max98390-kmod-common)
Requires: (galaxybook-setup >= 1.00.48 if galaxybook-setup)
%description
Solver-only fixture matching the packaged common subpackage fence.
%files
EOF
	rpmbuild -bb --quiet --define "_topdir ${topdir}" "$spec_path"
}

write_package_spec galaxybook-max98390-kmod-common 1.00.11 ''
write_package_spec galaxybook-max98390-kmod-common 1.00.12 ''
write_package_spec galaxybook-setup 1.00.47 ''
write_package_spec galaxybook-setup 1.00.48 ''
write_root_filesystem_spec
write_guard_spec

rpm_dir="${topdir}/RPMS/noarch"
guard_rpm="${rpm_dir}/ov02c10-mixed-version-guard-1.00.25-1.noarch.rpm"
max_old="${rpm_dir}/galaxybook-max98390-kmod-common-1.00.11-1.noarch.rpm"
max_new="${rpm_dir}/galaxybook-max98390-kmod-common-1.00.12-1.noarch.rpm"
setup_old="${rpm_dir}/galaxybook-setup-1.00.47-1.noarch.rpm"
setup_new="${rpm_dir}/galaxybook-setup-1.00.48-1.noarch.rpm"
filesystem_rpm="${rpm_dir}/ov02c10-test-filesystem-1-1.noarch.rpm"

dnf_root() {
	local install_root="$1"
	shift
	mkdir -p "$install_root"
	if ! rpm --root "$install_root" -q ov02c10-test-filesystem >/dev/null 2>&1; then
		rpm --root "$install_root" --nodeps --noscripts -i "$filesystem_rpm"
	fi
	dnf5 \
		--assumeyes \
		--installroot "$install_root" \
		--releasever 44 \
		--use-host-config \
		--disable-repo='*' \
		"$@" >/dev/null
}

assert_installed() {
	local install_root="$1"
	local package="$2"
	rpm --root "$install_root" -q "$package" >/dev/null || \
		fail "expected installed package: ${package}"
}

assert_absent() {
	local install_root="$1"
	local package="$2"
	if rpm --root "$install_root" -q "$package" >/dev/null 2>&1; then
		fail "unexpected installed package: ${package}"
	fi
}

absent_root="${test_root}/root-absent"
dnf_root "$absent_root" install "$guard_rpm"
assert_installed "$absent_root" ov02c10-mixed-version-guard
assert_absent "$absent_root" galaxybook-max98390-kmod-common
assert_absent "$absent_root" galaxybook-setup

for old_case in max setup; do
	case "$old_case" in
		max)
			old_rpm="$max_old"
			old_package=galaxybook-max98390-kmod-common
			;;
		setup)
			old_rpm="$setup_old"
			old_package=galaxybook-setup
			;;
	esac
	old_root="${test_root}/root-old-${old_case}"
	dnf_root "$old_root" install "$old_rpm"
	set +e
	dnf_root "$old_root" install "$guard_rpm" \
		> "${test_root}/${old_case}.out" 2> "${test_root}/${old_case}.err"
	old_status=$?
	set -e
	[[ "$old_status" -ne 0 ]] || fail "legacy ${old_case} peer was accepted"
	assert_installed "$old_root" "$old_package"
	assert_absent "$old_root" ov02c10-mixed-version-guard
done

upgrade_root="${test_root}/root-upgrade"
dnf_root "$upgrade_root" install "$max_old" "$setup_old"
dnf_root "$upgrade_root" install \
	--allowerasing \
	"$guard_rpm" "$max_new" "$setup_new"
assert_installed "$upgrade_root" ov02c10-mixed-version-guard
[[ "$(rpm --root "$upgrade_root" -q --qf '%{VERSION}\n' \
	galaxybook-max98390-kmod-common)" == 1.00.12 ]] || \
	fail "MAX peer did not upgrade to the compatible floor"
[[ "$(rpm --root "$upgrade_root" -q --qf '%{VERSION}\n' galaxybook-setup)" == 1.00.48 ]] || \
	fail "Setup peer did not upgrade to the compatible floor"
printf 'test-mixed-version-solver: ok\n'

#!/usr/bin/env bash
set -euo pipefail

fail() {
	printf 'test-built-common-transaction: %s\n' "$*" >&2
	exit 1
}

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

[[ "$#" -eq 1 ]] || {
	printf 'usage: %s <galaxybook-ov02c10-kmod-common.rpm>\n' "${0##*/}" >&2
	exit 64
}
[[ "$EUID" -eq 0 && -e /run/.containerenv ]] || {
	printf 'test-built-common-transaction: skipped (requires an ephemeral root container)\n'
	exit 0
}
for command in cmp rpmbuild rpm stat; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command: ${command}"
done

common_rpm="$1"
[[ -f "$common_rpm" ]] || fail "RPM does not exist: ${common_rpm}"
[[ "$(rpm -qp --qf '%{NAME}\n' -- "$common_rpm")" == \
	galaxybook-ov02c10-kmod-common ]] || fail 'not the OV02C10 common RPM'
[[ "$(rpm -qp --qf '%{VERSION}\n' -- "$common_rpm")" == 1.00.26 ]] || \
	fail 'common RPM is not release 1.00.26'
[[ ! -e /run/systemd/system ]] || \
	fail 'ephemeral test container unexpectedly exposes a running systemd runtime'

test_root="$(mktemp -d /tmp/ov02c10-built-common.XXXXXX)"
topdir="${test_root}/rpmbuild"
mkdir -p "${topdir}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
trap 'rm -rf -- "$test_root"' EXIT

rendered_pretrans="${test_root}/pretrans.sh"
LC_ALL=C rpm -qp --qf '%{PRETRANS}' -- "$common_rpm" > "$rendered_pretrans"
bash -n "$rendered_pretrans" || fail 'rendered pretrans is not valid Bash'
cmp --silent -- "${repo_root}/scripts/finalizer-transaction.sh" "$rendered_pretrans" || \
	fail 'rendered pretrans differs from authenticated Source2 bytes'

cat > "${topdir}/SPECS/legacy-common.spec" <<'LEGACY_SPEC'
Name: galaxybook-ov02c10-kmod-common
Version: 1.00.24
Release: 1
Summary: Legacy OV02C10 common-package transaction fixture
License: MIT
BuildArch: noarch
AutoReqProv: no

%description
Ephemeral upgrade fixture with the historical modules-load rule.

%install
install -d %{buildroot}/etc/modules-load.d
printf 'ov02c10\n' > %{buildroot}/etc/modules-load.d/galaxybook-ov02c10.conf

%files
/etc/modules-load.d/galaxybook-ov02c10.conf
LEGACY_SPEC
rpmbuild -bb --quiet --define "_topdir ${topdir}" \
	"${topdir}/SPECS/legacy-common.spec"
legacy_rpm="${topdir}/RPMS/noarch/galaxybook-ov02c10-kmod-common-1.00.24-1.noarch.rpm"
[[ -f "$legacy_rpm" ]] || fail 'legacy common fixture was not built'

LC_ALL=C rpm --nodeps -i "$legacy_rpm"
[[ "$(rpm -q --qf '%{VERSION}\n' galaxybook-ov02c10-kmod-common)" == 1.00.24 ]] || \
	fail 'legacy common fixture was not installed'
[[ "$(</etc/modules-load.d/galaxybook-ov02c10.conf)" == ov02c10 ]] || \
	fail 'legacy modules-load fixture is missing'

set +e
LC_ALL=C rpm --nodeps -Uvh "$common_rpm" \
	> "${test_root}/upgrade.out" 2> "${test_root}/upgrade.err"
upgrade_status=$?
set -e
[[ "$upgrade_status" -eq 0 ]] || {
	sed -n '1,80p' "${test_root}/upgrade.err" >&2
	fail "rendered common-package upgrade failed with status ${upgrade_status}"
}
if grep -Eqi 'scriptlet.*failed|missing configuration variable|unexpected configuration variable|invalid bytes in configuration|usage: finalizer-transaction|resume-after-rpm' \
	"${test_root}/upgrade.out" "${test_root}/upgrade.err"
then
	sed -n '1,80p' "${test_root}/upgrade.err" >&2
	fail 'rendered transaction scriptlet reported an ABI or CLI failure'
fi

[[ "$(rpm -q --qf '%{VERSION}\n' galaxybook-ov02c10-kmod-common)" == 1.00.26 ]] || \
	fail 'rendered upgrade did not install common 1.00.26'
[[ ! -e /etc/modules-load.d/galaxybook-ov02c10.conf ]] || \
	fail 'rendered upgrade retained the package-owned legacy modules-load rule'
marker=/var/lib/galaxybook-ov02c10/migration.pending
[[ -f "$marker" && ! -L "$marker" ]] || \
	fail 'real posttrans did not queue legacy migration'
[[ "$(stat -Lc '%u:%g:%a:%h' -- "$marker")" == 0:0:644:1 ]] || \
	fail 'real posttrans published unsafe migration-marker metadata'
[[ "$(<"$marker")" == \
	$'GALAXYBOOK_OV02C10_FINALIZATION_V1\nrequest=migration' ]] || \
	fail 'real posttrans published unexpected migration-marker bytes'
[[ -x /usr/libexec/galaxybook-ov02c10/finalizer-transaction ]] || \
	fail 'rendered package did not install the transaction helper'
cmp --silent -- "${repo_root}/scripts/finalizer-transaction.sh" \
	/usr/libexec/galaxybook-ov02c10/finalizer-transaction || \
	fail 'installed transaction helper differs from authenticated Source2'
if ! rpm -V --nodeps galaxybook-ov02c10-kmod-common \
	> "${test_root}/verify.out" 2> "${test_root}/verify.err"
then
	sed -n '1,80p' "${test_root}/verify.out" >&2
	sed -n '1,80p' "${test_root}/verify.err" >&2
	fail 'installed common package failed RPM verification'
fi
[[ ! -s "${test_root}/verify.out" && ! -s "${test_root}/verify.err" ]] || \
	fail 'installed common package verification emitted diagnostics'

printf 'test-built-common-transaction: ok\n'

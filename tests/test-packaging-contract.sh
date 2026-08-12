#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
	printf 'test-packaging-contract: %s\n' "$*" >&2
	exit 1
}

[[ ! -e data/modules-load.d/galaxybook-ov02c10.conf ]] || \
	fail "modules-load configuration must not be shipped"
[[ "$(<data/modprobe.d/galaxybook-ov02c10.conf)" == \
	"softdep intel_ipu6_isys pre: ov02c10" ]] || fail "unexpected softdep"
[[ "$(<data/depmod.d/galaxybook-ov02c10.conf)" == \
	"override ov02c10 * extra/galaxybook-ov02c10/drivers/media/i2c" ]] || \
	fail "unexpected depmod override"
if rg -q '_modulesloaddir|data/modules-load' packaging/fedora/galaxybook-ov02c10-kmod.spec; then
	fail "spec still references modules-load"
fi
rg -q '^%transfiletriggerin .* -- /lib/modules /usr/lib/modules$' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || fail "missing module file trigger"

expanded_spec="$(mktemp /tmp/ov02c10-spec-test.XXXXXX)"
expanded_kernel_spec_716="$(mktemp /tmp/ov02c10-spec-kernel-716-test.XXXXXX)"
expanded_kernel_spec_718="$(mktemp /tmp/ov02c10-spec-kernel-718-test.XXXXXX)"
generated_patch="$(mktemp /tmp/ov02c10-patch-test.XXXXXX)"
trap 'rm -f -- "$expanded_spec" "$expanded_kernel_spec_716" "$expanded_kernel_spec_718" "$generated_patch"' EXIT

rpmspec -P packaging/fedora/galaxybook-ov02c10-kmod.spec > "$expanded_spec"
rg -q '^%transfiletriggerin -n galaxybook-ov02c10-kmod-common .* -- /lib/modules /usr/lib/modules$' \
	"$expanded_spec" || fail "expanded spec lost the file trigger"
rg -q '/usr/libexec/galaxybook-ov02c10/finalize-kernel --from-rpm-trigger' \
	"$expanded_spec" || fail "expanded spec does not call the finalizer"
if rg -q '/modules-load.d/galaxybook-ov02c10.conf' "$expanded_spec"; then
	fail "expanded package still ships modules-load"
fi

for kernel_spec in \
	"7.1.6-201.fc44.x86_64:${expanded_kernel_spec_716}" \
	"7.1.8-200.fc44.x86_64:${expanded_kernel_spec_718}"
do
	kernel="${kernel_spec%%:*}"
	spec_output="${kernel_spec#*:}"
	rpmspec -P --define "kernels ${kernel}" \
		packaging/fedora/galaxybook-ov02c10-kmod.spec > "$spec_output"
	rg -q "^%package[[:space:]]+-n kmod-galaxybook-ov02c10-${kernel}$" \
		"$spec_output" || fail "expanded spec lost the binary kmod package for ${kernel}"
	rg -Fq "/lib/modules/${kernel}/extra/galaxybook-ov02c10/" \
		"$spec_output" || fail "expanded spec lost the kmod payload files for ${kernel}"
	rg -Fq "for kernel_version in ${kernel}___/usr/src/kernels/${kernel}; do" \
		"$spec_output" || fail "expanded spec lost the build loop for ${kernel}"
	rg -Fq 'drivers/media/i2c/ov02c10.ko' "$spec_output" || \
		fail "expanded spec lost the OV02C10 module install for ${kernel}"
done

diff_rc=0
diff -u \
	--label a/sources/intel-ipu6/ov02c10.c sources/intel-ipu6/ov02c10.c \
	--label b/module/ov02c10.c module/ov02c10.c > "$generated_patch" || diff_rc=$?
[[ "$diff_rc" -le 1 ]] || fail "could not regenerate downstream patch"
cmp -s "$generated_patch" patches/0001-galaxy-book-ov02c10-downstream.patch || \
	fail "downstream patch is stale"

rg -q 'static s64 ov02c10_get_pixel_rate' module/ov02c10.c || \
	fail "driver does not calculate per-lane pixel rate"
rg -q 'v4l2_ctrl_new_fwnode_properties' module/ov02c10.c || \
	fail "driver does not expose fwnode controls"
rg -q -- '--add-drivers ov02c10' scripts/finalize-kernel.sh || \
	fail "finalizer must add ov02c10 only after validating the external payload"

if rg -q 'data/modules-load.d/galaxybook-ov02c10.conf' \
	README.md README.en.md README.es.md README.it.md
then
	fail "documentation still references the removed modules-load source file"
fi
rg -q 'não instala mais `modules-load.d`' README.md || \
	fail "Portuguese documentation does not explain modules-load removal"
rg -q 'no longer installs `modules-load.d`' README.en.md || \
	fail "English documentation does not explain modules-load removal"
rg -q 'ya no instala `modules-load.d`' README.es.md || \
	fail "Spanish documentation does not explain modules-load removal"
rg -q 'non installa più `modules-load.d`' README.it.md || \
	fail "Italian documentation does not explain modules-load removal"

printf 'test-packaging-contract: ok\n'

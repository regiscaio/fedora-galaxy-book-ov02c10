<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book OV02C10

## Quick install

To install the driver from the public DNF repository:

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-ov02c10
```

As complementary diagnostics and userspace tools for the Galaxy Book4 Ultra,
it also makes sense to install:

```bash
sudo dnf install galaxybook-camera galaxybook-setup
```

`fedora-galaxy-book-ov02c10` is the repository for the downstream `ov02c10`
driver used on Samsung Galaxy Book laptops under Fedora, currently focused on
the **Galaxy Book4 Ultra**.

The goal of this project is to keep a **small and reviewable** delta on top of
the `ov02c10` base used by the **Intel IPU6** stack packaged for Fedora, not
on top of the pure upstream Linux kernel driver. That avoids large divergences
between the sensor module and the rest of the IPU6 stack installed on the
system.

## Current status

In the state validated in August 2026, the packaging installs the external
module, gives it priority over the in-tree copy, registers the sensor in the
IPU6 graph, and lets `libcamera` enumerate the camera. This proves
**installation and registration**, not stable capture.

Capture on the Galaxy Book4 Ultra still delivers no frames and reports
`csi2-4 error: Frame sync error`. The machine supplies a 26 MHz external clock,
but neither the [Linux v7.1 driver](https://github.com/torvalds/linux/blob/v7.1/drivers/media/i2c/ov02c10.c)
nor the [Intel IPU6 base](https://github.com/intel/ipu6-drivers/blob/master/drivers/media/i2c/ov02c10.c)
provides a validated 26 MHz PLL sequence that keeps the link at 400 MHz. The
[Intel clock discussion](https://github.com/intel/ipu6-drivers/issues/171)
also identifies that register sequence as the missing piece.

This project therefore **does not claim that the camera works** on this
hardware. It fixes installation, probing, and metadata without inventing PLL
registers. Browser and WebRTC exposure remains in `Galaxy Book Setup`, but no
userspace bridge can fix the physical synchronization error.

## What this repository provides

The repository separates three layers clearly:

- `sources/intel-ipu6/ov02c10.c`: snapshot of the `ov02c10` driver extracted
  from the Intel IPU6 source RPM used in Fedora;
- `module/ov02c10.c`: downstream version with the required project-specific
  delta;
- `patches/0001-galaxy-book-ov02c10-downstream.patch`: patch generated from
  the difference between those two files;
- `data/modprobe.d/galaxybook-ov02c10.conf`: `softdep` asking for `ov02c10`
  before `intel_ipu6_isys`;
- `data/depmod.d/galaxybook-ov02c10.conf`: override to prioritize the packaged
  module in `extra/galaxybook-ov02c10/drivers/media/i2c` over Fedora's in-tree
  copy;
- `scripts/finalize-kernel.sh`: same-kernel `depmod` and initramfs finalization
  after validating RPM ownership, vermagic, and the external payload;
- `scripts/migrate-legacy-config.sh`: conservative removal of old `/etc`
  shadows only when their bytes exactly match project-generated content;
- `scripts/cleanup-stale-modules.sh`: detection and guarded cleanup of old
  manually installed module copies.

The project no longer installs `modules-load.d`. Forcing the sensor early in
boot could run probe before the IPU6 graph was ready and produce a transient
defer. Device demand now drives loading, while `softdep` preserves the required
ordering.

Fedora packaging generates:

- `akmod-galaxybook-ov02c10`
- `kmod-galaxybook-ov02c10`
- `galaxybook-ov02c10-kmod-common`

## What the patch changes today

The current downstream delta is intentionally small:

- it exposes `get_selection()` and crop metadata so userspace can correctly see
  the active sensor area on top of the Intel IPU6 base;
- it applies the OV02C10 rotation quirk to the Samsung Galaxy Book4 Ultra as
  well, so the image is not inverted when the fixed module is in use;
- it validates power-management resources and SSDB data, reports probe defers
  through the appropriate API, and publishes firmware orientation/rotation
  controls;
- it corrects two-lane mode metadata to `pixel_rate=160 MHz` and `HTS=2280`,
  preserving line time while producing a valid `HBLANK` value.

That timing correction is metadata-only: it does not change the sensor PLL
table and does not, by itself, solve the `Frame sync error` seen with 26 MHz.

Rebasing on the Intel IPU6 base was a deliberate decision: the old module,
although it solved sensor probing, had drifted too far from the Fedora 44
installed stack and started breaking `libcamera` integration with the media
graph exposed by IPU6.

## Relationship to the community Galaxy Book3 fix

This work was enabled by the learnings from the community repository:

- <https://github.com/abdallah-alkanani/galaxybook3-ov02c10-fix/>

That repository guided the investigation of the camera path and the clock and
crop points. It does not, however, provide a validated 26 MHz PLL sequence for
this machine. This project is **not** a direct fork of that code: the goal is
to keep a small patch on top of the Intel IPU6 `ov02c10` that tracks Fedora.

## Scope

This repository only covers the **kernel side** of the solution.

For the userspace camera application, see:

- <https://github.com/regiscaio/fedora-galaxy-book-camera>

For the graphical installer and diagnostics helper, see:

- <https://github.com/regiscaio/fedora-galaxy-book-setup>

## Installation for users

### Via local RPMs

After generating packages with `make rpm`, the recommended local installation
is:

```bash
sudo dnf install \
  /path/to/galaxybook-ov02c10-kmod-common-*.rpm \
  /path/to/akmod-galaxybook-ov02c10-*.rpm \
  /path/to/kmod-galaxybook-ov02c10-*.rpm
kernel="$(uname -r)"
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$kernel"
sudo /usr/libexec/galaxybook-ov02c10/finalize-kernel --kernel "$kernel"
sudo reboot
```

This is the recommended flow because the `akmod` automatically builds the
module for the running kernel. If a binary RPM already exists for a specific
kernel, it will have a name like
`kmod-galaxybook-ov02c10-<kernel>.rpm`; that is the real module payload. The
`kmod-galaxybook-ov02c10` package without a kernel version in its name is only
the tracking metapackage and is not enough on its own to guarantee that the
`.ko` file will already be available at boot.

If you are updating already installed local RPMs, always include the three
files in the same transaction (`common`, `akmod`, and `kmod`). An old
`kmod-galaxybook-ov02c10` metapackage can pin the previous `akmod` version
through an exact dependency and make `dnf` ignore the driver update.

The common package installs two important configurations:

- a `softdep` to prefer `ov02c10` before `intel_ipu6_isys`;
- a `depmod.d` override to prioritize the packaged module in
  `extra/galaxybook-ov02c10/drivers/media/i2c` over Fedora's in-tree driver.

An RPM `transfiletrigger` reacts when the real kmod is installed, including
when that happens in a later transaction started by `akmods`. For each kernel,
the finalizer requires exactly one payload owned by
`kmod-galaxybook-ov02c10-<kernel>` with matching vermagic. Only then does it
run `depmod`, confirm resolution through `modinfo`, rebuild the initramfs, and
use `lsinitrd` to reject any in-tree copy. Failures are not hidden.

The package also migrates legacy files under `/etc/modules-load.d`,
`/etc/modprobe.d`, and `/etc/depmod.d`. It removes an unowned regular file only
when its bytes exactly match a historically generated variant; symlinks and
local customizations are preserved.

If you need to force a module rebuild, use:

```bash
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$(uname -r)"
sudo /usr/libexec/galaxybook-ov02c10/finalize-kernel --kernel "$(uname -r)"
sudo reboot
```

If DNF, PackageKit, or the transaction log starts showing `depmod` warnings
that mention `/lib/modules/<kernel>/updates/ov02c10.ko`, look for stale module
copies that are not owned by any RPM:

```bash
make cleanup-stale-modules
sudo make cleanup-stale-modules-apply
```

The cleanup target only considers old direct overrides in `updates/` or
`extra/` when they are not owned by any package. Even with `--apply`, it
refuses removal unless the same kernel already has exactly one external
replacement owned by the expected RPM and carrying the correct vermagic.
Fedora's in-tree module and Intel IPU6-packaged modules are left untouched.

### Validation after installation

Before rebooting, the `finalize-kernel` command above is the gate: it succeeds
only when the external module and the initramfs for the **same kernel** are
consistent. After reboot, separate validation into three levels:

```bash
modinfo -n ov02c10
rpm -qf "$(modinfo -n ov02c10)"
lsmod | grep '^ov02c10 '
cam -l
cam -c 1 --capture=10
journalctl -b -k | grep -Ei 'ov02c10|frame sync|csi2'
```

The three levels mean:

- **installed**: `modinfo` points to
  `extra/galaxybook-ov02c10/drivers/media/i2c`, and `rpm -qf` returns exactly
  the kmod for the running kernel;
- **registered**: the module is present in `lsmod`, and the camera appears in
  `cam -l`;
- **capturing**: `cam --capture` delivers all ten frames, and no new
  `Frame sync`/CSI-2 errors appear in the journal.

On the tested Galaxy Book4 Ultra, the first two levels pass but the third still
fails. `libcamera` enumeration must therefore not be used as proof that the
camera works.

If boot still shows:

```text
external clock 26000000 is not supported
probe with driver ov02c10 failed with error -22
```

that log is consistent with the in-tree driver's 26 MHz rejection, but it is
not provenance proof by itself. Confirm the path and exact RPM owner with the
commands above. The most useful additional checks are:

```bash
journalctl -b -u akmods --no-pager
sed -n '1,260p' /var/cache/akmods/galaxybook-ov02c10/*.failed.log
```

If packages are installed and `akmods` is healthy, but `modinfo -n ov02c10`
still resolves to `kernel/drivers/...`, the generated `akmods` package probably
does not contain the `kmod-galaxybook-ov02c10-<kernel>` payload. Reinstall the
fixed version, force `akmods` again, and confirm that `modinfo -n ov02c10`
points to an external path before rebooting. The graphical interface also
exposes this flow at:

- <https://github.com/regiscaio/fedora-galaxy-book-setup>

## Secure Boot

If `Secure Boot` is enabled, the system module-signing flow must be configured
for `akmods`. Otherwise the module may build successfully but still be rejected
at boot time.

## Build and maintenance

Build the module for the current kernel:

```bash
make build
```

Run driver, patch, helper, and packaging contract tests:

```bash
make test
```

Regenerate the patch after editing `module/ov02c10.c`:

```bash
make export-patch
```

Refresh the Intel IPU6 base used as reference from the source RPM installed on
the system:

```bash
make refresh-base
```

By default this target reads `/usr/src/akmods/intel-ipu6-kmod.latest`. If you
want to point to another source RPM, use:

```bash
INTEL_IPU6_SRPM=/path/to/intel-ipu6-kmod.src.rpm make refresh-base
```

Generate source RPM and binary RPMs:

```bash
make srpm
make rpm
```

Relevant files:

- RPM spec: [`packaging/fedora/galaxybook-ov02c10-kmod.spec`](packaging/fedora/galaxybook-ov02c10-kmod.spec)
- downstream patch: [`patches/0001-galaxy-book-ov02c10-downstream.patch`](patches/0001-galaxy-book-ov02c10-downstream.patch)
- Intel IPU6 reference base: [`sources/intel-ipu6/ov02c10.c`](sources/intel-ipu6/ov02c10.c)

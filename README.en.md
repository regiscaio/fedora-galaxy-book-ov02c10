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

In practice, for a complete Galaxy Book4 Ultra experience it also makes sense
to install:

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

In the validated April 2026 state, this driver already covers the critical
Galaxy Book4 Ultra scenario:

- the fixed module can be loaded from `updates/` with `Secure Boot` enabled,
  as long as the host akmods signing flow is configured;
- the camera becomes visible again to `libcamera` when the system actually uses
  the fixed module instead of the in-tree kernel copy;
- the rotation quirk for the Galaxy Book4 Ultra prevents the image from
  appearing upside down in the native camera app.

What this repository does **not** solve on its own is camera exposure to web
browsers and WebRTC communication apps. That flow remains centralized in
`Galaxy Book Setup`, because it also depends on the V4L2 bridge and host-side
integration.

## What this repository provides

The repository separates three layers clearly:

- `sources/intel-ipu6/ov02c10.c`: snapshot of the `ov02c10` driver extracted
  from the Intel IPU6 source RPM used in Fedora;
- `module/ov02c10.c`: downstream version with the required project-specific
  delta;
- `patches/0001-galaxy-book-ov02c10-downstream.patch`: patch generated from
  the difference between those two files;
- `data/modules-load.d/galaxybook-ov02c10.conf`: configuration to ensure the
  module is loaded automatically at boot;
- `data/modprobe.d/galaxybook-ov02c10.conf`: `softdep` asking for `ov02c10`
  before `intel_ipu6_isys`.

Fedora packaging generates:

- `akmod-galaxybook-ov02c10`
- `kmod-galaxybook-ov02c10`
- `galaxybook-ov02c10-kmod-common`

## What the patch changes today

The current downstream delta is intentionally small:

- it exposes `get_selection()` and crop metadata so userspace can correctly see
  the active sensor area on top of the Intel IPU6 base;
- it applies the OV02C10 rotation quirk to the Samsung Galaxy Book4 Ultra as
  well, so the image is not inverted when the fixed module is in use.

Rebasing on the Intel IPU6 base was a deliberate decision: the old module,
although it solved sensor probing, had drifted too far from the Fedora 44
installed stack and started breaking `libcamera` integration with the media
graph exposed by IPU6.

## Relationship to the community Galaxy Book3 fix

This work was enabled by the learnings from the community repository:

- <https://github.com/abdallah-alkanani/galaxybook3-ov02c10-fix/>

That repository was fundamental to validate the camera path and identify the
most important clock and crop points. Still, this project is **not** a direct
fork of that code. The goal here is to keep a small patch on top of the Intel
IPU6 `ov02c10` that actually tracks Fedora.

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

The common package also installs two important configurations:

- a `modules-load.d` file to load `ov02c10` at boot;
- a `softdep` to prefer `ov02c10` before `intel_ipu6_isys`.

That avoids a state where the module exists in `/lib/modules/.../updates` but
never gets loaded by the kernel.

If you need to force a module rebuild, use:

```bash
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$(uname -r)"
sudo depmod -a
sudo reboot
```

### Validation after installation

The most useful checks after reboot are:

```bash
modinfo -n ov02c10
lsmod | grep '^ov02c10 '
cam -l
journalctl -b -k | grep -i ov02c10
```

Expected results:

- `ov02c10` should resolve to a higher-priority external path, preferably
  `updates/`, not the in-tree `kernel/drivers/...` copy;
- the module should actually be loaded in the kernel, not only installed on
  disk;
- the camera should be visible to `libcamera`;
- the error `probe with driver ov02c10 failed with error -22` should be absent.

If boot still shows:

```text
external clock 26000000 is not supported
probe with driver ov02c10 failed with error -22
```

then the system fell back to the in-tree driver. In that case, the most useful
checks are:

```bash
journalctl -b -u akmods --no-pager
sed -n '1,260p' /var/cache/akmods/galaxybook-ov02c10/*.failed.log
```

If packages are installed and `akmods` is healthy, but `modinfo -n ov02c10`
still resolves to `kernel/drivers/...`, the next step is to **adjust the fixed
module priority**. That flow is already exposed in the graphical interface at:

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

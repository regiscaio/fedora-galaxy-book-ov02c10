Name: ov02c10-rpm-lock-writer
Version: 1
Release: 1
Summary: OV02C10 RPM write-lock regression payload
License: MIT
BuildArch: noarch

%description
Writer used only inside the ephemeral RPM 6 transaction regression test.

%prep

%build

%install
install -d %{buildroot}/opt/ov02c10-rpm-lock-test
printf '%s\n' fixture > %{buildroot}/opt/ov02c10-rpm-lock-test/writer

%pretrans
if [ -n "${OV02C10_WRITER_READY:-}" ] && [ -n "${OV02C10_WRITER_RELEASE:-}" ]; then
  : > "${OV02C10_WRITER_READY}"
  while [ ! -f "${OV02C10_WRITER_RELEASE}" ]; do
    /usr/bin/sleep 0.01
  done
fi

%files
/opt/ov02c10-rpm-lock-test/writer

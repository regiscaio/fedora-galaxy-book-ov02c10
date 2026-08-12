Name: ov02c10-rpm-lock-payload
Version: 1
Release: 1
Summary: OV02C10 RPM read-lock regression payload
License: MIT
BuildArch: noarch

%description
Payload used only inside the ephemeral RPM 6 transaction regression test.

%prep

%build

%install
install -d %{buildroot}/opt/ov02c10-rpm-lock-test
printf '%s\n' fixture > %{buildroot}/opt/ov02c10-rpm-lock-test/module.ko

%files
/opt/ov02c10-rpm-lock-test/module.ko

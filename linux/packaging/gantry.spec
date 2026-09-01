Name:           gantry
Version:        @VERSION@
Release:        1%{?dist}
Summary:        Local 3D printer status monitor
License:        MIT
URL:            https://github.com/parametryczny/Gantrybar
Source0:        gantry-%{version}.tar.gz
BuildArch:      noarch

BuildRequires:  python3-devel
Requires:       python3 >= 3.10
Requires:       python3-gobject
Requires:       python3-websocket-client
Requires:       gtk3
Requires:       libayatana-appindicator-gtk3
Requires:       libsecret
Requires:       libnotify
Requires:       openssl
Requires:       avahi
Requires:       xset
Requires:       gstreamer1-plugins-base
Requires:       gstreamer1-plugins-good
Requires:       gstreamer1-plugins-good-gtk
Requires:       gstreamer1-plugins-bad-free
Requires:       gstreamer1-plugin-libav
Conflicts:      bambubar
Obsoletes:      bambubar

%description
Gantry monitors Bambu Lab, Anycubic, Elegoo, Klipper/Moonraker and PrusaLink printers over the
local network. It shows print progress, temperatures, layers and filament
slots in a compact GTK desktop dashboard and system tray application.

%prep
%autosetup

%build
# Pure Python application; nothing is compiled here.

%install
install -d %{buildroot}%{python3_sitelib} \
           %{buildroot}%{_bindir} \
           %{buildroot}%{_datadir}/applications \
           %{buildroot}%{_datadir}/icons/hicolor/scalable/apps \
           %{buildroot}%{_datadir}/metainfo \
           %{buildroot}%{_docdir}/gantry
cp -a linux/gantry %{buildroot}%{python3_sitelib}/gantry
find %{buildroot}%{python3_sitelib}/gantry -type d -name __pycache__ -prune -exec rm -rf {} +
install -m 0755 linux/packaging/gantry %{buildroot}%{_bindir}/gantry
install -m 0755 linux/packaging/gantry-kiosk %{buildroot}%{_bindir}/gantry-kiosk
install -m 0755 linux/packaging/gantry-kiosk-setup %{buildroot}%{_bindir}/gantry-kiosk-setup
install -m 0644 linux/packaging/gantry.desktop %{buildroot}%{_datadir}/applications/gantry.desktop
install -m 0644 linux/packaging/gantry-kiosk.desktop %{buildroot}%{_datadir}/applications/gantry-kiosk.desktop
install -m 0644 linux/assets/gantry.svg %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/gantry.svg
install -m 0644 linux/packaging/gantry.metainfo.xml %{buildroot}%{_datadir}/metainfo/pl.parametryczny.Gantry.metainfo.xml
install -m 0644 linux/packaging/Gantry-printers-template.csv %{buildroot}%{_docdir}/gantry/Gantry-printers-template.csv

%files
%license LICENSE
%doc linux/README.md
%{_bindir}/gantry
%{_bindir}/gantry-kiosk
%{_bindir}/gantry-kiosk-setup
%{python3_sitelib}/gantry
%{_datadir}/applications/gantry.desktop
%{_datadir}/applications/gantry-kiosk.desktop
%{_datadir}/icons/hicolor/scalable/apps/gantry.svg
%{_datadir}/metainfo/pl.parametryczny.Gantry.metainfo.xml
%{_docdir}/gantry/Gantry-printers-template.csv

%changelog
* Mon Aug 31 2026 Kamil Grzegorczyk <parametryczny@users.noreply.github.com> - @VERSION@-1
- Add the native RPM package.

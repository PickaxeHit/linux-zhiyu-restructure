# D-Bus policy for zhiyu-sensord: it owns net.hadess.SensorProxy on the system
# bus.  Installed through services.dbus.packages so NixOS merges it into
# /etc/dbus-1/system.d instead of writing into a directory another package
# already owns.
{
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "zhiyu-sensord-dbus";
  version = "1";

  dontUnpack = true;

  installPhase = ''
    install -Dm0644 ${./sensord-dbus.conf} \
      $out/share/dbus-1/system.d/zhiyu-sensord.conf
  '';

  meta = {
    description = "D-Bus policy for zhiyu-sensord";
    platforms = lib.platforms.linux;
  };
}

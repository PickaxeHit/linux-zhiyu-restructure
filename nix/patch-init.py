"""Inject the NixOS selector without changing the shared distro /init."""
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
s = p.read_text()
anchor = "rootfs_init() {\n"
if s.count(anchor) != 1:
    raise SystemExit("Unexpected upstream init: rootfs_init anchor changed")
# Do not allow the legacy system-profile path or /sbin/init to bypass the
# ID check for a NixOS root. Other distributions retain their FHS path.
new = anchor + '''\t# NixOS has a system profile; a normal distro may also have Nix
\t# installed, so the mere existence of profiles/ is not sufficient.
\tfor profile in /newroot/nix/var/nix/profiles/system \\
\t               /newroot/nix/var/nix/profiles/zhiyu-boot \\
\t               /newroot/nix/var/nix/profiles/zhiyu-pending \\
\t               /newroot/nix/var/nix/profiles/system-*-link; do
\t\t[ -L "$profile" ] || continue
\t\tif selected=$(/bin/zhiyu-boot-select 2>/dev/kmsg); then
\t\t\tprintf '%s\\n' "$selected"
\t\t\treturn 0
\t\tfi
\t\tcmsg "NixOS: no generation matches the running boot artifacts"
\t\treturn 1
\tdone
'''
s = s.replace(anchor, new, 1)
p.write_text(s)

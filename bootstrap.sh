#!/bin/sh
#
# Turns the Debian the installer has just laid down into a moon desktop, while the installer is
# still running - so the first time the machine boots for itself, it boots into moon.
#
# `vm.sh create` hands this to VirtualBox as the command to run at the end of the install, and
# serves this repo over HTTP for the length of it. This runs inside the
# installer, as root, outside the chroot, with the new system mounted at /target.
#
#   bootstrap.sh <where the host is serving from> [<user>]
#
# Everything it says goes to the installer's console as well as its log, because a provisioning
# that goes wrong here is a machine with no desktop and no way in to ask why.

set -eu

FROM="${1:?the address this machine can fetch this repo from}"
MOON_USER="${2:-moon}"
TARGET=/target

say() {
    echo "moonos: $*" | tee /dev/console
}

in_target() {
    chroot "$TARGET" "$@"
}

# moon itself is not fetched from the host: the provisioning installs the published release.
say "fetching moonos from $FROM"
mkdir -p "$TARGET/home/$MOON_USER/moonos"
wget -q -O - "$FROM/moonos.tar.gz" \
    | tar -xz -C "$TARGET/home/$MOON_USER/moonos"
in_target chown -R "$MOON_USER:$MOON_USER" "/home/$MOON_USER"

# The provisioning wants a network it can reach: the installer's resolver is what the installed system
# will use anyway.
cp /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true

# And something for apt to fetch from. At this point in the install apt inside the target still
# only knows about the CD it was installed from, because d-i writes the real sources.list after
# this hook has run - so `apt-get update` in there answers "Err: cdrom://..." and everything
# that needs a package fails. This file is d-i's own name for it, and d-i overwrites it with
# the same thing later.
# The CD has to go as well as the network arriving: `apt-get update` fails outright on a
# `deb cdrom:` line it cannot read - "does not have a Release file" - however many working
# sources sit beside it. d-i writes the real sources.list after this hook, cdrom line and all,
# so nothing here is lost.
say "pointing the new system's apt at the network instead of the CD"
sed -i 's|^deb cdrom:|# deb cdrom:|' "$TARGET/etc/apt/sources.list"
echo "deb http://deb.debian.org/debian trixie main" \
    > "$TARGET/etc/apt/sources.list.d/moonos-bootstrap.list"

say "making it a desktop - packages from Debian and the released moon, a few minutes"

# Through `tee` so that it can be watched on the console, and the status written down on the
# way past: a pipeline answers with what its last command did, so `tee` succeeding would
# otherwise make a provisioning that failed look like one that worked - which is exactly what it did.
# `env` without `-i` keeps whatever PATH the process calling it had - which here is the live
# installer's, not the target filesystem's, and chrooting does not change that. The installer's
# PATH has no /usr/local/bin, so a plain `moon` - put there by this same provisioning, a moment
# earlier - is not found by the very next line that asks for it. Spelling PATH out is the fix;
# it is also then the same PATH a real login shell on the finished machine would have.
in_target env \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    MOON_USER="$MOON_USER" \
    MOONOS_DIR="/home/$MOON_USER/moonos" \
    HOME=/root \
    sh -c "sh /home/$MOON_USER/moonos/provision.sh all 2>&1; echo \$? > /moonos-built" \
    | tee /dev/console

built="$(cat "$TARGET/moonos-built" 2>/dev/null || echo 1)"
rm -f "$TARGET/moonos-built"
if [ "$built" != 0 ]; then
    say "the provisioning failed ($built) - this machine is a Debian, not a desktop"
    exit "$built"
fi

say "the machine is a moon desktop now"

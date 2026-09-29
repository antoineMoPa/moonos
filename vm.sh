#!/usr/bin/env bash
#
# The VirtualBox machine moon boots into as a desktop.
#
#   ./vm.sh create     a Debian machine of this host's architecture, installed unattended
#   ./vm.sh start      headless
#   ./vm.sh stop
#   ./vm.sh ssh [...]  a shell in it, or one command - once its user has trusted your key
#   ./vm.sh address    where it is on the network
#   ./vm.sh shot FILE  what its screen shows right now, as a PNG
#   ./vm.sh delete
#
# The machine has no display of its own to look at while it installs: `shot` is how the install
# and the desktop after it are watched.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="$HERE/.cache"

VM="${MOONOS_VM:-moonos}"
ISO_VERSION="13.7.0"

# The architecture the machine is built for, which is the one it is built on: VirtualBox runs a
# machine of the host's architecture and emulates no other. `MOONOS_ARCH` is for saying so by
# hand - the name is `uname -m`'s.
#
# What each one is called by the two that need naming it: Debian, whose ISOs are laid out by
# architecture, and VirtualBox, whose guest types are their own words. A new architecture is a
# row here and nothing else.
ARCHITECTURES="
aarch64 arm64 Debian13_arm64
arm64   arm64 Debian13_arm64
x86_64  amd64 Debian13_64
amd64   amd64 Debian13_64
"
# What the installer is booted with. `debian-installer/exit/poweroff` is the whole point of
# this line: without it the installer reboots into what it just installed and sits at a login
# prompt, which from out here is indistinguishable from an installer stuck on a question. With
# it the machine switches itself off, and off means done.
#
# Not `exit/halt`, which stops the machine without switching it off - the console says "System
# halted" and VirtualBox goes on reporting it as running, forever.
#
# VirtualBox writes this line itself, and passing any of it replaces all of it, so what it
# would have written is spelled out here. Anything after `--` is for the installed system
# rather than the installer, so ours goes before it.
INSTALL_KERNEL_PARAMETERS="auto=true preseed/file=/cdrom/preseed.cfg priority=critical quiet splash noprompt noshell automatic-ubiquity debian-installer/locale=en_US keyboard-configuration/layoutcode=us languagechooser/language-name=English localechooser/supported-locales=en_US.UTF-8 countrychooser/shortlist=US debian-installer/exit/poweroff=true --"

ARCH="${MOONOS_ARCH:-$(uname -m)}"
DEBIAN_ARCH="$(awk -v arch="$ARCH" '$1 == arch { print $2; exit }' <<<"$ARCHITECTURES")"
GUEST_TYPE="$(awk -v arch="$ARCH" '$1 == arch { print $3; exit }' <<<"$ARCHITECTURES")"
if [ -z "$DEBIAN_ARCH" ]; then
    echo "moonos does not know what Debian and VirtualBox call $ARCH - add a row to" >&2
    echo "ARCHITECTURES in $(basename "${BASH_SOURCE[0]}")" >&2
    exit 1
fi

ISO="$CACHE/debian-$ISO_VERSION-$DEBIAN_ARCH-netinst.iso"
ISO_URL="https://cdimage.debian.org/debian-cd/current/$DEBIAN_ARCH/iso-cd/debian-$ISO_VERSION-$DEBIAN_ARCH-netinst.iso"

# The machine builds moon from source - a Rust workspace with Ghostty's VT engine under it - so
# it is given the cores and the memory of a build machine, not of a desktop.
MEMORY_MB=8192
CPUS=6
DISK_MB=40960
VRAM_MB=128

# Who the desktop belongs to. ssh is by key.
USER_NAME=moon
USER_PASSWORD=moon
# The host interface the machine is bridged onto: whichever one the host's own default route
# goes out of, asked for in the way this host answers.
default_interface() {
    if command -v route >/dev/null 2>&1 && route -n get default >/dev/null 2>&1; then
        route -n get default | awk '/interface:/ { print $2 }'    # macOS, BSD
    elif command -v ip >/dev/null 2>&1; then
        ip route show default | awk '/default/ { print $5; exit }'  # Linux
    fi
}
BRIDGE_TO="${MOONOS_BRIDGE:-$(default_interface)}"
SSH_KEY="$CACHE/id_moonos"

say() { printf '\n=== %s\n' "$*"; }

need_iso() {
    if [ ! -f "$ISO" ]; then
        say "downloading Debian $ISO_VERSION $DEBIAN_ARCH"
        mkdir -p "$CACHE"
        curl -fL -o "$ISO" "$ISO_URL"
    fi
}

need_key() {
    if [ ! -f "$SSH_KEY" ]; then
        mkdir -p "$CACHE"
        ssh-keygen -t ed25519 -N "" -C "moonos" -f "$SSH_KEY" >/dev/null
    fi
}

create() {
    need_iso

    if VBoxManage showvminfo "$VM" >/dev/null 2>&1; then
        echo "$VM already exists - ./vm.sh delete first" >&2
        exit 1
    fi

    say "making $VM"
    VBoxManage createvm --name "$VM" --ostype "$GUEST_TYPE" --register
    # Bridged puts the machine on the same network as the host, where it gets its own address -
    # which is also how ssh reaches it. `./vm.sh ssh` finds that address by the card's MAC.
    VBoxManage modifyvm "$VM" \
        --memory "$MEMORY_MB" --cpus "$CPUS" --vram "$VRAM_MB" \
        --firmware efi --graphicscontroller vmsvga --audio-driver none \
        --usb-xhci on --keyboard usb --mouse usbtablet \
        --nic1 bridged --bridge-adapter1 "$BRIDGE_TO" --nic-type1 virtio --cableconnected1 on
    # USB keyboard and a USB tablet for the pointer. VirtualBox gives a new machine a PS/2
    # keyboard and a PS/2 mouse, and an ARM machine has no PS/2 at all: nothing typed at the
    # window reaches the guest, and `VBoxManage controlvm keyboardputscancode` answers "failed
    # to send a scancode".

    # A serial console, written to a file on this machine. It carries the firmware and GRUB, not
    # the ARM kernel.
    VBoxManage modifyvm "$VM" --uart1 0x3f8 4 --uart-mode1 file "$CACHE/$VM-serial.log"


    local disk="$HOME/VirtualBox VMs/$VM/$VM.vdi"
    VBoxManage createmedium disk --filename "$disk" --size "$DISK_MB" --format VDI
    # Room for the disk, the install ISO and the one VirtualBox makes for the unattended
    # answers: with only two ports, that third one takes the install ISO's place and the
    # installer gets as far as "no device for installation media was detected".
    VBoxManage storagectl "$VM" --name VirtioSCSI --add virtio-scsi --portcount 4 --bootable on
    VBoxManage storageattach "$VM" --storagectl VirtioSCSI --port 0 --device 0 \
        --type hdd --medium "$disk"
    VBoxManage storageattach "$VM" --storagectl VirtioSCSI --port 1 --device 0 \
        --type dvddrive --medium "$ISO"

    say "installing Debian, unattended"
    VBoxManage unattended install "$VM" \
        --iso="$ISO" \
        --user="$USER_NAME" --user-password="$USER_PASSWORD" \
        --admin-password="$USER_PASSWORD" \
        --full-user-name="moon" \
        --hostname="moonos.local" \
        --locale=en_US --country=US --time-zone=UTC \
        --package-selection-adjustment=minimal \
        --extra-install-kernel-parameters="$INSTALL_KERNEL_PARAMETERS" \
        --start-vm=headless

    await_install
}

# How much has to be on the disk before a machine counts as installed. A Debian with nothing
# chosen is well over a gigabyte; an empty disk is a rounding error.
INSTALLED_AT_LEAST_MB=500

# How long an install is given before it is called stuck. It takes about five minutes, so this
# is a long way past wrong rather than a guess at right.
INSTALL_PATIENCE=$((20 * 60))

# Wait for the install, and say which way it went.
#
# It is done when the machine powers itself off. Until then its screen is the only thing to go
# on, so one that stops changing is reported with a picture of it: that is the shape a stuck
# install takes - an installer asking something, with nobody there to answer. It asked about a
# mirror it could not reach for a whole afternoon once.
await_install() {
    local shot="$CACHE/$VM-install.png"
    local began=$SECONDS said_at=$SECONDS

    while running; do
        sleep 20
        if [ $((SECONDS - said_at)) -ge 120 ]; then
            echo "  $(((SECONDS - began) / 60))m, $(disk_written_mb)MB on disk"
            said_at=$SECONDS
        fi
        if [ $((SECONDS - began)) -ge "$INSTALL_PATIENCE" ]; then
            VBoxManage controlvm "$VM" screenshotpng "$shot" >/dev/null 2>&1 || true
            echo "$VM is still installing after $((INSTALL_PATIENCE / 60)) minutes." >&2
            echo "what its screen shows: $shot" >&2
            return 1
        fi
    done

    local ended
    ended="$(state)"
    if [ "$ended" != "poweroff" ]; then
        echo "$VM ended up ${ended:-gone} rather than off, so the install did not finish" >&2
        return 1
    fi

    # Powering off is how an install ends, but it is also how one that never started ends -
    # a machine with nothing to boot switches itself off in seconds and looks exactly the
    # same from here. What tells them apart is whether Debian is on the disk.
    written=$(disk_written_mb)
    if [ "$written" -lt "$INSTALLED_AT_LEAST_MB" ]; then
        echo "$VM switched off with only ${written}MB on its disk, so nothing was installed." >&2
        echo "what its screen last showed: $shot" >&2
        return 1
    fi
    say "installed in $(((SECONDS - began) / 60))m, ${written}MB on disk - ./vm.sh start"
}

start() {
    # Where the serial console is written is kept in the machine's own settings, as an
    # absolute path into this repo - so a repo that has been moved or renamed since the machine
    # was made leaves VirtualBox unable to create that file, and it refuses to start the
    # machine at all ("RawFile#0 failed to create the raw output file"). Pointing it at where
    # this repo is now costs nothing and makes moving the repo a non-event.
    mkdir -p "$CACHE"
    VBoxManage modifyvm "$VM" --uart-mode1 file "$CACHE/$VM-serial.log"
    VBoxManage startvm "$VM" --type headless
}

# How long the machine is given to go down on its own before it is switched off at the wall.
SHUTDOWN_PATIENCE=60

stop() {
    if ! running; then
        echo "$VM is not running"
        return
    fi

    # Over ssh first. The ACPI power button below is what a machine with a desktop environment
    # listens for, and this one has no such thing - moon is its desktop - so nothing in it acts
    # on the button and the machine stays up. Asking systemd directly is what actually works.
    if ssh_in 'sudo systemctl poweroff' >/dev/null 2>&1; then
        :
    else
        VBoxManage controlvm "$VM" acpipowerbutton || true
    fi

    local until_then=$((SECONDS + SHUTDOWN_PATIENCE))
    while running; do
        if [ "$SECONDS" -ge "$until_then" ]; then
            # Nothing else is left. This is the switch at the wall, and the machine comes back
            # up with a filesystem to replay - which is what `aborted` in VirtualBox means.
            echo "$VM would not go down in ${SHUTDOWN_PATIENCE}s - switching it off" >&2
            VBoxManage controlvm "$VM" poweroff
            break
        fi
        sleep 2
    done
    echo "$VM is off"
}

# How much of the machine's disk has actually been written, in megabytes. The file grows as
# the disk fills: a VDI is only as big as what is in it.
disk_written_mb() {
    local disk="$HOME/VirtualBox VMs/$VM/$VM.vdi"
    if [ ! -f "$disk" ]; then
        echo 0
        return
    fi
    echo $(( $(du -k "$disk" | cut -f1) / 1024 ))
}

# What VirtualBox says the machine is doing, and whether that is running.
state() {
    VBoxManage showvminfo "$VM" --machinereadable 2>/dev/null \
        | sed -n 's/^VMState="\(.*\)"/\1/p'
}

running() {
    [ "$(state)" = "running" ]
}

shot() {
    local out="${1:-/tmp/$VM.png}"
    VBoxManage controlvm "$VM" screenshotpng "$out"
    echo "$out"
}

# Where the machine is on the network: the address the host's own ARP table has against the
# MAC of the machine's card.
#
# An entry that nothing has talked to goes stale and drops out, so the address it last had is
# kept and pinged first - that alone brings it back most of the time. A broadcast ping is the
# fallback, for a machine that has just come up or been given another address.
address() {
    local mac remembered found
    mac="$(VBoxManage showvminfo "$VM" --machinereadable | sed -n 's/^macaddress1="\(.*\)"/\1/p' \
        | sed 's/\(..\)/\1:/g; s/:$//' | tr 'A-Z' 'a-z' | sed 's/0\(.\):/\1:/g')"
    remembered="$CACHE/$VM-address"

    if [ -f "$remembered" ]; then
        knock "$(cat "$remembered")"
    fi
    found="$(neighbour_with "$mac")"
    if [ -z "$found" ]; then
        knock 255.255.255.255
        found="$(neighbour_with "$mac")"
    fi

    if [ -n "$found" ]; then
        mkdir -p "$CACHE"
        printf '%s' "$found" > "$remembered"
    fi
    printf '%s' "$found"
}

# A ping that is not waited on for long, however this host spells that.
knock() {
    if ping -c 1 -t 1 "$1" >/dev/null 2>&1; then    # macOS, BSD: -t is the deadline
        return 0
    fi
    ping -c 1 -W 1 "$1" >/dev/null 2>&1 || true     # Linux: -W is the deadline, -t is TTL
}

# The address this host's own neighbour table has against a MAC.
neighbour_with() {
    local mac="$1"
    if command -v arp >/dev/null 2>&1 && arp -an >/dev/null 2>&1; then
        arp -an | awk -v mac="$mac" '$4 == mac { gsub(/[()]/, "", $2); print $2; exit }'
    elif command -v ip >/dev/null 2>&1; then
        ip neigh | awk -v mac="$mac" '$5 == mac { print $1; exit }'
    fi
}

ssh_in() {
    need_key
    local host
    host="$(address)"
    if [ -z "$host" ]; then
        echo "$VM is not on the network yet - is it started?" >&2
        exit 1
    fi
    if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$USER_NAME@$host" true 2>/dev/null
    then
        cat >&2 <<EOF
$VM will not let this machine in, which is how it is installed: it trusts no key until
somebody inside it says so. At its console, logged in as $USER_NAME:

  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  echo '$(cat "$SSH_KEY.pub")' >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys

Then this, and \`push.sh\`, reach it.
EOF
        exit 1
    fi
    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$USER_NAME@$host" "$@"
}

delete() {
    VBoxManage controlvm "$VM" poweroff 2>/dev/null || true
    # Unregistering a machine VirtualBox still holds a session on leaves its folder behind,
    # and the next `create` refuses to write over it.
    while running; do
        sleep 1
    done
    sleep 2
    VBoxManage unregistervm "$VM" --delete 2>/dev/null || true
    rm -rf "$HOME/VirtualBox VMs/$VM"
}

case "${1:-}" in
    create) create ;;
    start) start ;;
    stop) stop ;;
    shot) shift; shot "$@" ;;
    ssh) shift; ssh_in "$@" ;;
    delete) delete ;;
    key) need_key; echo "$SSH_KEY" ;;
    address) address ;;
    *) sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac

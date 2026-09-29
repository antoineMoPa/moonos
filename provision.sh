#!/usr/bin/env bash
#
# Turns the installed Debian into the machine that boots into moon.
#
# Runs inside the machine. `./push.sh` runs it from the outside over ssh, which is a way of
# working on moon rather than anything the machine needs - a desktop is not a thing you ssh
# into. Run it from a terminal in the machine itself and it does the same, with the two repos
# cloned wherever you like and `MOONOS`/`SOURCE` below pointed at them.
#
# Everything it does is idempotent: it is run again after every change to moon, and only the
# build takes any time.
#
#   provision.sh packages     what the desktop and the build need, from Debian
#   provision.sh applications what there is to start, and the extension that lists it
#   provision.sh toolchain    Rust and Zig, which moon is built with
#   provision.sh build        build moon out of ~/moon-dev-tools and install it
#   provision.sh session      boot into moon: autologin on tty1, and X starting the desktop
#   provision.sh all          all of the above, in that order

set -euo pipefail

# The two repos `push.sh` sends: moon's own source, which is built here, and this one.
# Who the desktop belongs to, and where their things go. Inside the Debian installer this runs
# as root against the user the installer just made, so neither is taken from whoever is typing.
MOON_USER="${MOON_USER:-${SUDO_USER:-${USER:-moon}}}"
MOON_HOME="$(getent passwd "$MOON_USER" | cut -d: -f6)"
: "${MOON_HOME:?no such user as $MOON_USER}"

# `sudo` when there is somebody to ask, and nothing at all when this is already root - the
# installer has no sudo installed yet at the point it runs this.
SUDO=sudo
if [ "$(id -u)" = 0 ]; then
    SUDO=
fi

SOURCE="${MOON_SOURCE_DIR:-$MOON_HOME/moon-dev-tools}"
MOONOS="${MOONOS_DIR:-$MOON_HOME/moonos}"
ZIG_VERSION=0.15.2
# Zig names its downloads by the architecture in the same words `uname -m` does, so there is
# nothing here to keep in step with anything.
ZIG_HOME="/opt/zig-$(uname -m)-linux-$ZIG_VERSION"

say() { printf '\n=== %s\n' "$*"; }

packages() {
    say "what the desktop and the build need"
    $SUDO apt-get update
    # Xorg and no desktop environment: moon is the desktop environment - see `moon desktop`.
    #
    # No video driver package: the card VirtualBox gives an ARM machine is a VMware SVGA II,
    # whose Xorg driver Debian does not build for arm64 at all. The kernel's own vmwgfx does
    # drive it - there is a /dev/dri/card0 - so Xorg's built-in modesetting driver takes it
    # from there, and mesa draws on it.
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xserver-xorg xserver-xorg-input-libinput xinit mesa-utils \
        x11-xserver-utils libgl1 libegl1 libglx-mesa0 libgl1-mesa-dri \
        fonts-dejavu-core fonts-noto-color-emoji \
        ca-certificates curl git xz-utils pkg-config build-essential cmake \
        xdotool \
        libx11-dev libxcursor-dev libxrandr-dev libxi-dev libxkbcommon-dev \
        libwayland-dev libfontconfig1-dev libssl-dev \
        x11-apps xterm xdotool
}

# What there is to start from the palette, which is also what the `applications` extension
# lists: the pair of eyes first, a browser after it.
applications() {
    say "applications to start in the frames"
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        x11-apps x11-utils chromium

    # x11-apps ships the programs and no desktop entries, so a machine with nothing else
    # installed has nothing to start.
    $SUDO install -d /usr/local/share/applications
    $SUDO tee /usr/local/share/applications/xeyes.desktop >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=X Eyes
Comment=A pair of eyes that follow the pointer
Exec=xeyes
Categories=Utility;
Terminal=false
EOF
    $SUDO tee /usr/local/share/applications/xclock.desktop >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=X Clock
Comment=The time, drawn once a second
Exec=xclock -update 1
Categories=Utility;
Terminal=false
EOF

    # The extension that lists them, into the folder moon offers a person's own extensions
    # from - see Extensions.md in moon for how the folder works.
    install -d -o "$MOON_USER" -g "$MOON_USER" "$MOON_HOME/.moonreview/extensions"
    install -o "$MOON_USER" -g "$MOON_USER" -m 0644 \
        "$MOONOS/extensions/applications.rhai" "$MOON_HOME/.moonreview/extensions/"
    echo "applications.rhai -> ~/.moonreview/extensions/"
}

toolchain() {
    say "Rust and Zig"
    if ! [ -x "$HOME/.cargo/bin/cargo" ]; then
        curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    fi
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
    rustup update stable
    rustup target add wasm32-unknown-unknown

    # egui_tty compiles Ghostty's VT engine from source, which needs a 0.15.x Zig - and Debian
    # has no Zig at all.
    if ! [ -x "$ZIG_HOME/zig" ]; then
        curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-$(uname -m)-linux-$ZIG_VERSION.tar.xz" \
            | $SUDO tar -xJ -C /opt
        $SUDO ln -sf "$ZIG_HOME/zig" /usr/local/bin/zig
    fi
    zig version
}

build() {
    say "building moon"
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
    cd "$SOURCE"
    cargo build --release --bin moon
    $SUDO install -m 0755 target/release/moon /usr/local/bin/moon
    moon --version
}

session() {
    say "booting into moon"

    # tty1 logs this user in without asking: the machine has one user, and the desktop is the
    # only thing it is for. The password still guards sudo, and the console of any other tty.
    $SUDO mkdir -p /etc/systemd/system/getty@tty1.service.d
    $SUDO tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $MOON_USER --noclear %I \$TERM
EOF

    # Logging in on tty1 starts X, and X starts moon. Any other tty gets a plain shell - which
    # is how a session that will not start is put right.
    install -o "$MOON_USER" -g "$MOON_USER" -m 0755 "$MOONOS/rootfs/xinitrc" "$MOON_HOME/.xinitrc"
    grep -q "moon desktop" "$MOON_HOME/.bash_profile" 2>/dev/null \
        || cat >> "$MOON_HOME/.bash_profile" <<'EOF'

# The desktop: logging in on the first console starts X, and X starts moon - see ~/.xinitrc.
# `startx` is not run again inside it, and every other way in gets an ordinary shell.
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx -- -keeptty vt1
fi
EOF
    chown "$MOON_USER:$MOON_USER" "$MOON_HOME/.bash_profile"

    # Anyone may start X, not only root: the desktop is started by the person logging in.
    $SUDO tee /etc/X11/Xwrapper.config >/dev/null <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

    # In the installer there is no systemd running to ask, so the same thing is done by hand:
    # the default target is a symlink, and a reload is only needed by a system that is up.
    $SUDO ln -sf /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
    systemctl daemon-reload 2>/dev/null || true
    echo "reboot to land in moon"
}

case "${1:-all}" in
    packages) packages ;;
    applications) applications ;;
    toolchain) toolchain ;;
    build) build ;;
    session) session ;;
    all)
        packages
        applications
        toolchain
        build
        session
        ;;
    *)
        echo "provision.sh [packages|applications|toolchain|build|session|all]" >&2
        exit 2
        ;;
esac

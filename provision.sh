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
SOURCE="$HOME/moon-dev-tools"
MOONOS="$HOME/moonos"
ZIG_VERSION=0.15.2
# Zig names its downloads by the architecture in the same words `uname -m` does, so there is
# nothing here to keep in step with anything.
ZIG_HOME="/opt/zig-$(uname -m)-linux-$ZIG_VERSION"

say() { printf '\n=== %s\n' "$*"; }

packages() {
    say "what the desktop and the build need"
    sudo apt-get update
    # Xorg and no desktop environment: moon is the desktop environment - see `moon desktop`.
    #
    # No video driver package: the card VirtualBox gives an ARM machine is a VMware SVGA II,
    # whose Xorg driver Debian does not build for arm64 at all. The kernel's own vmwgfx does
    # drive it - there is a /dev/dri/card0 - so Xorg's built-in modesetting driver takes it
    # from there, and mesa draws on it.
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
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
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        x11-apps x11-utils chromium

    # x11-apps ships the programs and no desktop entries, so a machine with nothing else
    # installed has nothing to start.
    sudo install -d /usr/local/share/applications
    sudo tee /usr/local/share/applications/xeyes.desktop >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=X Eyes
Comment=A pair of eyes that follow the pointer
Exec=xeyes
Categories=Utility;
Terminal=false
EOF
    sudo tee /usr/local/share/applications/xclock.desktop >/dev/null <<'EOF'
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
    mkdir -p "$HOME/.moonreview/extensions"
    install -m 0644 "$MOONOS/extensions/applications.rhai" "$HOME/.moonreview/extensions/"
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
            | sudo tar -xJ -C /opt
        sudo ln -sf "$ZIG_HOME/zig" /usr/local/bin/zig
    fi
    zig version
}

build() {
    say "building moon"
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
    cd "$SOURCE"
    cargo build --release --bin moon
    sudo install -m 0755 target/release/moon /usr/local/bin/moon
    moon --version
}

session() {
    say "booting into moon"

    # tty1 logs this user in without asking: the machine has one user, and the desktop is the
    # only thing it is for. The password still guards sudo, and the console of any other tty.
    sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
    sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
EOF

    # Logging in on tty1 starts X, and X starts moon. Any other tty gets a plain shell - which
    # is how a session that will not start is put right.
    cp "$MOONOS/rootfs/xinitrc" "$HOME/.xinitrc"
    chmod 0755 "$HOME/.xinitrc"
    grep -q "moon desktop" "$HOME/.bash_profile" 2>/dev/null || cat >> "$HOME/.bash_profile" <<'EOF'

# The desktop: logging in on the first console starts X, and X starts moon - see ~/.xinitrc.
# `startx` is not run again inside it, and every other way in gets an ordinary shell.
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx -- -keeptty vt1
fi
EOF

    # Anyone may start X, not only root: the desktop is started by the person logging in.
    sudo tee /etc/X11/Xwrapper.config >/dev/null <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

    sudo systemctl daemon-reload
    sudo systemctl set-default multi-user.target
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

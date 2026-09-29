#!/usr/bin/env bash
#
# This repo and moon's source, onto the machine, and then whatever step of `provision.sh` was
# asked for.
#
#   ./push.sh                the source and a build of it
#   ./push.sh all            the source, then everything the machine needs from scratch
#   ./push.sh build          the source, then build and install moon
#   ./push.sh session        the source, then the boot-into-moon part alone
#   ./push.sh -              the source and nothing else

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP="${1:-build}"

# Where moon itself is checked out. The machine builds moon from source, so this repo needs to
# be able to find it; it is a repo of its own - see the README - and sits beside this one
# unless `MOON_SOURCE` says otherwise.
MOON_SOURCE="${MOON_SOURCE:-$(cd "$HERE/.." && pwd)/moon-dev-tools}"
if [ ! -f "$MOON_SOURCE/Cargo.toml" ]; then
    cat >&2 <<EOF
moon's source is not at $MOON_SOURCE, and the machine is built from it. Clone it beside this
repo:

  git clone --recurse-submodules git@github.com:antoineMoPa/moon-dev-tools.git $MOON_SOURCE

or set MOON_SOURCE to where it already is.
EOF
    exit 1
fi

address="$("$HERE/vm.sh" address)"
if [ -z "$address" ]; then
    echo "the machine is not on the network - ./vm.sh start" >&2
    exit 1
fi
key="$("$HERE/vm.sh" key)"

send() {
    local from="$1" to="$2" sent
    # Everything but what is made from it: a build's own output is 40 GB of it, and the machine
    # has its own.
    #
    # `-rlpgoD` is `-a` without its `-t` - see the touch below.
    sent="$(rsync -rlpgoD --delete --compress --out-format='%n' \
        --exclude 'target/' \
        --exclude '.git/' \
        --exclude '.cache/' \
        --exclude '.moontasks/.deleted/' \
        -e "ssh -i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
        "$from/" "moon@$address:$to/" | grep -v '/$' || true)"

    # Every file that actually arrived, touched over there. cargo decides what to build again by
    # the time on a file against the time on what it last built - and a file sent from here can
    # land older than that, at which point cargo builds nothing and prints the errors of the
    # build before it, about lines that have since moved.
    if [ -n "$sent" ]; then
        printf '%s\n' "$sent" \
            | "$HERE/vm.sh" ssh "cd $to && tr '\\n' '\\0' | xargs -0 -r touch --"
    fi
    echo "  $to: $(printf '%s\n' "$sent" | grep -c . || true) files"
}

echo "=== sending this repo and moon's source to $address"
send "$HERE" moonos
send "$MOON_SOURCE" moon-dev-tools

if [ "$STEP" = "-" ]; then
    exit 0
fi

echo "=== $STEP, on the machine"
exec "$HERE/vm.sh" ssh "bash moonos/provision.sh $STEP"

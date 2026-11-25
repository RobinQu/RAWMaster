#!/bin/sh
# Populate the local Cargo cache for the Rust libraries built by SwiftPM plugins.
#
# SwiftPM runs build-tool plugins inside a sandbox that denies network access and
# allows writes only inside the plugin work directory. The plugins therefore
# build with `cargo --offline`, and they also need crates already unpacked in
# Cargo's home; this script is the only step that may download and extract them.
# Run it after a clean checkout, after changing a Cargo.lock, or once per CI job
# before `swift build` / `swift test`.
#
# Usage:
#   scripts/fetch-rust-dependencies.sh           # download and unpack missing crates
#   scripts/fetch-rust-dependencies.sh --check   # verify the cache without network
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir/.."

check_only=0
case "${1:-}" in
    --check) check_only=1 ;;
    "") ;;
    *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

cargo_bin=${CARGO:-cargo}
if ! command -v "$cargo_bin" >/dev/null 2>&1; then
    cargo_bin="$HOME/.cargo/bin/cargo"
fi
if ! command -v "$cargo_bin" >/dev/null 2>&1; then
    echo "Rust Cargo is required to build the RAWMaster Rust libraries." >&2
    exit 1
fi

# SwiftPM strips HOME and CARGO_HOME from plugin environments. Cargo then falls
# back to the account home, so fetch into exactly that cache rather than into a
# caller-specific CARGO_HOME the plugin can never see.
plugin_cargo_home=$(cd ~ && pwd)/.cargo
if [ -n "${CARGO_HOME:-}" ] && [ "$CARGO_HOME" != "$plugin_cargo_home" ]; then
    echo "SwiftPM ignores CARGO_HOME in plugin builds; caching Rust dependencies in $plugin_cargo_home" >&2
fi
CARGO_HOME=$plugin_cargo_home
export CARGO_HOME
echo "Preparing the Cargo cache at $CARGO_HOME for SwiftPM plugins"

# Cargo already retries, but verbose retrying keeps flaky CI networks from
# turning into a red build without a clear cause.
CARGO_NET_RETRY=${CARGO_NET_RETRY:-10}
CARGO_HTTP_TIMEOUT=${CARGO_HTTP_TIMEOUT:-120}
CARGO_HTTP_LOW_SPEED_LIMIT=${CARGO_HTTP_LOW_SPEED_LIMIT:-1}
CARGO_HTTP_MULTIPLEXING=${CARGO_HTTP_MULTIPLEXING:-false}
export CARGO_NET_RETRY CARGO_HTTP_TIMEOUT CARGO_HTTP_LOW_SPEED_LIMIT CARGO_HTTP_MULTIPLEXING

scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/rawmaster-cargo-vendor.XXXXXX")
trap 'rm -rf "$scratch_root"' EXIT INT TERM

found=0
for manifest in Modules/*/Cargo.toml; do
    [ -f "$manifest" ] || continue
    crate_root=${manifest%/Cargo.toml}
    if [ ! -f "$crate_root/Cargo.lock" ]; then
        echo "Missing $crate_root/Cargo.lock; SwiftPM plugin builds require --locked." >&2
        exit 1
    fi
    found=$((found + 1))

    if [ "$check_only" -eq 1 ]; then
        echo "Checking offline Rust dependencies for $crate_root"
    else
        # A complete cache needs no network at all; this keeps offline machines
        # and cache hits from touching crates.io.
        if "$cargo_bin" fetch --offline --locked --manifest-path "$manifest" >/dev/null 2>&1; then
            echo "Rust dependencies for $crate_root are already cached"
        else
            echo "Fetching pinned Rust dependencies for $crate_root"
            attempt=1
            while ! "$cargo_bin" fetch --locked --manifest-path "$manifest"; do
                if [ "$attempt" -ge 3 ]; then
                    echo "Unable to fetch Rust dependencies for $crate_root after $attempt attempts." >&2
                    exit 1
                fi
                attempt=$((attempt + 1))
                echo "Retrying Rust dependency fetch for $crate_root (attempt $attempt of 3)" >&2
                sleep 5
            done
        fi
    fi

    # `cargo fetch` downloads archives but does not unpack them. The plugin
    # sandbox cannot write to CARGO_HOME, so force extraction here; the copied
    # vendor tree is discarded and only the Cargo home stays populated.
    vendor_dir="$scratch_root/${crate_root##*/}"
    vendor_log="$scratch_root/${crate_root##*/}.log"
    rm -rf "$vendor_dir"
    if ! "$cargo_bin" vendor --offline --locked --versioned-dirs --manifest-path "$manifest" "$vendor_dir" >"$vendor_log" 2>&1; then
        cat "$vendor_log" >&2
        echo "Unable to unpack the pinned Rust dependencies for $crate_root; the cache is incomplete." >&2
        exit 1
    fi
    rm -rf "$vendor_dir" "$vendor_log"
done

if [ "$found" -eq 0 ]; then
    echo "No Rust crates found under Modules/." >&2
    exit 1
fi

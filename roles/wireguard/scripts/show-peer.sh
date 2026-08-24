#!/usr/bin/env bash
#
# Show a peer configuration from roles/wireguard/keys/, so it can be
# carried to the device it belongs to.
#
#   show-peer.sh <name> [--qr]
#
# e.g.
#
#   roles/wireguard/scripts/show-peer.sh Chtugha
#   roles/wireguard/scripts/show-peer.sh Sho-Gath --qr
#
# --qr renders it as a QR code, which the WireGuard app on Android and
# iOS scans directly - the only sane way to get a private key onto a
# phone, since the alternative is typing 44 base64 characters twice.
#
# This puts a private key on the terminal. That is the whole point of
# the script, but it is worth saying out loud: mind who can see the
# screen, and remember that the key stays in the scrollback until the
# terminal is closed.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
fi

name="$1"
mode="${2:-}"

config="roles/wireguard/keys/${name}.conf"
[ -e "${config}" ] || {
  echo "No such peer: ${config}" >&2
  echo "Known peers:" >&2
  ls -1 roles/wireguard/keys/*.conf >&2 2>/dev/null || true
  # These files are gitignored and generated one at a time, so a
  # missing one usually means this checkout never had it rather than
  # that it was deleted. new-peer-local.sh issues a replacement, which
  # is a *new* key: the inventory entry has to be replaced with it.
  echo "Missing one is not recoverable from the repository - re-key" >&2
  echo "the peer with new-peer-local.sh and replace its inventory" >&2
  echo "entry." >&2
  exit 1
}

case "${mode}" in
  "")
    cat "${config}"
    ;;
  --qr)
    command -v qrencode >/dev/null || {
      echo "qrencode not found. Run this from the Dev Container." >&2
      exit 1
    }
    # Comments and blank lines are stripped first. They are two thirds
    # of the file, and a QR code holding them needs 67 terminal rows
    # against 39 - large enough that a phone camera struggles with it.
    # The commented alternative Endpoint goes with them; on a network
    # that needs it, type it in on the device.
    #
    # -t ansiutf8 renders in the terminal itself, so the code is never
    # a file that has to be deleted afterwards.
    grep -v -e '^#' -e '^$' "${config}" | qrencode -t ansiutf8 -o -
    ;;
  *)
    echo "Unknown option: ${mode}" >&2
    exit 1
    ;;
esac

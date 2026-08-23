#!/usr/bin/env bash
#
# Generate the tunnel's server keypair and print the private half as a
# vaulted inventory value, ready to paste under
# `wireguard.server.private_key`.
#
# Run once per host, from the repository root:
#
#   roles/wireguard/scripts/generate_keys.sh
#
# The public key it prints is not a secret: it goes into every peer's
# own configuration, which is why it is printed in the clear.
#
# Same shape as roles/sshd/scripts/generate_keys.sh - the key is
# generated here rather than on the target so that a rebuilt host
# keeps its identity and no peer has to be reconfigured.
set -euo pipefail

command -v wg >/dev/null || {
  echo "wg not found. Install wireguard-tools." >&2
  exit 1
}
command -v ansible-vault >/dev/null || {
  echo "ansible-vault not found. Run this from the Dev Container." >&2
  exit 1
}

private="$(wg genkey)"
public="$(printf '%s' "${private}" | wg pubkey)"

echo "# Public key, for the [Peer] block of every device:"
echo "#   ${public}"
echo
echo "# Paste under wireguard.server. in the inventory:"
ansible-vault encrypt_string "${private}" --name private_key

# Leave nothing recoverable in the shell's memory for longer than
# needed. Not a strong guarantee - the value has already been through
# a pipe and the terminal - but free.
unset private public

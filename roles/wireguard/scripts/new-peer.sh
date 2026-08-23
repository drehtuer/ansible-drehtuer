#!/usr/bin/env bash
#
# Add a device to the tunnel.
#
# Run this ON THE DEVICE being added, not on the server: the point is
# that the device's private key is generated where it will be used and
# never travels. What comes back to the repository is the public key
# and the preshared key, neither of which can decrypt anything on
# their own.
#
#   new-peer.sh <name> <tunnel-ipv4> <tunnel-ipv6>
#
# e.g.
#
#   new-peer.sh laptop 10.7.0.2 fd9c:a40e:a2a8::2
#
# It prints two things: the device's own wg-quick configuration, and
# the YAML to add to `wireguard.peers` in the inventory. The preshared
# key appears in both, because both ends need it - vault it on the
# inventory side.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
fi

name="$1"
ip4="$2"
ip6="$3"

# Edit these two to match the inventory before handing the config over.
endpoint="vpn.example.invalid:51820"
server_public_key="PASTE_THE_SERVER_PUBLIC_KEY_HERE"

command -v wg >/dev/null || {
  echo "wg not found. Install wireguard-tools." >&2
  exit 1
}

private="$(wg genkey)"
public="$(printf '%s' "${private}" | wg pubkey)"
preshared="$(wg genpsk)"

cat <<CONF
# ---------- ${name}.conf, for this device ----------
[Interface]
PrivateKey = ${private}
Address = ${ip4}/32, ${ip6}/128
# The resolver on the far end of the tunnel. With a full tunnel this
# matters: without it the device keeps using the local network's
# resolver, which sees every name looked up.
DNS = 10.7.0.1, fd9c:a40e:a2a8::1
MTU = 1420

[Peer]
PublicKey = ${server_public_key}
PresharedKey = ${preshared}
# Everything, both families. The device's own LAN keeps working: its
# on-link route is more specific, on Linux through wg-quick's policy
# routing and on Windows through the interface metric.
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${endpoint}
# Hole-punching is not needed - the server has a public address - but
# a keepalive stops a mobile carrier's NAT dropping the mapping while
# the device is idle, which is what makes an incoming connection from
# another peer work.
PersistentKeepalive = 25

# ---------- for wireguard.peers in the inventory ----------
    - name: ${name}
      public_key: ${public}
      # Vault this: ansible-vault encrypt_string '<the key>' \\
      #   --name preshared_key
      preshared_key: ${preshared}
      ip4: ${ip4}
      ip6: ${ip6}
CONF

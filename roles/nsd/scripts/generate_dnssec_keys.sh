#!/usr/bin/env bash

set -euo pipefail

# Generates the DNSSEC key pair for a zone and writes the
# vault-encrypted private keys into files/dnssec/, where the role picks
# them up. Plaintext keys stay in keys/, which is gitignored. Same
# shape as roles/sshd/scripts/generate_keys.sh, and for the same
# reason: a rebuilt host has to come back with the *same* keys.
#
#   ./generate_dnssec_keys.sh drehtuer.net
#
# Why the keys belong in the repo at all, vault-encrypted, rather than
# being generated on the host: the KSK is what the DS record in the
# parent zone points at. Lose it and the chain of trust breaks until a
# new DS is published at the registrar and has propagated - during
# which the zone is worse than unsigned, it is *bogus*, and validating
# resolvers refuse the answers entirely. Keeping the keys here means a
# rebuild restores the same keys and the DS record never has to change,
# which is the whole point of the repo's disaster-recovery goal.
#
# Two keys per zone, not one:
#
#   KSK  signs only the DNSKEY RRset. Its hash is the DS record in the
#        parent, so rolling it means a registrar change.
#   ZSK  signs everything else. Rolling it is invisible to the parent
#        and needs no registrar involvement, which is the reason for
#        the split.
#
# ECDSAP256SHA256 (algorithm 13) rather than RSA: signatures are a
# fraction of the size, which matters for a protocol that still falls
# back to TCP when a response will not fit, and it is universally
# supported by validating resolvers now.
#
# Re-running is safe. Existing keys are left alone and simply
# re-encrypted, so this cannot silently replace a key that a published
# DS record depends on.

if [[ "${#}" -ne "1" ]]; then
  echo "Zone name as argument needed, e.g. ${0##*/} example.com" >&2
  exit 1
fi

SCRIPT_DIR="$(readlink -f "$(dirname "${0}")")"
KEY_DIR="$(readlink -f "${SCRIPT_DIR}/..")/keys"
FILE_DIR="$(readlink -f "${SCRIPT_DIR}/..")/files/dnssec"
ZONE="${1}"

mkdir -p "${KEY_DIR}" "${FILE_DIR}"

# dnssec-keygen names its output itself - Kzone.+013+keytag - so the
# key tag is not known until it has run. Finding an existing key
# therefore means looking for one rather than predicting its name.
find_key() {
  local flag_pattern="${1}"
  # `|| true` is load-bearing: grep exits 1 when nothing matches and
  # xargs turns that into 123, which under `set -e` aborts the script
  # on the entirely normal case of "no key exists yet".
  find "${KEY_DIR}" -name "K${ZONE}.+*.key" -print0 2>/dev/null \
    | xargs -0 -r grep -l "${flag_pattern}" 2>/dev/null | head -1 || true
}

generate() {
  local role="${1}" flag_pattern="${2}" existing
  shift 2

  existing="$(find_key "${flag_pattern}")"
  if [[ -n "${existing}" ]]; then
    echo "${role}: keeping existing $(basename "${existing%.key}")" >&2
  else
    # -K writes both files into the key directory. The base name it
    # prints is what everything below keys off.
    existing="${KEY_DIR}/$(dnssec-keygen -q -a ECDSAP256SHA256 \
      -K "${KEY_DIR}" "${@}" "${ZONE}").key"
    echo "${role}: generated $(basename "${existing%.key}")" >&2
  fi

  local base
  base="$(basename "${existing%.key}")"
  # The public .key file is not secret - it is published in the zone as
  # a DNSKEY record - but it is encrypted alongside the private half so
  # that the role deploys a matched pair from one place.
  for half in key private; do
    ansible-vault encrypt "${KEY_DIR}/${base}.${half}" \
      --output "${FILE_DIR}/${base}.${half}.aes256" 1>/dev/null
  done
  echo "  wrote ${FILE_DIR}/${base}.{key,private}.aes256" >&2
}

# The flag patterns distinguish the two: dnssec-keygen writes the role
# into a comment in the .key file, and a KSK additionally carries flag
# 257 where a ZSK carries 256.
generate KSK 'key-signing key' -f KSK
generate ZSK 'zone-signing key'

echo >&2
echo "Next: commit files/dnssec/, deploy with playbooks/nsd.yml, and" >&2
echo "only then publish the DS record at the registrar." >&2

exit 0

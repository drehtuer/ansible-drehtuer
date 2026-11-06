#!/usr/bin/env bash

set -euo pipefail
# set -x

# https://www.ssh-audit.com/hardening_guides.html#ubuntu_24_04_lts
#
# Generates the sshd host key pair for a host and writes the
# vault-encrypted private keys into files/, where the role picks them
# up. Plaintext keys stay in keys/, which is gitignored.

if [[ "${#}" -ne "1" ]]; then
  echo "Hostname as argument needed" >&2
  exit 1
fi

SCRIPT_DIR="$(readlink -f "$(dirname "${0}")")"
KEY_DIR="$(readlink -f "${SCRIPT_DIR}/../keys")"
FILE_DIR="$(readlink -f "${SCRIPT_DIR}/../files")"
HOSTNAME="${1}"

# Key types must match `sshd.host_keys` in the role defaults.
generate() {
  local type="${1}"
  shift
  local key="${KEY_DIR}/ssh_${HOSTNAME}_${type}_key"

  if [[ ! -e "${key}" ]]; then
    ssh-keygen -q -t "${type}" "${@}" -N "" -C "sshd@${HOSTNAME}" -f "${key}"
  fi
  ansible-vault encrypt "${key}" \
    --output "${FILE_DIR}/$(basename "${key}").aes256" 1>/dev/null
  echo "wrote ${FILE_DIR}/$(basename "${key}").aes256" >&2
}

generate ed25519
generate rsa -b 4096

exit 0

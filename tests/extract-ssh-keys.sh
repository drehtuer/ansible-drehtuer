#!/usr/bin/env bash
#
# Print every SSH public key in the tracked files under the given
# directories (default: inventories/), one per line in authorized_keys
# format, for tests/check-ssh-keys.sh to read.
#
#   tests/extract-ssh-keys.sh [dir...] > keys.txt
#
# The inventory writes keys as YAML folded scalars, with the key type
# and the base64 blob on lines of their own (see
# inventories/group_vars/testlab/users.yml). Collapsing each file's
# whitespace to single spaces puts them back on one line, which is
# what YAML's folding does as well, so no YAML parser - and no vault
# password - is needed. Vaulted files and `!vault |` values are hex
# and never match, so this only ever sees what is already public.
#
# The key's own comment is replaced by the file it came from, so a
# finding names the file to fix rather than a user@host that may
# appear in several.
#
# Fails if no key was found at all: an empty list would make the
# check behind it pass without checking anything.
set -euo pipefail

# Every key type OpenSSH accepts, including the FIDO "-sk" ones. The
# blob of each starts with the base64 of its length prefix, AAAA,
# which keeps a key type mentioned in a comment from matching.
KEY_PATTERN='(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)'
KEY_PATTERN+='|sk-ssh-ed25519@openssh\.com'
KEY_PATTERN+='|sk-ecdsa-sha2-nistp256@openssh\.com)'
KEY_PATTERN+=' AAAA[A-Za-z0-9+/]+={0,3}'

roots=("$@")
((${#roots[@]})) || roots=(inventories)

count=0
while IFS= read -r -d '' file; do
  # Tracked, but deleted in the working tree.
  [[ -f ${file} ]] || continue

  # grep exits 1 when a file holds no key, which is most of them.
  keys=$(tr -s '[:space:]' ' ' < "${file}" | grep -oE "${KEY_PATTERN}") \
    || continue

  while IFS= read -r key; do
    printf '%s %s\n' "${key}" "${file}"
    count=$((count + 1))
  done <<< "${keys}"
done < <(git ls-files -z -- "${roots[@]}")

if ((count == 0)); then
  printf 'error: no SSH public keys found under %s\n' "${roots[*]}" >&2
  exit 1
fi

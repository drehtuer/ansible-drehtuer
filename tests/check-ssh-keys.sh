#!/usr/bin/env bash
# Check SSH public keys, one per line (authorized_keys format), for:
#
#   1. Strength policy: Ed25519 or ECDSA (FIDO "-sk" variants
#      included), or RSA with at least MIN_RSA_BITS bits. Anything
#      else, DSA above all, fails.
#   2. Leaks: badkeys (https://badkeys.info) compares each key against
#      published lists of compromised keys: private keys found in
#      public repositories, firmware and documentation, Debian's weak
#      OpenSSL keys. It also runs its checks for broken key generation
#      (ROCA, Fermat, ...). The lists are downloaded first, then
#      everything runs locally. No key leaves the machine.
#
# Output names keys by their comment field only. It never prints
# fingerprints, because they would tie a key to the places it is used.
#
#   tests/check-ssh-keys.sh <file>
#
# Exit 0 only if at least one key was checked and none failed.
#
# The same script, tab-indented, is ci/check-ssh-keys.sh in the
# dotfiles repository (chezmoi), where it was written and tested. Only
# the layout was changed here - two-space indent, braced variables and
# 80 columns, per .editorconfig - so a fix to the logic in either copy
# belongs in the other as well.
set -euo pipefail

MIN_RSA_BITS=3072

file=${1:?usage: check-ssh-keys.sh <file with one public key per line>}
command -v badkeys > /dev/null || {
  echo "error: badkeys not installed (pip install badkeys)" >&2
  exit 1
}

# --- 1. strength policy -----------------------------------------------
n=0 failed=0
while IFS= read -r line || [[ -n ${line} ]]; do
  [[ ${line} =~ ^[[:space:]]*(#|$) ]] && continue
  n=$((n + 1))
  # "<bits> <fingerprint> <comment> (<TYPE>)", comment may contain
  # spaces
  if ! info=$(ssh-keygen -l -f /dev/stdin <<< "${line}" 2> /dev/null) \
    || [[ ! ${info} =~ ^([0-9]+)\ [^\ ]+\ (.*)\ \(([A-Z0-9-]+)\)$ ]]; then
    echo "FAIL key ${n}: not a parseable SSH public key"
    failed=1
    continue
  fi
  bits=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]} type=${BASH_REMATCH[3]}
  case ${type} in
    ED25519 | ED25519-SK | ECDSA | ECDSA-SK) ok=1 ;;
    RSA) ok=$((bits >= MIN_RSA_BITS)) ;;
    *) ok=0 ;;
  esac
  if ((ok)); then
    echo "ok   ${name}: ${type} ${bits}"
  else
    echo "FAIL ${name}: ${type} ${bits} is below policy" \
      "(Ed25519, ECDSA or RSA >= ${MIN_RSA_BITS})"
    failed=1
  fi
done < "${file}"
if ((n == 0)); then
  echo "FAIL no keys in ${file}; an empty check proves nothing"
  exit 1
fi

# --- 2. leaks and known-weak keys -------------------------------------
# Refresh the lists on every run. Leaks are found after the fact, so a
# stale list would quietly stop catching new ones.
badkeys --update-bl --quiet
rc=0
badkeys --ssh-lines "${file}" || rc=$?
# badkeys exit status is a bitmask: 1 error, 2 input not scannable,
# 4 vulnerable.
((rc & 4)) && echo "FAIL badkeys: a key above is compromised or weak," \
  "replace it"
((rc & 2)) && echo "FAIL badkeys: some input could not be scanned"
((rc & 1)) && echo "FAIL badkeys: error" >&2
((rc == 0)) && echo "ok   badkeys: none of the ${n} keys is on a leak" \
  "list or known-weak"
((rc == 0 && failed == 0))

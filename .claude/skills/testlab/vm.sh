#!/usr/bin/env bash
#
# Deployment-test VM, run by QEMU/KVM inside this dev container.
#
# No libvirt and no root. The guest boots an Ubuntu cloud image with a
# cloud-init seed and uses QEMU's user-mode networking, so the only
# privilege needed is access to /dev/kvm, which devcontainer.json
# passes through. Nothing here touches the host's network.
#
# The disk is a qcow2 overlay on an untouched base image, so `reset`
# is "throw the overlay away" - a genuinely pristine install in a
# couple of seconds, which is what makes this the default test target
# rather than the physical machine.

set -euo pipefail

# Which guest to act on. Each one is a row here and a matching block
# in ~/.ssh/config; they run side by side, so several releases can be
# up at once.
#
#   yuggoth  the default. Runs the same release as production, so a
#            deploy here rehearses what carcosa will actually do.
#   hastur   the upgrade rehearsal guest. Starts on the same release
#            and carries upgrade.target_release, so it is the one that
#            gets moved to the next LTS once Ubuntu offers it.
#
# Both therefore track production, not the newest release. For a
# forward-compatibility check against a release production has not
# reached yet, override it for one run:
#   LAB_VM_RELEASE=26.04 vm.sh reset
HOST="${LAB_VM_HOST:-yuggoth}"
case "$HOST" in
  yuggoth) DEFAULT_PORT=2222; DEFAULT_RELEASE=24.04 ;;
  hastur)  DEFAULT_PORT=2223; DEFAULT_RELEASE=24.04 ;;
  *) printf 'Unknown guest "%s". Known: yuggoth, hastur.\n' "$HOST" >&2; exit 1 ;;
esac
SSH_PORT="${LAB_VM_SSH_PORT:-$DEFAULT_PORT}"

# Codename-independent path, so this keeps working across releases.
RELEASE="${LAB_VM_RELEASE:-$DEFAULT_RELEASE}"
IMAGE_URL="${LAB_VM_IMAGE_URL:-https://cloud-images.ubuntu.com/releases/${RELEASE}/release/ubuntu-${RELEASE}-server-cloudimg-amd64.img}"

# Container-local by design: the guest is disposable and re-created
# from the base image, so nothing here is worth persisting across a
# container rebuild except the download. Point LAB_VM_STATE at a
# bind-mounted path to keep the base images between rebuilds.
#
# Base images are shared and keyed by release, so a second guest on a
# release already downloaded costs nothing; everything a guest writes
# lives under its own directory.
STATE="${LAB_VM_STATE:-/var/tmp/testlab-vm}"
BASE="${STATE}/base-${RELEASE}.qcow2"
GUEST="${STATE}/${HOST}"
DISK="${GUEST}/disk.qcow2"
SEED="${GUEST}/seed.iso"
MONITOR="${GUEST}/monitor.sock"
CONSOLE="${GUEST}/console.sock"
PIDFILE="${GUEST}/qemu.pid"

MEM="${LAB_VM_MEM:-4096}"
CPUS="${LAB_VM_CPUS:-4}"
DISK_SIZE="${LAB_VM_DISK:-20G}"
BOOT_TIMEOUT=300

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m%s\033[0m\n\n' "$*"; exit 1; }

# Public half of the key ssh logs in to $HOST with: the first
# IdentityFile of its Host block in ~/.ssh/config. Today every local
# guest's block names the same key (they are ephemeral, identical in
# purpose, and reachable only from inside this container). The key
# files have opaque names (the dotfiles repo hides what each key is
# for), so never name one here - always go through the alias.
host_pubkey() {
  local f
  f="$(ssh -G "$HOST" 2>/dev/null | awk '$1 == "identityfile" { print $2; exit }')"
  f="${f/#\~/$HOME}"
  [[ -r "$f" ]] && ssh-keygen -y -f "$f" 2>/dev/null
}

require_kvm() {
  [[ -e /dev/kvm ]] || die "/dev/kvm is missing. The dev container needs rebuilding: devcontainer.json passes it through with --device=/dev/kvm, and that only takes effect on a rebuild (Dev Containers: Rebuild Container)."
  [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm exists but is not readable/writable by $(id -un). Check the device's group on the WSL2 side."
  command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 is missing - rebuild the dev container."
  command -v cloud-localds >/dev/null || die "cloud-localds is missing (cloud-image-utils) - rebuild the dev container."
}

running() { [[ -s "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

wait_for_ssh() {
  local deadline=$((SECONDS + BOOT_TIMEOUT))
  info "waiting up to ${BOOT_TIMEOUT}s for sshd in the guest"
  while ((SECONDS < deadline)); do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true 2>/dev/null; then
      ok "guest is up"
      return 0
    fi
    running || die "QEMU exited while booting. Last console output:$(printf '\n')$(tail -20 "${GUEST}/console.log" 2>/dev/null)"
    sleep 5
  done
  die "The guest did not answer SSH within ${BOOT_TIMEOUT}s. Attach to the console with 'vm.sh console' to see where it stopped."
}

write_seed() {
  local pubkey
  pubkey="$(host_pubkey)" || die "No readable IdentityFile for Host ${HOST} in ~/.ssh/config. The Host block and its key come from the dotfiles (chezmoi apply)."
  # The account and its NOPASSWD sudo have to exist before Ansible can
  # do anything: ansible.cfg escalates on every play.
  cat > "${GUEST}/user-data" <<EOF
#cloud-config
hostname: ${HOST}
fqdn: ${HOST}.lab.lan
users:
  - name: drehtuer
    groups: [sudo]
    shell: /usr/bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    # "testlab" - only reachable on the guest's own serial console,
    # which is not exposed outside this container.
    passwd: \$6\$Eaf5VP6t9TNfbMch\$dxYdnEbaYgNAAyssxHYwmpuKfPZG1jJyuXyG9LGKXNQfFS9HGuXbFu/cGfVRN5T6P3e6a7UdIzwPj5K2iAbMd1
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: false
package_update: false
EOF
  printf 'instance-id: %s\nlocal-hostname: %s\n' "${HOST}-$$" "$HOST" > "${GUEST}/meta-data"
  cloud-localds "$SEED" "${GUEST}/user-data" "${GUEST}/meta-data"
}

cmd_create() {
  require_kvm
  running && { info "already running"; return 0; }
  mkdir -p "$STATE" "$GUEST"

  if [[ ! -f "$BASE" ]]; then
    say "Downloading the Ubuntu ${RELEASE} cloud image"
    info "$IMAGE_URL"
    curl -fL --progress-bar -o "${BASE}.tmp" "$IMAGE_URL" ||
      die "Download failed. If ${RELEASE} is not published yet, set LAB_VM_RELEASE (e.g. 24.04) or LAB_VM_IMAGE_URL."
    mv "${BASE}.tmp" "$BASE"
  fi

  say "Creating a fresh overlay on the base image"
  rm -f "$DISK"
  qemu-img create -f qcow2 -b "$BASE" -F qcow2 "$DISK" "$DISK_SIZE" >/dev/null
  ok "overlay created (base image untouched)"

  write_seed
  cmd_start
}

cmd_start() {
  require_kvm
  running && { info "already running"; return 0; }
  [[ -f "$DISK" ]] || die "No disk yet - run 'vm.sh create' first."

  say "Starting ${HOST}"
  rm -f "$MONITOR" "$CONSOLE"
  qemu-system-x86_64 \
    -name "$HOST" \
    -machine q35,accel=kvm -cpu host \
    -m "$MEM" -smp "$CPUS" \
    -drive "file=${DISK},if=virtio,format=qcow2" \
    -drive "file=${SEED},if=virtio,format=raw,readonly=on" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial "unix:${CONSOLE},server,nowait" \
    -monitor "unix:${MONITOR},server,nowait" \
    -pidfile "$PIDFILE" \
    -daemonize
  # The serial socket only has one reader, so mirror it to a file for
  # after-the-fact diagnosis.
  socat -u "unix-connect:${CONSOLE}" "create:${GUEST}/console.log" &
  disown
  info "ssh forwarded on 127.0.0.1:${SSH_PORT}"
  wait_for_ssh
}

cmd_stop() {
  running || { info "not running"; return 0; }
  say "Stopping ${HOST}"
  ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" 'sudo systemctl poweroff' 2>/dev/null || true
  local deadline=$((SECONDS + 60))
  while running && ((SECONDS < deadline)); do sleep 2; done
  running && { info "still up, killing QEMU"; kill "$(cat "$PIDFILE")" 2>/dev/null || true; }
  rm -f "$PIDFILE"
  ok "stopped"
}

# The whole point of the VM: back to a pristine installation in
# seconds, with no reboot dance and nothing to go wrong.
cmd_reset() {
  say "Resetting ${HOST} to a pristine ${RELEASE} image"
  cmd_stop
  rm -f "$DISK"
  cmd_create
}

cmd_snapshot() {
  local name="${1:-baseline}"
  running && die "Stop the guest first ('vm.sh stop'): qcow2 snapshots of a live disk are not consistent."
  say "Snapshotting as '${name}'"
  qemu-img snapshot -c "$name" "$DISK"
  qemu-img snapshot -l "$DISK"
}

cmd_revert() {
  local name="${1:-baseline}"
  running && die "Stop the guest first ('vm.sh stop')."
  say "Reverting to '${name}'"
  qemu-img snapshot -a "$name" "$DISK" ||
    die "No snapshot '${name}'. Existing: $(qemu-img snapshot -l "$DISK" | tail -n +3 | awk '{print $2}' | tr '\n' ' ')"
  cmd_start
}

cmd_console() {
  [[ -S "$CONSOLE" ]] || die "No console socket - is the guest running?"
  say "Serial console (ctrl-o to exit)"
  info "log in as drehtuer, password 'testlab'"
  socat -,raw,echo=0,escape=0x0f "unix-connect:${CONSOLE}"
}

cmd_status() {
  say "${HOST}"
  if running; then
    ok "running (pid $(cat "$PIDFILE"))"
    ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" \
      'echo "  $(. /etc/os-release; echo "$PRETTY_NAME")  kernel $(uname -r)"; uptime -p | sed "s/^/  /"' 2>/dev/null ||
      bad "running but not answering SSH"
  else
    bad "not running"
  fi
  [[ -f "$DISK" ]] && info "disk:  $(du -h "$DISK" | cut -f1) overlay on $(du -h "$BASE" 2>/dev/null | cut -f1) base"
  [[ -f "$DISK" ]] && qemu-img snapshot -l "$DISK" 2>/dev/null | tail -n +2 | sed 's/^/  snap /'
  return 0
}

cmd_destroy() {
  cmd_stop
  say "Removing the overlay and seed (the base image is kept)"
  rm -f "$DISK" "$SEED" "${GUEST}/user-data" "${GUEST}/meta-data" "${GUEST}/console.log"
  ok "destroyed - 'vm.sh create' rebuilds it without re-downloading"
}

usage() {
  cat <<'USAGE'
vm.sh <command>            deployment-test VM (QEMU/KVM, in this container)

  create           download the cloud image if needed, build a fresh
                   overlay, boot it, wait for sshd
  start | stop     lifecycle without touching the disk
  reset            throw the overlay away and rebuild - a pristine
                   installation, in seconds
  snapshot [name]  qcow2 snapshot of the stopped guest (default: baseline)
  revert [name]    restore a snapshot and boot
  console          attach to the serial console (the way back in when
                   SSH is broken)
  status           running? which release? which snapshots?
  destroy          remove the overlay, keep the downloaded base image

Deploy to it with the testlab skill's other driver:
  lab.sh deploy    (targets whichever host LAB_HOST names)
or directly:
  invoke run-playbook --hosts=testlab_vm --playbook=playbooks/apt.yml
USAGE
}

case "${1:-}" in
  create)   shift; cmd_create "$@" ;;
  start)    shift; cmd_start "$@" ;;
  stop)     shift; cmd_stop "$@" ;;
  reset)    shift; cmd_reset "$@" ;;
  snapshot) shift; cmd_snapshot "$@" ;;
  revert)   shift; cmd_revert "$@" ;;
  console)  shift; cmd_console "$@" ;;
  status)   shift; cmd_status "$@" ;;
  destroy)  shift; cmd_destroy "$@" ;;
  *)        usage; exit 1 ;;
esac

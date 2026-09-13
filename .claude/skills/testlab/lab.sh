#!/usr/bin/env bash
#
# Driver for the `nyarlathotep` deployment-test machine.
#
# Every subcommand is safe to re-run. Anything that could leave the
# machine unreachable exits with STATUS_NEEDS_HUMAN (10) and prints a
# banner saying so, because this box has no remote console: if it does
# not come back over SSH, only physical access recovers it.

set -euo pipefail

# Which test host to act on. The VM is the default: it resets in
# seconds and has a console, so nothing done to it is unrecoverable.
# The physical machine is kept for what a VM cannot show - real
# hardware, real firmware, a real NIC.
TARGET="${LAB_TARGET:-vm}"
case "$TARGET" in
  vm)
    HOST=yuggoth
    # Loopback, via the port forward in ~/.ssh/config.
    IP=127.0.0.1
    KEY="${HOME}/.ssh/yuggoth"
    ;;
  metal)
    HOST=nyarlathotep
    IP=192.168.89.41
    KEY="${HOME}/.ssh/nyarlathotep"
    ;;
  *) printf 'LAB_TARGET must be "vm" or "metal", not "%s"\n' "$TARGET" >&2; exit 1 ;;
esac
HOST="${LAB_HOST:-$HOST}"
IP="${LAB_IP:-$IP}"

VG=ubuntu-vg
LV=ubuntu-lv
SNAP=ubuntu-lv-baseline
# Sized to the full origin, so the snapshot can never overflow and
# invalidate itself no matter how much a deploy rewrites. The volume
# group has ~829G free, so this costs nothing that matters.
SNAP_SIZE=100G
BOOT_BACKUP=/var/backups/boot-baseline.tar.gz

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
# One inventory, several groups. Every playbook is `hosts: all`, so
# the group selected above is what keeps a deploy off carcosa.
INVENTORY=inventories/machines.yml

# Reboots on this hardware take ~90s; a merge-on-boot adds to that.
BOOT_TIMEOUT=420

STATUS_NEEDS_HUMAN=10

# Playbooks in dependency order. `system`/`apt`/`users` first (the apt
# role is the only one that refreshes the cache, and users installs
# the key sshd then locks the door with), TLS consumers last.
PLAYBOOKS=(
  system apt users sshd time cron firewall fail2ban
  dns database docker http cloud mail imap spam
  # Reads the log nginx has been writing since `http` ran, and is
  # served through a vhost whose name has to be on the seeded
  # certificate - so `seed-certs` has to have covered `weblog`.
  analytics
  # Last: it delivers its alerts through the local Postfix, so mail
  # has to exist before the alert path can be shown to work.
  monitoring
)

# Units each role is expected to leave running, checked by `verify`.
VERIFY_UNITS=(ssh cron ntpsec fail2ban nginx mariadb redis-server unbound docker postfix dovecot rspamd
              prometheus prometheus-alertmanager prometheus-node-exporter)
# "port:address-fragment" - loopback-only services must NOT be on 0.0.0.0.
# 4190 is ManageSieve, which is public in the same sense as 993: the
# listener inherits dovecot's global `listen`, and roles/firewall is
# what decides who reaches it - it opens 993 and not this.
VERIFY_LISTEN=(22 25 80 443 587 993 4190)
# 9090/9093/9100 are roles/monitoring, 3000 is its Grafana container -
# on host networking, so it binds the host's own loopback and `ss` sees
# it like any other local service. Note what is deliberately absent:
# 9094, Alertmanager's HA gossip listener, which it opens on every
# interface unless --cluster.listen-address is emptied.
VERIFY_LOOPBACK=(3306 6379 53 9090 9093 9100 3000)

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# Loud on purpose: the caller is expected to stop and tell the user.
needs_human() {
  printf '\n\033[1;31m'
  printf '=========================================================\n'
  printf ' INTERVENTION NEEDED on %s (%s)\n' "$HOST" "$IP"
  printf '=========================================================\n'
  printf '\033[0m%s\n\n' "$1"
  printf 'This machine has no remote console. If it is not reachable\n'
  printf 'over SSH, recovering it needs physical access:\n'
  printf '  - screen + keyboard, or\n'
  printf '  - boot media to repair or reinstall.\n\n'
  exit "$STATUS_NEEDS_HUMAN"
}

# Multiplexed on purpose. Opening a fresh connection per check made
# this box stop accepting SSH for about a minute part-way through a
# `verify` run - not fail2ban (zero bans recorded) and not OpenSSH's
# per-source penalties (9.6 predates them), so the exact limit was
# never pinned down. Reusing one session sidesteps it entirely and is
# faster anyway.
SSH_MUX=(-o ControlMaster=auto -o "ControlPath=/tmp/.lab-%C" -o ControlPersist=60)
sshq() { ssh -o ConnectTimeout=10 -o BatchMode=yes "${SSH_MUX[@]}" "$HOST" "$@"; }

# The LVM snapshot dance exists because the physical machine cannot be
# reset any other way. The VM has qcow2 overlays instead.
metal_only() {
  [[ "$TARGET" == "metal" ]] || {
    printf '\n"%s" applies to the physical machine only.\n' "$1"
    printf 'For the VM use: .claude/skills/testlab/vm.sh %s\n\n' "$2"
    exit 1
  }
}

require_up() {
  # Skipped for the VM: its address is loopback, so ICMP always
  # succeeds whether or not the guest is running. SSH is the real test.
  [[ "$TARGET" == "vm" ]] || ping -c 1 -W 2 "$IP" >/dev/null 2>&1 ||
    needs_human "$IP does not answer ICMP. The machine is powered off, has lost its network link, or changed address."
  sshq true >/dev/null 2>&1 ||
    needs_human "$IP answers ping but SSH does not accept our key. sshd is down, or the users role removed the key. (A changed *host* key cannot cause this: ~/.ssh/config sets StrictHostKeyChecking no for this host.)"
}

wait_for_boot() {
  local deadline=$((SECONDS + BOOT_TIMEOUT))
  info "waiting up to ${BOOT_TIMEOUT}s for $HOST to come back"
  # It has to go away first, otherwise we race the shutdown and
  # report success against the session that is about to die.
  while ping -c 1 -W 1 "$IP" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || break
    sleep 2
  done
  while ((SECONDS < deadline)); do
    if sshq true >/dev/null 2>&1; then
      ok "back after ~$((BOOT_TIMEOUT - (deadline - SECONDS)))s"
      return 0
    fi
    sleep 5
  done
  needs_human "The machine did not come back within ${BOOT_TIMEOUT}s of the reboot. It may be sitting at a boot prompt, have failed an fsck, or failed to complete the snapshot merge."
}

cmd_check() {
  say "Reachability"
  if ping -c 2 -W 2 "$IP" >/dev/null 2>&1; then ok "ping $IP"; else
    needs_human "$IP does not answer ICMP."
  fi
  if sshq true >/dev/null 2>&1; then ok "ssh $HOST"; else
    needs_human "SSH to $HOST failed even though it answers ping."
  fi
  if sshq 'sudo -n true' >/dev/null 2>&1; then ok "passwordless sudo"; else
    needs_human "sudo on $HOST wants a password. The users role grants %sudo NOPASSWD; without it Ansible cannot escalate."
  fi

  say "Machine"
  sshq 'echo "  $(. /etc/os-release; echo "$PRETTY_NAME")  kernel $(uname -r)"
        echo "  virt: $(systemd-detect-virt || true)   uptime:$(uptime -p | sed s/up//)"'

  say "Rollback"
  if [[ "$TARGET" == "metal" ]]; then
    sshq "sudo vgs --noheadings -o vg_name,vg_free ${VG} | sed 's/^/  vg /'
          sudo lvs --noheadings -o lv_name,lv_size,origin,snap_percent ${VG} | sed 's/^/  lv /'"
    if sshq "sudo lvs ${VG}/${SNAP} >/dev/null 2>&1"; then
      ok "baseline snapshot ${VG}/${SNAP} exists - 'lab.sh reset' can roll back"
    else
      bad "no baseline snapshot - 'lab.sh reset' cannot work until 'lab.sh snapshot' runs"
    fi
    if sshq "test -f ${BOOT_BACKUP}"; then ok "/boot baseline archive present"; else
      bad "no /boot archive at ${BOOT_BACKUP}"
    fi
  else
    # The guest has no LVM and needs none: its disk is a qcow2 overlay
    # on an untouched base image, so rollback is 'vm.sh reset'.
    ok "qcow2 overlay - 'vm.sh reset' restores a pristine image in seconds"
    info "snapshots: $(.claude/skills/testlab/vm.sh status 2>/dev/null | grep -c '^  snap ') named"
  fi

  say "Lockout guards"
  local key
  key="$(ssh-keygen -y -f "$KEY" 2>/dev/null | awk '{print $2}')"
  if sshq "grep -qF '${key}' ~/.ssh/authorized_keys"; then
    ok "our public key is in authorized_keys"
  else
    bad "our key is NOT in authorized_keys - running the users role would lock this session out"
  fi
  if grep -qF "$key" "${REPO_ROOT}/inventories/group_vars/testlab/users.yml" 2>/dev/null; then
    ok "our public key is in the testlab inventory"
  else
    needs_human "inventories/group_vars/testlab/users.yml does not carry our public key. The users role sets authorized_keys authoritatively (authorized_keys_exclusive), so deploying it would remove our key and lock us out permanently."
  fi
}

cmd_snapshot() {
  metal_only snapshot snapshot
  require_up
  if sshq "sudo lvs ${VG}/${SNAP} >/dev/null 2>&1"; then
    if [[ "${1:-}" != "--force" ]]; then
      info "baseline already exists; pass --force to replace it with the current state"
      return 0
    fi
    say "Removing the old baseline"
    sshq "sudo lvremove -y ${VG}/${SNAP}"
  fi

  # The /boot archive is written BEFORE the snapshot on purpose, so it
  # is part of the baseline and survives every rollback. /boot is a
  # separate partition and is not covered by the LV snapshot.
  say "Archiving /boot"
  sshq "sudo tar czf ${BOOT_BACKUP} -C / boot && sudo ls -lh ${BOOT_BACKUP}"

  say "Creating baseline snapshot ${VG}/${SNAP}"
  sshq "sudo lvcreate -s -n ${SNAP} -L ${SNAP_SIZE} /dev/${VG}/${LV}"
  ok "baseline taken - this is the state 'lab.sh reset' returns to"
}

cmd_reset() {
  metal_only reset reset
  require_up
  sshq "sudo lvs ${VG}/${SNAP} >/dev/null 2>&1" ||
    needs_human "There is no ${VG}/${SNAP} to roll back to. Run 'lab.sh snapshot' while the machine is in the state you want as the baseline."

  say "Rolling back to the baseline"
  # Root is mounted, so the merge cannot run now; LVM schedules it for
  # the next activation and it completes during boot.
  sshq "sudo lvconvert --merge /dev/${VG}/${SNAP}" ||
    needs_human "lvconvert --merge failed. The machine is still running the current state; do not reboot until this is understood."
  info "merge scheduled for next boot"

  # /boot is restored before the reboot, not after: rolling root back
  # under a newer kernel leaves /lib/modules without that kernel's
  # modules, and the machine may not boot at all.
  say "Restoring /boot from the baseline archive"
  sshq "sudo tar xzf ${BOOT_BACKUP} -C /" ||
    needs_human "Restoring ${BOOT_BACKUP} failed while a snapshot merge is already scheduled. Do NOT reboot: /boot and the pending root state disagree."

  say "Rebooting"
  sshq "sudo systemctl reboot" || true
  wait_for_boot

  # A merge consumes the snapshot, so the baseline has to be retaken
  # or the next reset would have nothing to roll back to.
  say "Re-taking the baseline"
  sshq "sudo lvs ${VG}/${SNAP} >/dev/null 2>&1" &&
    needs_human "The snapshot still exists after the reboot, which means the merge did not complete. The machine is in an undefined state between baseline and current."
  sshq "sudo lvcreate -s -n ${SNAP} -L ${SNAP_SIZE} /dev/${VG}/${LV}"
  ok "machine is back at the baseline, snapshot re-armed"
}

# certbot cannot work here: the machine is LAN-only, so Let's Encrypt
# can never reach it for the HTTP-01 challenge. Seeding a self-signed
# certificate with exactly the names the http role computes makes its
# SAN comparison find nothing to do, so the role converges and every
# TLS consumer (nginx, postfix, dovecot) gets a usable certificate.
cmd_seed_certs() {
  require_up
  cd "$REPO_ROOT"
  say "Working out which names the certificate needs"
  # The expression is copied verbatim from the "Build the list of
  # names the certificate has to cover" task in roles/http. It has to
  # stay identical: the point is to produce exactly the SAN set the
  # role will compare against, so that certbot is never reached.
  # `ansible-inventory --host` cannot be used here - it dumps raw
  # vars without templating, so http.domains comes back as literal
  # Jinja.
  local expr names fqdn lineage
  expr="{{ ([hostname_fqdn] + (http.domains | list)
            + (http.domains | product(http.letsencrypt.subdomains)
               | map('reverse') | map('join', '.') | list))
           | unique | sort | join(',DNS:') }}"
  names="DNS:$(ansible -i "$INVENTORY" "$HOST" -m debug -a "msg=${expr}" 2>/dev/null |
    sed -n 's/.*"msg": "\(.*\)".*/\1/p')"
  [[ "$names" != "DNS:" ]] || needs_human "Could not derive the certificate names from $INVENTORY."
  info "$names"

  fqdn="$(ansible -i "$INVENTORY" "$HOST" -m debug -a 'msg={{ hostname_fqdn }}' 2>/dev/null |
    sed -n 's/.*"msg": "\(.*\)".*/\1/p')"
  lineage="/etc/letsencrypt/live/${fqdn}"

  say "Writing a self-signed certificate to ${lineage}"
  sshq "sudo mkdir -p ${lineage} && sudo openssl req -x509 -newkey rsa:4096 -nodes \
        -days 3650 -subj '/CN=${fqdn}' -addext 'subjectAltName=${names}' \
        -keyout ${lineage}/privkey.pem -out ${lineage}/cert.pem 2>/dev/null &&
        sudo cp ${lineage}/cert.pem ${lineage}/fullchain.pem &&
        sudo cp ${lineage}/cert.pem ${lineage}/chain.pem &&
        sudo chmod 600 ${lineage}/privkey.pem &&
        sudo openssl x509 -in ${lineage}/cert.pem -noout -ext subjectAltName | tail -1"
  ok "seeded - the http role's SAN comparison will now skip certbot"
}

cmd_deploy() {
  require_up
  cd "$REPO_ROOT"
  local books=("$@")
  [[ ${#books[@]} -gt 0 ]] || books=("${PLAYBOOKS[@]}")

  local failed=()
  for book in "${books[@]}"; do
    say "playbook: ${book}"
    # --hosts is the HOST, not its group: testlab_vm holds more than
    # one guest now, and targeting the group deployed to all of them.
    if invoke run-playbook --hosts="$HOST" \
        --playbook="playbooks/${book}.yml"; then
      ok "${book}"
    else
      bad "${book}"
      failed+=("$book")
      # The one role that can cut the connection it runs over.
      if [[ "$book" == "sshd" || "$book" == "users" || "$book" == "firewall" ]]; then
        sshq true >/dev/null 2>&1 || needs_human "The ${book} playbook failed AND the machine is no longer reachable over SSH. This role controls host keys, authorized_keys or the packet filter, so a partial run can lock the door."
      fi
    fi
    # No known_hosts fixup needed after the sshd role swaps host
    # keys: ~/.ssh/config does not record or check them for this host.
  done

  if ((${#failed[@]})); then
    say "Failed: ${failed[*]}"
    return 1
  fi
  say "All playbooks converged"
}

cmd_verify() {
  require_up
  # Everything is collected in ONE remote call: a check-per-connection
  # loop is what tripped this machine's SSH rate limiting before.
  # The heredoc is quoted so nothing expands locally; the three lists
  # arrive as positional arguments instead.
  local report status
  report="$(sshq "bash -s -- '${VERIFY_UNITS[*]}' '${VERIFY_LISTEN[*]}' '${VERIFY_LOOPBACK[*]}'" <<'REMOTE'
set -u
units="$1"; listen="$2"; loopback="$3"
for u in $units; do
  systemctl is-active --quiet "$u" && echo "ok   $u active" || echo "FAIL $u not active"
done
sockets="$(ss -Hltnu)"
for p in $listen; do
  grep -qE "[^0-9]${p}\b" <<<"$sockets" \
    && echo "ok   port $p listening" || echo "FAIL port $p not listening"
done
for p in $loopback; do
  grep -E "[^0-9]${p}\b" <<<"$sockets" | grep -qE '127\.0\.0\.1|\[::1\]' \
    && echo "ok   port $p bound to loopback" || echo "FAIL port $p not on loopback (or absent)"
done
sudo nginx -t      >/dev/null 2>&1 && echo "ok   nginx -t"      || echo "FAIL nginx -t"
sudo sshd -t       >/dev/null 2>&1 && echo "ok   sshd -t"       || echo "FAIL sshd -t"
sudo postfix check >/dev/null 2>&1 && echo "ok   postfix check" || echo "FAIL postfix check"
sudo iptables -S INPUT 2>/dev/null | head -1 | grep -q 'INPUT DROP' \
  && echo "ok   INPUT policy DROP" || echo "FAIL INPUT policy not DROP"
echo | openssl s_client -connect 127.0.0.1:443 2>/dev/null | grep -q 'Verify return code' \
  && echo "ok   TLS handshake on 443 (self-signed here)" || echo "FAIL no TLS handshake on 443"
REMOTE
)" && status=0 || status=$?

  if ((status != 0)); then
    # A failed call is not automatically a dead machine - it is far
    # more often a bug in the check itself. Only escalate to
    # needs_human if the host has genuinely stopped answering.
    if ping -c 1 -W 2 "$IP" >/dev/null 2>&1 && sshq true >/dev/null 2>&1; then
      bad "the verification call failed (exit ${status}) but ${HOST} is still reachable - this is a bug in verify, not a broken machine"
      return 1
    fi
    needs_human "The verification call failed and ${HOST} no longer answers SSH."
  fi

  say "Results"
  local rc=0
  while IFS= read -r line; do
    case "$line" in
      ok*)   ok "${line#ok }" ;;
      FAIL*) bad "${line#FAIL }"; rc=1 ;;
    esac
  done <<<"$report"

  ((rc == 0)) && say "verify: PASS" || say "verify: FAIL (expected until every playbook has been deployed)"
  return $rc
}

# UNVERIFIED - see SKILL.md. Stages an unattended 26.04 install but
# does not arm it; `reinstall-arm` is the separate step that reboots
# into the installer.
cmd_reinstall_stage() {
  metal_only reinstall-stage reset
  require_up
  local iso_url="${LAB_ISO_URL:?set LAB_ISO_URL to the 26.04 live-server ISO URL}"
  local key; key="$(ssh-keygen -y -f ~/.ssh/nyarlathotep)"

  say "Staging the installer on the machine"
  sshq "sudo mkdir -p /var/lib/autoinstall /boot/autoinstall
        sudo curl -fL --continue-at - -o /var/lib/autoinstall/ubuntu.iso '${iso_url}'
        sudo mount -o loop,ro /var/lib/autoinstall/ubuntu.iso /mnt
        sudo cp /mnt/casper/vmlinuz /mnt/casper/initrd /boot/autoinstall/
        sudo umount /mnt"

  say "Writing the autoinstall seed"
  sshq "sudo tee /var/lib/autoinstall/user-data >/dev/null <<'SEED'
#cloud-config
autoinstall:
  version: 1
  interactive-sections: []
  identity:
    hostname: ${HOST}
    username: drehtuer
    password: '!'
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - ${key}
  storage:
    layout:
      name: lvm
  shutdown: reboot
SEED
        sudo touch /var/lib/autoinstall/meta-data"
  ok "staged - nothing has been armed; 'lab.sh reinstall-arm' is the step that reboots"
  info "review: ssh ${HOST} sudo cat /var/lib/autoinstall/user-data"
}

cmd_reinstall_arm() {
  [[ "${1:-}" == "--yes-i-have-console" ]] || {
    printf '\nRefusing to arm an unattended reinstall without --yes-i-have-console.\n'
    printf 'If the installer stalls or the seed is wrong, this machine can only\n'
    printf 'be recovered with a screen and keyboard attached to it.\n\n'
    exit 1
  }
  metal_only reinstall-arm reset
  require_up
  say "Arming a one-shot boot into the installer"
  sshq "sudo tee /etc/grub.d/45_autoinstall >/dev/null <<'ENTRY'
#!/bin/sh
exec tail -n +3 \\\$0
menuentry 'Ubuntu autoinstall' --id autoinstall {
  linux /autoinstall/vmlinuz autoinstall ds=nocloud\\;s=/var/lib/autoinstall/ ---
  initrd /autoinstall/initrd
}
ENTRY
        sudo chmod +x /etc/grub.d/45_autoinstall
        sudo update-grub
        sudo grub-reboot autoinstall"
  say "Rebooting into the installer"
  sshq "sudo systemctl reboot" || true
  BOOT_TIMEOUT=1800 wait_for_boot
  say "The machine answered SSH again. Confirm it is actually reinstalled:"
  sshq '. /etc/os-release; echo "  $PRETTY_NAME"; uptime -p'
}

usage() {
  cat <<'USAGE'
lab.sh <command>

  check            reachability, sudo, storage, baseline, lockout guards
  snapshot [--force]
                   take the rollback baseline (archives /boot, then snapshots)
  reset            roll back to the baseline, reboot, re-arm the snapshot
  seed-certs       install a self-signed cert so the http role skips certbot
  deploy [role...] run the playbooks (all, in dependency order, by default)
  verify           check units, sockets, config validators, firewall, TLS
  reinstall-stage  UNVERIFIED: download the ISO and write the autoinstall seed
  reinstall-arm --yes-i-have-console
                   UNVERIFIED: reboot into the unattended installer

Exit 10 means the machine needs hands-on attention; stop and say so.
USAGE
}

case "${1:-}" in
  check)           shift; cmd_check "$@" ;;
  snapshot)        shift; cmd_snapshot "$@" ;;
  reset)           shift; cmd_reset "$@" ;;
  seed-certs)      shift; cmd_seed_certs "$@" ;;
  deploy)          shift; cmd_deploy "$@" ;;
  verify)          shift; cmd_verify "$@" ;;
  reinstall-stage) shift; cmd_reinstall_stage "$@" ;;
  reinstall-arm)   shift; cmd_reinstall_arm "$@" ;;
  *)               usage; exit 1 ;;
esac

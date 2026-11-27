---
name: testlab
description: Deploy and test this repo's Ansible roles on a real system before production. Use when asked to try a role/playbook against a real machine, deploy to the test host, verify a deployment works end to end, reset the test environment, or prove a from-scratch provision. Default target is a local QEMU/KVM VM; a physical LAN machine is also available. Not for `carcosa` — that is production.
---

Two disposable test hosts, both in the inventory's `testlab` group. Nothing on either is backed up.

| | `testlab_vm` (default) | `testlab_metal` |
|---|---|---|
| Host | `yuggoth` (+ `hastur`) | `nyarlathotep` |
| What | QEMU/KVM guest **inside this dev container** | ZOTAC ZBOX on the LAN, `192.168.89.41` |
| Reset | seconds, to a pristine cloud image | ~3 min, to an LVM snapshot |
| Console | `vm.sh console` — always available | **none** |
| Reach | loopback port forward, this container only | LAN |
| Driver | `vm.sh` (lifecycle) + `lab.sh` (deploy) | `lab.sh` |

**Prefer the VM.** It resets to a genuinely clean install, it has a serial console so no mistake is unrecoverable, and it is fast. Reach for the metal only to check something a VM cannot show — real firmware, a real NIC, an Atom CPU's instruction set.

## Before the VM works: rebuild the container

`devcontainer.json` passes `/dev/kvm` through and the Dockerfile installs `qemu-system-x86`, `qemu-utils`, `cloud-image-utils` and `socat`. **Both only take effect after a rebuild** (*Dev Containers: Rebuild Container*). Until then `vm.sh` stops with an explanation.

**The VM path works** — it has run real deployments, and `doc/TESTING.adoc` records their results. (It was originally written blind, in a container that could not reach `/dev/kvm`, since the device cgroup denies access even to a hand-made node; that caveat is now history.) After a rebuild, verify in this order:

```bash
ls -l /dev/kvm                                   # exists and is read/write
.claude/skills/testlab/vm.sh create              # downloads ~700 MB once, then boots
.claude/skills/testlab/vm.sh status              # release, uptime, snapshots
ssh yuggoth 'echo hello'
.claude/skills/testlab/lab.sh check
```

If the container will not start at all after the rebuild, the host has no `/dev/kvm`: drop the `--device=/dev/kvm` line from `runArgs` and use `LAB_TARGET=metal`.

## The VM loop

```bash
vm.sh create           # pristine guest, booted, sshd up
vm.sh reset            # throw the overlay away and rebuild - pristine again
vm.sh snapshot [name]  # qcow2 snapshot (guest must be stopped)
vm.sh revert [name]    # back to a snapshot, then boot
vm.sh console          # serial console; ctrl-o exits
vm.sh status | stop | start | destroy

lab.sh check           # reachable? sudo? is our key in the inventory?
lab.sh seed-certs      # self-signed cert so the http role skips certbot
lab.sh deploy          # every playbook, dependency order
lab.sh verify          # units, sockets, config validators, firewall, TLS
```

There are two guests: `yuggoth`, the default, and `hastur`, which carries `upgrade.target_release` and exists to rehearse the release upgrade. Both run **24.04**, the release production runs — the lab is meant to mirror carcosa, not to run ahead of it. Select one with `LAB_VM_HOST=hastur`, and check a newer release ad hoc with `LAB_VM_RELEASE=26.04 vm.sh reset`.

The disk is a qcow2 overlay on an untouched base image, so `reset` is "delete the overlay and re-run cloud-init". That is a real from-scratch provision every time — the thing `doc/TODO.adoc` has wanted for a long time and neither molecule nor the metal box can do.

Defaults: 4 GiB RAM, 4 vCPUs, 20 GiB disk, Ubuntu **24.04** cloud image — the release production runs — state in `/var/tmp/testlab-vm`. Override with `LAB_VM_MEM`, `LAB_VM_CPUS`, `LAB_VM_DISK`, `LAB_VM_RELEASE`, `LAB_VM_IMAGE_URL`, `LAB_VM_STATE`, `LAB_VM_SSH_PORT`.

## The metal loop

```bash
LAB_TARGET=metal lab.sh check
LAB_TARGET=metal lab.sh snapshot      # LVM baseline, once
LAB_TARGET=metal lab.sh deploy
LAB_TARGET=metal lab.sh reset         # merge the snapshot, reboot, re-arm
```

`snapshot`, `reset` and the `reinstall-*` commands are metal-only and refuse to run against the VM. Specifics:

* Root is `ubuntu-vg/ubuntu-lv` with ~829 GB free in the VG, so the snapshot is sized to the whole origin and can never overflow. A `reset` *consumes* the snapshot (LVM merges it), so the driver re-takes it afterwards.
* `/boot` is a separate partition outside the snapshot. It is archived before the snapshot is taken and restored before the reboot — not as a backup, but so root and `/boot` never disagree about which kernel is installed.
* The machine is an **Atom D525: x86-64-v1**, no SSE4.2 or POPCNT, 1.9 GiB RAM, no `vmx`. Enough to converge the roles; marginal to run the whole stack at once, and possibly below the baseline of newer releases. Check that an installer boots before wiping a working install.
* `reinstall-stage` / `reinstall-arm` build an unattended 26.04 install. **Unverified and able to strand the machine**, which has no console; `reinstall-arm` refuses without `--yes-i-have-console`.

## Why certbot never runs on either

The domain (`lab.lan`) resolves nowhere and neither host is reachable from the internet, so Let's Encrypt can never complete an HTTP-01 challenge. `lab.sh seed-certs` writes a self-signed certificate to `/etc/letsencrypt/live/<fqdn>/` carrying **exactly** the names the `http` role computes.

That is what makes it work rather than a hack: the role decides whether to call certbot by comparing the certificate's SANs against the set the inventory asks for, so a matching seed leaves nothing to do. Re-run `seed-certs` after changing `http.domains` or `http.letsencrypt.subdomains`. The certificate is self-signed, so `verify` only asserts that a handshake completes.

## Locking yourself out

On the VM this is a non-event: `vm.sh console` always works, and `vm.sh reset` is seconds. On the metal it is unrecoverable without physical access. Either way:

* **`users`** manages `authorized_keys` authoritatively (`authorized_keys_exclusive`). Only the keys in `inventories/group_vars/testlab/users.yml` survive a run — it carries the public keys of both the `nyarlathotep` and the `yuggoth` Host blocks in `~/.ssh/config` (`ssh -G <host> | grep -i identityfile` shows the file; the names are opaque). `lab.sh check` refuses to continue if the relevant one is missing.
* **`sshd`** replaces host keys on every run. Handled: both `~/.ssh/config` blocks set `StrictHostKeyChecking no`, `UserKnownHostsFile /dev/null` and `LogLevel ERROR`, which Ansible inherits. No MITM protection for these two hosts — accepted, and must not be copied to the `carcosa` block.
* **`firewall`** flushes and reloads the whole filter table. It opens 22, but a half-applied run may not.

## When it needs hands

Exit code **10** from `lab.sh` means physical attention is required and no further automation will help — in practice only ever the metal host. **Stop and tell the user immediately**: what was attempted, what state the machine is in, that recovery needs a screen and keyboard. If it happened during a long unattended run, also send a `PushNotification`. Do not retry.

An ordinary playbook failure is not this. A role that fails while the host still answers SSH is a normal test result; reset and move on.

## Gotchas

* **`invoke run-playbook` requires `--hosts`.** The inventory holds production and both test hosts, and every playbook is `hosts: all`, so a defaulted run would deploy to all of them. Use `--hosts=testlab_vm`, `testlab_metal`, or `production`. `lab.sh deploy` passes the right group for its target.
* **`invoke check-drift` defaults to `--hosts=production`.** Test hosts are expected to differ constantly.
* **`verify` failing is normal before a full deploy.** It asserts the end state of every role, so redis, unbound, postfix, dovecot, rspamd and TLS all report FAIL on a partially deployed host.
* **Do not open an SSH connection per check.** A `verify` that connected once per unit made the metal host stop accepting SSH for about a minute, then recover. Not fail2ban (zero bans) and not OpenSSH per-source penalties (9.6 predates them) — the exact limit was never identified. `sshq` multiplexes and `verify` collects everything in one remote call; keep new checks inside it.
* **The VM's user-mode networking is NAT-only.** The guest can reach out; nothing outside this container can reach it except through the forwarded SSH port. Fine for Ansible, useless for pointing a browser at from another machine.
* **The VM dies with the container or the WSL2 VM.** `wsl --shutdown`, a Windows reboot or a container rebuild all take it with them. Re-`create` it; the downloaded base image survives if `LAB_VM_STATE` points somewhere persistent.
* **`ansible-inventory --host` does not template.** It dumps raw vars, so `http.domains` comes back as literal Jinja and vaulted values look like one-character strings. Use `ansible <host> -m debug -a 'msg={{ ... }}'` instead.

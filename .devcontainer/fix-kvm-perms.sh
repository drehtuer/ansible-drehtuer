#!/usr/bin/env bash
# /dev/kvm is passed through by devcontainer.json (--device=/dev/kvm)
# for the deployment-test VM. Docker recreates the node inside the
# container with the host's ownership - root, and whatever GID the
# host's `kvm` group happens to have (993 on this machine). That group
# does not exist in the image, so the container user is not in it and
# cannot open the device: everything looks correctly passed through,
# and QEMU still fails with "Permission denied".
#
# Fixed with chmod rather than a matching group, unlike the docker
# socket next door, for two reasons:
#
#   - The socket is bind-mounted from the host, so a chmod there would
#     change the host's file. /dev inside a container is a private
#     tmpfs and this node is a container-local copy, so a chmod here
#     affects nothing outside the container.
#   - usermod only takes effect in a new login session, which is the
#     long-standing annoyance with the docker fix. chmod applies at
#     once, so the VM works in the shell that is already open.
#
# 0666 lets any process in this container use KVM. That is no wider
# than the passwordless sudo and the host docker socket it already
# has, in a single-user dev environment.
#
# Skipped silently when the device is absent, so this script is safe
# on a host without KVM - though the container itself will not start
# there, see the --device line in devcontainer.json.
set -euo pipefail

if [[ -e /dev/kvm ]]; then
    sudo chmod 0666 /dev/kvm
fi

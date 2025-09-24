#!/bin/bash
# SPDX-FileCopyrightText: 2021 Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu

chmod 755 /

# Mount the local drive on /tmp
mount "$TEMP_DEVICE" /tmp

# Reset the content of the local drive
rm -rf /tmp/*

# Get the nameserver address from the in-kernel dhcp client
grep ^nameserver /proc/net/pnp > /etc/resolv.conf
grep ^domain /proc/net/pnp >> /etc/resolv.conf

# Add the tracing group expected by lttng-tools
groupadd tracing

depmod -a

# Create a python virtual env to install vlttng
python3 -m venv /tmp/python-venv
set +ux
# shellcheck disable=SC1091
. /tmp/python-venv/bin/activate
set -ux

pip3 install --quiet vlttng

hash -r

# Setup ssh access
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp lava/system-tests/authorized_keys /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

sync

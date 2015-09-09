#!/bin/sh -exu
#
# Copyright (C) 2015 - Michael Jeanson <mjeanson@efficios.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Dumb libvirt provisionning script for CI slaves

echo "
ci-slave-x32-02-01 i386 52:54:00:bf:45:af cloud02.internal.efficios.com
ci-slave-x32-02-02 i386 52:54:00:8d:b6:5e cloud02.internal.efficios.com
ci-slave-x32-02-03 i386 52:54:00:97:ab:8c cloud02.internal.efficios.com
ci-slave-x32-02-04 i386 52:54:00:d1:22:0b cloud02.internal.efficios.com

ci-slave-x64-02-01 amd64 52:54:00:c3:1a:30 cloud02.internal.efficios.com
ci-slave-x64-02-02 amd64 52:54:00:b1:92:a3 cloud02.internal.efficios.com
ci-slave-x64-02-03 amd64 52:54:00:3a:6b:ca cloud02.internal.efficios.com
ci-slave-x64-02-04 amd64 52:54:00:c9:91:d1 cloud02.internal.efficios.com" | \
while read node arch mac host
do

if [ "x$host" != "x" ]; then

virt-install --name ${node} \
    --ram 4096 \
    --vcpus 8 \
    --disk pool=default,size=20 \
    --os-type linux \
    --os-variant ubuntutrusty \
    --network bridge=br102,mac="${mac}" \
    --location "http://archive.ubuntu.com/ubuntu/dists/trusty/main/installer-${arch}/" \
    --initrd-inject='preseed.cfg' \
    --extra-args='debian-installer/locale=en_US.UTF-8 keyboard-configuration/layoutcode=us netcfg/choose_interface=auto hostname=unassigned' \
    --connect=qemu+ssh://root@${host}/system \
    >/dev/null 2>&1 &

sleep 10
fi

done


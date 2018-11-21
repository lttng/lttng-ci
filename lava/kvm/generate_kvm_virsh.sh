#!/bin/bash -exu
#
# Copyright (C) 2018 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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

export LIBVIRT_DEFAULT_URI="qemu:///system"

tmp=$(mktemp)
name=$1
virsh vol-create-as --pool default --name "${name}.raw" --capacity 2G --format raw
data_disk_path="$(virsh vol-path ${name}.raw --pool default)"
sudo mkfs.ext4 "$data_disk_path"
virt-install --print-xml \
	--name "$name" \
	--memory 2096\
	--disk /var/lib/libvirt/images/ipxe.iso,device=cdrom \
	--boot cdrom \
	--disk "$data_disk_path,format=raw" \
	--vcpus 2 \
	--cpu host \
	--serial pty \
	--graphics none \
	--autostart \
	--check path_in_use=off > "$tmp"
virsh define --validate "$tmp"
virsh start "$name"
rm -rf "$tmp"


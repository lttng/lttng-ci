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
virt-install --print-xml \
	--name "$1" \
	--memory 2096\
	--disk /var/lib/libvirt/images/ipxe.iso,device=cdrom \
	--boot cdrom \
	--vcpus 2 \
	--cpu host \
	--serial pty \
	--graphics none \
	--check path_in_use=off > "$tmp"
virsh define --validate "$tmp"
rm -rf "$tmp"


#!/bin/bash -xeu
# Copyright (C) 2016 - Francis Deslauriers <francis.deslauriers@efficios.com>
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

echo 'modules-built.txt does not exist'
echo 'So we built them against the kernel'

$SCP_COMMAND "$STORAGE_USER@$STORAGE_HOST:$STORAGE_KERNEL_MODULE_SYMVERS" "$LINUX_PATH/Module.symvers"

KERNELDIR="$LINUX_PATH" make -j"$NPROC" --directory="$LTTNG_MODULES_PATH"

KERNELDIR="$LINUX_PATH" make -j"$NPROC" --directory="$LTTNG_MODULES_PATH" modules_install INSTALL_MOD_PATH="$MODULES_INSTALL_FOLDER"

tar -czf "$DEPLOYDIR/$BUILD_NAME.lttng.modules.tar.gz" -C "$MODULES_INSTALL_FOLDER/" ./

$SCP_COMMAND "$DEPLOYDIR/$BUILD_NAME.lttng.modules.tar.gz" "$STORAGE_USER@$STORAGE_HOST:$STORAGE_LTTNG_MODULES"

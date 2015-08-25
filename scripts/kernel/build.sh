#!/bin/sh
#
# Copyright (C) 2015 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#                      Michael Jeanson <mjeanson@efficios.com>
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

# Exit with error when using an undefined variable
set -u

#Check if ccache is present
#if [ -d /usr/lib/ccache ]; then
#	echo "Using CCACHE"
#	export PATH="/usr/lib/ccache:$PATH"
#    export CC="ccache gcc"
#    export CXX="ccache g++"
#fi

# Use all CPU cores
NPROC=$(nproc)

SRCDIR="${WORKSPACE}/linux"
BUILDDIR="${WORKSPACE}/build"

# Create build directory
rm -rf "${BUILDDIR}"
mkdir -p "${BUILDDIR}"

# Enter source dir
cd "${SRCDIR}"

# Prepare linux sources for modules OOT build
make O="${BUILDDIR}" defconfig

# Enable CONFIG_KALLSYMS_ALL
sed -i "s/# CONFIG_KALLSYMS_ALL is not set/CONFIG_KALLSYMS_ALL=y/g" "${BUILDDIR}"/.config

# Build to out of tree dir
#make -j$nbrProc O="${BUILDDIR}"
make O="${BUILDDIR}" prepare
make -j${NPROC} O="${BUILDDIR}" modules

# Clean up artifact directory to keep only relevant stuff for lttng-modules
cd "${BUILDDIR}"
find . -maxdepth 1 ! -name "arch" ! -name ".config" ! -name "include" ! -name "Makefile" ! -name "Module.symvers" ! -name "scripts" ! -name "." -exec rm -rf {} \;

# EOF

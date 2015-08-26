#!/bin/sh -exu
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

# Use all CPU cores
NPROC=$(nproc)

SRCDIR="${WORKSPACE}/lttng-modules"
BUILDDIR="${WORKSPACE}/build"
LNXSRCDIR="${WORKSPACE}/linux"
LNXBINDIR="${WORKSPACE}/deps/linux/build"

# Create build directory
rm -rf "${BUILDDIR}"
mkdir -p "${BUILDDIR}"

# Enter source dir
cd "${SRCDIR}"

# Fix linux Makefile
sed -i "s#MAKEARGS := -C .*#MAKEARGS := -C ${LNXSRCDIR}#" "${LNXBINDIR}"/Makefile

# Build modules
make -j${NPROC} -C "${LNXBINDIR}" M="$(pwd)"

# Install modules to build dir
make INSTALL_MOD_PATH="${BUILDDIR}" -C "${LNXBINDIR}" M="$(pwd)" modules_install

# EOF

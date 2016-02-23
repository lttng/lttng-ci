#!/bin/bash -xue
# Copyright (C) 2016- Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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

set -x

# http://stackoverflow.com/questions/4609668/override-variable-in-bash-script-from-command-line
: ${ARCH:="amd64"}
: ${DISTRIBUTION:="trusty"}
: ${MIRROR:=http://archive.ubuntu.com/ubuntu}
: ${COMPONENTS:=universe,multiverse,main,restricted}

date=`date +%Y-%m-%d-%H%M`
tarname="rootfs_${ARCH}_${DISTRIBUTION}_${date}.tar"

./lava-vmdebootstrap \
	--arch=$ARCH \
	--distribution=$DISTRIBUTION \
	--tarball $tarname \
	--mirror=$MIRROR \
	--package=autoconf,automake,bash-completion,bison,bsdtar,build-essential,chrpath,clang,cloc,cppcheck,curl,flex,gettext,git,htop,jq,libglib2.0-dev,libpopt-dev,libtap-harness-archive-perl,libtool,libxml2-dev,python-virtualenv,python3,python3-dev,python3-sphinx,swig2.0,texinfo,tree,uuid-dev,vim,wget \
	--debootstrapopts=components=main,universe,multiverse\
	--hostname='linaro-server' \
	--user=linaro/linaro \
	--no-kernel \
	"$@"

if [ $? -ne 0 ]; then
	echo "An error occurred"
	exit
else
	gzip --best $tarname
fi

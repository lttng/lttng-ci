#!/usr/bin/python3
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

import argparse
import gzip
import os
import shutil
import subprocess

from datetime import datetime


def compress(filename):
    with open(filename, 'rb') as f_in:
        with gzip.open('{}.gz'.format(filename), 'wb') as f_out:
            shutil.copyfileobj(f_in, f_out)
    os.remove(filename)


packages = [
    'autoconf',
    'automake',
    'bash-completion',
    'bison',
    'bsdtar',
    'build-essential',
    'chrpath',
    'clang',
    'cloc',
    'curl',
    'elfutils',
    'flex',
    'gettext',
    'git',
    'htop',
    'jq',
    'libdw-dev',
    'libelf-dev',
    'libffi-dev',
    'libglib2.0-dev',
    'libmount-dev',
    'libnuma-dev',
    'libpfm4-dev',
    'libpopt-dev',
    'libtap-harness-archive-perl',
    'libtool',
    'libxml2',
    'libxml2-dev',
    'netcat-traditional',
    'openssh-server',
    'psmisc',
    'python-virtualenv',
    'python3',
    'python3-dev',
    'python3-numpy',
    'python3-pandas',
    'python3-pip',
    'python3-setuptools',
    'python3-sphinx',
    'stress',
    'swig',
    'texinfo',
    'tree',
    'uuid-dev',
    'vim',
    'wget',
]


def main():
    parser = argparse.ArgumentParser(description='Generate lava lttng rootfs')
    parser.add_argument("--arch", default='amd64')
    # We are using xenial instead of bionic ++ since some syscall test depends
    # on cat and the libc to use the open syscall. In recent libc openat is
    # used. See these commit in lttng-tools that helps with the problem:
    # c8e51d1559c48a12f18053997bbcff0c162691c4
    # 192bd8fb712659b9204549f29d9a54dc2c57a9e
    # These are only part of 2.11 and were not backported since they do not
    # represent a *problem* per se.
    parser.add_argument("--distribution", default='xenial')
    parser.add_argument("--mirror", default='http://archive.ubuntu.com/ubuntu')
    parser.add_argument(
        "--component", default='universe,multiverse,main,restricted')
    args = parser.parse_args()

    name = "rootfs_{}_{}_{}.tar".format(args.arch, args.distribution,
                                        datetime.now().strftime("%Y-%m-%d"))

    hostname = "linaro-server"
    user = "linaro/linaro"
    root_password = "root"
    print(name)
    command = [
        "sudo",
        "vmdebootstrap",
        "--arch={}".format(args.arch),
        "--distribution={}".format(args.distribution),
        "--mirror={}".format(args.mirror),
        "--debootstrapopts=components={}".format(args.component),
        "--tarball={}".format(name),
        "--package={}".format(",".join(packages)),
        "--hostname={}".format(hostname),
        "--user={}".format(user),
        "--root-password={}".format(root_password),
        "--no-kernel",
        "--verbose",
    ]

    completed_command = subprocess.run(command, check=True)

    compress(name)


if __name__ == "__main__":
    main()

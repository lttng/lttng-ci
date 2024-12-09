#!/usr/bin/python
# -*- coding: utf-8 -*-
#
# Copyright (C) 2015 - Michael Jeanson <mjeanson@efficios.com>
#                      Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
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

""" This script is used to generate a yaml list of kernel version tag """

import argparse
import os
import re
from distutils.version import Version

import yaml
from git import Repo


class KernelVersion(Version):
    """Kernel version class"""

    re26 = re.compile(r"^(2\.\d+) \. (\d+) (\. (\d+))? (\-rc(\d+))?$", re.VERBOSE)
    re30 = re.compile(r"^(\d+) \. (\d+) (\. (\d+))? (\-rc(\d+))?$", re.VERBOSE)

    def __init__(self, vstring=None):
        self._rc = None
        self._version = None
        if vstring:
            self.parse(vstring)

    def parse(self, vstring):
        """Parse version string"""

        self._vstring = vstring

        if self._vstring.startswith("2"):
            match = self.re26.match(self._vstring)
        else:
            match = self.re30.match(self._vstring)

        if not match:
            raise ValueError("invalid version number '%s'" % self._vstring)

        (major, minor, patch, rc_num) = match.group(1, 2, 4, 6)

        major = int(float(major) * 10)

        if patch:
            self._version = tuple(map(int, [major, minor, patch]))
        else:
            self._version = tuple(map(int, [major, minor])) + (0,)

        if rc_num:
            self._rc = int(rc_num)
        else:
            self._rc = None

    def isrc(self):
        """Is this version an RC"""
        return self._rc is not None

    def __str__(self):
        return self._vstring

    def __repr__(self):
        return "KernelVersion ('%s')" % str(self)

    def _cmp(self, other):
        if isinstance(other, str):
            other = KernelVersion(other)

        if self._version != other._version:
            # numeric versions don't match
            # prerelease stuff doesn't matter
            if self._version < other._version:
                return -1
            else:
                return 1

        # have to compare rc
        # case 1: neither has rc; they're equal
        # case 2: self has rc, other doesn't; other is greater
        # case 3: self doesn't have rc, other does: self is greater
        # case 4: both have rc: must compare them!

        if not self._rc and not other._rc:
            return 0
        elif self._rc and not other._rc:
            return -1
        elif not self._rc and other._rc:
            return 1
        elif self._rc and other._rc:
            if self._rc == other._rc:
                return 0
            elif self._rc < other._rc:
                return -1
            else:
                return 1
        else:
            assert False, "never get here"


def main():
    """Main"""

    versions = []
    kernel_cutoff = KernelVersion("2.6.36")
    kernel_git = "git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"
    kernel_path = os.getcwd() + "/kernel"

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--kernel-path",
        help="The location of the kernel.  Default to the currentdir/linux",
    )
    parser.add_argument(
        "--kernel-git-remote",
        help="The git url of the kernel. Default to git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git",
    )
    parser.add_argument(
        "--kernel-cutoff",
        help="The lower bersion cutoff in X.X.X format. Default to 2.6.36",
    )
    args = parser.parse_args()

    if args.kernel_path:
        kernel_path = args.kernel_path
    if args.kernel_git_remote:
        kernel_git = args.kernel_git_remote
    if args.kernel_cutoff:
        kernel_cutoff = KernelVersion(args.kernel_cutoff)

    # Open or create the local repository
    if os.path.isdir(kernel_path):
        linux_repo = Repo(kernel_path)
    else:
        linux_repo = Repo.clone_from(kernel_git, kernel_path)

    # Pull the latest
    linux_repo.remote().pull()

    # First get all valid versions
    for tag in linux_repo.tags:
        try:
            version = KernelVersion(tag.name.lstrip("v"))

            # Add only those who are superior to the cutoff version
            if version >= kernel_cutoff:
                versions.append(version)
        except ValueError:
            # print(tag.name)
            continue

    # Sort the list by version order
    versions.sort()

    # Keep only one rc if it's the latest version
    last = True
    for version in reversed(versions):
        if version.isrc() and not last:
            versions.remove(version)
        last = False

    # for version in versions:
    #    print(version)

    # Build yaml object
    yversions = []

    for version in versions:
        yversions.append(version.__str__())

    print(yaml.dump(yversions, default_flow_style=False))


if __name__ == "__main__":
    main()

# EOF

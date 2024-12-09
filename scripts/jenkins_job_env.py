#!/usr/bin/env python3
#
# SPDX-FileCopyrightText: 2024 Kienan Stewart <kstewart@efficios.com>
# SPDX-License-Identifier: GPL-2.0-only
#

import argparse
import logging
import os
import pathlib
import platform
import re
import shlex
import subprocess
import sys
import tempfile
import urllib

_ENV_VARS = [
    "BABELTRACE_PLUGIN_PATH",
    "CPPFLAGS",
    "LD_LIBRARY_PATH",
    "LDFLAGS",
    "PATH",
    "PKG_CONFIG_PATH",
    "PYTHONPATH",
    "WORKSPACE",
]


def _get_argparser():
    parser = argparse.ArgumentParser(
        description="Fetch and create a stub environment from common job artifacts",
    )
    # Commands: fetch (implies activate), activate, deactivate
    subparsers = parser.add_subparsers(dest="command")
    parser.add_argument(
        "-v", "--verbose", action="count", help="Increase the verbosity"
    )

    fetch_parser = subparsers.add_parser("fetch")
    fetch_parser.add_argument(
        "directory",
        help="The directory",
        type=pathlib.Path,
    )
    fetch_parser.add_argument(
        "-s",
        "--server",
        default="https://ci.lttng.org",
        help="The jenkins server to use",
    )
    fetch_parser.add_argument(
        "-j",
        "--job",
        help="The job name, eg. 'lttng-tools_master_root_slesbuild'",
        default=None,
        required=True,
    )
    fetch_parser.add_argument(
        "-jc",
        "--job-configuration",
        help="An optional job configuration, eg. 'babeltrace_version=stable-2.0,build=std,conf=agents,liburcu_version=master,node=sles15sp4-amd64-rootnode,platform=sles15sp4-amd64'",
        default=None,
    )
    fetch_parser.add_argument(
        "-b", "--build-id", help="The build ID, eg. '28'", default=None, required=True
    )
    fetch_parser.add_argument(
        "-n",
        "--no-download",
        help="Do not activate environment after fetching artifacts",
        action="store_false",
        dest="download",
        default=True,
    )

    return parser


def fetch(destination, server, job, build, job_configuration=None, download=True):
    if destination.exists() and not destination.is_dir():
        raise Exception("'{}' exists but is not a directory".format(str(destination)))
    if not destination.exists():
        destination.mkdir()

    if download:
        components = [
            "job",
            job,
            job_configuration or "",
            build,
            "artifact",
            "*zip*",
            "archive.zip",
        ]
        url_components = [urllib.parse.quote_plus(x) for x in components]
        url = "/".join([server] + url_components)
        logging.info("Fetching archive from '{}'".format(url))

        with tempfile.NamedTemporaryFile() as archive:
            subprocess.run(["wget", url, "-O", archive.name])
            subprocess.run(["unzip", "-d", str(destination), archive.name])

        # The artifact archive doesn't include symlinks, so the the symlinks for
        # the ".so" in libdir_arch must be rebuilt
        lib_dir = "lib"
        lib_dir_arch = lib_dir
        if (
            pathlib.Path("/etc/products.d/SLES.prod").exists()
            or pathlib.Path("/etc/redhat-release").exists()
            or pathlib.Path("/etc/yocto-release").exists()
        ) and "64bit" in platform.architecture():
            lib_dir_arch = "{}64"

        so_re = re.compile("^.*\.so\.\d+\.\d+\.\d+$")
        for root, dirs, files in os.walk(
            str(destination / "deps" / "build" / lib_dir_arch)
        ):
            for f in files:
                if so_re.match(f):
                    bits = f.split(".")
                    alts = [
                        ".".join(bits[:-1]),
                        ".".join(bits[:-2]),
                        ".".join(bits[:-3]),
                    ]
                    for a in alts:
                        os.symlink(f, os.path.join(root, a))

    env = create_activate(destination)
    create_deactivate(destination, env)


def create_activate(destination):
    lib_dir = "lib"
    lib_dir_arch = lib_dir
    if (
        pathlib.Path("/etc/products.d/SLES.prod").exists()
        or pathlib.Path("/etc/redhat-release").exists()
        or pathlib.Path("/etc/yocto-release").exists()
    ) and "64bit" in platform.architecture():
        lib_dir_arch = "{}64"

    env = {}
    env["_JENKINS_ENV"] = destination.name
    for var in _ENV_VARS:
        original = os.getenv(var)
        env["_JENKINS_{}".format(var)] = original if original else ""
        if var == "BABELTRACE_PLUGIN_PATH":
            env["BABELTRACE_PLUGIN_PATH"] = "{}{}".format(
                "{}:".format(original) if original else "",
                str(
                    (
                        destination
                        / "archive"
                        / "deps"
                        / "build"
                        / lib_dir_arch
                        / "babeltrace2"
                        / "plugins"
                    ).absolute()
                ),
            )
        elif var == "CPPFLAGS":
            env["CPPFLAGS"] = "{}-I{}".format(
                "{} ".format(original) if original else "",
                str(
                    (destination / "archive" / "deps" / "build" / "include").absolute()
                ),
            )
        elif var == "LD_LIBRARY_PATH":
            env["LD_LIBRARY_PATH"] = "{}{}".format(
                "{}:".format(original) if original else "",
                str(
                    (
                        destination / "archive" / "deps" / "build" / lib_dir_arch
                    ).absolute()
                ),
            )
        elif var == "LDFLAGS":
            env["LDFLAGS"] = "{}-L{}".format(
                "{} ".format(original) if original else "",
                str(
                    (
                        destination / "archive" / "deps" / "build" / lib_dir_arch
                    ).absolute()
                ),
            )
        elif var == "PATH":
            env["PATH"] = "{}:{}".format(
                original,
                str((destination / "archive" / "deps" / "build" / "bin").absolute()),
            )
        elif var == "PKG_CONFIG_PATH":
            env["PKG_CONFIG_PATH"] = "{}{}".format(
                "{}:" if original else "",
                str(
                    (
                        destination
                        / "archive"
                        / "deps"
                        / "build"
                        / lib_dir_arch
                        / "pkgconfig"
                    ).absolute()
                ),
            )
        elif var == "PYTHONPATH":
            pass
        elif var == "WORKSPACE":
            env["WORKSPACE"] = str((destination / "archive").absolute())
        else:
            raise Exception("Unsupported environment variable '{}'".format(var))

    args = ["{}={}".format(k, shlex.quote(v)) for k, v in env.items()]
    with open(str(destination / "activate"), "w") as fp:
        fp.writelines("#!/usr/bin/bash\n")
        for arg in args:
            fp.writelines("export {}\n".format(arg))
    (destination / "activate").chmod(0o755)
    return env


def create_deactivate(destination, env):
    with open(str(destination / "deactivate"), "w") as fp:
        fp.writelines("#!/usr/bin/bash\n")
        for k, v in env.items():
            if k.startswith("_JENKINS_"):
                fp.writelines("unset {}\n".format(k))
            else:
                original = env["_JENKINS_{}".format(k)]
                fp.writelines("export {}={}\n".format(k, original))
    (destination / "deactivate").chmod(0o755)


if __name__ == "__main__":
    logger = logging.getLogger()
    parser = _get_argparser()
    args = parser.parse_args()
    logger.setLevel(max(1, 30 - (args.verbose or 0) * 10))
    logging.debug("Initialized with log level: {}".format(logger.getEffectiveLevel()))

    if args.command == "fetch":
        fetch(
            destination=args.directory,
            server=args.server,
            job=args.job,
            build=args.build_id,
            job_configuration=args.job_configuration,
            download=args.download,
        )
    else:
        raise Exception("Command '{}' unsupported".format(args.command))
    sys.exit(0)

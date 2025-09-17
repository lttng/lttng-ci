#!/usr/bin/python3

import argparse
import enum
import logging
import pathlib
import os
import re
import shutil
import subprocess
import sys
import tempfile


class UploadMethod(enum.StrEnum):
    s3cmd = "s3cmd"
    minio_client = "minio_client"
    curl = "curl"


BuildID_re = re.compile(r"BuildID\[(?P<hash>[a-z0-9]+)\]=(?P<buildid>[a-z0-9]+)")


def get_argument_parser():
    parser = argparse.ArgumentParser(
        prog="upload_debuginfo.py", description="Upload debuginfo to a server"
    )
    parser.add_argument(
        "-q",
        "--quiet",
        action="store_const",
        dest="loglevel",
        const=logging.ERROR,
        default=logging.INFO,
        help="Only output errors",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_const",
        dest="loglevel",
        const=logging.DEBUG,
        help="Increase verbosity",
    )
    parser.add_argument(
        "-u",
        "--url",
        default="obj.internal.efficios.com/jenkins",
        help="Base URL for the upload",
    )
    parser.add_argument("-b", "--bucket", default="jenkins", help="s3 bucket to use")
    parser.add_argument(
        "--s3cfg", default=None, type=pathlib.Path, help="s3cmd configuration file"
    )
    parser.add_argument("--minio-alias", default="obj2", help="minio alias")
    parser.add_argument(
        "-m",
        "--method",
        default="s3cmd",
        help="Upload method",
        type=UploadMethod,
        choices=list(UploadMethod),
    )
    parser.add_argument(
        "files",
        default=[],
        help="Files or directories to search for objects with BuildIDs",
        nargs="*",
        action="extend",
    )
    parser.add_argument(
        "--ignore-files",
        default=["build/deps/.*"],
        help="Regexes to ignore file patterns",
        action="append",
    )
    return parser


def files_buildid(path):
    if not path.is_file():
        return False

    p = subprocess.Popen(["file", str(path)], stdout=subprocess.PIPE)
    p.wait()
    if p.returncode != 0:
        logging.debug("Failed to run `file` on '{}': {}".format(path, p.returncode))
        return False

    data = p.stdout.read().decode("utf-8")
    m = BuildID_re.search(data)
    if m:
        logging.debug("{}: BuildID[{}]={}".format(path, m["hash"], m["buildid"]))
        if "not stripped" in data:
            return m["buildid"]

        logging.debug("{}: is stripped, skipping".format(path))

    return False


def files_with_buildid(path, ignore_files_res=[]):
    _files = set()
    for root, dirs, files in path.walk():
        for f in files:
            file_path = root / f
            skip = False
            for ignore_re in ignore_files_res:
                if ignore_re.search(str(file_path)):
                    logging.debug(
                        "'{}' matched ignore file regex '{}'".format(
                            str(file_path), ignore_re
                        )
                    )
                    skip = True
                    break

            if skip:
                continue

            buildid = files_buildid(file_path)
            if buildid:
                _files.add((file_path, buildid))

    return _files


def upload_debug_info(
    method, path, buildid, bucket=None, url=None, s3cfg=None, minio_alias=None
):
    args = []
    if method is UploadMethod.s3cmd:
        args = ["s3cmd"]
        if s3cfg:
            args.extend(["--config", str(s3cfg)])
        args.extend(
            [
                "put",
                str(path),
                "s3://{}/buildid/{}/debuginfo".format(bucket, buildid),
            ]
        )
    elif method is UploadMethod.minio_client:
        args = [
            "minio-client",
            "put",
            str(path),
            "{}/{}/buildid/{}/debuginfo".format(minio_alias, bucket, buildid),
        ]
    else:
        logging.error("Unhandled upload method: {}".format(method))
        return False

    logging.debug(args)
    p = subprocess.Popen(args)
    p.wait()
    return p.returncode == 0


if __name__ == "__main__":
    parser = get_argument_parser()
    args = parser.parse_args()
    logging.basicConfig(
        level=args.loglevel, format="[%(asctime)s] - %(levelname)s - %(message)s"
    )

    if not args.files:
        args.files = [os.path.join(os.getenv("WORKSPACE", ""), "build")]

    logging.debug("Paths to search: {}".format(args.files))
    files = set()
    ignore_res = []
    for r in args.ignore_files:
        ignore_res.append(re.compile(r))

    for f in args.files:
        files = files.union(files_with_buildid(pathlib.Path(f), ignore_res))

    logging.info("{} files with BuildIDs".format(len(files)))
    failures = 0
    for path, buildid in files:
        # Create a copy
        copy = tempfile.NamedTemporaryFile()
        debug = tempfile.NamedTemporaryFile()
        shutil.copyfile(str(path), copy.name)

        # Strip
        p = subprocess.Popen(["eu-strip", copy.name, "-f", debug.name])
        p.wait()
        if p.returncode != 0:
            logging.error(
                "Failed to strip debuginfo from copy of original file '{}'".format(path)
            )
            failures += 1
            continue

        if not upload_debug_info(
            args.method,
            debug.name,
            buildid,
            bucket=args.bucket,
            url=args.url,
            s3cfg=args.s3cfg,
            minio_alias=args.minio_alias,
        ):
            logging.error(
                "Failed to upload debuginfo '{}' to '{}' using {}".format(
                    debug.name, args.url, args.method
                )
            )
            failures += 1
    sys.exit(0 if failures == 0 else 1)

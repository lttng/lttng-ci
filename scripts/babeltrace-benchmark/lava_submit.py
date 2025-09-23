#!/usr/bin/python3
# SPDX-FileCopyrightText: 2019 Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

import argparse
import math
import os
import sys
import time
import xmlrpc.client

from jinja2 import Environment, FileSystemLoader

# 4.4.194
DEFAULT_KERNEL_COMMIT = "a227f8436f2b21146fc024d84e6875907475ace2"

LAVA_USERNAME = os.environ.get("LAVA_USERNAME")
LAVA_HOST = os.environ.get("LAVA_HOST")
LAVA_PROTO = os.environ.get("LAVA_PROTO")

S3_ACCESS_KEY = os.environ.get("S3_ACCESS_KEY")
S3_SECRET_KEY = os.environ.get("S3_SECRET_KEY")

S3_HOST = os.environ.get("S3_HOST")
S3_BUCKET = os.environ.get("S3_BUCKET")
S3_BASE_DIR = os.environ.get("S3_BASE_DIR")

S3_HTTP_BUCKET_URL = os.environ.get("S3_HTTP_BUCKET_URL")

TRACE_DEFAULT_LOCATION = "https://obj-lava.internal.efficios.com/traces/benchmark/babeltrace/babeltrace_benchmark_trace.tar.gz"
TRACE_TOOLS_2_10_LOCATION = "https://obj-lava.internal.efficios.com/traces/benchmark/babeltrace/babeltrace_benchmark_trace-tools-2.10.tar.gz"
TRACE_TOOLS_2_14_LOCATION = "https://obj-lava.internal.efficios.com/traces/benchmark/babeltrace/babeltrace_benchmark_trace-tools-2.14.tar.gz"


def wait_on(server, jobid):
    """
    Wait for the completion of the job.
    Do not care for result. This is mostly to prevent flooding of lava with
    multiple jobs for the same commit hash. Jenkins is responsible for
    running only one job for job submissions.
    """
    # Check the status of the job every 30 seconds
    jobstatus = server.scheduler.job_state(jobid)["job_state"]
    running = False
    while jobstatus in ["Submitted", "Scheduling", "Scheduled", "Running"]:
        if not running and jobstatus == "Running":
            print("Job started running", flush=True)
            running = True
        time.sleep(30)
        try:
            jobstatus = server.scheduler.job_state(jobid)["job_state"]
        except xmlrpc.client.ProtocolError:
            print("Protocol error, retrying", flush=True)
            continue
    print("Job ended with {} status.".format(jobstatus), flush=True)


def submit(
    commits,
    bt_repo,
    ci_repo,
    ci_branch,
    nfsrootfs,
    debug=False,
    kernel_commit=DEFAULT_KERNEL_COMMIT,
    wait_for_completion=True,
):
    kernel_url = (
        "{}/system-tests/kernel/{}.baremetal.bzImage".format(
            S3_HTTP_BUCKET_URL,
            kernel_commit
        )
    )

    # Get the S3 secret from the environment
    lava_api_key = None
    if not debug:
        try:
            lava_api_key = os.environ["LAVA2_JENKINS_TOKEN"]
        except Exception as error:
            print(
                "LAVA2_JENKINS_TOKEN not found in the environment variable. Exiting...",
                error,
            )
            return -1

    # Context for the lava job template
    context = dict()
    context["kernel_url"] = kernel_url
    context["nfsrootfs_url"] = nfsrootfs
    context["commit_hashes"] = " ".join(commits)

    context["ci_repo"] = ci_repo
    context["ci_branch"] = ci_branch

    context["job_timeout_hours"] = max(3, math.ceil(len(commits) * 1.5))
    context["bt_repo"] = bt_repo

    context["trace_default_location"] = TRACE_DEFAULT_LOCATION
    context["trace_tools_2_10_location"] = TRACE_TOOLS_2_10_LOCATION
    context["trace_tools_2_14_location"] = TRACE_TOOLS_2_14_LOCATION

    context["s3_access_key"] = S3_ACCESS_KEY
    context["s3_secret_key"] = S3_SECRET_KEY

    context["s3_host"] = S3_HOST
    context["s3_bucket"] = S3_BUCKET
    context["s3_base_dir"] = S3_BASE_DIR

    # Render the lava job template
    jinja_loader = FileSystemLoader(os.path.dirname(os.path.realpath(__file__)))
    jinja_env = Environment(loader=jinja_loader, trim_blocks=True, lstrip_blocks=True)
    jinja_template = jinja_env.get_template("template_lava_job_bt_benchmark.yml.jinja2")
    render = jinja_template.render(context)

    print("Job to be submitted:", flush=True)

    print(render, flush=True)

    if debug:
        return 0

    server = xmlrpc.client.ServerProxy(
        "%s://%s:%s@%s/RPC2" % (LAVA_PROTO, LAVA_USERNAME, lava_api_key, LAVA_HOST)
    )

    for attempt in range(10):
        try:
            jobid = server.scheduler.submit_job(render)
        except xmlrpc.client.ProtocolError as error:
            print(
                "Protocol error on submit, sleeping and retrying. Attempt #{}".format(
                    attempt
                ),
                flush=True,
            )
            time.sleep(5)
            continue
        else:
            break

    print("Lava jobid:{}".format(jobid), flush=True)
    print(
        "Lava job URL: https://{}/scheduler/job/{}".format(LAVA_HOST, jobid),
        flush=True,
    )

    if not wait_for_completion:
        return 0

    wait_on(server, jobid)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Launch baremetal babeltrace test using Lava"
    )
    parser.add_argument("-c", "--commit", required=True, action="append")
    parser.add_argument(
        "-k", "--kernel-commit", required=False, default=DEFAULT_KERNEL_COMMIT
    )
    parser.add_argument("-d", "--debug", required=False, action="store_true")
    args = parser.parse_args()

    sys.exit(submit(args.commits, kernel_commit=args.kernel_commit, debug=args.debug))

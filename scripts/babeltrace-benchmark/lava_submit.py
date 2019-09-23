#!/usr/bin/python3
# Copyright (C) 2019 - Jonathan Rajotte Julien <jonathan.rajotte-julien@efficios.com>
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
import os
import sys
import time
import xmlrpc.client

from jinja2 import Environment, FileSystemLoader

USERNAME = "lava-jenkins"
HOSTNAME = "lava-master-02.internal.efficios.com"
DEFAULT_KERNEL_COMMIT = "1a1a512b983108015ced1e7a7c7775cfeec42d8c"


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
    commit, debug=False, kernel_commit=DEFAULT_KERNEL_COMMIT, wait_for_completion=True
):
    nfsrootfs = "https://obj.internal.efficios.com/lava/rootfs/rootfs_amd64_xenial_2018-12-05.tar.gz"
    kernel_url = "https://obj.internal.efficios.com/lava/kernel/{}.baremetal.bzImage".format(
        kernel_commit
    )
    modules_url = "https://obj.internal.efficios.com/lava/modules/linux/{}.baremetal.linux.modules.tar.gz".format(
        kernel_commit
    )

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

    jinja_loader = FileSystemLoader(os.path.dirname(os.path.realpath(__file__)))
    jinja_env = Environment(loader=jinja_loader, trim_blocks=True, lstrip_blocks=True)
    jinja_template = jinja_env.get_template("template_lava_job_bt_benchmark.jinja2")

    context = dict()
    context["kernel_url"] = kernel_url
    context["nfsrootfs_url"] = nfsrootfs
    context["commit_hash"] = commit

    render = jinja_template.render(context)

    print("Job to be submitted:", flush=True)

    print(render, flush=True)

    if debug:
        return 0

    server = xmlrpc.client.ServerProxy(
        "http://%s:%s@%s/RPC2" % (USERNAME, lava_api_key, HOSTNAME)
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
        "Lava job URL: http://lava-master-02.internal.efficios.com/scheduler/job/{}".format(
            jobid
        ),
        flush=True,
    )

    if not wait_for_completion:
        return 0

    wait_on(server, jobid)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Launch baremetal babeltrace test using Lava"
    )
    parser.add_argument("-c", "--commit", required=True)
    parser.add_argument(
        "-k", "--kernel-commit", required=False, default=DEFAULT_KERNEL_COMMIT
    )
    parser.add_argument("-d", "--debug", required=False, action="store_true")
    args = parser.parse_args()
    sys.exit(submit(args.kernel_commit, args.commit, args.debug))

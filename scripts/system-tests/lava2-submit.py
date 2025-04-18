#!/usr/bin/python3
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

import argparse
import json
import os
import random
import re
import sys
import time
import xmlrpc.client
from urllib.parse import urljoin
from urllib.request import urlretrieve

import yaml
from jinja2 import Environment, FileSystemLoader

USERNAME = "lava-jenkins"
HOSTNAME = os.environ.get("LAVA_HOST", "lava-master-03.internal.efficios.com")
PROTO = os.environ.get("LAVA_PROTO", "https")
OBJSTORE_URL = "https://obj.internal.efficios.com/lava/results/"


def parse_stable_version(stable_version_string):
    # Get the major and minor version numbers from the lttng version string.
    version_match = re.search("stable-(\d).(\d\d)", stable_version_string)

    if version_match is not None:
        major_version = int(version_match.group(1))
        minor_version = int(version_match.group(2))
    else:
        # Setting to zero to make the comparison below easier.
        major_version = 0
        minor_version = 0
    return major_version, minor_version


class TestType:
    """Enum like for test type"""

    baremetal_tests = 1
    kvm_tests = 2
    values = {
        "baremetal-tests": baremetal_tests,
        "kvm-tests": kvm_tests,
    }


class DeviceType:
    """Enum like for device type"""

    x86 = "x86"
    kvm = "qemu"
    values = {"kvm": kvm, "x86": x86}


def get_job_bundle_content(server, job):
    try:
        bundle_sha = server.scheduler.job_status(str(job))["bundle_sha1"]
        bundle = server.dashboard.get(bundle_sha)
    except xmlrpc.client.Fault as error:
        print("Error while fetching results bundle", error.faultString)
        raise error

    return json.loads(bundle["content"])


def check_job_all_test_cases_state_count(server, job):
    """
    Parse the results bundle to see the run-tests testcase
    of the lttng-kernel-tests passed successfully
    """
    print("Testcase result:")
    content = server.results.get_testjob_results_yaml(str(job))
    testcases = yaml.load(content, Loader=yaml.Loader)

    passed_tests = 0
    failed_tests = 0
    for testcase in testcases:
        if testcase["result"] != "pass":
            print(
                "\tFAILED {}\n\t\t See {}://{}{}".format(
                    testcase["name"], PROTO, HOSTNAME, testcase["url"]
                )
            )
            failed_tests += 1
        else:
            passed_tests += 1
    return (passed_tests, failed_tests)


def print_test_output(server, job):
    """
    Parse the attachment of the testcase to fetch the stdout of the test suite
    """
    job_finished, log = server.scheduler.jobs.logs(str(job))
    logs = yaml.load(log.data.decode("ascii"), Loader=yaml.Loader)
    print_line = False
    for line in logs:
        if line["lvl"] != "target":
            continue
        if line["msg"] == "<LAVA_SIGNAL_STARTTC run-tests>":
            print("---- TEST SUITE OUTPUT BEGIN ----")
            print_line = True
            continue
        if line["msg"] == "<LAVA_SIGNAL_ENDTC run-tests>":
            print("----- TEST SUITE OUTPUT END -----")
            print_line = False
            continue
        if print_line:
            print("{} {}".format(line["dt"], line["msg"]))


def get_vlttng_cmd(
    lttng_version,
    lttng_tools_url,
    lttng_tools_commit,
    lttng_ust_url=None,
    lttng_ust_commit=None,
):
    """
    Return vlttng cmd to be used in the job template for setup.
    """

    major_version, minor_version = parse_stable_version(lttng_version)

    urcu_profile = ""
    if lttng_version == "master" or (major_version >= 2 and minor_version >= 11):
        urcu_profile = "urcu-master"
    else:
        urcu_profile = "urcu-stable-0.12"

    # Starting with 2.14, babeltrace2 is the reader for testing.
    if lttng_version == "master" or (major_version >= 2 and minor_version >= 14):
        babeltrace_profile = (
            " --profile babeltrace2-stable-2.0 --profile babeltrace2-python"
        )
        babeltrace_overrides = " --override projects.babeltrace2.build-env.PYTHON=python3 --override projects.babeltrace2.build-env.PYTHON_CONFIG=python3-config -o projects.babeltrace2.configure+=--disable-man-pages"
    else:
        babeltrace_profile = (
            " --profile babeltrace-stable-1.5 --profile babeltrace-python"
        )
        babeltrace_overrides = " --override projects.babeltrace.build-env.PYTHON=python3 --override projects.babeltrace.build-env.PYTHON_CONFIG=python3-config"

    vlttng_cmd = (
        "vlttng --jobs=$(nproc) --profile "
        + urcu_profile
        + babeltrace_profile
        + babeltrace_overrides
        + " --profile lttng-tools-master"
        " --override projects.lttng-tools.source="
        + lttng_tools_url
        + " --override projects.lttng-tools.checkout="
        + lttng_tools_commit
        + " --profile lttng-tools-no-man-pages"
    )

    if lttng_ust_commit is not None:
        vlttng_cmd += (
            " --profile lttng-ust-master "
            " --override projects.lttng-ust.source="
            + lttng_ust_url
            + " --override projects.lttng-ust.checkout="
            + lttng_ust_commit
            + " --profile lttng-ust-no-man-pages"
        )

    if lttng_version == "master" or (major_version >= 2 and minor_version >= 11):
        vlttng_cmd += (
            " --override projects.lttng-tools.configure+=--enable-test-sdt-uprobe"
        )

    vlttng_path = "/tmp/virtenv"

    vlttng_cmd += " " + vlttng_path

    return vlttng_cmd


def main():
    send_retry_limit = 10
    test_type = None
    parser = argparse.ArgumentParser(description="Launch baremetal test using Lava")
    parser.add_argument("-t", "--type", required=True)
    parser.add_argument("-lv", "--lttng-version", required=True)
    parser.add_argument("-j", "--jobname", required=True)
    parser.add_argument("-k", "--kernel", required=True)
    parser.add_argument("-lm", "--lmodule", required=True)
    parser.add_argument("-tu", "--tools-url", required=True)
    parser.add_argument("-tc", "--tools-commit", required=True)
    parser.add_argument("-id", "--build-id", required=True)
    parser.add_argument("-uu", "--ust-url", required=False)
    parser.add_argument("-uc", "--ust-commit", required=False)
    parser.add_argument("-d", "--debug", required=False, action="store_true")
    parser.add_argument(
        "-r",
        "--rootfs-url",
        required=False,
        default="https://obj.internal.efficios.com/lava/rootfs_amd64_bookworm_2024-01-15.tar.gz",
    )
    parser.add_argument(
        "--ci-repo", required=False, default="https://github.com/lttng/lttng-ci.git"
    )
    parser.add_argument("--ci-branch", required=False, default="master")
    args = parser.parse_args()

    if args.type not in TestType.values:
        print("argument -t/--type {} unrecognized.".format(args.type))
        print("Possible values are:")
        for k in TestType.values:
            print("\t {}".format(k))
        return -1

    lava_api_key = None
    if not args.debug:
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
    jinja_template = jinja_env.get_template("template_lava_job.jinja2")

    test_type = TestType.values[args.type]

    if test_type is TestType.baremetal_tests:
        device_type = DeviceType.x86
    else:
        device_type = DeviceType.kvm

    vlttng_path = "/tmp/virtenv"

    vlttng_cmd = get_vlttng_cmd(
        args.lttng_version,
        args.tools_url,
        args.tools_commit,
        args.ust_url,
        args.ust_commit,
    )

    if args.lttng_version == "master":
        lttng_version_string = "master"
    elif args.lttng_version == "canary":
        lttng_version_string = "2.13"
    else:
        major, minor = parse_stable_version(args.lttng_version)
        lttng_version_string = str(major) + "." + str(minor)

    context = dict()
    context["DeviceType"] = DeviceType
    context["TestType"] = TestType

    context["job_name"] = args.jobname
    context["test_type"] = test_type
    context["random_seed"] = random.randint(0, 1000000)
    context["device_type"] = device_type

    context["vlttng_cmd"] = vlttng_cmd
    context["vlttng_path"] = vlttng_path
    context["lttng_version_string"] = lttng_version_string

    context["kernel_url"] = args.kernel
    context["nfsrootfs_url"] = args.rootfs_url
    context["lttng_modules_url"] = args.lmodule
    context["jenkins_build_id"] = args.build_id

    context["kprobe_round_nb"] = 10

    context["ci_repo"] = args.ci_repo
    context["ci_branch"] = args.ci_branch

    render = jinja_template.render(context)

    print("Job to be submitted:")

    print(render)

    if args.debug:
        return 0

    server = xmlrpc.client.ServerProxy(
        "%s://%s:%s@%s/RPC2" % (PROTO, USERNAME, lava_api_key, HOSTNAME)
    )

    for attempt in range(1, send_retry_limit + 1):
        try:
            jobid = server.scheduler.submit_job(render)
        except xmlrpc.client.ProtocolError as error:
            print(
                "Protocol error on submit, sleeping and retrying. Attempt #{}".format(
                    attempt
                )
            )
            time.sleep(5)
            continue
        else:
            break
    # Early exit when the maximum number of retry is reached.
    if attempt == send_retry_limit:
        print(
            "Protocol error on submit, maximum number of retry reached ({})".format(
                attempt
            )
        )
        return -1

    print("Lava jobid:{}".format(jobid))
    print("Lava job URL: {}://{}/scheduler/job/{}".format(PROTO, HOSTNAME, jobid))

    # Check the status of the job every 30 seconds
    jobstatus = server.scheduler.job_state(jobid)["job_state"]
    running = False
    while jobstatus in ["Submitted", "Scheduling", "Scheduled", "Running"]:
        if not running and jobstatus == "Running":
            print("Job started running")
            running = True
        time.sleep(30)
        try:
            jobstatus = server.scheduler.job_state(jobid)["job_state"]
        except xmlrpc.client.ProtocolError as error:
            print("Protocol error, retrying")
            continue
    print("Job ended with {} status.".format(jobstatus))

    if jobstatus != "Finished":
        return -1

    if test_type is TestType.kvm_tests or test_type is TestType.baremetal_tests:
        print_test_output(server, jobid)

    passed, failed = check_job_all_test_cases_state_count(server, jobid)
    print("With {} passed and {} failed Lava test cases.".format(passed, failed))

    if failed != 0:
        return -1

    return 0


if __name__ == "__main__":
    sys.exit(main())

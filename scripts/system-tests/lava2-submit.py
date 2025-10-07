#!/usr/bin/python3
# SPDX-FileCopyrightText: 2016 Francis Deslauriers <francis.deslauriers@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

import argparse
import json
import os
import re
import sys
import time
import xmlrpc.client
from urllib.parse import urljoin
from urllib.request import urlretrieve

import yaml
from jinja2 import Environment, FileSystemLoader

LAVA_USERNAME = os.environ.get("LAVA_USERNAME")
LAVA_HOST = os.environ.get("LAVA_HOST")
LAVA_PROTO = os.environ.get("LAVA_PROTO")

S3_ACCESS_KEY = os.environ.get("S3_ACCESS_KEY")
S3_SECRET_KEY = os.environ.get("S3_SECRET_KEY")

S3_HOST = os.environ.get("S3_HOST")
S3_BUCKET = os.environ.get("S3_BUCKET")
S3_BASE_DIR = os.environ.get("S3_BASE_DIR")


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
                    testcase["name"], LAVA_PROTO, LAVA_HOST, testcase["url"]
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


def main():
    send_retry_limit = 10

    parser = argparse.ArgumentParser(description="Launch baremetal test using Lava")

    parser.add_argument("--type", required=True)
    parser.add_argument("--lttng-version", required=True)
    parser.add_argument("--jobname", required=True)
    parser.add_argument("--jenkins-build-id", required=True)
    parser.add_argument("--kernel-url", required=True)
    parser.add_argument("--modules-url", required=True)
    parser.add_argument("--rootfs-url", required=True)
    parser.add_argument("--tools-repo", required=True)
    parser.add_argument("--tools-commit", required=True)
    parser.add_argument("--ust-repo", required=True)
    parser.add_argument("--ust-commit", required=True)
    parser.add_argument("--urcu-repo", required=True)
    parser.add_argument("--urcu-branch", required=True)
    parser.add_argument("--bt-repo", required=True)
    parser.add_argument("--bt-branch", required=True)
    parser.add_argument("--ci-repo", required=True)
    parser.add_argument("--ci-branch", required=False, default="master")
    parser.add_argument("--debug", action="store_true")

    args = parser.parse_args()

    # Parse test type
    if args.type not in TestType.values:
        print("argument -t/--type {} unrecognized.".format(args.type))
        print("Possible values are:")
        for k in TestType.values:
            print("\t {}".format(k))
        return -1

    test_type = TestType.values[args.type]

    if test_type is TestType.baremetal_tests:
        device_type = DeviceType.x86
    else:
        device_type = DeviceType.kvm

    # Get the S3 secret from the environment
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

    # Context for the lava job template
    context = dict()
    context["DeviceType"] = DeviceType
    context["TestType"] = TestType

    context["job_name"] = args.jobname
    context["test_type"] = test_type
    context["device_type"] = device_type

    context["tools_repo"] = args.tools_repo
    context["tools_commit"] = args.tools_commit

    context["ust_repo"] = args.ust_repo
    context["ust_commit"] = args.ust_commit

    context["urcu_repo"] = args.urcu_repo
    context["urcu_branch"] = args.urcu_branch

    context["bt_repo"] = args.bt_repo
    context["bt_branch"] = args.bt_branch

    context["kernel_url"] = args.kernel_url
    context["rootfs_url"] = args.rootfs_url
    context["modules_url"] = args.modules_url
    context["jenkins_build_id"] = args.jenkins_build_id

    context["ci_repo"] = args.ci_repo
    context["ci_branch"] = args.ci_branch

    context["s3_access_key"] = S3_ACCESS_KEY
    context["s3_secret_key"] = S3_SECRET_KEY

    context["s3_host"] = S3_HOST
    context["s3_bucket"] = S3_BUCKET
    context["s3_base_dir"] = S3_BASE_DIR

    # Render the lava job template
    jinja_loader = FileSystemLoader(os.path.dirname(os.path.realpath(__file__)))
    jinja_env = Environment(loader=jinja_loader, trim_blocks=True, lstrip_blocks=True)
    jinja_template = jinja_env.get_template("template_lava_job.yml.jinja2")
    render = jinja_template.render(context)

    print("Job to be submitted:")

    print(render)

    if args.debug:
        return 0

    server = xmlrpc.client.ServerProxy(
        "%s://%s:%s@%s/RPC2" % (LAVA_PROTO, LAVA_USERNAME, lava_api_key, LAVA_HOST)
    )

    # Submit the job to lava
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
    print("Lava job URL: {}://{}/scheduler/job/{}".format(LAVA_PROTO, LAVA_HOST, jobid))

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

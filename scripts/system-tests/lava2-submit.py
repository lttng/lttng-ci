#!/usr/bin/python
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
import base64
import json
import os
import random
import sys
import time
import yaml
import xmlrpc.client
import pprint

from jinja2 import Environment, FileSystemLoader, meta

USERNAME = 'lava-jenkins'
HOSTNAME = 'lava-master-02.internal.efficios.com'

class TestType():
    baremetal_benchmarks=1
    baremetal_tests=2
    kvm_tests=3
    kvm_fuzzing_tests=4
    values = {
        'baremetal-benchmarks' : baremetal_benchmarks,
        'baremetal-tests' : baremetal_tests,
        'kvm-tests' : kvm_tests,
        'kvm-fuzzin-tests' : kvm_fuzzing_tests,
    }

class DeviceType():
    x86 = 'x86'
    kvm = 'qemu'
    values = {
        'kvm' : kvm,
        'x86' : x86,
    }

def get_packages():
    return ['bsdtar', 'psmisc', 'wget', 'python3', 'python3-pip', \
            'libglib2.0-dev', 'libffi-dev', 'elfutils', 'libdw-dev', \
            'libelf-dev', 'libmount-dev', 'libxml2', 'libpfm4-dev', \
            'libnuma-dev', 'python3-dev', 'swig', 'stress']

def get_job_bundle_content(server, job):
    try:
        bundle_sha = server.scheduler.job_status(str(job))['bundle_sha1']
        bundle = server.dashboard.get(bundle_sha)
    except xmlrpc.client.Fault as f:
        print('Error while fetching results bundle', f.faultString)
        raise f

    return json.loads(bundle['content'])

# Parse the results bundle to see the run-tests testcase
# of the lttng-kernel-tests passed successfully
def check_job_all_test_cases_state_count(server, job):
    content = get_job_bundle_content(server, job)

    # FIXME:Those tests are part of the boot actions and fail randomly but
    # doesn't affect the behaviour of the tests. We should update our Lava
    # installation and try to reproduce it. This error was encountered on
    # Ubuntu 16.04.
    tests_known_to_fail=['mount', 'df', 'ls', 'ip', 'wait_for_test_image_prompt']

    passed_tests=0
    failed_tests=0
    for run in content['test_runs']:
        for result in run['test_results']:
            if 'test_case_id' in result :
                if result['result'] in 'pass':
                    passed_tests+=1
                elif result['test_case_id'] in tests_known_to_fail:
                    pass
                else:
                    failed_tests+=1
    return (passed_tests, failed_tests)

# Get the benchmark results from the lava bundle
# save them as CSV files localy
def fetch_benchmark_results(server, job):
    content = get_job_bundle_content(server, job)
    testcases = ['processed_results_close.csv',
            'processed_results_ioctl.csv',
            'processed_results_open_efault.csv',
            'processed_results_open_enoent.csv',
            'processed_results_dup_close.csv',
            'processed_results_raw_syscall_getpid.csv',
            'processed_results_lttng_test_filter.csv']

    # The result bundle is a large JSON containing the results of every testcase
    # of the LAVA job as well as the files that were attached during the run.
    # We need to iterate over this JSON to get the base64 representation of the
    # benchmark results produced during the run.
    for run in content['test_runs']:
        # We only care of the benchmark testcases
        if 'benchmark-' in run['test_id']:
            if 'test_results' in run:
                for res in run['test_results']:
                    if 'attachments' in res:
                        for a in res['attachments']:
                            # We only save the results file
                            if a['pathname'] in testcases:
                                with open(a['pathname'],'wb') as f:
                                    # Convert the b64 representation of the
                                    # result file and write it to a file
                                    # in the current working directory
                                    f.write(base64.b64decode(a['content']))

# Parse the attachment of the testcase to fetch the stdout of the test suite
def print_test_output(server, job):
    content = get_job_bundle_content(server, job)
    found = False

    for run in content['test_runs']:
        if run['test_id'] in 'lttng-kernel-test':
            for attachment in run['attachments']:
                if attachment['pathname'] in 'stdout.log':

                    # Decode the base64 file and split on newlines to iterate
                    # on list
                    testoutput = str(base64.b64decode(bytes(attachment['content'], encoding='UTF-8')))

                    testoutput = testoutput.replace('\\n', '\n')

                    # Create a generator to iterate on the lines and keeping
                    # the state of the iterator across the two loops.
                    testoutput_iter = iter(testoutput.split('\n'))
                    for line in testoutput_iter:

                        # Find the header of the test case and start printing
                        # from there
                        if 'LAVA_SIGNAL_STARTTC run-tests' in line:
                            print('---- TEST SUITE OUTPUT BEGIN ----')
                            for line in testoutput_iter:
                                if 'LAVA_SIGNAL_ENDTC run-tests' not in line:
                                    print(line)
                                else:
                                    # Print until we reach the end of the
                                    # section
                                    break

                            print('----- TEST SUITE OUTPUT END -----')
                            break

def get_vlttng_cmd(device, lttng_tools_commit, lttng_ust_commit=None):

    vlttng_cmd = 'vlttng --jobs=$(nproc) --profile urcu-master' \
                    ' --override projects.babeltrace.build-env.PYTHON=python3' \
                    ' --override projects.babeltrace.build-env.PYTHON_CONFIG=python3-config' \
                    ' --profile babeltrace-stable-1.4' \
                    ' --profile babeltrace-python' \
                    ' --profile lttng-tools-master' \
                    ' --override projects.lttng-tools.checkout='+lttng_tools_commit + \
                    ' --profile lttng-tools-no-man-pages'

    if lttng_ust_commit is not None:
        vlttng_cmd += ' --profile lttng-ust-master ' \
                    ' --override projects.lttng-ust.checkout='+lttng_ust_commit+ \
                    ' --profile lttng-ust-no-man-pages'

    if device is DeviceType.kvm:
        vlttng_path = '/root/virtenv'
    else:
        vlttng_path = '/tmp/virtenv'

    vlttng_cmd += ' ' + vlttng_path

    return vlttng_cmd

def main():
    nfsrootfs = "https://obj.internal.efficios.com/lava/rootfs/rootfs_amd64_trusty_2016-02-23-1134.tar.gz"
    test_type = None
    parser = argparse.ArgumentParser(description='Launch baremetal test using Lava')
    parser.add_argument('-t', '--type', required=True)
    parser.add_argument('-j', '--jobname', required=True)
    parser.add_argument('-k', '--kernel', required=True)
    parser.add_argument('-lm', '--lmodule', required=True)
    parser.add_argument('-tc', '--tools-commit', required=True)
    parser.add_argument('-id', '--build-id', required=True)
    parser.add_argument('-uc', '--ust-commit', required=False)
    parser.add_argument('-d', '--debug', required=False, action='store_true')
    args = parser.parse_args()

    if args.type not in TestType.values:
        print('argument -t/--type {} unrecognized.'.format(args.type))
        print('Possible values are:')
        for k in TestType.values:
            print('\t {}'.format(k))
        return -1

    lava_api_key = None
    if not args.debug:
        try:
            lava_api_key = os.environ['LAVA2_JENKINS_TOKEN']
        except Exception as e:
            print('LAVA2_JENKINS_TOKEN not found in the environment variable. Exiting...', e )
            return -1

    jinja_loader = FileSystemLoader(os.path.dirname(os.path.realpath(__file__)))
    jinja_env = Environment(loader=jinja_loader, trim_blocks=True,
            lstrip_blocks= True)
    jinja_template = jinja_env.get_template('template_lava_job.jinja2')
    template_source = jinja_env.loader.get_source(jinja_env, 'template_lava_job.jinja2')
    parsed_content = jinja_env.parse(template_source)
    undef = meta.find_undeclared_variables(parsed_content)

    test_type = TestType.values[args.type]

    if test_type in [TestType.baremetal_benchmarks, TestType.baremetal_tests]:
        device_type = DeviceType.x86
        vlttng_path = '/tmp/virtenv'

    else:
        device_type = DeviceType.kvm
        vlttng_path = '/root/virtenv'

    vlttng_cmd = get_vlttng_cmd(device_type, args.tools_commit, args.ust_commit)

    context = dict()
    context['DeviceType'] = DeviceType
    context['TestType'] = TestType

    context['job_name'] = args.jobname
    context['test_type'] = test_type
    context['packages'] = get_packages()
    context['random_seed'] = random.randint(0, 1000000)
    context['device_type'] = device_type

    context['vlttng_cmd'] = vlttng_cmd
    context['vlttng_path'] = vlttng_path

    context['kernel_url'] = args.kernel
    context['nfsrootfs_url'] = nfsrootfs
    context['lttng_modules_url'] = args.lmodule
    context['jenkins_build_id'] = args.build_id

    context['kprobe_round_nb'] = 10

    render = jinja_template.render(context)

    print('Current context:')
    pprint.pprint(context, indent=4)
    print('Job to be submitted:')

    print(render)

    if args.debug:
        return 0

    server = xmlrpc.client.ServerProxy('http://%s:%s@%s/RPC2' % (USERNAME, lava_api_key, HOSTNAME))

    jobid = server.scheduler.submit_job(render)

    print('Lava jobid:{}'.format(jobid))
    print('Lava job URL: http://lava-master-02.internal.efficios.com/scheduler/job/{}/log_file'.format(jobid))

    #Check the status of the job every 30 seconds
    jobstatus = server.scheduler.job_status(jobid)['job_status']
    not_running = False
    while jobstatus in 'Submitted' or jobstatus in 'Running':
        if not_running is False and jobstatus in 'Running':
            print('Job started running')
            not_running = True
        time.sleep(30)
        jobstatus = server.scheduler.job_status(jobid)['job_status']

#    Do not fetch result for now
#    if test_type is TestType.kvm_tests or test_type is TestType.baremetal_tests:
#        print_test_output(server, jobid)
#    elif test_type is TestType.baremetal_benchmarks:
#        fetch_benchmark_results(server, jobid)

    print('Job ended with {} status.'.format(jobstatus))
    if jobstatus not in 'Complete':
        return -1
    else:
        passed, failed=check_job_all_test_cases_state_count(server, jobid)
        print('With {} passed and {} failed Lava test cases.'.format(passed, failed))

        if failed == 0:
            return 0
        else:
            return -1

if __name__ == "__main__":
    sys.exit(main())

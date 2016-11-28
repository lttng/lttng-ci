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
import sys
import time
import xmlrpclib
from collections import OrderedDict
from enum import Enum

USERNAME = 'frdeso'
HOSTNAME = 'lava-master.internal.efficios.com'
SCP_PATH = 'scp://jenkins-lava@storage.internal.efficios.com'

class TestType(Enum):
    benchmarks=1
    tests=2

def get_job_bundle_content(server, job):
    bundle_sha = server.scheduler.job_status(str(job))['bundle_sha1']
    bundle = server.dashboard.get(bundle_sha)

    return json.loads(bundle['content'])

# Parse the results bundle to see the run-tests testcase
# of the lttng-kernel-tests passed successfully
def check_job_all_test_cases_state_count(server, job):
    content = get_job_bundle_content(server, job)

    passed_tests=0
    failed_tests=0
    for run in content['test_runs']:
        for result in run['test_results']:
            if 'test_case_id' in result:
                if result['result'] in 'pass':
                    passed_tests+=1
                else:
                    failed_tests+=1
    return (passed_tests, failed_tests)

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
                    testoutput = base64.b64decode(attachment['content']).split('\n')

                    # Create a generator to iterate on the lines and keeping
                    # the state of the iterator across the two loops.
                    testoutput_iter = iter(testoutput)
                    for line in testoutput_iter:

                        # Find the header of the test case and start printing
                        # from there
                        if 'LAVA_SIGNAL_STARTTC run-tests' in line:
                            found = True
                            print('---- TEST SUITE OUTPUT BEGIN ----')
                            for line in testoutput_iter:
                                if 'LAVA_SIGNAL_ENDTC run-tests' not in line:
                                    print(line)
                                else:
                                    # Print until we reach the end of the
                                    # section
                                    break

                        if found is True:
                            print('----- TEST SUITE OUTPUT END -----')
                            break

def create_new_job(name, build_device):
    job = OrderedDict({
        'health_check': False,
        'job_name': name,
        'device_type':build_device,
        'tags': [ ],
        'timeout': 18000,
        'actions': []
    })
    if build_device in 'x86':
        job['tags'].append('dev-sda1')

    return job

def get_boot_cmd():
    command = OrderedDict({
        'command': 'boot_image'
        })
    return command

def get_config_cmd(build_device):
    packages=['bsdtar', 'psmisc', 'wget', 'python3', 'python3-pip', \
            'libglib2.0-dev', 'libffi-dev', 'elfutils', 'libdw-dev', \
            'libelf-dev', 'libmount-dev', 'libxml2']
    command = OrderedDict({
        'command': 'lava_command_run',
        'parameters': {
            'commands': [
                'ifup eth0',
                'route -n',
                'cat /etc/resolv.conf',
                'echo nameserver 172.18.0.12 > /etc/resolv.conf',
                'groupadd tracing'
                ]
            }
        })
    if build_device in 'x86':
        command['parameters']['commands'].extend([
                    'mount /dev/sda1 /tmp',
                    'rm -rf /tmp/*'])

    command['parameters']['commands'].extend([
                    'depmod -a',
                    'locale-gen en_US.UTF-8',
                    'apt-get update',
                    'apt-get install -y {}'.format(' '.join(packages))
                ])
    return command

def get_benchmarks_cmd():
    command = OrderedDict({
        'command': 'lava_test_shell',
        'parameters': {
            'testdef_repos': [
                {
                    'git-repo': 'https://github.com/lttng/lttng-ci.git',
                    'revision': 'master',
                    'testdef': 'lava/baremetal-tests/failing-close.yml'
                },
                {
                    'git-repo': 'https://github.com/lttng/lttng-ci.git',
                    'revision': 'master',
                    'testdef': 'lava/baremetal-tests/failing-open-efault.yml'
                },
                {
                    'git-repo': 'https://github.com/lttng/lttng-ci.git',
                    'revision': 'master',
                    'testdef': 'lava/baremetal-tests/failing-open-enoent.yml'
                },
                {
                    'git-repo': 'https://github.com/lttng/lttng-ci.git',
                    'revision': 'master',
                    'testdef': 'lava/baremetal-tests/perf-tests.yml'
                }
                ],
            'timeout': 18000
            }
        })
    return command

def get_tests_cmd():
    command = OrderedDict({
        'command': 'lava_test_shell',
        'parameters': {
            'testdef_repos': [
                {
                    'git-repo': 'https://github.com/lttng/lttng-ci.git',
                    'revision': 'master',
                    'testdef': 'lava/baremetal-tests/kernel-tests.yml'
                }
                ],
            'timeout': 18000
            }
        })
    return command

def get_results_cmd(stream_name):
    command = OrderedDict({
            'command': 'submit_results',
            'parameters': {
                'server': 'http://lava-master.internal.efficios.com/RPC2/'
            }
        })
    command['parameters']['stream']='/anonymous/'+stream_name+'/'
    return command

def get_deploy_cmd_kvm(jenkins_job, kernel_path, linux_modules_path, lttng_modules_path):
    command = OrderedDict({
            'command': 'deploy_kernel',
            'metadata': {},
            'parameters': {
                'customize': {},
                'kernel': None,
                'rootfs': 'file:///var/lib/lava-server/default/media/images/trusty-grub.img.gz',
                'target_type': 'ubuntu'
                }
            })

    command['parameters']['customize'][SCP_PATH+linux_modules_path]=['rootfs:/','archive']
    command['parameters']['customize'][SCP_PATH+lttng_modules_path]=['rootfs:/','archive']
    command['parameters']['kernel'] = str(SCP_PATH+kernel_path)
    command['metadata']['jenkins_jobname'] = jenkins_job

    return command

def get_deploy_cmd_x86(jenkins_job, kernel_path, linux_modules_path, lttng_modules_path, nb_iter=None):
    command = OrderedDict({
            'command': 'deploy_kernel',
            'metadata': {},
            'parameters': {
                'overlays': [],
                'kernel': None,
                'nfsrootfs': str(SCP_PATH+'/storage/jenkins-lava/rootfs/rootfs_amd64_trusty_2016-02-23-1134.tar.gz'),
                'target_type': 'ubuntu'
                }
            })

    command['parameters']['overlays'].append( str(SCP_PATH+linux_modules_path))
    command['parameters']['overlays'].append( str(SCP_PATH+lttng_modules_path))
    command['parameters']['kernel'] = str(SCP_PATH+kernel_path)
    command['metadata']['jenkins_jobname'] = jenkins_job
    if nb_iter is not None:
        command['metadata']['nb_iterations'] = nb_iter

    return command


def get_env_setup_cmd(build_device, lttng_tools_commit, lttng_ust_commit=None):
    command = OrderedDict({
        'command': 'lava_command_run',
        'parameters': {
            'commands': [
                'git clone https://github.com/frdeso/syscall-bench-it.git bm',
                'pip3 install vlttng',
                        ],
            'timeout': 18000
            }
        })

    vlttng_cmd = 'vlttng --jobs=16 --profile urcu-master' \
                    ' --profile babeltrace-stable-1.4 ' \
                    ' --profile lttng-tools-master' \
                    ' --override projects.lttng-tools.checkout='+lttng_tools_commit + \
                    ' --profile lttng-tools-no-man-pages'

    if lttng_ust_commit is not None:
        vlttng_cmd += ' --profile lttng-ust-master ' \
                    ' --override projects.lttng-ust.checkout='+lttng_ust_commit+ \
                    ' --profile lttng-ust-no-man-pages'

    virtenv_path = None
    if build_device in 'kvm':
        virtenv_path = '/root/virtenv'
    else:
        virtenv_path = '/tmp/virtenv'

    vlttng_cmd += ' '+virtenv_path

    command['parameters']['commands'].append(vlttng_cmd)
    command['parameters']['commands'].append('ln -s '+virtenv_path+' /root/lttngvenv')
    command['parameters']['commands'].append('sync')

    return command

def main():
    test_type = None
    parser = argparse.ArgumentParser(description='Launch baremetal test using Lava')
    parser.add_argument('-t', '--type', required=True)
    parser.add_argument('-j', '--jobname', required=True)
    parser.add_argument('-k', '--kernel', required=True)
    parser.add_argument('-km', '--kmodule', required=True)
    parser.add_argument('-lm', '--lmodule', required=True)
    parser.add_argument('-l', '--lava-key', required=True)
    parser.add_argument('-tc', '--tools-commit', required=True)
    parser.add_argument('-uc', '--ust-commit', required=False)
    args = parser.parse_args()

    if args.type in 'benchmarks':
        test_type = TestType.benchmarks
    elif args.type in 'tests':
        test_type = TestType.tests
    else:
        print('argument -t/--type {} unrecognized. Exiting...'.format(args.type))
        return -1

    if test_type is TestType.benchmarks:
        j = create_new_job(args.jobname, build_device='x86')
        j['actions'].append(get_deploy_cmd_x86(args.jobname, args.kernel, args.kmodule, args.lmodule))
    elif test_type  is TestType.tests:
        j = create_new_job(args.jobname, build_device='kvm')
        j['actions'].append(get_deploy_cmd_kvm(args.jobname, args.kernel, args.kmodule, args.lmodule))

    j['actions'].append(get_boot_cmd())

    if test_type is TestType.benchmarks:
        j['actions'].append(get_config_cmd('x86'))
        j['actions'].append(get_env_setup_cmd('x86', args.tools_commit))
        j['actions'].append(get_benchmarks_cmd())
        j['actions'].append(get_results_cmd(stream_name='benchmark-kernel'))
    elif test_type  is TestType.tests:
        if args.ust_commit is None:
            print('Tests runs need -uc/--ust-commit options. Exiting...')
            return -1
        j['actions'].append(get_config_cmd('kvm'))
        j['actions'].append(get_env_setup_cmd('kvm', args.tools_commit, args.ust_commit))
        j['actions'].append(get_tests_cmd())
        j['actions'].append(get_results_cmd(stream_name='tests-kernel'))
    else:
        assert False, 'Unknown test type'

    server = xmlrpclib.ServerProxy('http://%s:%s@%s/RPC2' % (USERNAME, args.lava_key, HOSTNAME))

    jobid = server.scheduler.submit_job(json.dumps(j))

    print('Lava jobid:{}'.format(jobid))

    #Check the status of the job every 30 seconds
    jobstatus = server.scheduler.job_status(jobid)['job_status']
    while jobstatus in 'Submitted' or jobstatus in 'Running':
        time.sleep(30)
        jobstatus = server.scheduler.job_status(jobid)['job_status']

    passed, failed=check_job_all_test_cases_state_count(server, jobid)

    if test_type is TestType.tests:
        print_test_output(server, jobid)

    print('Job ended with {} status.'.format(jobstatus))
    if jobstatus not in 'Complete':
        return -1
    else:
        print('With {} passed and {} failed Lava test cases.'.format(passed, failed))

    if failed == 0:
        return 0
    else:
        return -1

if __name__ == "__main__":
    sys.exit(main())
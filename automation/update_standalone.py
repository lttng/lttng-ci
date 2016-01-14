#!/usr/bin/python
# -*- coding: utf-8 -*-
#
# Copyright (C) 2015 - Michael Jeanson <mjeanson@efficios.com>
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

""" This script is used to upgrade the base snapshot of standalone ci slaves """

USERNAME = ''
APIKEY = ''
JENKINS_URL = 'https://ci.lttng.org'

DISTRO_LIST = ['el', 'sles', 'ubuntu']
DEFAULT_DISTRO = 'ubuntu'
DISTRO_COMMAND = {
    'el': 'yum update -y && package-cleanup -y --oldkernels --count=2 && yum clean all',
    'sles': 'zypper --non-interactive refresh && zypper --non-interactive patch --auto-agree-with-licenses --with-interactive',
    'ubuntu': 'apt-get update && apt-get dist-upgrade -V -y && apt-get clean && apt-get --purge autoremove -y',
}

BASESNAP = 'base-configuration'

SNAPSHOTXML = """
<domainsnapshot>
  <name>%s</name>
  <description>Snapshot of OS install and updates</description>
  <memory snapshot='no'/>
</domainsnapshot>
""" % BASESNAP

import argparse
import sys
import libvirt
from jenkinsapi.jenkins import Jenkins
from time import sleep
import paramiko
import select


def main():
    """ Main """

    parser = argparse.ArgumentParser(description='Update base snapshot.')
    parser.add_argument('instance_name', metavar='INSTANCE', type=str,
                        help='the shortname of the instance to update')
    parser.add_argument('vmhost_name', metavar='VMHOST', type=str,
                        help='the hostname of the VM host')
    parser.add_argument('--distro', choices=DISTRO_LIST,
                        default=DEFAULT_DISTRO, type=str,
                        help='the distro of the target instance')

    args = parser.parse_args()

    instance_name = args.instance_name
    vmhost_name = args.vmhost_name
    distro = args.distro


    # Get jenkibs connexion
    jenkins = Jenkins(JENKINS_URL, username=USERNAME, password=APIKEY)

    # Get jenkins node
    print("Getting node %s from Jenkins..." % instance_name)
    node = jenkins.get_node(instance_name)

    if not node:
        print("Could not get node %s on %s" % (instance_name, JENKINS_URL))
        sys.exit(1)

    # Check if node is idle
    if not node.is_idle:
        print("Node %s is not idle" % instance_name)
        sys.exit(1)


    # Set node temporarily offline
    if not node.is_temporarily_offline():
        node.toggle_temporarily_offline('Down for upgrade to base snapshot')

    # Get libvirt connexion
    print("Opening libvirt connexion to %s..." % vmhost_name)
    vmhost = libvirt.open("qemu+ssh://root@%s/system" % vmhost_name)

    if not vmhost:
        print("Could not connect to libvirt on %s" % vmhost_name)
        sys.exit(1)

    # Get instance
    print("Getting instance %s from libvirt..." % instance_name)
    vminstance = vmhost.lookupByName(instance_name)

    if not vminstance:
        print("Could not get instance %s on %s" % (instance_name, vmhost_name))
        sys.exit(1)

    # If instance is running, shutdown
    print("Checking if instance %s is running..." % instance_name)
    if vminstance.isActive():
        try:
            print("Shutting down instance %s" % instance_name)
            vminstance.destroy()
        except:
            print("Failed to shutdown %s", instance_name)
            sys.exit(1)


    # Revert to base snapshot
    print("Getting base snapshot...")
    basesnap = vminstance.snapshotLookupByName(BASESNAP)
    if not basesnap:
        print("Could not find base snapshot %s" % BASESNAP)
        sys.exit(1)

    #if not basesnap.isCurrent():
    #    print("Not current snapshot")

    print("Reverting to base snapshot...")
    try:
        vminstance.revertToSnapshot(basesnap)
    except:
        print("Failed to revert to base snapshot %s" % basesnap.getName())
        sys.exit(1)

    # Launch instance
    try:
        print("Starting instance %s.." % instance_name)
        vminstance.create()
    except:
        print("Failed to start instance %s" % instance_name)
        sys.exit(1)


    # Wait for instance to boot
    print("Waiting for instance to boot...")
    sleep(10)

    # Run dist-upgrade
    print("Running upgrade command...")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.load_system_host_keys()
    client.connect(instance_name, username="root")
    stdin, stdout, stderr = client.exec_command(DISTRO_COMMAND[distro])
    while not stdout.channel.exit_status_ready():
        if stdout.channel.recv_ready():
            rl, wl, xl = select.select([stdout.channel], [], [], 0.0)
            if len(rl) > 0:
                print(stdout.channel.recv(1024)),

    if stdout.channel.recv_exit_status() != 0:
        print("Update command failed!")
        sys.exit(1)

    # Close ssh connexion
    client.close()

    # Shutdown VM
    print("Shutting down instance...")
    try:
        vminstance.shutdown()
    except:
        print("Failed to shutdown instance %s" % instance_name)
        sys.exit(1)

    while vminstance.isActive():
        sleep(1)
        print("Waiting for instance to shutdown...")

    # Delete original base snapshot
    print("Deleting current base snapshot...")
    try:
        basesnap.delete()
    except:
        print("Failed to delete base snapshot %s" % basesnap.getName())
        sys.exit(1)

    # Create new base snapshot
    print("Creating new base snapshot...")
    try:
        vminstance.snapshotCreateXML(SNAPSHOTXML)
    except:
        print("Failed to create new snapshot.")
        sys.exit(1)

    # Set node online in jenkins
    if node.is_temporarily_offline():
        node.toggle_temporarily_offline()

    # And we're done!
    print("All done!")


if __name__ == "__main__":
    main()

# EOF

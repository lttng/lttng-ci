# Setup

1. Install system requirements

    apt install python3-pip

2. Install project dependencies

    pip3 install --user requirements.txt # --break-system-packages
    # Note: --break-system-packages is required on recent Debian versions

3. (Optional) Install mitogen on Debian/Ubuntu:

    apt install ansible-mitogen

4. Install required ansible collections

    ansible-galaxy install -r roles/requirements.yml

5. Install the Bitwarden command-line client

## Privileged data

Privileged data is stored in Bitwarden. To use roles that fetch privileged data,
the following utilities must be available:

* [bw](https://bitwarden.com/help/cli/)

Once installed, login and unlock the vault:

```
bw login # or, `bw unlock`
export BW_SESSION=xxxx
bw sync -f
```

# Running playbooks

```
ansible-playbook -i hosts [-l SUBSET] site.yaml
```
## Tags

* access: Any user / ssh access tasks
* certs: Any certificate deployment and renewal tasks
* monitoring: Any tasks related to installing or configuring monitoring services
* slow: Any tasks that may take a long time

### Example: Skip slow tasks

`ansible-playbook --skip-tags slow`

### Example: Only manage users/SSH keys

`ansible-playbook -t access`

# Bootstrapping hosts

## CI host

### Debian

1. Boot host with PXE
2. Select the option `Debian Bookworm amd64 (CI-host)` or equivalent
3. Post-preseed verifications:
  * Check that start-stop-daemon is available in `$PATH`. If not: `touch /sbin/start-stop-daemon; chmod +x /sbin/start-stop-daemon ; apt-get install --reinstall dpkg`
  * Verify that the ZFS pool `tank` exists on the target host. If not, create it e.g. `zpool create -f tank mirror dev1 dev2`
4. Add the host to the ansible inventory in the hosts group and in the appropriate cluster group
5. For LXD hosts, add the host to the `lxd` group
6. Follow the appropriate LXD or Incus cluster steps

### Windows

1. Configure either SSH or WinRM connection: see https://docs.ansible.com/ansible/latest/os_guide/windows_setup.html
2. For arm64 hosts:
  * Install the necessary optional features (eg. OpenSSH, Hyper-V) since Windows RSAT isn't available on Arm64 yet

## CI 'rootnode'

1. Add the new ansible node to the `node_standalone` group in the inventory
2. Add an entry to the `vms` variable in the host vars for the libvirt host
  * See the defaults and details in `roles/libvirt/vars/main.yml` and `roles/libvirt/tasks/main.yml`
  * Make sure to set the `cdrom` key to the path of ISO for the installer
3. Run the playbook, eg. `ansible-playbook -i hosts -l cloud07.internal.efficios.com site.yml`
  * The VM should be created and started
4. Once the VM is installed take a snapshot so that Jenkins may revert to the original state
  * `ansible-playbook playbooks/snapshot-rootnode.yml -e '{"revert_before": false}' -l new-rootnode`

### Ubuntu auto-installer

1. Note your IP address
2. Switch to the directory with the user-data files: `cd roles/libvirt/files`
3. Write out the instance-specific metadata, eg.

```
cat > meta-data <<EOF
instance-id: iid-XXX
hostname: XXX.internal.efficios.com
EOF
```
  * The instance-id is used to determine if re-installation is necessary.
4. Start a python web server: `python3 -m http.server 3003`
5. Connect to the VM using a remote viewer on the address given by `virsh --connect qemu+ssh://root@host/system domdisplay`
6. Edit the grub boot options for the installer and append the following as arguments for the kernel: `autoinstall 'ds=nocloud-net;s=http://IPADDRESS:3003/'` and boot the installer
  * Note that the trailing `/` and quoting are important
  * The will load the `user-data`, `meta-data`, and `vendor-data` files in the directory served by the python web server
7. After the installation is complete, the system will reboot and run cloud-init for the final portion of the initial setup. Once completed, ansible can be run against it using the ubuntu user and becoming root, eg. `ansible-playbook -i hosts -u ubuntu -b ...`

# LXD Cluster

## Start a new cluster

1. For the initial member of the cluster, set the `lxd_cluster` variable in the host variables to something similar to:

```
lxd_cluster:
  server_name: cluster-member-name
  enabled: true
  member_config:
    - entity: storage-pool
      name: default
      key: source
      value: tank/lxd
```

2. Run the `site.yml` playbook on the node
3. Verify that storage pool is configured:

```
$ lxc storage list
| name    | driver | state   |
| default | zfs    | created |
```

  * If not present, create it on necessary targets:

```
$ lxc storage create default zfs source=tank/lxd --target=cluster-member-name
# Repeat for any other members
# Then, on the member itself
$ lxc storage create default zfs
# The storage listed should not be in the 'pending' state
```

4. Create a metrics certificate pair for the cluster, or use an existing one

```
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -sha384 -keyout metrics.key -nodes -out metrics.crt -days 3650 -subj "/CN=metrics.local"
lxc config trust add metrics.crt --type=metrics
```

## Adding a new host

2. In the member's host_vars file set the following keys:
1. On the existing host or cluster, generate a token for the new member: `lxc cluster add member-host-name`
  * `lxd_cluster_ip`: The IP address on which the server will listen
  * `lxd_cluster`: In a fashion similar to the following entry
```
lxd_cluster:
  enabled: true
  # Same as the name from the token created above
  server_name: 'member-host-name'
  # This shoud match `lxd_cluster_ip`
  server_address: 172.18.0.192
  cluster_token: 'xxx'
  member_config:
    - entity: storage-pool
      name: default
      key: source
      value: tank/lxd
```
  * The `cluster_token` does not need to be kept in git after the the playbook's first run
3. Assuming the member is in the host's group of the inventory, run the `site.yml` playbook.

## Managing instances

Local requirements:

 * python3, python3-dnspython, python3-jenkins, samba-tool, kinit

To automatically provision instances, perform certain operations, and update DNS entries:

1. Update `vars/ci-instances.yml`
2. Open a kerberos ticket with `kinit`
  * If samba-tool doesn't pick up on the ticket, you may need to 'client use kerberos = required' in `/etc/samba/smb.conf`
3. Run the playbook, eg. `ansible-playbook playbooks/ci-instances.yml`

# Incus cluster

## Migration from LXD

1. Run the `site.yml` playbook on the hosts to install `incus` and `incus-tools`
2. On one cluster member, start the `lxd-to-incus` script, and follow the prompts
3. On each other cluster member, start `lxd-to-incus --cluster-member`
4. When prompted on each cluster member, uninstall `lxd`.

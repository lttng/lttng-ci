# Setup on Ubuntu

```
apt install ansible ansible-mitogen
```

# Required collections

```
ansible-galaxy install -r roles/requirements.yml
```

# Privileged data

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

# Bootstrapping hosts

## Windows

1. Configure either SSH or WinRM connection: see https://docs.ansible.com/ansible/latest/os_guide/windows_setup.html
2. For arm64 hosts:
  * Install the necessary optional features (eg. OpenSSH, Hyper-V) since Windows RSAT isn't available on Arm64 yet

## CI 'rootnode'

1. Add an entry to the `vms` variable in the host vars for a libvirt host
  * See the defaults and details in `roles/libvirt/vars/main.yml` and `roles/libvirt/tasks/main.yml`
  * Make sure to set the `cdrom` key to the path of ISO for the installer
2. Run the playbook, eg. `ansible-playbook -i hosts -l cloud07.internal.efficios.com site.yml`
  * The VM should be created and started
3. Once the VM is installed take a snapshot so that Jenkins may revert to the original state

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

# Required collections

```
ansible-galaxy collection install community.general
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

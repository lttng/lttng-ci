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

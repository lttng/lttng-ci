#!/usr/bin/env bash

set -eu

# sudo -u gitdaemon git clone --mirror git://git.kernel.org/pub/scm/linux/kernel/git/rt/linux-rt-devel.git

update_git() {
    local repodir="$1"
    local origin="$2"

    if [ ! -d "${repodir}" ] ; then
        git clone --mirror "${origin}" "${repodir}"
    fi

    pushd "$repodir"

    git remote update
    #git gc
    mkdir -p info/web
    git for-each-ref --sort=-committerdate --format='%(committerdate:iso8601)' --count=1 >info/web/last-modified

    popd
}

##
# Vanilla composite repo
##

update_git linux-all.git/ https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git

pushd linux-all.git/
## Add stable if needed
if ! git remote | grep -q stable ; then
    git remote add stable https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
    git fetch stable
fi
## Delete broken tree tags
git tag -d v2.6.11 || true
git tag -d v2.6.11-tree || true
popd

##
# EL kernel RPMs
##
update_git rocky.git/ https://git.rockylinux.org/staging/rpms/kernel.git

##
# SLES kernels
##
update_git sles.git/ https://github.com/SUSE/kernel.git

##
# Ubuntu kernels
##

update_git ubuntu-jammy.git/ git://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/jammy

update_git ubuntu-noble.git/ git://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/noble

##
# GDB repos
##

update_git binutils-gdb.git/ git://sourceware.org/git/binutils-gdb.git

##
# Glibc repos
##

update_git glibc.git/ git://sourceware.org/git/glibc.git

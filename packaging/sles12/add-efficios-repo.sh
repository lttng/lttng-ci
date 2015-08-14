#/bin/sh

zypper --non-interactive addrepo https://packages.efficios.com/repo.files/EfficiOS-SLE12-x86-64.repo

rpmkeys --import https://packages.efficios.com/sle/repo.key

zypper --non-interactive refresh

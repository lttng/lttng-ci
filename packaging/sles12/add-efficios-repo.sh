#/bin/sh

zypper --non-interactive addrepo http://packages.efficios.com/repo.files/EfficiOS-SLE12-x86-64.repo

rpmkeys --import http://packages.efficios.com/sle/repo.key

zypper --non-interactive refresh

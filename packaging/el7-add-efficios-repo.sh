#/bin/sh

yum -y install wget

wget -P /etc/yum.repos.d/ http://packages.efficios.com/repo.files/EfficiOS-RHEL7-x86-64.repo

rpmkeys --import http://packages.efficios.com/rhel/repo.key

yum updateinfo

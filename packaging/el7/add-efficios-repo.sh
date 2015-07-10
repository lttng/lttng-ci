#/bin/sh

yum -y install wget

wget -P /etc/yum.repos.d/ https://packages.efficios.com/repo.files/EfficiOS-RHEL7-x86-64.repo

rpmkeys --import https://packages.efficios.com/rhel/repo.key

yum updateinfo

#!/bin/bash -ex
#
# Copyright (C) 2016 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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

PYTHON_2_ENV=$WORKSPACE"/.python2_venv"
PYTHON_3_ENV=$WORKSPACE"/.python3_venv"

# Prepare JJB python 2 environment
set -x
if [ ! -d "$PYTHON_2_ENV" ]; then
	virtualenv -p python2 $PYTHON_2_ENV
fi
set +x

. $PYTHON_2_ENV/bin/activate
pip install --force-reinstall git+git://github.com/mjeanson/jenkins-job-builder@ci
deactivate

# Prepare python 3 env
if [ ! -d "$PYTHON_3_ENV" ]; then
	virtualenv -p python3 $PYTHON_3_ENV
fi

. $PYTHON_3_ENV/bin/activate
pip install --upgrade gitpython pyyaml
deactivate

# Prepare the configuration file for jjb
cp $WORKSPACE/etc/jenkins_jobs.ini-sample $WORKSPACE/etc/jenkins_jobs.ini

# Set +x: hide information from the jenkins console log since we use injected
# secrets
set +x
sed -i -e "s/user=jenkins/user=$JJB_JENKINS_USER/g" $WORKSPACE/etc/jenkins_jobs.ini
sed -i -e "s/password=1234567890abcdef1234567890abcdef/password=$JJB_JENKINS_TOKEN/g" $WORKSPACE/etc/jenkins_jobs.ini
set -x

#Prepare the kernel
if [ ! -d "$WORKSPACE/kernel" ]; then
	git clone git://artifacts.internal.efficios.com/git/linux-stable.git $WORKSPACE/kernel
else
	pushd $WORKSPACE/kernel
	git fetch --tags origin
	popd
fi

# Clean the previous rc
# Note: this step is stateful since it use the last generated version.
. $PYTHON_2_ENV/bin/activate
jenkins-jobs --conf $WORKSPACE/etc/jenkins_jobs.ini delete --path $WORKSPACE/jobs/lttng-modules.yaml:$WORKSPACE/jobs/kernel.yaml \*rc\*_build
deactivate

# Run the kernel seed generator
. $PYTHON_3_ENV/bin/activate
python $WORKSPACE/automation/kernel-seed.py --kernel-path $WORKSPACE/kernel --kernel-cutoff 2.6.36 > $WORKSPACE/jobs/inc/kernel-versions.yaml.inc
deactivate

. $PYTHON_2_ENV/bin/activate
jenkins-jobs --conf $WORKSPACE/etc/jenkins_jobs.ini update $WORKSPACE/jobs/lttng-modules.yaml:$WORKSPACE/jobs/kernel.yaml
deactivate

# Flush the configuration file so no one can access it
rm -f $WORKSPACE/etc/jenkins_jobs.ini
# EOF

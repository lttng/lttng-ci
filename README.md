# LTTng configuration for Jenkins

This repository holds the configuration of the LTTng Jenkins jobs. It is
meant to be used with Jenkins Job Builder from the OpenStack Foundation.

    $ virtualenv -p python2 .venv
    $ . .venv/bin/activate
    $ pip install jenkins-job-builder


## Example Usage

Generate XML files for Jenkins jobs from YAML files:

    $ jenkins-jobs test jobs/ -o output/

Update Jenkins jobs which name starts with "babeltrace":

    $ jenkins-jobs --conf etc/jenkins_jobs.ini update jobs/ babeltrace*


## Updating kernel and modules jobs

    # Delete current RC jobs
    $ jenkins-jobs --conf etc/jenkins_jobs.ini delete --path jobs/lttng-modules.yaml:jobs/kernel.yaml \*rc\*_build

    # Update kernel versions
    $ automation/kernel-seed.py > jobs/inc/kernel-versions.yaml.inc

    # Update jobs
    $ jenkins-jobs --conf etc/jenkins_jobs.ini update jobs/lttng-modules.yaml:jobs/kernel.yaml

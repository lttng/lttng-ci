# LTTng configuration for Jenkins

This repository holds the configuration of the LTTng Jenkins jobs. It is
meant to be used with Jenkins Job Builder from the OpenStack Foundation.

The dependencies can be installed in a dedicated Python virtual
environment using [Poetry](https://python-poetry.org/):

    $ poetry install

You can then run commands from the virtual environments by prepending
`poetry run` to them:

    $ poetry run jenkins-jobs --version
    Jenkins Job Builder version: 6.4.2

or by spawning a shell:

    $ poetry shell
    Spawning shell within /home/user/.cache/pypoetry/virtualenvs/lttng-ci-qYTnEJGo-py3.12
    (lttng-ci-py3.12) $ jenkins-jobs --version
    Jenkins Job Builder version: 6.4.2

Install [pre-commit](https://pre-commit.com) hooks with:

    $ pre-commit install

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

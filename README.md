# LTTng configuration for Jenkins

This repository holds the configuration of the LTTng Jenkins jobs. It is
meant to be used with Jenkins Job Builder from the OpenStack Foundation.

## Example Usage

Generate XML files for Jenkins jobs from YAML files:

    $ jenkins-jobs test jobs/ -o output/

Update Jenkins jobs which name starts with "babeltrace":

    $ jenkins-jobs --conf etc/jenkins_jobs.ini update jobs/ babeltrace*

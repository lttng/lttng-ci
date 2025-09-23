/**
 * SPDX-FileCopyrightText: 2017 Francis Deslauriers <francis.deslauriers@efficios.com>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import hudson.console.HyperlinkNote
import hudson.model.*
import java.io.File
import org.eclipse.jgit.api.Git
import org.eclipse.jgit.lib.Ref

class InvalidKVersionException extends Exception {
  public InvalidKVersionException(String message) {
    super(message)
  }
}

class EmptyKVersionException extends Exception {
  public EmptyKVersionException(String message) {
    super(message)
  }
}

class VanillaKVersion implements Comparable<VanillaKVersion> {

  Integer major = 0
  Integer majorB = 0
  Integer minor = 0
  Integer patch = 0
  Integer rc = Integer.MAX_VALUE
  Boolean inStable = false;

  VanillaKVersion() {}

  VanillaKVersion(version) {
    this.parse(version)
  }

  static VanillaKVersion minKVersion() {
    return new VanillaKVersion("v0.0.0")
  }

  static VanillaKVersion maxKVersion() {
    return new VanillaKVersion("v" + Integer.MAX_VALUE + ".0.0")
  }

  static VanillaKVersion factory(version) {
    return new VanillaKVersion(version)
  }

  def parse(version) {
    this.major = 0
    this.majorB = 0
    this.minor = 0
    this.patch = 0
    this.rc = Integer.MAX_VALUE

    if (!version) {
      throw new EmptyKVersionException("Empty kernel version")
    }

    def match = version =~ /^v(\d+)\.(\d+)(\.(\d+))?(\.(\d+))?(-rc(\d+))?$/
    if (!match) {
      throw new InvalidKVersionException("Invalid kernel version: ${version}")
    }

    Integer offset = 0;

    // Major
    this.major = Integer.parseInt(match.group(1))
    if (this.major <= 2) {
      offset = 2
      this.majorB = Integer.parseInt(match.group(2))
    }

    // Minor
    if (match.group(2 + offset) != null) {
      this.minor = Integer.parseInt(match.group(2 + offset))
    }

    // Patch level
    if (match.group(4 + offset) != null) {
      this.patch = Integer.parseInt(match.group(4 + offset))
      this.inStable = true
    }

    // RC
    if (match.group(8) != null) {
      this.rc = Integer.parseInt(match.group(8))
    }
  }

  Boolean isInStableBranch() {
    return this.inStable
  }

  // Return true if both version are of the same stable branch
  Boolean isSameStable(VanillaKVersion o) {
    if (this.major != o.major) {
      return false
    }
    if (this.majorB != o.majorB) {
      return false
    }
    if (this.minor != o.minor) {
      return false
    }

    return true
  }

  @Override int compareTo(VanillaKVersion o) {
    if (this.major != o.major) {
      return Integer.compare(this.major, o.major)
    }
    if (this.majorB != o.majorB) {
      return Integer.compare(this.majorB, o.majorB)
    }
    if (this.minor != o.minor) {
      return Integer.compare(this.minor, o.minor)
    }
    if (this.patch != o.patch) {
      return Integer.compare(this.patch, o.patch)
    }
    if (this.rc != o.rc) {
      return Integer.compare(this.rc, o.rc)
    }

    // Same version
    return 0;
  }

  String toString() {
    String vString = "v${this.major}"

    if (this.majorB > 0) {
      vString = vString.concat(".${this.majorB}")
    }

    vString = vString.concat(".${this.minor}")

    if (this.patch > 0) {
      vString = vString.concat(".${this.patch}")
    }

    if (this.rc > 0 && this.rc < Integer.MAX_VALUE) {
      vString = vString.concat("-rc${this.rc}")
    }
    return vString
  }
}

// Save the hashmap containing all the jobs and their status to disk. We can do
// that because this job is configured to always run on the master node on
// Jenkins.
def SaveCurrentJobsToWorkspace = { currentJobs, ondiskpath->
  try {
    File myFile = new File(ondiskpath);
    myFile.createNewFile();
    def out = new ObjectOutputStream(new FileOutputStream(ondiskpath))
    out.writeObject(currentJobs)
    out.close()
  } catch (e) {
    println("Failed to save previous Git object IDs to disk." + e);
  }
}

// Load the hashmap containing all the jobs and their last status from disk.
// It's possible because this job is configured to always run on the master
// node on Jenkins
def LoadPreviousJobsFromWorkspace = { ondiskpath ->
  def previousJobs = [:]
  try {
    File myFile = new File(ondiskpath);
    def input = new ObjectInputStream(new FileInputStream(ondiskpath))
    previousJobs = input.readObject()
    input.close()
  } catch (e) {
    println("Failed to load previous runs from disk." + e);
  }
  return previousJobs
}


def GetHeadCommits = { remoteRepo, branchesOfInterest ->
  def remoteHeads = [:]
  def remoteHeadRefs = Git.lsRemoteRepository()
                          .setTags(false)
                          .setHeads(true)
                          .setRemote(remoteRepo).call()

  remoteHeadRefs.each {
    def branch = it.getName().replaceAll('refs/heads/', '')
    if (branchesOfInterest.contains(branch))
      remoteHeads[branch] = it.getObjectId().name()
  }

  return remoteHeads
}

def GetTagIds = { remoteRepo ->
  def remoteTags = [:]
  def remoteTagRefs = Git.lsRemoteRepository()
                         .setTags(true)
                         .setHeads(false)
                         .setRemote(remoteRepo).call()

  remoteTagRefs.each {
    // Exclude release candidate tags
    if (!it.getName().contains('-rc')) {
      remoteTags[it.getName().replaceAll('refs/tags/', '')] = it.getObjectId().name()
    }
  }

  return remoteTags
}

def GetLastTagOfBranch = { tagRefs, branch ->
  def tagVersions = tagRefs.collect {new VanillaKVersion(it.key)}
  def currMax = new VanillaKVersion('v0.0.0');
  if (!branch.contains('master')){
    def targetVersion = new VanillaKVersion(branch.replaceAll('linux-', 'v').replaceAll('.y', ''))
    tagVersions.each {
      if (it.isSameStable(targetVersion)) {
        if (currMax < it) {
          currMax = it;
        }
      }
    }
  } else {
    tagVersions.each {
      if (!it.isInStableBranch() && currMax < it) {
        currMax = it;
      }
    }
  }
  return currMax.toString()
}

// Returns the latest tags of each of the branches passed in the argument
def GetLastTagIds = { remoteRepo, branchesOfInterest ->
  def remoteHeads = GetHeadCommits(remoteRepo, branchesOfInterest)
  def remoteTagRefs = GetTagIds(remoteRepo)
  def remoteLastTagCommit = [:]

  remoteTagRefs = remoteTagRefs.findAll { !it.key.contains("v2.") }
  branchesOfInterest.each {
    remoteLastTagCommit[it] = remoteTagRefs[GetLastTagOfBranch(remoteTagRefs, it)]
  }

  return remoteLastTagCommit
}

def CraftJobName = { jobType, linuxBranch, lttngBranch ->
  return "${jobType}_k${linuxBranch}_l${lttngBranch}"
}

def LaunchJob = { jobName, jobInfo ->
  def job = Hudson.instance.getJob(jobName)
  if (job == null) {
    println(String.format("Failed to find job by name '%s'", jobName))
    return null;
  }
  def params = []
  for (paramdef in job.getProperty(ParametersDefinitionProperty.class).getParameterDefinitions()) {
    // If there is a default value for this parameter, use it. Don't use empty
    // default value parameters.
    if (paramdef.getDefaultParameterValue() != null) {
      params += paramdef.getDefaultParameterValue();
    }
  }

  params.add(new StringParameterValue('LTTNG_TOOLS_COMMIT_ID', jobInfo['config']['toolsCommit']))
  params.add(new StringParameterValue('LTTNG_MODULES_COMMIT_ID', jobInfo['config']['modulesCommit']))
  params.add(new StringParameterValue('LTTNG_UST_COMMIT_ID', jobInfo['config']['ustCommit']))
  params.add(new StringParameterValue('KERNEL_COMMIT_ID', jobInfo['config']['linuxCommit']))
  def currBuild = job.scheduleBuild2(0, new Cause.UpstreamCause(build), new ParametersAction(params))

  if (currBuild != null ) {
    println("Launching job: ${HyperlinkNote.encodeTo('/' + job.url, job.fullDisplayName)}");
  } else {
    println("Job ${jobName} not found or deactivated.");
  }

  return currBuild
}

final String toolsRepo = "https://github.com/lttng/lttng-tools.git"
final String modulesRepo = "https://github.com/lttng/lttng-modules.git"
final String ustRepo = "https://github.com/lttng/lttng-ust.git"
final String linuxRepo = "git://git-mirror.internal.efficios.com/kernel/stable/linux.git"

final String pastJobsPath = build.getEnvironment(listener).get('WORKSPACE') + "/pastjobs";

def recentLttngBranchesOfInterest = [
  'master',
  'stable-2.14',
  'stable-2.13',
]

def recentLinuxBranchesOfInterest = [
  'master',
  'linux-6.12.y',
  'linux-6.6.y',
  'linux-6.1.y',
  'linux-5.15.y',
  'linux-5.10.y',
  'linux-4.4.y',
]

def legacyLttngBranchesOfInterest = [
  'stable-2.12',
]

def legacyLinuxBranchesOfInterest = [
    'linux-5.15.y',
    'linux-5.10.y',
    'linux-4.4.y',
]

def vmLinuxBranchesOfInterest = []

// Generate configurations of interest.
def configurationOfInterest = [] as Set

recentLttngBranchesOfInterest.each { lttngBranch ->
  recentLinuxBranchesOfInterest.each { linuxBranch ->
    configurationOfInterest.add([lttngBranch, linuxBranch])
  }
}

legacyLttngBranchesOfInterest.each { lttngBranch ->
  legacyLinuxBranchesOfInterest.each { linuxBranch ->
    configurationOfInterest.add([lttngBranch, linuxBranch])
  }
}

def lttngBranchesOfInterest = recentLttngBranchesOfInterest + legacyLttngBranchesOfInterest
def linuxBranchesOfInterest = recentLinuxBranchesOfInterest + legacyLinuxBranchesOfInterest + vmLinuxBranchesOfInterest

// For LTTng branches, we look for new commits.
def toolsHeadCommits = GetHeadCommits(toolsRepo, lttngBranchesOfInterest)
def modulesHeadCommits = GetHeadCommits(modulesRepo, lttngBranchesOfInterest)
def ustHeadCommits = GetHeadCommits(ustRepo, lttngBranchesOfInterest)

// For Linux branches, we look for new non-RC tags.
def linuxLastTagIds = GetLastTagIds(linuxRepo, linuxBranchesOfInterest)

def CraftConfig = { linuxBr, lttngBr ->
  def job = [:];
  job['config'] = [:];
  job['config']['linuxBranch'] = linuxBr;
  job['config']['lttngBranch'] = lttngBr;
  job['config']['linuxCommit'] = linuxLastTagIds[linuxBr];
  job['config']['toolsCommit'] = toolsHeadCommits[lttngBr];
  job['config']['modulesCommit'] = modulesHeadCommits[lttngBr];
  job['config']['ustCommit'] = ustHeadCommits[lttngBr];
  job['status'] = 'NOT_SET';
  job['build'] = null;
  return job;
}

// Check what type of jobs should be triggered.
triggerJobName = build.project.getFullDisplayName();
if (triggerJobName.contains("vm_tests")) {
  jobType = 'vm_tests';
  recentLttngBranchesOfInterest.each { lttngBranch ->
    vmLinuxBranchesOfInterest.each { linuxBranch ->
      configurationOfInterest.add([lttngBranch, linuxBranch])
    }
  }
} else if (triggerJobName.contains("baremetal_tests")) {
  jobType = 'baremetal_tests';
}

// Hashmap containing all the jobs, their configuration (commit id, etc. )and
// their status (SUCCEEDED, FAILED, etc.). This Hashmap is made of basic strings
// rather than objects and enums because strings are easily serializable.
def currentJobs = [:];

// Get an up to date view of all the branches of interest.
configurationOfInterest.each { lttngBr, linuxBr  ->
  def jobName = CraftJobName(jobType, linuxBr, lttngBr);
  currentJobs[jobName] = CraftConfig(linuxBr, lttngBr);
}

// Add canary job
def jobNameCanary = jobType + "_kcanary_lcanary";
currentJobs[jobNameCanary] = [:];
currentJobs[jobNameCanary]['config'] = [:];
currentJobs[jobNameCanary]['config']['linuxBranch'] = 'v5.15.112';
currentJobs[jobNameCanary]['config']['lttngBranch'] = 'v2.13.9';
currentJobs[jobNameCanary]['config']['linuxCommit'] ='9d6bde853685609a631871d7c12be94fdf8d912e'; // v5.15.112
currentJobs[jobNameCanary]['config']['toolsCommit'] = '2ff0385718ff894b3d0e06f3961334c20c5436f8' // v2.13.9
currentJobs[jobNameCanary]['config']['modulesCommit'] = 'da1f5a264fff33fc5a9518e519fb0084bf1074af' // v2.13.9
currentJobs[jobNameCanary]['config']['ustCommit'] = 'de624c20694f69702b42c5d47b5bcf692293a238' // v2.13.5
currentJobs[jobNameCanary]['status'] = 'NOT_SET';
currentJobs[jobNameCanary]['build'] = null;

def pastJobs = LoadPreviousJobsFromWorkspace(pastJobsPath);

def failedRuns = []
def abortedRuns = []
def isFailed = false
def isAborted = false
def ongoingJobs = 0;

currentJobs.each { jobName, jobInfo ->
  // If the job ran in the past, we check if the IDs changed since.
  // Fetch past results only if the job is not of type canary.
  if (!jobName.contains('_kcanary_lcanary') && pastJobs.containsKey(jobName) &&
         build.getBuildVariables().get('FORCE_JOB_RUN') == 'false') {
    pastJob = pastJobs[jobName];

    // If the code has not changed report previous status.
    if (pastJob['config'] == jobInfo['config']) {
      // if the config has not changed, we keep it.
      // if it's failed, we don't launch a new job and keep it failed.
      jobInfo['status'] = pastJob['status'];
      if (pastJob['status'] == 'FAILED' &&
            build.getBuildVariables().get('FORCE_FAILED_JOB_RUN') == 'false') {
        println("${jobName} as not changed since the last failed run. Don't run it again.");
        // Marked the umbrella job for failure but still run the jobs that since the
        // last run.
        isFailed = true;
        return;
      } else if (pastJob['status'] == 'ABORTED') {
        println("${jobName} as not changed since last aborted run. Run it again.");
      } else if (pastJob['status'] == 'SUCCEEDED') {
        println("${jobName} as not changed since the last successful run. Don't run it again.");
        return;
      }
    }
  }

  jobInfo['status'] = 'PENDING';
  jobInfo['build'] = LaunchJob(jobName, jobInfo);
  if (jobInfo['build'] != null) {
    ongoingJobs += 1;
  }
}

// Some jobs may have a null build immediately if LaunchJob
// failed for some reason, those jobs can immediately be removed.
def jobKeys = currentJobs.collect { jobName, jobInfo ->
    return jobName;
}
jobKeys.each { k ->
  if (currentJobs.get(k)['build'] == null) {
    println(String.format("Removing job '%s' since build is null", k));
    currentJobs.remove(k);
  }
}

while (ongoingJobs > 0) {
  currentJobs.each { jobName, jobInfo ->

    if (jobInfo['status'] != 'PENDING') {
      return;
    }

    jobBuild = jobInfo['build']

    // The isCancelled() method checks if the run was cancelled before
    // execution. We consider such run as being aborted.
    if (jobBuild.isCancelled()) {
      println("${jobName} was cancelled before launch.")
      isAborted = true;
      abortedRuns.add(jobName);
      ongoingJobs -= 1;
      jobInfo['status'] = 'ABORTED'
      // Invalidate the build field, as it's not serializable and we don't need
      // it anymore.
      jobInfo['build'] = null;
    } else if (jobBuild.isDone()) {

      jobExitStatus = jobBuild.get();

      // Invalidate the build field, as it's not serializable and we don't need
      // it anymore.
      jobInfo['build'] = null;
      println("${jobExitStatus.fullDisplayName} completed with status ${jobExitStatus.result}.");

      // If the job didn't succeed, add its name to the right list so it can
      // be printed at the end of the execution.
      ongoingJobs -= 1;
      switch (jobExitStatus.result) {
      case Result.ABORTED:
        isAborted = true;
        abortedRuns.add(jobName);
        jobInfo['status'] = 'ABORTED'
        break;
      case Result.FAILURE:
        isFailed = true;
        failedRuns.add(jobName);
        jobInfo['status'] = 'FAILED'
        break;
      case Result.SUCCESS:
        jobInfo['status'] = 'SUCCEEDED'
        break;
      default:
        break;
      }
    }
  }

  // Sleep before the next iteration.
  try {
    Thread.sleep(30000)
  } catch(e) {
    if (e in InterruptedException) {
      build.setResult(hudson.model.Result.ABORTED)
      throw new InterruptedException()
    } else {
      throw(e)
    }
  }
}

//All jobs are done running. Save their exit status to disk.
SaveCurrentJobsToWorkspace(currentJobs, pastJobsPath);

// Get log of failed runs.
if (failedRuns.size() > 0) {
  println("Failed job(s):");
  for (failedRun in failedRuns) {
    println("\t" + failedRun)
  }
}

// Get log of aborted runs.
if (abortedRuns.size() > 0) {
  println("Cancelled job(s):");
  for (cancelledRun in abortedRuns) {
    println("\t" + cancelledRun)
  }
}

// Mark this build as Failed if atleast one child build has failed and mark as
// aborted if there was no failure but atleast one job aborted.
if (isFailed) {
  build.setResult(hudson.model.Result.FAILURE)
} else if (isAborted) {
  build.setResult(hudson.model.Result.ABORTED)
}

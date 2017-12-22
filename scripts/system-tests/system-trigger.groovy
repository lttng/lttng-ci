/**
 * Copyright (C) 2017 - Francis Deslauriers <francis.deslauriers@efficios.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
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

class RunConfiguration {
  def linuxBranch
  def linuxTagId
  def lttngBranch
  def lttngModulesCommitId
  def lttngToolsCommitId
  def lttngUstCommitId
  RunConfiguration(linuxBranch, linuxTagId, lttngBranch, lttngToolsCommitId,
                  lttngModulesCommitId, lttngUstCommitId) {
    this.linuxBranch = linuxBranch
    this.linuxTagId = linuxTagId
    this.lttngBranch = lttngBranch
    this.lttngModulesCommitId = lttngModulesCommitId
    this.lttngToolsCommitId = lttngToolsCommitId
    this.lttngUstCommitId = lttngUstCommitId
  }

  String toString() {
    return "${this.linuxBranch}:{${this.linuxTagId}}, ${this.lttngBranch}" +
      ":{${this.lttngModulesCommitId}, ${this.lttngToolsCommitId}," +
      "${this.lttngUstCommitId}}"
  }
}

def LoadPreviousIdsFromWorkspace = { ondiskpath ->
  def previousIds = []
  try {
    File myFile = new File(ondiskpath);
    def input = new ObjectInputStream(new FileInputStream(ondiskpath))
    previousIds = input.readObject()
    input.close()
  } catch (all) {
    println("Failed to load previous ids from disk.")
  }
  return previousIds
}

def saveCurrentIdsToWorkspace = { currentIds, ondiskpath ->
  try {
    File myFile = new File(ondiskpath);
    myFile.createNewFile();
    def out = new ObjectOutputStream(new FileOutputStream(ondiskpath))
    out.writeObject(currentIds)
    out.close()
  } catch (all) {
    println("Failed to save previous ids from disk.")
  }
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

def CraftJobName = { jobType, runConfig ->
  return "${jobType}_k${runConfig.linuxBranch}_l${runConfig.lttngBranch}"
}

def LaunchJob = { jobName, runConfig ->
  def job = Hudson.instance.getJob(jobName)
  def params = []
  for (paramdef in job.getProperty(ParametersDefinitionProperty.class).getParameterDefinitions()) {
    params += paramdef.getDefaultParameterValue();
  }

  params.add(new StringParameterValue('tools_commit_id', runConfig.lttngToolsCommitId))
  params.add(new StringParameterValue('modules_commit_id', runConfig.lttngModulesCommitId))
  params.add(new StringParameterValue('ust_commit_id', runConfig.lttngUstCommitId))
  params.add(new StringParameterValue('kernel_tag_id', runConfig.linuxTagId))
  job.scheduleBuild2(0, new Cause.UpstreamCause(build), new ParametersAction(params))
  println "Launching job: ${HyperlinkNote.encodeTo('/' + job.url, job.fullDisplayName)}"
}

def jobTypes = ['baremetal_tests', 'vm_tests', 'baremetal_benchmarks']
final String toolsRepo = "https://github.com/lttng/lttng-tools.git"
final String modulesRepo = "https://github.com/lttng/lttng-modules.git"
final String ustRepo = "https://github.com/lttng/lttng-ust.git"
final String linuxRepo = "git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"

final String toolsOnDiskPath = build.getEnvironment(listener).get('WORKSPACE') + "/on-disk-tools-ref"
final String modulesOnDiskPath = build.getEnvironment(listener).get('WORKSPACE') + "/on-disk-modules-ref"
final String ustOnDiskPath = build.getEnvironment(listener).get('WORKSPACE') + "/on-disk-ust-ref"
final String linuxOnDiskPath = build.getEnvironment(listener).get('WORKSPACE') + "/on-disk-linux-ref"

def recentLttngBranchesOfInterest = ['master', 'stable-2.10', 'stable-2.9']
def recentLinuxBranchesOfInterest = ['master', 'linux-4.9.y', 'linux-4.4.y']

def legacyLttngBranchesOfInterest = ['stable-2.7']
def legacyLinuxBranchesOfInterest = ['linux-3.18.y', 'linux-4.4.y']

// Generate configurations of interest
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
def linuxBranchesOfInterest = recentLinuxBranchesOfInterest + legacyLinuxBranchesOfInterest

// For Linux branches, we look for new non-RC tags
def toolsHeadCommits = GetHeadCommits(toolsRepo, lttngBranchesOfInterest)
def modulesHeadCommits = GetHeadCommits(modulesRepo, lttngBranchesOfInterest)
def ustHeadCommits = GetHeadCommits(ustRepo, lttngBranchesOfInterest)

// For LTTng branches, we look for new commits
def linuxLastTagIds = GetLastTagIds(linuxRepo, linuxBranchesOfInterest)

// Load previously build Linux tag ids
def oldLinuxTags = LoadPreviousIdsFromWorkspace(linuxOnDiskPath) as Set

// Load previously built LTTng commit ids
def oldToolsHeadCommits = LoadPreviousIdsFromWorkspace(toolsOnDiskPath) as Set
def oldModulesHeadCommits = LoadPreviousIdsFromWorkspace(modulesOnDiskPath) as Set
def oldUstHeadCommits = LoadPreviousIdsFromWorkspace(ustOnDiskPath) as Set

def newOldLinuxTags = oldLinuxTags
def newOldToolsHeadCommits = oldToolsHeadCommits
def newOldModulesHeadCommits = oldModulesHeadCommits
def newOldUstHeadCommits = oldUstHeadCommits

def canaryRunConfigs = [] as Set
canaryRunConfigs.add(
    ['v4.4.9', '1a1a512b983108015ced1e7a7c7775cfeec42d8c', 'v2.8.1','d11e0db', '7fd9215', '514a87f'] as RunConfiguration)

def runConfigs = [] as Set

// For each top of branch kernel tags that were not seen before, schedule one
// job for each lttng/linux tracked configurations
linuxLastTagIds.each { linuxTag ->
  if (!oldLinuxTags.contains(linuxTag.value)) {
    lttngBranchesOfInterest.each { lttngBranch ->
      if (configurationOfInterest.contains([lttngBranch, linuxTag.key])) {
        runConfigs.add([linuxTag.key, linuxTag.value,
                    lttngBranch, toolsHeadCommits[lttngBranch],
                    modulesHeadCommits[lttngBranch], ustHeadCommits[lttngBranch]]
                    as RunConfiguration)

        newOldLinuxTags.add(linuxTag.value)
      }
    }
  }
}

// For each top of branch commits of LTTng-Tools that were not seen before,
// schedule one job for each lttng/linux tracked configurations
toolsHeadCommits.each { toolsHead ->
  if (!oldToolsHeadCommits.contains(toolsHead.value)) {
    linuxLastTagIds.each { linuxTag ->
      def lttngBranch = toolsHead.key
      if (configurationOfInterest.contains([lttngBranch, linuxTag.key])) {
        runConfigs.add([linuxTag.key, linuxTag.value,
                    lttngBranch, toolsHeadCommits[lttngBranch],
                    modulesHeadCommits[lttngBranch], ustHeadCommits[lttngBranch]]
                    as RunConfiguration)

        newOldToolsHeadCommits.add(toolsHead.value)
      }
    }
  }
}

// For each top of branch commits of LTTng-Modules that were not seen before,
// schedule one job for each lttng/linux tracked configurations
modulesHeadCommits.each { modulesHead ->
  if (!oldModulesHeadCommits.contains(modulesHead.value)) {
    linuxLastTagIds.each { linuxTag ->
      def lttngBranch = modulesHead.key
      if (configurationOfInterest.contains([lttngBranch, linuxTag.key])) {
        runConfigs.add([linuxTag.key, linuxTag.value,
                    lttngBranch, toolsHeadCommits[lttngBranch],
                    modulesHeadCommits[lttngBranch], ustHeadCommits[lttngBranch]]
                    as RunConfiguration)

        newOldModulesHeadCommits.add(modulesHead.value)
      }
    }
  }
}

// For each top of branch commits of LTTng-UST that were not seen before,
// schedule one job for each lttng/linux tracked configurations
ustHeadCommits.each { ustHead ->
  if (!oldUstHeadCommits.contains(ustHead.value)) {
    linuxLastTagIds.each { linuxTag ->
      def lttngBranch = ustHead.key
      if (configurationOfInterest.contains([lttngBranch, linuxTag.key])) {
        runConfigs.add([linuxTag.key, linuxTag.value,
                    lttngBranch, toolsHeadCommits[lttngBranch],
                    modulesHeadCommits[lttngBranch], ustHeadCommits[lttngBranch]]
                    as RunConfiguration)

        newOldUstHeadCommits.add(ustHead.value)
      }
    }
  }
}

// Save the tag and commit IDs scheduled in the past and during this run to the
// workspace
saveCurrentIdsToWorkspace(newOldLinuxTags, linuxOnDiskPath)
saveCurrentIdsToWorkspace(newOldToolsHeadCommits, toolsOnDiskPath)
saveCurrentIdsToWorkspace(newOldModulesHeadCommits, modulesOnDiskPath)
saveCurrentIdsToWorkspace(newOldUstHeadCommits, ustOnDiskPath)

// Launch jobs
println("Schedule canary jobs once a day")
canaryRunConfigs.each { config ->
  jobTypes.each { type ->
    LaunchJob(type + '_canary', config)
  }
}

if (runConfigs.size() > 0) {
  println("Schedule jobs because of code changes.")
  runConfigs.each { config ->
    jobTypes.each { type ->
      LaunchJob(CraftJobName(type, config), config);
    }

    // Jobs to run only on master branchs of both linux and lttng
    if (config.linuxBranch.contains('master') &&
        config.lttngBranch.contains('master')) {
      LaunchJob(CraftJobName('vm_tests_fuzzing', config), config)
    }
  }
} else {
  println("No new commit or tags, nothing more to do.")
}
/**
 * Copyright (C) 2016-2017 - Michael Jeanson <mjeanson@efficios.com>
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

import hudson.model.*
import hudson.AbortException
import hudson.console.HyperlinkNote
import java.util.concurrent.CancellationException
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
    }

    // RC
    if (match.group(8) != null) {
      this.rc = Integer.parseInt(match.group(8))
    }
  }

  // Return true if this version is a release candidate
  Boolean isRC() {
    return this.rc != Integer.MAX_VALUE
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

class UbuntuKVersion implements Comparable<UbuntuKVersion> {

  Integer major = 0
  Integer minor = 0
  Integer patch = 0
  Integer umajor = 0
  Integer uminor = 0
  String suffix = ""
  Boolean isLTS = false

  UbuntuKVersion() {}

  UbuntuKVersion(version) {
    this.parse(version)
  }

  static UbuntuKVersion minKVersion() {
    return new UbuntuKVersion("Ubuntu-lts-0.0.0-0.0")
  }

  static UbuntuKVersion maxKVersion() {
    return new UbuntuKVersion("Ubuntu-" + Integer.MAX_VALUE + ".0.0-0.0")
  }

  static UbuntuKVersion factory(version) {
    return new UbuntuKVersion(version)
  }

  def parse(version) {
    this.major = 0
    this.minor = 0
    this.patch = 0
    this.umajor = 0
    this.uminor = 0
    this.suffix = "";
    this.isLTS = false

    if (!version) {
      throw new EmptyKVersionException("Empty kernel version")
    }

    //'Ubuntu-lts-4.8.0-27.29_16.04.1',
    //'Ubuntu-4.4.0-70.91',
    def match = version =~ /^Ubuntu-(lts-)??(\d+)\.(\d+)\.(\d+)-(\d+)\.(\d+)(.*)??$/
    if (!match) {
      throw new InvalidKVersionException("Invalid kernel version: ${version}")
    }

    this.isLTS = match.group(1) != null

    // Major
    this.major = Integer.parseInt(match.group(2))

    // Minor
    this.minor = Integer.parseInt(match.group(3))

    // Patch level
    this.patch = Integer.parseInt(match.group(4))

    // Ubuntu major
    this.umajor = Integer.parseInt(match.group(5))

    // Ubuntu minor
    this.uminor = Integer.parseInt(match.group(6))

    if (match.group(7) != null) {
      this.suffix = match.group(7)
    }
  }

  // Return true if this version is a release candidate
  Boolean isRC() {
    return false
  }

  // Return true if both version are of the same stable branch
  Boolean isSameStable(UbuntuKVersion o) {
    if (this.isLTS != o.isLTS) {
      return false
    }
    if (this.major != o.major) {
      return false
    }
    if (this.minor != o.minor) {
      return false
    }
    if (this.patch != o.patch) {
      return false
    }

    return true
  }

  @Override int compareTo(UbuntuKVersion o) {
    if (this.major != o.major) {
      return Integer.compare(this.major, o.major)
    }
    if (this.minor != o.minor) {
      return Integer.compare(this.minor, o.minor)
    }
    if (this.patch != o.patch) {
      return Integer.compare(this.patch, o.patch)
    }
    if (this.umajor != o.umajor) {
      return Integer.compare(this.umajor, o.umajor)
    }
    if (this.uminor != o.uminor) {
      return Integer.compare(this.uminor, o.uminor)
    }
    if (this.isLTS != o.isLTS) {
      if (o.isLTS) {
        return 1
      } else {
        return -1
      }
    }

    // Same version
    return 0;
  }

  String toString() {
    String vString = "Ubuntu-"

    if (this.isLTS) {
      vString = vString.concat("lts-")
    }

    vString = vString.concat("${this.major}.${this.minor}.${this.patch}-${this.umajor}.${this.uminor}${this.suffix}")

    return vString
  }
}


// Retrieve parameters of the current build
def mversion = build.buildVariableResolver.resolve('mversion')
def maxConcurrentBuild = build.buildVariableResolver.resolve('maxConcurrentBuild')
def kgitrepo = build.buildVariableResolver.resolve('kgitrepo')
def kverfloor_raw = build.buildVariableResolver.resolve('kverfloor')
def kverceil_raw = build.buildVariableResolver.resolve('kverceil')
def kverfilter = build.buildVariableResolver.resolve('kverfilter')
def uversion = build.buildVariableResolver.resolve('uversion')
def job = Hudson.instance.getJob(build.buildVariableResolver.resolve('kbuildjob'))
def currentJobName = build.project.getFullDisplayName()


// Get the out variable
def config = new HashMap()
def bindings = getBinding()
config.putAll(bindings.getVariables())
def out = config['out']


// Get tags from git repository
def refs = Git.lsRemoteRepository().setTags(true).setRemote(kgitrepo).call();

// Get kernel versions to build
def kversions = []
def kversionsRC = []
def matchStrs = []
def blacklist = []
def kversionFactory = ""

if (uversion != null) {
  kversionFactory = new UbuntuKVersion()
  switch (uversion) {
    case 'bionic':
      matchStrs = [
        ~/^refs\/tags\/(Ubuntu-4\.15\.0-\d{1,3}?\.[\d]+)$/,
      ]
      break

    case 'xenial':
      matchStrs = [
        ~/^refs\/tags\/(Ubuntu-4\.4\.0-\d{1,3}?\.[\d]+)$/,
        ~/^refs\/tags\/(Ubuntu-lts-4\.8\.0-.*_16\.04\.\d+)$/,
        ~/^refs\/tags\/(Ubuntu-lts-4\.10\.0-.*_16\.04\.\d+)$/,
        ~/^refs\/tags\/(Ubuntu-lts-4\.15\.0-.*_16\.04\.\d+)$/,
      ]

      blacklist = [
        'Ubuntu-lts-4.10.0-7.9_16.04.1',
      ]
      break

    case 'trusty':
      matchStrs = [
        ~/^refs\/tags\/(Ubuntu-3\.13\.0-[\d\.]+)$/,
        ~/^refs\/tags\/(Ubuntu-lts-.*_14\.04\.\d+)$/,
      ]
      break

    default:
      println "Unsupported Ubuntu version: ${uversion}"
      throw new InterruptedException()
      break
  }
} else {
  // Vanilla
  kversionFactory = new VanillaKVersion()
  matchStrs = [
    ~/^refs\/tags\/(v[\d\.]+(-rc(\d+))?)$/,
  ]
}

// Parse kernel versions
def kverfloor = ""
try {
    kverfloor = kversionFactory.factory(kverfloor_raw)
} catch (EmptyKVersionException e) {
    kverfloor = kversionFactory.minKVersion()
}

def kverceil = ""
try {
    kverceil = kversionFactory.factory(kverceil_raw)
} catch (EmptyKVersionException e) {
    kverceil = kversionFactory.maxKVersion()
}

// Build a sorted list of versions to build
for (ref in refs) {
  for (matchStr in matchStrs) {
    def match = ref.getName() =~ matchStr
    if (match && !blacklist.contains(match.group(1))) {
      def v = kversionFactory.factory(match.group(1))

      if ((v >= kverfloor) && (v < kverceil)) {
        if (v.isRC()) {
          kversionsRC.add(v)
        } else {
          kversions.add(v)
        }
      }
    }
  }
}

kversions.sort()
kversionsRC.sort()

switch (kverfilter) {
  case 'stable-head':
    // Keep only the head of each stable branch
    println('Filter kernel versions to keep only the latest point release of each stable branch.')

    for (i = 0; i < kversions.size(); i++) {
      def curr = kversions[i]
      def next = i < kversions.size() - 1 ? kversions[i + 1] : null

      if (next != null) {
        if (curr.isSameStable(next)) {
          kversions.remove(i)
          i--
        }
      }
    }
    break

  default:
    // No filtering of kernel versions
    println('No kernel versions filtering selected.')
    break
}

// If the last RC version is newer than the last stable, add it to the build list
if (kversionsRC.size() > 0 && kversionsRC.last() > kversions.last()) {
  kversions.add(kversionsRC.last())
}

println "Building the following kernel versions:"
for (k in kversions) {
  println k
}

// Debug: Stop build here
//throw new InterruptedException()

def joburl = HyperlinkNote.encodeTo('/' + job.url, job.fullDisplayName)

def allBuilds = []
def ongoingBuild = []
def failedRuns = []
def isFailed = false
def similarJobQueued = 0;

// Loop while we have kernel versions remaining or jobs running
while ( kversions.size() != 0 || ongoingBuild.size() != 0 ) {

  if(ongoingBuild.size() < maxConcurrentBuild.toInteger() && kversions.size() != 0) {
    def kversion = kversions.pop()
    def job_params = [
      new StringParameterValue('mversion', mversion),
      new StringParameterValue('ktag', kversion.toString()),
      new StringParameterValue('kgitrepo', kgitrepo),
    ]

    // Launch the parametrized build
    def param_build = job.scheduleBuild2(0, new Cause.UpstreamCause(build), new ParametersAction(job_params))
    println "triggering ${joburl} for the ${mversion} branch on kernel ${kversion}"

    // Add it to the ongoing build queue
    ongoingBuild.push(param_build)

  } else {

    println "Waiting... Queued: " + kversions.size() + " Running: " + ongoingBuild.size()
    try {
      Thread.sleep(10000)
    } catch(e) {
      if (e in InterruptedException) {
        build.setResult(hudson.model.Result.ABORTED)
        throw new InterruptedException()
      } else {
        throw(e)
      }
    }

    // Abort job if a newer instance is queued
    similarJobQueued = Hudson.instance.queue.items.count{it.task.getFullDisplayName() == currentJobName}
    if ( similarJobQueued > 0 ) {
        build.setResult(hudson.model.Result.ABORTED)
        throw new InterruptedException()
    }

    def i = ongoingBuild.iterator()
    while ( i.hasNext() ) {
      currentBuild = i.next()
      if ( currentBuild.isCancelled() || currentBuild.isDone() ) {
        // Remove from queue
        i.remove()

        // Print results
        def matrixParent = currentBuild.get()
        allBuilds.add(matrixParent)
        def kernelStr = matrixParent.buildVariableResolver.resolve("ktag")
        println "${matrixParent.fullDisplayName} (${kernelStr}) completed with status ${matrixParent.result}"

        // Process child runs of matrixBuild
        def childRuns = matrixParent.getRuns()
        for ( childRun in childRuns ) {
          println "\t${childRun.fullDisplayName} (${kernelStr}) completed with status ${childRun.result}"
          if (childRun.result != Result.SUCCESS) {
            failedRuns.add(childRun)
            isFailed = true
          }
        }
      }
    }
  }
}

// Get log of failed runs
for (failedRun in failedRuns) {
  println "---START---"
  failedRun.writeWholeLogTo(out)
  println "---END---"
}

println "---Build report---"
for (b in allBuilds) {
  def kernelStr = b.buildVariableResolver.resolve("ktag")
  println "${b.fullDisplayName} (${kernelStr}) completed with status ${b.result}"
  // Cleanup builds
  try {
    b.delete()
  } catch (all) {}
}

// Mark this build failed if any child build has failed
if (isFailed) {
  build.setResult(hudson.model.Result.FAILURE)
}

// EOF

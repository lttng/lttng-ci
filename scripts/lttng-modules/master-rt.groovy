/**
 * Copyright (C) 2016-2018 - Michael Jeanson <mjeanson@efficios.com>
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

class RTKVersion implements Comparable<RTKVersion> {

  Integer major = 0
  Integer majorB = 0
  Integer minor = 0
  Integer patch = 0
  Integer rt = 0

  RTKVersion() {}

  RTKVersion(version) {
    this.parse(version)
  }

  static RTKVersion minKVersion() {
    return new RTKVersion("v0.0.0-rt0-rebase")
  }

  static RTKVersion maxKVersion() {
    return new RTKVersion("v" + Integer.MAX_VALUE + ".0.0-rt0-rebase")
  }

  static RTKVersion factory(version) {
    return new RTKVersion(version)
  }

  def parse(version) {
    this.major = 0
    this.majorB = 0
    this.minor = 0
    this.patch = 0
    this.rt = 0

    if (!version) {
      throw new EmptyKVersionException("Empty kernel version")
    }

    def match = version =~ /^v(\d+)\.(\d+)(\.(\d+))?(\.(\d+))?(-rt(\d+)-rebase)$/
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

    // RT
    this.rt = Integer.parseInt(match.group(8))
  }

  // Return true if both version are of the same stable branch
  Boolean isSameStable(RTKVersion o) {
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

  @Override int compareTo(RTKVersion o) {
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
    if (this.rt != o.rt) {
      return Integer.compare(this.rt, o.rt)
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

    if (this.rt > 0) {
      vString = vString.concat("-rt${this.rt}-rebase")
    }
    return vString
  }
}


// Retrieve parameters of the current build
def mbranch = build.getEnvironment(listener).get('GIT_BRANCH').minus('origin/')
def maxConcurrentBuild = build.buildVariableResolver.resolve('maxConcurrentBuild')
def kgitrepo = build.buildVariableResolver.resolve('kgitrepo')
def kverfloor_raw = build.buildVariableResolver.resolve('kverfloor')
def kverceil_raw = build.buildVariableResolver.resolve('kverceil')
def kverfilter = build.buildVariableResolver.resolve('kverfilter')
def job = Hudson.instance.getJob(build.buildVariableResolver.resolve('kbuildjob'))
def currentJobName = build.project.getFullDisplayName()
def gitmodpath = build.getEnvironment(listener).get('WORKSPACE') + "/src/lttng-modules"

// Get the out variable
def config = new HashMap()
def bindings = getBinding()
config.putAll(bindings.getVariables())
def out = config['out']


// Get the lttng-modules git url
def gitmodrepo = Git.open(new File(gitmodpath))
def mgitrepo = gitmodrepo.getRepository().getConfig().getString("remote", "origin", "url")

// Get tags from git repository
def refs = Git.lsRemoteRepository().setTags(true).setRemote(kgitrepo).call()

// Get kernel versions to build
def kversions = []
def tagMatchStrs = [
  ~/^refs\/tags\/(v[\d\.]+(-rt(\d+)-rebase))$/,
]
def blacklist = [
  ~/v4\.11\.8-rt5-rebase/,
  ~/v4\.11\.9-rt6-rebase/,
  ~/v4\.11\.9-rt7-rebase/,
  ~/v4\.11\.12-rt8-rebase/,
  ~/v4\.11\.12-rt9-rebase/,
  ~/v4\.11\.12-rt10-rebase/,
  ~/v4\.11\.12-rt11-rebase/,
  ~/v4\.11\.12-rt12-rebase/,
  ~/v4\.11\.12-rt13-rebase/,
  ~/v3\.6.*-rebase/,
  ~/v3\.8.*-rebase/,
]

def kversionFactory = new RTKVersion()

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
  for (tagMatchStr in tagMatchStrs) {
    def tagMatch = ref.getName() =~ tagMatchStr

    if (tagMatch) {
      def kversion_raw = tagMatch.group(1)
      def blacklisted = false

      // Check if the kversion is blacklisted
      for (blackMatchStr in blacklist) {
        def blackMatch = kversion_raw =~ blackMatchStr

        if (blackMatch) {
          blacklisted = true
          break;
        }
      }

      if (!blacklisted) {
        def v = kversionFactory.factory(kversion_raw)

        if ((v >= kverfloor) && (v < kverceil)) {
          kversions.add(v)
        }
      }
    }
  }
}

kversions.sort()

//println "Pre filtering kernel versions:"
//for (k in kversions) {
//  println k
//}

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
      new StringParameterValue('mversion', mbranch),
      new StringParameterValue('mgitrepo', mgitrepo),
      new StringParameterValue('ktag', kversion.toString()),
      new StringParameterValue('kgitrepo', kgitrepo),
    ]

    // Launch the parametrized build
    def param_build = job.scheduleBuild2(0, new Cause.UpstreamCause(build), new ParametersAction(job_params))
    println "triggering ${joburl} for the ${mbranch} branch on kernel ${kversion}"

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

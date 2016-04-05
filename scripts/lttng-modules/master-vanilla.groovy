/**
 * Copyright (C) 2016 - Michael Jeanson <mjeanson@efficios.com>
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


class kVersion implements Comparable<kVersion> {

  Integer major = 0;
  Integer majorB = 0;
  Integer minor = 0;
  Integer patch = 0;
  Integer rc = Integer.MAX_VALUE;

  kVersion() {}

  kVersion(version) {
    this.parse(version)
  }

  def parse(version) {
    this.major = 0
    this.majorB = 0
    this.minor = 0
    this.patch = 0
    this.rc = Integer.MAX_VALUE

    def match = version =~ /^v(\d+)\.(\d+)(\.(\d+))?(\.(\d+))?(-rc(\d+))?$/
    if (!match) {
      throw new Exception("Invalid kernel version: ${version}")
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

  @Override int compareTo(kVersion o) {
    if (this.major != o.major) {
      return Integer.compare(this.major, o.major);
    }
    if (this.majorB != o.majorB) {
      return Integer.compare(this.majorB, o.majorB);
    }
    if (this.minor != o.minor) {
      return Integer.compare(this.minor, o.minor);
    }
    if (this.patch != o.patch) {
      return Integer.compare(this.patch, o.patch);
    }
    if (this.rc != o.rc) {
      return Integer.compare(this.rc, o.rc);
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


// Retrieve parameters of the current build
def mversion = build.buildVariableResolver.resolve('mversion')
def maxConcurrentBuild = build.buildVariableResolver.resolve('maxConcurrentBuild')
def kgitrepo = build.buildVariableResolver.resolve('kgitrepo')
def kverfloor = new kVersion(build.buildVariableResolver.resolve('kverfloor'))
def job = Hudson.instance.getJob(build.buildVariableResolver.resolve('kbuildjob'))

// Get the out variable
def config = new HashMap()
def bindings = getBinding()
config.putAll(bindings.getVariables())
def out = config['out']

def jlc = new jenkins.model.JenkinsLocationConfiguration()
def jenkinsUrl = jlc.url

// Get tags from git repository
def refs = Git.lsRemoteRepository().setTags(true).setRemote(kgitrepo).call();

// Get kernel versions to build
def kversions = []
def kversionsRC = []
for (ref in refs) {
  def match = ref.getName() =~ /^refs\/tags\/(v[\d\.]+(-rc(\d+))?)$/

  if (match) {
    def v = new kVersion(match.group(1))

    if (v >= kverfloor) {
      if (v.isRC()) {
        kversionsRC.add(v)
      } else {
        kversions.add(v)
      }
    }
  }
}

kversions.sort()
kversionsRC.sort()

// If the last RC version is newer than the last stable, add it to the build list
if (kversionsRC.last() > kversions.last()) {
  kversions.add(kversionsRC.last())
}

// Debug
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

// Loop while we have kernel versions remaining or jobs running
while ( kversions.size() != 0 || ongoingBuild.size() != 0 ) {

  if(ongoingBuild.size() < maxConcurrentBuild.toInteger() && kversions.size() != 0) {
    def kversion = kversions.pop()
    def job_params = [
      new StringParameterValue('mversion', mversion),
      new StringParameterValue('kversion', kversion.toString()),
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
      Thread.sleep(5000)
    } catch(e) {
      if (e in InterruptedException) {
        build.setResult(hudson.model.Result.ABORTED)
        throw new InterruptedException()
      } else {
        throw(e)
      }
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
        def kernelStr = matrixParent.buildVariableResolver.resolve("kversion")
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
  def kernelStr = b.buildVariableResolver.resolve("kversion")
  println "${b.fullDisplayName} (${kernelStr}) completed with status ${b.result}"
  // Cleanup builds
  b.delete()
}

// Mark this build failed if any child build has failed
if (isFailed) {
  build.getExecutor().interrupt(Result.FAILURE)
}

// EOF

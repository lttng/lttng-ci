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


// Retrieve parameters of the current build
def mversion = build.buildVariableResolver.resolve('mversion')
def maxConcurrentBuild = build.buildVariableResolver.resolve('maxConcurrentBuild')
def kgitrepo = build.buildVariableResolver.resolve('kgitrepo')
def uversion = build.buildVariableResolver.resolve('uversion')
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

def matchStrs = []

switch (uversion) {
  case 'xenial':
    matchStrs = [
      ~/^refs\/tags\/(Ubuntu-4\.4\.0-\d{1,3}\.[\d\.]+)$/,
      ~/^refs\/tags\/(Ubuntu-lts-.*_16\.04\.\d+)$/,
    ]
    break

  case 'trusty':
    matchStrs = [
      ~/^refs\/tags\/(Ubuntu-3\.13\.0-[\d\.]+)$/,
      ~/^refs\/tags\/(Ubuntu-lts-.*_14\.04\.\d+)$/,
    ]
    break

  default:
    println 'Unsupported Ubuntu version: ${uversion}'
    throw new InterruptedException()
    break
}

for (ref in refs) {
  for (matchStr in matchStrs) {
    def match = ref.getName() =~ matchStr

    if (match) {
      kversions.add(match.group(1))
    }
  }
}

kversions.sort()

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
      new StringParameterValue('kversion', kversion),
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

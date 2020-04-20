/**
 * Copyright (C) 2017 - Michael Jeanson <mjeanson@efficios.com>
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

def kgitrepo = "git://git-mirror.internal.efficios.com/git/linux-all.git"
def ondiskpath = build.getEnvironment(listener).get('WORKSPACE') + "/ondisk-refs"

def trigger_jobs = [
  'lttng-modules_master_build-vanilla',
  'lttng-modules_stable-2.12_build-vanilla',
  'lttng-modules_stable-2.11_build-vanilla',
  'lttng-modules_stable-2.10_build-vanilla',
  'lttng-modules_master_crossbuild-vanilla',
  'lttng-modules_stable-2.12_crossbuild-vanilla',
  'lttng-modules_stable-2.11_crossbuild-vanilla',
  'lttng-modules_stable-2.10_crossbuild-vanilla',
]

def previous_tags = []
def current_refs = []
def current_tags = [] as Set

// First try to load previous tags from disk
try {
  def input = new ObjectInputStream(new FileInputStream(ondiskpath))
  previous_tags = input.readObject()
  input.close()
} catch (all) {
  println("Failed to load previous tags from disk.")
}

println("Loaded " + previous_tags.size() + " tags from disk.")
//println("Previous tags:")
//for (tag in previous_tags) {
//  println(" - ${tag}")
//}

// Get current tag refs from git repository
current_refs = Git.lsRemoteRepository().setTags(true).setRemote(kgitrepo).call();

println("Loaded " + current_refs.size() + " tags from git repository.")
//println("Current tags:")
for (ref in current_refs) {
  //println(" - " + ref.getName())
  current_tags.add(ref.getName())
}

// Write currents tags to disk
try {
  def out = new ObjectOutputStream(new FileOutputStream(ondiskpath))
  out.writeObject(current_tags)
  out.close()
} catch (all) {
  println("Failed to write tags to disk")
}

// Debug
//current_tags.add("this_is_a_test")

// Compare tags
current_tags.removeAll(previous_tags)

// If there are new tags, trigger the builds
if (current_tags.size() > 0) {
  println("Found " + current_tags.size() + "new tags:")
  for (tag in current_tags) {
    println(" - ${tag}")
  }

  for (jobname in trigger_jobs) {
    println("Triggering job : ${jobname}")
    def job = Hudson.instance.getJob(jobname)

    def params = [];
    for (paramdef in job.getProperty(ParametersDefinitionProperty.class).getParameterDefinitions()) {
      params += paramdef.getDefaultParameterValue();
    }
    def paramsAction = new hudson.model.ParametersAction(params)

    def cause = new Cause.UpstreamCause(build)
    def causeAction = new CauseAction(cause)

    Hudson.instance.queue.schedule(job, 0, causeAction, paramsAction)
  }
} else {
  println("No new tags, nothing to do.")
}

// EOF

/**
 * Copyright (C) 2016 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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


def jobs = hudson.model.Hudson.instance.items
def jobStartWith = "kernel_"
def toBuild = []
def counter = 0

def anotherBuild
jobs.each { job ->
	def jobName = job.getName()
	if (jobName.startsWith(jobStartWith)) {
		counter = counter + 1
		def lastBuild = job.getLastBuild()
		if (lastBuild == null || lastBuild.result != Result.SUCCESS) {
			toBuild.push(job)
		} else {
			println("\t"+ jobName + " Already built")
		}
	}
}

def ongoingBuild = []
def maxConcurrentBuild = 4

while (toBuild.size() != 0) {
	if(ongoingBuild.size() <= maxConcurrentBuild) {
		def job = toBuild.pop()
		ongoingBuild.push(job.scheduleBuild2(0))
		println "\t triggering " + HyperlinkNote.encodeTo('/' + job.url, job.fullDisplayName)
	} else {
		sleep(5000)
		ongoingBuild.removeAll{ it.isCancelled() || it.isDone() }
	}
}

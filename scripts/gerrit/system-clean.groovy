import hudson.matrix.*
import hudson.model.*
import jenkins.model.*

import com.sonyericsson.hudson.plugins.gerrit.trigger.hudsontrigger.GerritCause;
import com.sonymobile.tools.gerrit.gerritevents.dto.attr.Change;

// Iterate over all jobs and find the ones that have a hudson.plugins.git.util.BuildData
// as an action.
//
// We then clean it by removing the useless array action.buildsByBranchName
//

def jobPattern = "dev_gerrit_.*"

def matchedJobs = Jenkins.instance.items.findAll { job ->
    job.name =~ /$jobPattern/
}

for (job in matchedJobs) {
  println("job: " + job.name);

  def changes = []

  for (build in job.getBuilds()) {
    println("  build: " + build.number);

    // Skip currently building builds
    if (build.isBuilding()) {
      println("  Is building, skip it.");
      continue
    }

    // Keep only the last build of a Gerrit Change
    if (build.getCause(GerritCause.class) != null &&
        build.getCause(GerritCause.class).getEvent() != null &&
        build.getCause(GerritCause.class).getEvent().getChange() != null) {

      Change change = build.getCause(GerritCause.class).getEvent().getChange()

      if (changes.contains(change)) {
        println("  Is not the latest for change " + change.getId() + ", delete it.");
        build.delete()
        continue
      } else {
        changes.add(change)
      }
    }

    // Delete successful and aborted builds
    if (build.result.toString() == 'SUCCESS' || build.result.toString() == 'ABORTED') {
      println("  Is SUCCESSFUL / ABORTED, delete it.");
      build.delete()
      continue
    }


    // It is possible for a build to have multiple BuildData actions
    // since we can use the Mulitple SCM plugin.
    def gitActions = build.getActions(hudson.plugins.git.util.BuildData.class)
    if (gitActions != null) {
      for (action in gitActions) {
        action.buildsByBranchName = new HashMap<String, Build>();
        hudson.plugins.git.Revision r = action.getLastBuiltRevision();
        if (r != null) {
          for (branch in r.getBranches()) {
            action.buildsByBranchName.put(branch.getName(), action.lastBuild)
          }
        }
        build.actions.remove(action);
        build.actions.add(action);
        build.save();
      }
    }

    if (job instanceof MatrixProject) {
      for (run in build.getRuns()) {
        println("    run: " + run);

        gitActions = run.getActions(hudson.plugins.git.util.BuildData.class)
        if (gitActions != null) {
          for (action in gitActions) {
            action.buildsByBranchName = new HashMap<String, Build>();
            hudson.plugins.git.Revision r = action.getLastBuiltRevision();
            if (r != null) {
              for (branch in r.getBranches()) {
                action.buildsByBranchName.put(branch.getName(), action.lastBuild)
              }
            }
            run.actions.remove(action);
            run.actions.add(action);
            run.save();
          }
        }
      }
    }
  }
}

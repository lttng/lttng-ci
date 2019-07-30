#!/usr/bin/python3
# Copyright (C) 2019 - Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

import json
import os
import tempfile
from statistics import mean
import argparse
import sys
from operator import add

import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.ticker import PercentFormatter

import git
import numpy
import lava_submit

from minio import Minio
from minio.error import NoSuchKey
from minio.error import ResponseError


BENCHMARK_TYPES = ["dummy", "text"]
DEFAULT_BUCKET = "lava"


def graph_get_color(branch):
    """
    Get the color matching the branch.
    """
    color = {"stable-1.5": "red", "stable-2.0": "green", "master": "blue"}
    return color[branch]


def graph_get_title(branch, benchmark_type):
    """
    Get title for graph based on benchmark type.
    """
    string = {"dummy": "Dummy output", "text": "Text output"}
    return "{} - {}".format(branch, string[benchmark_type])


def get_client():
    """
    Return minio client configured.
    """
    return Minio(
        "obj.internal.efficios.com", access_key="jenkins", secret_key="echo123456"
    )


def get_file(client, prefix, file_name, workdir_name):
    """
    Return the path of the downloaded file.
    Return None on error
    """
    destination = os.path.join(workdir_name, file_name)
    object_name = "{}/{}".format(prefix, file_name)
    try:
        client.fget_object(DEFAULT_BUCKET, object_name, destination)
    except NoSuchKey:
        return None

    return destination


def delete_file(client, prefix, file_name):
    """
    Delete the file on remote.
    """
    object_name = "{}/{}".format(prefix, file_name)
    try:
        client.remove_object(DEFAULT_BUCKET, object_name)
    except ResponseError as err:
        print(err)
    except NoSuchKey:
        pass


def get_git_log(bt_version, cutoff, repo_path):
    """
    Return an ordered (older to newer) list of commits for the bt_version and
    cutoff. WARNING: This changes the git repo HEAD.
    """
    repo = git.Repo(repo_path)
    repo.git.fetch()
    return repo.git.log(
        "{}..origin/{}".format(cutoff, bt_version), "--pretty=format:%H", "--reverse"
    ).split("\n")


def parse_result(result_path):
    """
    Parse the result file. Return a dataset of User time + System time.
    """
    with open(result_path) as result:
        parsed_result = json.load(result)
        return list(
            map(
                add,
                parsed_result["User time (seconds)"],
                parsed_result["System time (seconds)"],
            )
        )


def get_benchmark_results(client, commit, workdir):
    """
    Fetch the benchmark result from a certain commit across all benchmark type.
    """
    results = {}
    benchmark_valid = True
    for b_type in BENCHMARK_TYPES:
        prefix = "/results/benchmarks/babeltrace/{}/".format(b_type)
        result_file = get_file(client, prefix, commit, workdir)
        if not result_file:
            """
            Benchmark is either corrupted or not complete.
            """
            return None, benchmark_valid
        results[b_type] = parse_result(result_file)
        if all(i == 0.0 for i in results[b_type]):
            benchmark_valid = False
            print("Invalid benchmark for {}/{}/{}".format(prefix, b_type, commit))
    # The dataset is valid return immediately.
    return results, benchmark_valid


def plot_raw_value(branch, benchmark_type, x_data, y_data, labels, latest_values):
    """
    Plot the graph using the raw value.
    """
    point_x_data = []
    outlier_x_data = []
    point_y_data = []
    outlier_y_data = []
    for pos in range(len(x_data)):
        x = x_data[pos]
        valid_points, outliers = sanitize_dataset(y_data[pos])
        for y in valid_points:
            point_x_data.append(x)
            point_y_data.append(y)
        for y in outliers:
            outlier_x_data.append(x)
            outlier_y_data.append(y)

    plt.plot(
        point_x_data, point_y_data, "o", label=branch, color=graph_get_color(branch)
    )
    plt.plot(outlier_x_data, outlier_y_data, "+", label="outlier", color="black")

    ymax = 1
    if y_data:
        ymin = 0.8 * min([item for sublist in y_data for item in sublist])
        ymax = 1.2 * max([item for sublist in y_data for item in sublist])
    # Put latest of other branches for reference as horizontal line.
    for l_branch, l_result in latest_values.items():
        if not l_result or l_branch == branch:
            continue
        plt.axhline(
            y=l_result,
            label="Latest {}".format(l_branch),
            color=graph_get_color(l_branch),
        )
        if l_result >= ymax:
            ymax = 1.2 * l_result
    ax = plt.gca()
    plt.ylim(ymin=0, ymax=ymax)
    plt.xticks(x_data, labels, rotation=90, family="monospace")
    plt.title(graph_get_title(branch, benchmark_type), fontweight="bold")
    plt.ylabel("User + system time (s)")
    plt.xlabel("Latest commits")
    plt.legend()

    # Put tick on the right side
    ax.tick_params(labeltop=False, labelright=True)

    plt.tight_layout()
    return

def plot_delta_between_point(branch, benchmark_type, x_data, y_data, labels, latest_values):
    """
    Plot the graph of delta between each sequential commit.
    """
    local_abs_max = 100

    # Transform y_data to a list of  for which the reference is the first
    # element.
    local_y_data = []
    for pos, y in enumerate(y_data):
        if pos == 0:
            local_y_data.append(0.0)
            continue
        local_y_data.append(y - y_data[pos - 1])

    plt.plot(x_data, local_y_data, "o", label=branch, color=graph_get_color(branch))

    # Get max absolute value to align the y axis with zero in the middle.
    if local_y_data:
        local_abs_max = abs(max(local_y_data, key=abs)) * 1.3

    plt.ylim(ymin=local_abs_max * -1, ymax=local_abs_max)

    ax = plt.gca()
    plt.xticks(x_data, labels, rotation=90, family="monospace")
    plt.title(graph_get_title(branch, benchmark_type) + " Delta to previous commit", fontweight="bold")
    plt.ylabel("Seconds")
    plt.xlabel("Latest commits")
    plt.legend()

    # Put tick on the right side
    ax.tick_params(labeltop=False, labelright=True)

    plt.tight_layout()
    return

def plot_ratio(branch, benchmark_type, x_data, y_data, labels, latest_values):
    """
    Plot the graph using a ratio using first point as reference (0%).
    """
    reference = 0.01
    y_abs_max = 100

    if y_data:
        reference = y_data[0]

    # Transform y_data to a list of ratio for which the reference is the first
    # element.
    local_y_data = list(map(lambda y: ((y / reference) - 1.0) * 100, y_data))

    plt.plot(x_data, local_y_data, "o", label=branch, color=graph_get_color(branch))

    # Put latest of other branches for reference as horizontal line.
    for l_branch, l_result in latest_values.items():
        if not l_result or l_branch == branch:
            continue
        ratio_l_result = ((l_result / reference) - 1.0) * 100.0
        print(
            "branch {} branch {} value {} l_result {} reference {}".format(
                branch, l_branch, ratio_l_result, l_result, reference
            )
        )
        plt.axhline(
            y=ratio_l_result,
            label="Latest {}".format(l_branch),
            color=graph_get_color(l_branch),
        )

    # Draw the reference line.
    plt.axhline(y=0, label="Reference (leftmost point)", linestyle="-", color="Black")

    # Get max absolute value to align the y axis with zero in the middle.
    if local_y_data:
        local_abs_max = abs(max(local_y_data, key=abs)) * 1.3
        if y_abs_max > 100:
            y_abs_max = local_abs_max

    plt.ylim(ymin=y_abs_max * -1, ymax=y_abs_max)

    ax = plt.gca()
    percent_formatter = PercentFormatter()
    ax.yaxis.set_major_formatter(percent_formatter)
    ax.yaxis.set_minor_formatter(percent_formatter)
    plt.xticks(x_data, labels, rotation=90, family="monospace")
    plt.title(graph_get_title(branch, benchmark_type), fontweight="bold")
    plt.ylabel("Ratio")
    plt.xlabel("Latest commits")
    plt.legend()

    # Put tick on the right side
    ax.tick_params(labeltop=False, labelright=True)

    plt.tight_layout()
    return

def generate_graph(branches, report_name, git_path):

    # The PDF document
    pdf_pages = PdfPages(report_name)

    client = get_client()
    branch_results = dict()

    # Fetch the results for each branch.
    for branch, cutoff in branches.items():
        commits = get_git_log(branch, cutoff, git_path)
        results = []
        with tempfile.TemporaryDirectory() as workdir:
            for commit in commits:
                b_results, valid = get_benchmark_results(client, commit, workdir)
                if not b_results or not valid:
                    continue
                results.append((commit, b_results))
        branch_results[branch] = results

    for b_type in BENCHMARK_TYPES:
        latest_values = {}
        max_len = 0

        # Find the maximum size for a series inside our series dataset.
        # This is used later to compute the size of the actual plot (pdf).
        # While there gather the comparison value used to draw comparison line
        # between branches.
        for branch, results in branch_results.items():
            max_len = max([max_len, len(results)])
            if results:
                latest_values[branch] = mean(
                    sanitize_dataset(results[-1][1][b_type])[0]
                )
            else:
                latest_values[branch] = None

        for branch, results in branch_results.items():
            # Create a figure instance
            if max_len and max_len > 10:
                width = 0.16 * max_len
            else:
                width = 11.69

            x_data = list(range(len(results)))
            y_data = [c[1][b_type] for c in results]
            labels = [c[0][:8] for c in results]

            fig = plt.figure(figsize=(width, 8.27), dpi=100)
            plot_raw_value(branch, b_type, x_data, y_data, labels, latest_values)
            pdf_pages.savefig(fig)

            # Use the mean of each sanitize dataset here, we do not care for
            # variance for ratio. At least not yet.
            y_data = [mean(sanitize_dataset(c[1][b_type])[0]) for c in results]
            fig = plt.figure(figsize=(width, 8.27), dpi=100)
            plot_ratio(branch, b_type, x_data, y_data, labels, latest_values)
            pdf_pages.savefig(fig)

            fig = plt.figure(figsize=(width, 8.27), dpi=100)
            plot_delta_between_point(branch, b_type, x_data, y_data, labels, latest_values)
            pdf_pages.savefig(fig)

    pdf_pages.close()


def launch_jobs(branches, git_path, wait_for_completion, debug, force):
    """
    Lauch jobs for all missing results.
    """
    client = get_client()
    for branch, cutoff in branches.items():
        commits = get_git_log(branch, cutoff, git_path)

        with tempfile.TemporaryDirectory() as workdir:
            for commit in commits:
                b_results = get_benchmark_results(client, commit, workdir)[0]
                if b_results and not force:
                    continue
                lava_submit.submit(
                    commit, wait_for_completion=wait_for_completion, debug=debug
                )


def main():
    """
    Parse arguments and execute as needed.
    """
    bt_branches = {
        "master": "31976fe2d70a8b6b7f8b31b9e0b3bc004d415575",
        "stable-2.0": "07f585356018b4ddfbd0e09c49a14e38977c6973",
        "stable-1.5": "49e98b837a5667130e0d1e062a6bd7985c7c4582",
    }

    parser = argparse.ArgumentParser(description="Babeltrace benchmark utility")
    parser.add_argument(
        "--generate-jobs", action="store_true", help="Generate and send jobs"
    )
    parser.add_argument(
        "--force-jobs", action="store_true", help="Force the queueing of jobs to lava"
    )
    parser.add_argument(
        "--do-not-wait-on-completion",
        action="store_true",
        default=False,
        help="Wait for the completion of each jobs sent. This is useful"
        "for the ci. Otherwise we could end up spaming the lava instance.",
    )
    parser.add_argument(
        "--generate-report",
        action="store_true",
        help="Generate graphs and save them to pdf",
    )
    parser.add_argument(
        "--report-name", default="report.pdf", help="The name of the pdf report."
    )
    parser.add_argument(
        "--debug", action="store_true", default=False, help="Do not send jobs to lava."
    )
    parser.add_argument(
        "--repo-path", help="The location of the git repo to use.", required=True
    )

    args = parser.parse_args()

    if not os.path.exists(args.repo_path):
        print("Repository location does not exists.")
        return 1

    if args.generate_jobs:
        print("Launching jobs for:")

        for branch, cutoff in bt_branches.items():
            print("\t Branch {} with cutoff {}".format(branch, cutoff))

        launch_jobs(
            bt_branches,
            args.repo_path,
            not args.do_not_wait_on_completion,
            args.debug,
            args.force_jobs,
        )

    if args.generate_report:
        print("Generating pdf report ({}) for:".format(args.report_name))
        for branch, cutoff in bt_branches.items():
            print("\t Branch {} with cutoff {}".format(branch, cutoff))
        generate_graph(bt_branches, args.report_name, args.repo_path)

    return 0


def sanitize_dataset(dataset):
    """
    Use IRQ 1.5 [1] to remove outlier from the dataset. This is useful to get a
    representative mean without outlier in it.
    [1] https://en.wikipedia.org/wiki/Interquartile_range#Outliers
    """
    sorted_data = sorted(dataset)
    q1, q3 = numpy.percentile(sorted_data, [25, 75])
    iqr = q3 - q1
    lower_bound = q1 - (1.5 * iqr)
    upper_bound = q3 + (1.5 * iqr)
    new_dataset = []
    outliers = []
    for i in dataset:
        if lower_bound <= i <= upper_bound:
            new_dataset.append(i)
        else:
            outliers.append(i)
    return new_dataset, outliers


if __name__ == "__main__":
    sys.exit(main())

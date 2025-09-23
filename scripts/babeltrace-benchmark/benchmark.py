#!/usr/bin/python3
# SPDX-FileCopyrightText: 2019 Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

import argparse
import json
import os
import sys
import tempfile
from operator import add
from statistics import mean

import git
import lava_submit
import matplotlib.pyplot as plt
import numpy
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.ticker import PercentFormatter
from minio import Minio
from minio.error import NoSuchKey, ResponseError

BENCHMARK_TYPES = [
    "dummy-default",
    "text-default",
    # traces created using lttng-tools 2.10
    "dummy-tools_2_10",
    "text-tools_2_10",
    # traces created using lttng-tools master (soon to be 2.14)
    "dummy-tools_2_14",
    "text-tools_2_14",
]

# Get S3 config from environment
S3_HOST = os.getenv("S3_HOST")
S3_BUCKET = os.getenv("S3_BUCKET")
S3_ACCESS_KEY = os.getenv("S3_ACCESS_KEY")
S3_SECRET_KEY = os.getenv("S3_SECRET_KEY")

invalid_commits = {
    "ec9a9794af488a9accce7708a8b0d8188b498789",  # Does not build
    "8c99128c640cbce71fb8a6caa15e4c672252b662",  # Block on configure
    "f3847c753f1b4f12353c38d97b0577d9993d19fb",  # Does not build
    "e0111295f17ddfcc33ec771a8deac505473a06ad",  # Does not build
    "d0d4e0ed487ea23aaf0d023513c0a4d86901b79b",  # Does not build
    "c24f7ab4dd9edeb5e50b0070fd9d9e8691057dde",  # Does not build
    "ce67f5614a4db3b2de4d887eca52135b439b4937",  # Does not build
    "80aff5efc66679fd934cef433c0e698694748385",  # Does not build
    "f4f11e84942d36fcc8a597d226928bce2ccac4b3",  # Does not build
    "ae466a6e1b856d96cf5112a371b4df2b732503ec",  # Does not build
    "ade5c95e2a4f90f839f222fc1a66175b3b199922",  # Configuration fails
    "30341532906d62808e9d66fb115f5edb4e6f5706",  # Configuration fails
    "006c5ffb42f32e802136e3c27a63accb59b4d6c4",  # Does not build
    "88488ff5bdcd7679ff1f04fe6cff0d24b4f8fc0c",  # Does not build
    # Other errors
    "7c7301d5827bd10ec7c34da7ffc5fe74e5047d38",
    "a0df3abf88616cb0799f87f4eb57c54268e63448",
    "b7045dd71bc0524ad6b5db96df365e98e237d395",
    "cf7b259eaa602abcef308d2b5dd8e6c9ee995d8b",
    "90a55a4ef47cac7b568f5f0a8a78bd760f82d23c",
    "baa5e3aa82a82c9d0fa59e3c586c0168bb5dc267",
    "af9f8da7ba4a9b16fc36d637b8c3a0c7a8774da2",
    "fe748379adbd385efdfc7acae9c2340fb8b7d717",
    "baa5e3aa82a82c9d0fa59e3c586c0168bb5dc267",
    "af9f8da7ba4a9b16fc36d637b8c3a0c7a8774da2",
    "fe748379adbd385efdfc7acae9c2340fb8b7d717",
    "929627965e33e06dc77254d81e8ec1d66cc06590",
    "48a0e52c4632a60cd43423f2f34f10de350bf868",
    "b7fa35fce415b33207a9eba111069ed31ef122a0",
    "828c8a25785e0cedaeb6987256a4dfc3c43b982f",
    "213489680861e4d796173513effac7023312ec2d",
    "430a5ccbbd15782501ca56bb148f3850126277ad",
    "629d19044c43b195498d0a4e002906c54b6186d5",
    "c423217ed1640b4152739f7e5613775d46c25050",
    # Elfutils
    "776a2a252c9875caa1e8b4f41cb8cc12c79611c3",
    "435aa29aff0527d36aafa1b657ae70b9db5f9ea5",
    "95651695473495501fc6b2c4a1cf6a78cfb3cd6a",
    "e0748fb2ba8994c136bcc0b67d3044f09841cf8e",
    "9e632b22e1310fe773edc32ab08a60602f4b2861",
    "271fb6907a6f4705a1c799d925394243eae51d68",
    "328342cd737582216dc7b8b7d558b2a1bf8ea5e8",
    "ae5c1a4481be68fae027910b141354c1d86daa64",
    "e6938018975e45d35dab5fef795fe7344eef7d62",
    "e015bae2ef343b30c890eebb9182a8be13d12ed0",
    "5e8a0751ae0c418a615025d1da10bc84f91b3d97",
    "887d26fa0fd0ae0c5c15e4b885473c4cdc0bf078",
    "e97fe75eac59fc39a6e4f3c4f9f3301835a0315e",
    "8b130e7f1d6a41fb5c64a014c15246ba74b79470",
    "f4f8f79893b18199b38edc3330093a9403c4c737",
}


def json_type(string):
    """
    Argpase type for json args.
    We expect a base dictionary.
    """
    passed_json = json.loads(string)
    if not isinstance(passed_json, dict):
        msg = "%r is not a dict" % string
        raise argparse.ArgumentTypeError(msg)
    return passed_json


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
    string = {
        "dummy-default": "Dummy output",
        "text-default": "Text output",
        "dummy-tools_2_10": "Dummy output with tools 2.10 trace",
        "text-tools_2_10": "Text output with tools 2.10 trace",
        "dummy-tools_2_14": "Dummy output with tools 2.14 trace",
        "text-tools_2_14": "Text output with tools 2.14 trace",
    }
    return "{} - {}".format(branch, string[benchmark_type])


def get_client():
    """
    Return minio client configured.
    """
    return Minio(
        S3_HOST, access_key=S3_ACCESS_KEY, secret_key=S3_SECRET_KEY
    )


def get_file(client, prefix, file_name, workdir_name):
    """
    Return the path of the downloaded file.
    Return None on error
    """
    destination = os.path.join(workdir_name, file_name)
    object_name = "{}/{}".format(prefix, file_name)
    try:
        client.fget_object(S3_BUCKET, object_name, destination)
    except NoSuchKey:
        return None

    return destination


def delete_file(client, prefix, file_name):
    """
    Delete the file on remote.
    """
    object_name = "{}/{}".format(prefix, file_name)
    try:
        client.remove_object(S3_BUCKET, object_name)
    except ResponseError as err:
        print(err)
    except NoSuchKey:
        pass


def get_git_log(bt_version, cutoff, bt_repo_path):
    """
    Return an ordered (older to newer) list of commits for the bt_version and
    cutoff. WARNING: This changes the git repo HEAD.
    """
    repo = git.Repo(bt_repo_path)
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
        prefix = "/results/benchmarks/babeltrace/{}".format(b_type)
        result_file = get_file(client, prefix, commit, workdir)
        if not result_file:
            """
            Benchmark is either corrupted or not complete.
            """
            return None, False
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
    plt.grid(True)

    # Put tick on the right side
    ax.tick_params(labeltop=False, labelright=True)

    plt.tight_layout()
    return


def plot_delta_between_point(
    branch, benchmark_type, x_data, y_data, labels, latest_values
):
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
    plt.title(
        graph_get_title(branch, benchmark_type) + " Delta to previous commit",
        fontweight="bold",
    )
    plt.ylabel("Seconds")
    plt.xlabel("Latest commits")
    plt.legend()
    plt.grid(True)

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
    plt.grid(True)

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
            plot_delta_between_point(
                branch, b_type, x_data, y_data, labels, latest_values
            )
            pdf_pages.savefig(fig)

    pdf_pages.close()


def launch_jobs(
    branches,
    bt_repo_path,
    wait_for_completion,
    debug,
    force,
    batch_size,
    max_batches,
    bt_repo,
    ci_repo,
    ci_branch,
    nfs_root_url,
):
    """
    Lauch jobs for all missing results.
    """
    client = get_client()
    commits_to_test = set()
    for branch, cutoff in branches.items():
        commits = [
            x for x in get_git_log(branch, cutoff, bt_repo_path) if x not in invalid_commits
        ]
        with tempfile.TemporaryDirectory() as workdir:
            for commit in commits:
                if get_benchmark_results(client, commit, workdir)[1] and not force:
                    print("All benchmarks are valid for {}, skipping".format(commit))
                    continue
                commits_to_test.add(commit)

    commits_to_test = list(commits_to_test)
    print("{} commits to run benchmarks for".format(len(commits_to_test)))
    if len(commits_to_test) == 0:
        return

    chunks = [commits_to_test]
    batches_run = 0
    if batch_size > 0:
        chunks = [
            commits_to_test[i : i + batch_size]
            for i in range(0, len(commits_to_test), batch_size)
        ]

    for index, commits in enumerate(chunks):
        print("Job {}/{}".format(index + 1, max(len(chunks), max_batches)))
        lava_submit.submit(
            commits,
            bt_repo,
            ci_repo,
            ci_branch,
            nfs_root_url,
            wait_for_completion=wait_for_completion,
            debug=debug,
        )
        batches_run += 1
        if max_batches > 0 and batches_run >= max_batches:
            break


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
        "-b",
        "--batch-size",
        type=int,
        help="When generating jobs, run up to N commits per job. When set to 0, run all commits in a single job",
        default=100,
    )
    parser.add_argument(
        "--max-batches",
        type=int,
        default=0,
        help="Only run up to N batches. Generally used for testing.",
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
        "--bt-repo-path", help="The location of the babeltrace git repo to use.", required=True
    )
    parser.add_argument(
        "--overwrite-branches-cutoff",
        help="A dictionary of the form {"
        "'branch_name': 'commit_hash_cutoff',...}. Allow custom graphing and"
        "jobs generation.",
        required=False,
        type=json_type,
    )
    parser.add_argument(
        "--bt-repo",
        default="https://github.com/efficios/babeltrace.git",
    )
    parser.add_argument(
        "--ci-repo",
        default="https://github.com/lttng/lttng-ci.git",
    )
    parser.add_argument("--ci-branch", default="master")
    parser.add_argument("--nfs-root-url", default=os.getenv("NFS_ROOT_URL"))

    args = parser.parse_args()
    if args.batch_size < 0:
        print("Batch size must be greater than or equal to 0")
        return 1

    if args.overwrite_branches_cutoff:
        bt_branches = args.overwrite_branches_cutoff

    if not os.path.exists(args.bt_repo_path):
        print("Repository location does not exists.")
        return 1

    if args.generate_jobs:
        print("Launching jobs for:")

        for branch, cutoff in bt_branches.items():
            print("\t Branch {} with cutoff {}".format(branch, cutoff))

        launch_jobs(
            bt_branches,
            args.bt_repo_path,
            not args.do_not_wait_on_completion,
            args.debug,
            args.force_jobs,
            args.batch_size,
            args.max_batches,
            args.bt_repo,
            args.ci_repo,
            args.ci_branch,
            args.nfs_root_url,
        )

    if args.generate_report:
        print("Generating pdf report ({}) for:".format(args.report_name))
        for branch, cutoff in bt_branches.items():
            print("\t Branch {} with cutoff {}".format(branch, cutoff))
        generate_graph(bt_branches, args.report_name, args.bt_repo_path)

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

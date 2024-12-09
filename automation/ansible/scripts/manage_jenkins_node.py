#!/usr/bin/python3

import argparse
import configparser
import enum
import json
import logging
import pathlib
import pprint
import re
import sys
import time
import xml.etree.ElementTree

import jenkins
import requests


class OutputFormat(enum.Enum):
    pprint = "pprint"
    json = "json"
    pjson = "pjson"  # Pretty json

    def __str__(self):
        return self.value


def get_hypervisor(server, nodes, args):
    found = 0
    for node in nodes:
        raw_config = server.get_node_config(node["name"])
        logging.debug("Node config\n---\n%s\n---\n", raw_config)
        node_config = xml.etree.ElementTree.fromstring(raw_config)
        hypervisor = node_config.find(".//hypervisorDescription")
        if hypervisor is None:
            logging.info("Node '%s' has no hypervisorDescription", node["name"])
            continue
        found += 1
        print(hypervisor.text.split("-", maxsplit=1)[1].strip() or "")
    if found == 0:
        sys.exit(1)
    elif found != len(nodes):
        sys.exit(2)


def get_info(server, nodes, args):
    data = []
    for node in nodes:
        data.append(server.get_node_info(node["name"]))

    if args.format == OutputFormat.pprint:
        pprint.PrettyPrinter().pprint(data)
    elif args.format == OutputFormat.json:
        print(json.dumps(data))
    elif args.format == OutputFormat.pjson:
        print(json.dumps(data, sort_keys=True, indent=4))
    else:
        raise Exception("Unknown output format")


def toggle_nodes(server, nodes, args, want_offline=True):
    changed = []
    for node in nodes:
        if node["offline"] != want_offline:
            logging.info(
                "%s is %s, toggling",
                node["name"],
                "offline" if node["offline"] else "online",
            )
            if not args.dry_run:
                if want_offline:
                    server.disable_node(node["name"], args.reason)
                else:
                    server.enable_node(node["name"])
            changed.append(node)
        else:
            logging.debug(
                "%s is %s, skipping",
                node["name"],
                "offline" if node["offline"] else "online",
            )

    if "wait" not in args:
        return

    if args.wait < 0:
        return

    force_abort = True if "force_abort" in args and args.force_abort else False
    abort_wait = args.abort_after if "abort_after" in args else 0
    waited = 0
    while True:
        if not changed:
            break
        if (waited % 5) < 0.5:
            try:
                running_jobs = server.get_running_builds()
                running_job_nodes = [build["node"] for build in running_jobs]
                node_status = {
                    node["name"]: node["offline"] for node in server.get_nodes()
                }
                logging.debug("%d job(s) running", len(running_job_nodes))
            except requests.exceptions.ConnectionError:
                server = jenkins.Jenkins(
                    args.url, username=args.user, password=args.password
                )
                continue
            changed = [
                node
                for node in changed
                if node["name"] in running_job_nodes
                or not node_status.get(node["name"], False)
            ]
            if not changed:
                break
            else:
                logging.info(
                    "%d node(s) still online or running jobs, waiting...", len(changed)
                )
                for node in changed:
                    logging.debug("\t%s", node["name"])
            if force_abort and waited >= abort_wait:
                print(abort_wait)
                abort_on = [
                    node["name"]
                    for node in changed
                    if node["name"] in running_job_nodes
                ]
                for job in running_jobs:
                    if job["node"] in [node["name"] for node in changed]:
                        logging.info(
                            "Aborting %s #%d on %s",
                            job["name"],
                            job["number"],
                            job["node"],
                        )
                        if not args.dry_run:
                            server.stop_build(job["name"], job["number"])
        time.sleep(0.5)
        waited += 0.5
        if args.wait != 0 and waited > args.wait:
            break
    return


def get_argument_parser():
    parser = argparse.ArgumentParser(
        prog="update_ci_nodes.py", description="Run playbook against Jenkins nodes"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Do not submit any changes",
    )
    parser.add_argument(
        "-q",
        "--quiet",
        action="store_const",
        dest="loglevel",
        const=logging.ERROR,
        default=logging.INFO,
        help="Only output errors",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_const",
        dest="loglevel",
        const=logging.DEBUG,
        help="Increase verbosity",
    )
    parser.add_argument(
        "-u", "--url", default=None, help="Jenkins server URL including protocol"
    )
    parser.add_argument("--user", default=None, help="Jenkins username")
    parser.add_argument("--password", default=None, help="Jenkins password")
    parser.add_argument(
        "--include-builtin",
        default=False,
        action="store_true",
        help="Allow operations to be done on the built-in node",
    )
    parser.add_argument(
        "-f",
        "--config-file",
        default="~/.config/jenkins_jobs/jenkins_jobs.ini",
        type=pathlib.Path,
        help="An INI config file as used by jenkins_jobs",
    )
    subparsers = parser.add_subparsers(help="sub-command help")

    enable_parser = subparsers.add_parser("enable", help="Enable a Jenkins node")
    enable_parser.set_defaults(
        callback=lambda server, nodes, args: toggle_nodes(
            server, nodes, args, want_offline=False
        )
    )
    enable_parser.add_argument(
        "node", default="", help="A python regex to filter nodes by", nargs="?"
    )

    disable_parser = subparsers.add_parser("disable", help="Disable a Jenkins node")
    disable_parser.set_defaults(
        callback=lambda server, nodes, args: toggle_nodes(
            server, nodes, args, want_offline=True
        )
    )
    disable_parser.add_argument(
        "-w",
        "--wait",
        default=0,
        type=int,
        help="The number of minutes to wait until the node(s) are offline. 0 waits forever, and anything less than zero doesn't wait",
    )
    disable_parser.add_argument(
        "-r", "--reason", help="The offline reason", default="No reason given"
    )
    disable_parser.add_argument(
        "--force-abort",
        default=False,
        action="store_true",
        help="Abort any running jobs on nodes that should be offlined",
    )
    disable_parser.add_argument(
        "--abort-after",
        default=0,
        type=int,
        help="Force the job abort after N seconds have passed. For values larger than 0, the --wait argument should also be set",
    )
    disable_parser.add_argument(
        "node", default="", help="A python regex to filter nodes by", nargs="?"
    )

    getcloud_parser = subparsers.add_parser(
        "get_hypervisor", help="Get the libvirt cloud of a node"
    )
    getcloud_parser.set_defaults(callback=get_hypervisor)
    getcloud_parser.add_argument(
        "node", default="", help="A python regex to filter nodes by", nargs="?"
    )

    info_parser = subparsers.add_parser("info", help="Get node info")
    info_parser.set_defaults(callback=get_info)
    info_parser.add_argument(
        "node", default="", help="A python regex to filter nodes by", nargs="?"
    )
    info_parser.add_argument(
        "-f",
        "--format",
        default="pprint",
        help="The output format",
        type=OutputFormat,
        choices=list(OutputFormat),
    )

    return parser


if __name__ == "__main__":
    parser = get_argument_parser()
    args = parser.parse_args()
    logging.basicConfig(
        level=args.loglevel, format="[%(asctime)s] - %(levelname)s - %(message)s"
    )
    if "callback" not in args or not args.callback:
        logging.error("Valid command required")
        parser.print_help()
        sys.exit(1)

    if args.config_file is not None:
        config = configparser.ConfigParser()
        config.read(args.config_file.expanduser().absolute())
        if "jenkins" not in config.sections():
            logging.error(
                "[jenkins] section not found in config file '%s", args.config_file
            )
            sys.exit(1)
        if args.url is None:
            args.url = config.get("jenkins", "url")
        if args.user is None:
            args.user = config["jenkins"]["user"]
        if args.password is None:
            args.password = config["jenkins"]["password"]

    assert args.user is not None
    assert args.url is not None
    assert args.password is not None
    server = jenkins.Jenkins(args.url, username=args.user, password=args.password)
    nodes = server.get_nodes()
    logging.debug("%d node(s) before filtering", len(nodes))
    if not args.include_builtin:
        logging.debug("Filtering out Built-In Node")
        nodes = [n for n in nodes if n["name"] != "Built-In Node"]

    if "node" in args and args.node:
        pattern = re.compile(args.node)
        nodes = [node for node in nodes if pattern.match(node["name"])]
        logging.debug("%d node(s) after filtering with `%s`", len(nodes), pattern)

    args.callback(server, nodes, args)

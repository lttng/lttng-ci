#!/usr/bin/python3

import argparse
import configparser
import sys
import xml.etree.ElementTree

import jenkins

def get_argument_parser():
    parser = argparse.ArgumentParser(
        prog='update_jenkins_node.py',
        description='Create, update, or delete Jenkins nodes'
    )
    parser.add_argument(
        '-u', '--url', default=None,
        help='Jenkins server URL including protocol'
    )
    parser.add_argument(
        '--user', default=None,
        help='Jenkins username'
    )
    parser.add_argument(
        '--password', default=None,
        help='Jenkins password'
    )
    parser.add_argument(
        '-n', '--node', default=None, required=True,
        help='The name of the node to manage in Jenkins'
    )
    parser.add_argument(
        '-c', '--node-config', default=[], action='append',
        help='An equals-separated set path=value[=attrib]. When attrib is not set, text is assumed'
    )
    parser.add_argument(
        '-f', '--config-file', default=None, type=argparse.FileType('r'),
        help='An INI config file as used by jenkins_jobs'
    )
    parser.add_argument(
        '-s', '--state', default='online',
        choices=['online', 'offline', 'absent'],
        help='The state of the Jenkins node'
    )
    parser.add_argument(
        '-m', '--message', default='',
        help='A message to set for the offline reason of a node'
    )
    return parser


def manage_node(url, user, password, node, state, offline_message='', config={}):
    server = jenkins.Jenkins(url, username=user, password=password)
    exists = server.node_exists(node)
    node_info = {}
    changed = False
    if exists and state == 'absent':
        server.delete_node(node)
        changed = True
    if not exists and state != 'absent':
        server.create_node(node, numExecutors=1, remoteFS='/home/jenkins',
                           launcher=jenkins.LAUNCHER_SSH)
        changed = True
    if state != 'absent':
        # Check configuration
        updated = False
        node_config = xml.etree.ElementTree.fromstring(server.get_node_config(node))
        for key, value in config.items():
            element = node_config.find(key)
            new_element = None
            current_key = key
            while element is None:
                head = key.rsplit('/', 1)[0] if '/' in current_key else None
                tail = key.rsplit('/', 1)[1] if '/' in current_key else current_key
                e = xml.etree.ElementTree.Element(tail)
                if new_element is not None:
                    e.append(new_element)
                    new_element = None
                if head is None:
                    node_config.append(e)
                    element = node_config.find(key)
                else:
                    parent = node_config.find(head)
                    if parent:
                        parent.append(e)
                        element = node_config.find(key)
                    else:
                        new_element = e
                        current_key = head
                        continue

            if value['attrib'] is None:
                if element.text != value['value']:
                    updated = True
                    element.text = value['value']
            else:
                try:
                    if element.attrib[value['attrib']] != value['value']:
                        updated = True
                        element.attrib[value['attrib']] = value['value']
                except KeyError:
                    element.attrib[value['attrib']] = value['value']
                    updated = True
        if updated:
            server.reconfig_node(
                node,
                xml.etree.ElementTree.tostring(
                    node_config,
                    xml_declaration=True,
                    encoding='unicode'
                )
            )
            changed = True
        # Online/offline
        node_info = server.get_node_info(node)
        if node_info['offline'] and state == 'online':
            server.enable_node(node)
            changed = True
        if not node_info['offline'] and state == 'offline':
            server.disable_node(node, offline_message)
            changed = True
    return changed


if __name__ == '__main__':
    parser = get_argument_parser()
    args = parser.parse_args()
    if args.config_file is not None:
        config = configparser.ConfigParser()
        config.read_file(args.config_file)
        if 'jenkins' not in config.sections():
            print("[jenkins] section not found")
            sys.exit(1)
        if args.url is None:
            args.url = config.get('jenkins', 'url')
        if args.user is None:
            args.user = config['jenkins']['user']
        if args.password is None:
            args.password = config['jenkins']['password']
    assert(args.user is not None)
    assert(args.url is not None)
    assert(args.password is not None)
    node_config = {}
    for entry in args.node_config:
        key, value = entry.split('=', 1)
        node_config[key] = {
            'attrib': value.split('=', 1)[1] if '=' in value else None,
            'value': value.split('=', 1)[0] if '=' in value else value,
        }
    print(node_config)
    manage_node(
        args.url, args.user, args.password, args.node, args.state,
        args.message, node_config
    )

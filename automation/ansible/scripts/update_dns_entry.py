#!/usr/bin/env python3
#

import argparse
import ipaddress
import subprocess

import dns.message
import dns.query
import dns.resolver


def get_argument_parser():
    parser = argparse.ArgumentParser(
        prog="update_dns_entry.py",
        description="Generate fixed-address DHCP configuration based for hosts based on DNS entries",
    )
    parser.add_argument(
        "-s", "--server", default=None, required=True, help="Server for DNS updates"
    )
    parser.add_argument(
        "-u", "--user", default=None, help="The user to use with samba-tool"
    )
    parser.add_argument(
        "-z", "--zone", required=True, help="The zone in which to update the entry"
    )
    parser.add_argument("-n", "--name", required=True, help="DNS entry name")
    parser.add_argument("-v", "--value", required=True, help="DNS entry value")
    parser.add_argument("-t", "--type", default="A", help="Entry type")
    return parser


def update_dns_entry(
    server, zone, name, entry_type, value, user=None, with_reverse=True
):
    if entry_type == "A":
        assert ipaddress.ip_address(value)
    try:
        server_ip = str(ipaddress.ip_address(server))
    except ValueError:
        server_ip = dns.resolver.resolve(server)[0].to_text()

    commands = []
    # Verify existing entry
    query = dns.message.make_query(".".join([name, zone]), entry_type)
    record = dns.query.udp(query, server_ip)
    if len(record.answer) == 0:
        # Create
        argv = ["samba-tool", "dns", "add", server, zone, name, entry_type, value]
        if user is not None:
            argv += ["-U", user]
        commands.append(argv)
    else:
        assert len(record.answer) == 1
        # Check validity
        existing = (record.answer)[0][0].to_text()
        if existing != value:
            # Update
            argv = [
                "samba-tool",
                "dns",
                "update",
                server,
                zone,
                name,
                entry_type,
                existing,
                value,
            ]
            if user is not None:
                argv += ["-U", user]
            commands.append(argv)

    # Check reverse
    if with_reverse and entry_type == "A":
        rname, rzone = ipaddress.ip_address(value).reverse_pointer.split(".", 1)
        rvalue = ".".join([name, zone]) + "."
        rtype = "PTR"
        query = dns.message.make_query(
            ipaddress.ip_address(value).reverse_pointer, rtype
        )
        record = dns.query.udp(query, server_ip)
        if len(record.answer) == 0:
            argv = ["samba-tool", "dns", "add", server, rzone, rname, rtype, rvalue]
            if user is not None:
                argv += ["-U", user]
            commands.append(argv)
        else:
            assert len(record.answer) == 1
            existing = (record.answer)[0][0].to_text()
            if existing != value:
                argv = [
                    "samba-tool",
                    "dns",
                    "update",
                    server,
                    rzone,
                    rname,
                    rtype,
                    existing,
                    rvalue,
                ]
                if user is not None:
                    argv += ["-U", user]
                commands.append(argv)

    # Run commands
    for command in commands:
        subprocess.run(command, check=True)


if __name__ == "__main__":
    parser = get_argument_parser()
    args = parser.parse_args()
    update_dns_entry(
        args.server, args.zone, args.name, args.type, args.value, user=args.user
    )

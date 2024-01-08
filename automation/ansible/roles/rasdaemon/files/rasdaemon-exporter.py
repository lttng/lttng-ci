#!/usr/bin/python3
#
# SPDX-FileCopyrightText: 2024 Kienan Stewart <kstewart@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Prometheus exporter for rasdaemon
#
# Based on https://github.com/openstreetmap/prometheus-exporters/blob/main/exporters/rasdaemon/rasdaemon_exporter
#

import argparse
import http.server
import sqlite3
import urllib.parse

METRICS = {
    'rasdaemon_mc_events_total': {
        'help': 'Memory controller errors',
        'type': 'counter',
        'query': 'SELECT mc, top_layer, middle_layer, lower_layer, err_type, SUM(err_count) as err_count FROM mc_event GROUP BY mc, top_layer, middle_layer, lower_layer, err_type',
    },
}

class ExporterServer(http.server.ThreadingHTTPServer):

    def __init__(self, server_address, RequestHandlerClass, db_file='/var/lib/rasdaemon/ras-mc_event.db'):
        super().__init__(server_address, RequestHandlerClass)
        self.db_file = db_file


class ExporterHandler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path != '/metrics':
            self.send_response(404)
            self.end_headers()
            return

        metrics_details = {key: dict() for (key, _) in METRICS.items()}
        with sqlite3.connect('file:{}?mode=ro'.format(self.server.db_file), uri=True) as con:
            cursor = con.cursor()
            cursor.row_factory = sqlite3.Row
            for key, _ in METRICS.items():
                result = cursor.execute(METRICS[key]['query'])
                metrics_details[key] = result.fetchall()

        print(metrics_details)
        self.send_response(200)
        self.end_headers()
        for key, value in METRICS.items():
            self.wfile.write("# HELP {} {}\n".format(key, value['help']).encode())
            self.wfile.write("# TYPE {} {}\n".format(key, value['type']).encode())
            if not metrics_details[key]:
                self.wfile.write("{} 0\n".format(key).encode())
            for entry in metrics_details[key]:
                labels = ','.join(['{}="{}"'.format(key, entry[key]) for key in entry.keys() if key != 'err_count'])
                if labels:
                    self.wfile.write("{}{{{}}} {}\n".format(key, labels, entry['err_count']).encode())
                else:
                    self.wfile.write("{} {}\n".format(key, entry['err_count']).encode())


def _get_argument_parser():
    parser = argparse.ArgumentParser(
        prog='rasdaemon-exporter',
        description='Exporters rasdaemon metrics'
    )
    parser.add_argument(
        '-p', '--port', type=int, default=9797,
        help='The port to listen on'
    )
    parser.add_argument(
        '-l', '--listen-address', type=str, default='',
        help='The address to listen on'
    )
    parser.add_argument(
        '-f', '--rasdaemon-db-file', type=str, #type=argparse.FileType('r'),
        default='/var/lib/rasdaemon/ras-mc_event.db',
        help='The path to the rasdaemon sqlite3 database'
    )
    return parser


def serve(listen_address, listen_port, db_file):
    with ExporterServer((listen_address, listen_port), ExporterHandler, db_file) as httpd:
        httpd.serve_forever()
    print('done')


if __name__ == '__main__':
    parser = _get_argument_parser()
    args = parser.parse_args()
    serve(args.listen_address, args.port, args.rasdaemon_db_file)

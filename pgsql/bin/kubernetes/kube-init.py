#!/usr/bin/env python
# pylint: disable=C0103

from __future__ import print_function
import sys
import os
import urllib2
import json
import socket
import time
from contextlib import closing

if __name__ == '__main__':
    HOSTNAME = socket.gethostname()
    POD_NAME = os.getenv('POD_NAME', HOSTNAME)
    ELECTION_PORT = int(os.getenv('ELECTION_PORT', 4040))
    ELECTION_URI = os.getenv('ELECTION_URI', 'http://localhost:4040')
    SLEEP_TIME = float(os.getenv('SLEEP_TIME', 5))
    print('HOSTNAME = {}'.format(HOSTNAME), file=sys.stderr)
    print('POD_NAME = {}'.format(POD_NAME), file=sys.stderr)
    print('ELECTION_URI = {}'.format(ELECTION_URI), file=sys.stderr)
    print('SLEEP_TIME = {}'.format(SLEEP_TIME), file=sys.stderr)

    def pause():
        """Sleep"""
        print('Sleeping for {} secs...'.format(SLEEP_TIME), file=sys.stderr)
        time.sleep(SLEEP_TIME)

    def load_data(uri):
        """Load json data from uri"""
        print('Request {}...'.format(uri), file=sys.stderr)
        try:
            with closing(urllib2.urlopen(uri)) as fd:
                s = fd.read()
                print('Response: {}'.format(s), file=sys.stderr)
                return json.loads(s)
        except Exception as e:
            print('Error: {}'.format(e), file=sys.stderr)
            return None

    while True:
        d = load_data(ELECTION_URI)
        if not d:
            pause()
            continue
        endpoints = d.get('endpoints', None)
        master_name = d.get('name', None)
        master_ip = d.get('podIP', None)
        if not endpoints or not master_name or not master_ip:
            pause()
            continue
        check_uri = 'http://{}:{}'.format(master_ip, ELECTION_PORT)
        d1 = load_data(check_uri)
        if not d1:
            pause()
            continue
        if d1 != d:
            print('Election check mismatch: {} != {}'.format(d1, d), file=sys.stderr)
            pause()
            continue
        endpoints = sorted(endpoints, key=lambda i: i['name'])
        # Note: IDs must be greater than 0
        for i, endpoint in enumerate(endpoints):
            endpoint_name = endpoint['name']
            endpoint_ip = endpoint['ip']
            if endpoint_name == master_name:
                print('MASTER_ID={}'.format(i+1))
                print('MASTER_IP={}'.format(endpoint_ip))
                print('MASTER_NAME={}'.format(master_name))
            if endpoint_name == POD_NAME:
                print('NODE_ID={}'.format(i+1))
                print('NODE_IP={}'.format(endpoint_ip))
                if endpoint_name == master_name:
                    node_type = 'master'
                else:
                    node_type = 'standby'
                print('NODE_TYPE={}'.format(node_type))
        break

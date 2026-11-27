#!/usr/bin/env python3
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""List every outgoing network request in a Chromium NetLog.

Usage:
  netlog_report.py <netlog.json> <annotations.xml> [sockets.txt]

A request counts if it leaves the machine: a URL request to an http(s) or
ws(s) URL, a host name resolution, or a TCP/UDP connection to an address that
is not loopback. For URL requests the network traffic annotation names the
code that made it: the NetLog records the annotation's hash, and
tools/traffic_annotation/summary/annotations.xml maps each id to its file.

sockets.txt, if given, holds `ss` lines that netcheck.sh sampled from the
browser's processes. It is a second, independent view: the NetLog only sees
the network service.

Exits 1 if anything went out, 0 if nothing did.
"""

import collections
import ipaddress
import json
import re
import sys
import xml.etree.ElementTree as ElementTree

NETWORK_SCHEMES = ('http://', 'https://', 'ws://', 'wss://')


def annotation_hash(unique_id):
    """net::internal::ComputeAnnotationHash, as Chromium computes it."""
    value = 0
    for char in unique_id.encode():
        value = (value * 31 + char) % 138003713
    return value


def load_annotations(path):
    by_hash = {}
    for item in ElementTree.parse(path).getroot().iter('item'):
        unique_id = item.get('id')
        by_hash[annotation_hash(unique_id)] = (unique_id, item.get('file_path', ''))
    return by_hash


def load_netlog(path):
    """Parse a NetLog, also one cut short because the browser was killed."""
    with open(path, encoding='utf-8') as netlog:
        text = netlog.read()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # The events array is written incrementally; drop a half-written last
        # event and close the document.
        cut = text.rfind('},\n')
        return json.loads(text[:cut + 1] + ']}')


def is_remote(address):
    host = address.rsplit(':', 1)[0].strip('[]')
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return True
    return not (ip.is_loopback or ip.is_unspecified)


def host_of(serialized):
    # "https://example.com:443" or "example.com:443" or "[::1]:80"
    serialized = re.sub(r'^[a-z]+://', '', serialized)
    return re.sub(r':\d+$', '', serialized).strip('[]')


def collect(netlog):
    constants = netlog['constants']
    event_name = {v: k for k, v in constants['logEventTypes'].items()}
    phase_begin = constants['logEventPhase']['PHASE_BEGIN']

    requests = collections.OrderedDict()  # source id -> (url, annotation hash)
    lookups = collections.Counter()
    connects = collections.Counter()

    for event in netlog['events']:
        name = event_name.get(event['type'])
        params = event.get('params') or {}
        if event.get('phase') != phase_begin and name not in (
                'URL_REQUEST_START_JOB',):
            continue
        source = event['source']['id']
        if name in ('REQUEST_ALIVE', 'URL_REQUEST_START_JOB'):
            url = params.get('url')
            if url and url.startswith(NETWORK_SCHEMES):
                previous = requests.get(source, (None, None))
                requests[source] = (
                    previous[0] or url,
                    previous[1] if previous[1] is not None
                    else params.get('traffic_annotation'))
        elif name == 'HOST_RESOLVER_MANAGER_REQUEST':
            host = host_of(params.get('host', ''))
            if host and host != 'localhost' and is_remote(host + ':0'):
                lookups[host] += 1
        elif name in ('TCP_CONNECT', 'UDP_CONNECT'):
            addresses = params.get('address_list') or [params.get('address')]
            for address in filter(None, addresses):
                if is_remote(address):
                    connects[(name.split('_')[0], address)] += 1
    return requests, lookups, connects


def read_sockets(path):
    remote = collections.OrderedDict()
    with open(path, encoding='utf-8') as sockets:
        for line in sockets:
            fields = line.split()
            # ss -tunapH: netid state recv-q send-q local peer process
            if len(fields) >= 6 and is_remote(fields[5]):
                remote[(fields[0], fields[5])] = line.strip()
    return remote


def main(argv):
    if len(argv) not in (3, 4):
        sys.exit(__doc__.strip().splitlines()[2])
    netlog = load_netlog(argv[1])
    annotations = load_annotations(argv[2])
    requests, lookups, connects = collect(netlog)
    sockets = read_sockets(argv[3]) if len(argv) == 4 else {}

    by_request = collections.Counter()
    for url, code in requests.values():
        unique_id, path = annotations.get(code, (
            'unknown annotation %s' % code if code is not None else '-', ''))
        by_request[(host_of(url.split('/')[2]), unique_id, path)] += 1

    print('URL requests: %d' % sum(by_request.values()))
    for (host, unique_id, path), count in sorted(by_request.items()):
        print('  %3d  %-40s %-40s %s' % (count, host, unique_id, path))
    print('Host name lookups: %d' % sum(lookups.values()))
    for host, count in sorted(lookups.items()):
        print('  %3d  %s' % (count, host))
    print('TCP/UDP connections: %d' % sum(connects.values()))
    for (kind, address), count in sorted(connects.items()):
        print('  %3d  %s %s' % (count, kind, address))
    if len(argv) == 4:
        print('Sockets seen by ss: %d' % len(sockets))
        for line in sockets.values():
            print('       ' + line)

    total = sum(by_request.values()) + sum(lookups.values()) + \
        sum(connects.values()) + len(sockets)
    print('TOTAL: %d' % total)
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Read one dependency entry out of a Chromium-style DEPS file.

Several tools Chromium needs at build time are not part of a toolchain package:
they are separate downloads listed in DEPS, and ungoogled-chromium prunes them.
scripts/build.sh fetches those itself. Reading the version out of DEPS on every
build keeps that working across a rebase, instead of pinning artefacts that
belong to one Chromium version.

DEPS is Python, but it calls Var() and is not safe to exec, so this reads the
one entry it is asked for textually.

Usage:
  deps_tool.py <DEPS> gcs  <entry> [host_os]  -> "bucket object_name sha256 output_file"
  deps_tool.py <DEPS> cipd <entry>            -> "package version"

A gcs entry may list one object per host OS, each with its own condition, so
the matching one is picked by host_os ("linux", "mac", "win"; default linux).
output_file is "-" when the entry does not name one, which means the object is
an archive to unpack rather than a single file to install.
"""

import re
import sys

ENTRY_RE = r"'%s':\s*\{(.*?)\n  \},"


def read_entry(deps_path, name):
    with open(deps_path, encoding='utf-8') as deps_file:
        deps = deps_file.read()
    entry = re.search(ENTRY_RE % re.escape(name), deps, re.S)
    if not entry:
        sys.exit('deps_tool.py: no %s entry in %s' % (name, deps_path))
    return entry.group(1)


def field(body, name, default=None):
    found = re.search(r"'%s':\s*'([^']+)'" % name, body)
    if found:
        return found.group(1)
    if default is not None:
        return default
    sys.exit('deps_tool.py: entry has no %s' % name)


def gcs(body, host_os):
    bucket = field(body, 'bucket')
    objects = re.findall(r'\{([^{}]*)\}', body, re.S)
    if not objects:
        sys.exit('deps_tool.py: entry has no objects')

    # Entries that ship one object per platform condition it per object. Ones
    # with a single object usually put the condition on the entry instead.
    chosen = None
    for obj in objects:
        condition = field(obj, 'condition', default='')
        if not condition:
            chosen = chosen or obj
        elif 'host_os == "%s"' % host_os in condition:
            chosen = obj
            break
    if chosen is None:
        sys.exit('deps_tool.py: no object for host_os %s' % host_os)

    return [
        bucket,
        field(chosen, 'object_name'),
        field(chosen, 'sha256sum'),
        field(chosen, 'output_file', default='-'),
    ]


def cipd(body):
    return [field(body, 'package'), field(body, 'version')]


def main(argv):
    if len(argv) < 4 or argv[2] not in ('gcs', 'cipd'):
        sys.exit('usage: deps_tool.py <DEPS> gcs|cipd <entry> [host_os]')
    body = read_entry(argv[1], argv[3])
    if argv[2] == 'gcs':
        values = gcs(body, argv[4] if len(argv) > 4 else 'linux')
    else:
        values = cipd(body)
    print(' '.join(values))


if __name__ == '__main__':
    main(sys.argv)

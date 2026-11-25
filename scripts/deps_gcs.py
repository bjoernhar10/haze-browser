#!/usr/bin/env python3
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Print "bucket object_name sha256" for a gcs entry in Chromium's DEPS.

Some tools Chromium needs at build time are plain Google Cloud Storage objects
listed in DEPS rather than parts of a toolchain package, and ungoogled-chromium
prunes them. scripts/build.sh fetches those itself. Reading the object name and
checksum out of DEPS keeps that working across a rebase, instead of pinning a
binary that belongs to one Chromium version.

DEPS is Python, but it calls Var() and is not safe or convenient to exec, so
this reads the one entry it is asked for textually.

Usage: deps_gcs.py <path to DEPS> <entry name>
"""

import re
import sys

FIELDS = ('bucket', 'object_name', 'sha256sum')


def main(argv):
    if len(argv) != 3:
        sys.exit('usage: deps_gcs.py <DEPS> <entry>')
    deps_path, name = argv[1], argv[2]

    with open(deps_path, encoding='utf-8') as deps_file:
        deps = deps_file.read()

    entry = re.search(r"'%s':\s*\{(.*?)\n  \}," % re.escape(name), deps, re.S)
    if not entry:
        sys.exit('deps_gcs.py: no %s entry in %s' % (name, deps_path))
    body = entry.group(1)

    values = []
    for field in FIELDS:
        found = re.search(r"'%s':\s*'([^']+)'" % field, body)
        if not found:
            sys.exit('deps_gcs.py: %s has no %s' % (name, field))
        values.append(found.group(1))

    print(' '.join(values))


if __name__ == '__main__':
    main(sys.argv)

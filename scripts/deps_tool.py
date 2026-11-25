#!/usr/bin/env python3
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Read one dependency entry out of a Chromium-style DEPS file.

Some tools Chromium needs at build time are not part of a toolchain package:
they are separate downloads listed in DEPS, and ungoogled-chromium prunes them.
scripts/build.sh fetches those itself. Reading the version out of DEPS on every
build keeps that working across a rebase, instead of pinning a binary that
belongs to one Chromium version.

DEPS is Python, but it calls Var() and is not safe to exec, so this reads the
one entry it is asked for textually.

Usage:
  deps_tool.py <DEPS> gcs  <entry>   -> "bucket object_name sha256"
  deps_tool.py <DEPS> cipd <entry>   -> "package version"
"""

import re
import sys

FIELDS = {
    'gcs': ('bucket', 'object_name', 'sha256sum'),
    'cipd': ('package', 'version'),
}


def main(argv):
    if len(argv) != 4 or argv[2] not in FIELDS:
        sys.exit('usage: deps_tool.py <DEPS> gcs|cipd <entry>')
    deps_path, kind, name = argv[1], argv[2], argv[3]

    with open(deps_path, encoding='utf-8') as deps_file:
        deps = deps_file.read()

    # Entries are two spaces deep and close with a line of exactly "  },".
    entry = re.search(r"'%s':\s*\{(.*?)\n  \}," % re.escape(name), deps, re.S)
    if not entry:
        sys.exit('deps_tool.py: no %s entry in %s' % (name, deps_path))
    body = entry.group(1)

    values = []
    for field in FIELDS[kind]:
        found = re.search(r"'%s':\s*'([^']+)'" % field, body)
        if not found:
            sys.exit('deps_tool.py: %s has no %s' % (name, field))
        values.append(found.group(1))

    print(' '.join(values))


if __name__ == '__main__':
    main(sys.argv)

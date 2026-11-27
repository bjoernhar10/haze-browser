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
  deps_tool.py <DEPS> gcs  <entry> [host_os [host_cpu]]
      -> "bucket object_name sha256 output_file"
  deps_tool.py <DEPS> cipd <entry>
      -> "package version"
  deps_tool.py <DEPS> hook <name>
      -> "bucket sha1_file"   (a download_from_google_storage hook)

A gcs entry may list one object per host, each with its own condition, so the
matching one is picked by host_os ("linux", "mac", "win"; default linux) and
host_cpu ("x64", "arm64"; default x64). libclang, for one, ships separate Mac
objects for Intel and Apple Silicon.
output_file is "-" when the entry does not name one, which means the object is
an archive to unpack rather than a single file to install.
"""

import re
import sys

ENTRY_RE = r"'%s':\s*\{(.*?)\n  \},"


def read_entry(deps_path, name):
    """Return (entry body, vars) for one DEPS entry."""
    with open(deps_path, encoding='utf-8') as deps_file:
        deps = deps_file.read()
    entry = re.search(ENTRY_RE % re.escape(name), deps, re.S)
    if not entry:
        sys.exit('deps_tool.py: no %s entry in %s' % (name, deps_path))
    return entry.group(1), read_vars(deps)


def read_vars(deps):
    """Map the names in a DEPS `vars = {...}` block to their string values."""
    block = re.search(r'^vars\s*=\s*\{(.*?)^\}', deps, re.S | re.M)
    if not block:
        return {}
    return dict(re.findall(r"'([A-Za-z0-9_]+)':\s*'([^']*)'", block.group(1)))


def field(body, name, default=None, variables=None):
    """Read one field: a quoted string, a Var('name'), or a `+` of those, e.g.
      'version': Var('dawn_go_version'),
      'package': Var('ninja_package') + '${{platform}}',
    Anything else stops with an error rather than returning half a value.
    """
    found = re.search(r"'%s':\s*(.+?),?\s*$" % name, body, re.M)
    if not found:
        if default is not None:
            return default
        sys.exit('deps_tool.py: entry has no %s' % name)

    expr = found.group(1)
    terms = [t.strip() for t in expr.split('+')]
    value = ''
    for term in terms:
        literal = re.fullmatch(r"'([^']*)'", term)
        var = re.fullmatch(r"Var\('([A-Za-z0-9_]+)'\)", term)
        if literal:
            value += literal.group(1)
        elif var and variables is not None:
            if var.group(1) not in variables:
                sys.exit('deps_tool.py: DEPS has no var %s' % var.group(1))
            value += variables[var.group(1)]
        else:
            sys.exit('deps_tool.py: cannot evaluate %s: %s' % (name, expr))
    return value


def _matches_host(condition, host_os, host_cpu):
    """Whether every host_os/host_cpu clause in a DEPS condition holds."""
    for var, value in re.findall(r'(host_os|host_cpu)\s*==\s*"([^"]+)"',
                                 condition):
        if value != (host_os if var == 'host_os' else host_cpu):
            return False
    return True


def gcs(body, host_os, host_cpu):
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
        elif _matches_host(condition, host_os, host_cpu):
            chosen = obj
            break
    if chosen is None:
        sys.exit('deps_tool.py: no object for %s-%s' % (host_os, host_cpu))

    return [
        bucket,
        field(chosen, 'object_name'),
        field(chosen, 'sha256sum'),
        field(chosen, 'output_file', default='-'),
    ]


def hook(deps_path, name):
    """Bucket and .sha1 file of a download_from_google_storage hook.

    Some Windows tools, rc.exe among them, are not deps but hooks that fetch a
    blob named by the SHA-1 in a file checked into the tree.
    """
    with open(deps_path, encoding='utf-8') as deps_file:
        deps = deps_file.read()
    block = re.search(r"'name':\s*'%s',(.*?)\n  \}," % re.escape(name), deps, re.S)
    if not block:
        sys.exit('deps_tool.py: no %s hook in %s' % (name, deps_path))
    body = block.group(1)
    if 'download_from_google_storage' not in body:
        sys.exit('deps_tool.py: hook %s does not download from storage' % name)
    bucket = re.search(r"'--bucket',\s*'([^']+)'", body)
    sha1_file = re.search(r"'-s',\s*'([^']+)'", body)
    if not bucket or not sha1_file:
        sys.exit('deps_tool.py: hook %s has no --bucket or -s' % name)
    return [bucket.group(1), sha1_file.group(1)]


def cipd(body, variables):
    return [
        field(body, 'package', variables=variables),
        field(body, 'version', variables=variables),
    ]


def main(argv):
    if len(argv) < 4 or argv[2] not in ('gcs', 'cipd', 'hook'):
        sys.exit('usage: deps_tool.py <DEPS> gcs|cipd|hook <entry> '
                 '[host_os [host_cpu]]')
    if argv[2] == 'hook':
        print(' '.join(hook(argv[1], argv[3])))
        return
    body, variables = read_entry(argv[1], argv[3])
    if argv[2] == 'gcs':
        values = gcs(body, argv[4] if len(argv) > 4 else 'linux',
                     argv[5] if len(argv) > 5 else 'x64')
    else:
        values = cipd(body, variables)
    print(' '.join(values))


if __name__ == '__main__':
    main(sys.argv)

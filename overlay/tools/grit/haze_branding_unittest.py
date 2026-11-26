#!/usr/bin/env python3
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Run from build/src: python3 haze/tools/grit/haze_branding_unittest.py"""

import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, '..', '..', '..', 'tools', 'grit'))
sys.path.insert(0, _HERE)

from grit import tclib  # pylint: disable=wrong-import-position
import haze_branding  # pylint: disable=wrong-import-position


def _Ph(name, original):
  return tclib.Placeholder(name, original, 'example')


class RebrandTest(unittest.TestCase):

  def testWord(self):
    self.assertEqual(haze_branding.Rebrand('About Chromium'), 'About Haze')
    self.assertEqual(haze_branding.Rebrand('Chromium aktualisieren'),
                     'Haze aktualisieren')

  def testOtherNamesStay(self):
    for text in ('ChromiumOS', 'ch40m1um.qjz9zk', 'xChromium', 'Chromium2'):
      self.assertEqual(haze_branding.Rebrand(text), text)

  def testInflectedStemKeepsEnding(self):
    self.assertEqual(haze_branding.Rebrand('Chromiumin'), 'Hazein')

  def testPlaceholdersUntouched(self):
    message = tclib.Message(text='Open BROWSER now', placeholders=[
        _Ph('BROWSER', '<b data-x="Chromium">')])
    self.assertEqual(haze_branding.RealContent(message),
                     'Open <b data-x="Chromium"> now')

  def testProjectLinkKeepsChromium(self):
    message = tclib.Message(
        text='Chromium is made possible by the BEGIN_LINK_CHROMIUM'
        'ChromiumEND_LINK_CHROMIUM open source project.',
        placeholders=[_Ph('BEGIN_LINK_CHROMIUM', '<a href="$1">'),
                      _Ph('END_LINK_CHROMIUM', '</a>')])
    self.assertEqual(
        haze_branding.RealContent(message),
        'Haze is made possible by the <a href="$1">Chromium</a> open source '
        'project.')


if __name__ == '__main__':
  unittest.main()

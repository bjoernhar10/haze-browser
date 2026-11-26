# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Puts Haze's name into every string grit writes out.

grit keys each translation by a fingerprint of the English source text, so
renaming the product in the .grd files would orphan the translations of every
string that names it, in all locales. grit's MessageNode.Translate() calls in
here after the translation has been picked instead, so ids never change and
nothing upstream has to be copied or edited.
"""

import re

PRODUCT_NAME = 'Haze'

# The word "Chromium", including the stem of inflected forms ("Chromiuma",
# "Chromiumin"), whose case ending is kept. A letter or digit before it, or an
# uppercase letter after it, means a different name such as "ChromiumOS".
_NAME = re.compile(r'(?<![\w])Chromium(?![A-Z0-9])')

# "<product> is made possible by the Chromium open source project": the link
# text names the project, not the product, in every locale.
_PROJECT_LINK = ('BEGIN_LINK_CHROMIUM', 'END_LINK_CHROMIUM')


def Rebrand(text):
  return _NAME.sub(PRODUCT_NAME, text)


def RealContent(message):
  """Like tclib.Message.GetRealContent(), with the product renamed.

  Placeholders are emitted unchanged: they hold markup and format specifiers,
  not prose.
  """
  parts = message.GetContent()
  bits = []
  for index, part in enumerate(parts):
    if not isinstance(part, str):
      bits.append(part.GetOriginal())
    elif _IsProjectLinkText(parts, index):
      bits.append(part)
    else:
      bits.append(Rebrand(part))
  return ''.join(bits)


def _IsProjectLinkText(parts, index):
  if index == 0 or index + 1 >= len(parts):
    return False
  before, after = parts[index - 1], parts[index + 1]
  return (not isinstance(before, str) and not isinstance(after, str)
          and (before.GetPresentation(), after.GetPresentation())
          == _PROJECT_LINK)

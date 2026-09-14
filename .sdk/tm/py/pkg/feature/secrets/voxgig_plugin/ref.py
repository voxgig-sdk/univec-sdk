# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/ref.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""Identity: name+tag, written `name$tag` (section 4).

The four pure functions, and the whole of what `ref` pins. They are the
first thing a new port implements and the first corpus section it passes.
"""

import re

from .types import fail

# Section 4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024.
#
# `\Z`, NOT `$`. PYTHON'S `$` ALSO MATCHES BEFORE A TRAILING NEWLINE, so
# `^...$` accepts "abc\n" as a plugin name - and nothing else in the
# grammar, in this file, or (until `ref/name#trailing-newline`) in the
# corpus would ever say so. The anchors in the design's grammar mean
# STRING start and end; ruby needs `\A`/`\z` for the same reason, and
# worse, since its `^`/`$` match at every line boundary.
NAME_RE = re.compile(r'^[a-zA-Z@][a-zA-Z0-9.~_\-/]*\Z')

# Section 4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
#
# The asymmetry with a name is deliberate: a tag MAY start with a digit
# because auto-tagging assigns integer tags (`stripe$1`), and a tag admits
# neither `@` nor `/` because a name is a package specifier and a tag is
# not.
TAG_RE = re.compile(r'^[a-zA-Z0-9.~_-]+\Z')

MAX = 1024


def check_name(name):
    if not isinstance(name, str):
        return False
    if 0 == len(name) or MAX < len(name):
        return False
    return None is not NAME_RE.match(name)


def check_tag(tag):
    if not isinstance(tag, str):
        return False
    # The empty tag is an ordinary tag (section 4 rule 2). The
    # single-instance case writes no tag and never learns tags exist.
    if 0 == len(tag):
        return True
    if MAX < len(tag):
        return False
    return None is not TAG_RE.match(tag)


def parse_ref(text):
    """`name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both
    give tag ''."""
    if not isinstance(text, str):
        fail('plugin_bad_name', 'ref must be a string')

    # Split on the FIRST `$`. Nothing in the grammar decides this - `$` is
    # in neither character class - so the corpus is the arbiter (section 4
    # rule 5), and it picks the split that blames the part actually at
    # fault: `a$b$c` is a good name with a bad tag, not the reverse.
    cut = text.find('$')
    name = text if -1 == cut else text[:cut]
    tag = '' if -1 == cut else text[cut + 1:]

    if not check_name(name):
        fail('plugin_bad_name', 'invalid plugin name: ' + name, {'name': name})
    if not check_tag(tag):
        fail('plugin_bad_tag', 'invalid plugin tag: ' + tag,
             {'name': name, 'tag': tag})

    return {'name': name, 'tag': tag}


def format_ref(name, tag=None):
    """The pair -> `name$tag`. An empty tag NEVER writes the separator,
    which is the half of canonicalization format_ref owns: parse tolerates
    `stripe$`, format never produces it, so a round trip is idempotent."""
    tag = '' if None is tag else tag
    if not check_name(name):
        fail('plugin_bad_name', 'invalid plugin name: ' + str(name),
             {'name': name})
    if not check_tag(tag):
        fail('plugin_bad_tag', 'invalid plugin tag: ' + str(tag),
             {'name': name, 'tag': tag})
    return name if '' == tag else name + '$' + tag


def canon_ref(text):
    """The canonical spelling of a ref. Section 4 rule 5: ports must
    canonicalize before comparison."""
    ref = parse_ref(text)
    return format_ref(ref['name'], ref['tag'])


def try_ref(text):
    """The canonical ref this string denotes, or None if it denotes none -
    the TOLERANT half of `canon_ref`, and the one a requirement name needs.

    A REQUIREMENT NAME IS A CAPABILITY NAME FIRST (section 11.1), and
    capability names are free-form: the design puts no grammar on them, so
    `2fa` and `my cap` are perfectly good ones and neither is a well-formed
    ref. `canon_ref` RAISES on those, so asking it "is this a ref?" made a
    legal document kill the host. Answering None is the whole difference.
    """
    if not isinstance(text, str):
        return None
    cut = text.find('$')
    name = text if -1 == cut else text[:cut]
    tag = '' if -1 == cut else text[cut + 1:]
    if not check_name(name) or not check_tag(tag):
        return None
    return name if '' == tag else name + '$' + tag

# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/ref.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# Identity: name+tag, written `name$tag` (section 4).
#
# The four pure functions, and the whole of what `ref` pins. They are the
# first thing a new port implements and the first corpus section it
# passes.

require_relative 'types'

module VoxgigPlugin
  # Section 4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024.
  #
  # \A and \z, NOT ^ and $. Ruby's ^ and $ match at a LINE boundary, so
  # "a\nb$c" would pass a ^...$ anchored name check - a ref grammar with
  # a newline in it, admitted by exactly the port whose regex idiom
  # differs from every other language's.
  NAME_RE = /\A[a-zA-Z@][a-zA-Z0-9.~_\-\/]*\z/.freeze

  # Section 4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
  #
  # The asymmetry with a name is deliberate: a tag MAY start with a digit
  # because auto-tagging assigns integer tags (`stripe$1`), and a tag
  # admits neither `@` nor `/` because a name is a package specifier and
  # a tag is not.
  TAG_RE = /\A[a-zA-Z0-9.~_-]+\z/.freeze

  REF_MAX = 1024

  def self.check_name(name)
    return false unless name.is_a?(String)
    return false if name.empty? || REF_MAX < name.length

    !NAME_RE.match(name).nil?
  end

  def self.check_tag(tag)
    return false unless tag.is_a?(String)
    # The empty tag is an ordinary tag (section 4 rule 2). The
    # single-instance case writes no tag and never learns tags exist.
    return true if tag.empty?
    return false if REF_MAX < tag.length

    !TAG_RE.match(tag).nil?
  end

  # `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both
  # give tag ''.
  def self.parse_ref(str)
    fail_with('plugin_bad_name', 'ref must be a string') unless str.is_a?(String)

    # Split on the FIRST `$`. Nothing in the grammar decides this - `$`
    # is in neither character class - so the corpus is the arbiter
    # (section 4 rule 5), and it picks the split that blames the part
    # actually at fault: `a$b$c` is a good name with a bad tag, not the
    # reverse.
    cut = str.index('$')
    name = cut.nil? ? str : str[0, cut]
    tag = cut.nil? ? '' : str[(cut + 1)..]

    unless check_name(name)
      fail_with('plugin_bad_name', "invalid plugin name: #{name}", { 'name' => name })
    end
    unless check_tag(tag)
      fail_with('plugin_bad_tag', "invalid plugin tag: #{tag}",
                { 'name' => name, 'tag' => tag })
    end

    { 'name' => name, 'tag' => tag }
  end

  # The pair -> `name$tag`. An empty tag NEVER writes the separator,
  # which is the half of canonicalization format_ref owns: parse
  # tolerates `stripe$`, format never produces it, so a round trip is
  # idempotent.
  def self.format_ref(name, tag = nil)
    tag = '' if tag.nil?
    unless check_name(name)
      fail_with('plugin_bad_name', "invalid plugin name: #{name}", { 'name' => name })
    end
    unless check_tag(tag)
      fail_with('plugin_bad_tag', "invalid plugin tag: #{tag}",
                { 'name' => name, 'tag' => tag })
    end
    tag.empty? ? name : "#{name}$#{tag}"
  end

  # The canonical spelling of a ref. Section 4 rule 5: ports must
  # canonicalize before comparison.
  def self.canon_ref(str)
    r = parse_ref(str)
    format_ref(r['name'], r['tag'])
  end

  # canon_ref for the internal callers that want the input back unchanged
  # when it is not well formed. NEVER use it where a bad ref must be
  # reported - the corpus pins plugin_bad_name at every public entry.
  def self.canon(str)
    canon_ref(str)
  rescue PluginError
    str
  end

  def self.refname(str)
    parse_ref(str)['name']
  rescue PluginError
    str
  end
end

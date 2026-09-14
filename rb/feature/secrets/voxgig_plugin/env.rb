# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/env.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# Environment overrides (section 9.5) - level 7 of the ladder.
#
# One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
#
#   VOXGIG_PLUGIN_PROFILE            the profile name
#   VOXGIG_PLUGIN_<REF>_<PATH>       one option
#   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
#
# THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
# OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` ->
# `_`. But `_` is legal in a name and in a tag, and the mapping folds
# case, so `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.
#
# Rather than restrict a grammar the rest of the stack already uses, the
# host DETECTS THE COLLISION: it encodes every ref it holds, and a key
# two refs claim is `plugin_env_ambiguous`, naming both.

require 'json'
require_relative 'types'
require_relative 'ref'

module VoxgigPlugin
  ENV_PREFIX = 'VOXGIG_PLUGIN_'

  # `retry$fast` -> `RETRY__FAST`.
  def self.encode_ref(ref)
    ref.gsub('$', '__').gsub('.', '_').upcase
  end

  def self.apply_env(input)
    input ||= {}
    env = input['env'] || {}
    refs = (input['refs'] || []).map { |r| canon_ref(r) }
    reserved = input['reserved'] || []
    out = { 'options' => {}, 'active' => [], 'inactive' => [] }

    # Encode every ref the host holds, and refuse a key that two of them
    # claim. Done up front so the collision is reported even when no
    # environment variable exercises it - a latent ambiguity is still an
    # ambiguity, and finding it at deploy time is the failure this exists
    # to prevent.
    byencoded = {}
    refs.each { |r| (byencoded[encode_ref(r)] ||= []) << r }
    byencoded.keys.sort.each do |e|
      next unless byencoded[e].length > 1

      pair = byencoded[e].sort
      fail_with('plugin_env_ambiguous',
                "refs collide in the environment encoding as #{e}: #{pair.join(', ')}",
                { 'encoded' => e, 'refs' => pair })
    end

    # Longest encoded ref first, so `retry$fast` wins over `retry` on
    # `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
    encoded = Util.stable_sort_by(byencoded.keys.sort) { |e| -e.length }

    env.keys.sort.each do |key|
      next unless key.start_with?(ENV_PREFIX)

      rest = key[ENV_PREFIX.length..]

      if rest == 'PROFILE'
        out['profile'] = env[key]
        next
      end

      if %w[ACTIVE INACTIVE].include?(rest)
        env_split(env[key]).each do |raw|
          ref = canon_ref(raw)
          # The reservation covers EVERY input layer (section 9.1).
          # VOXGIG_PLUGIN_INACTIVE=station is easier to set than editing
          # a config file, and INACTIVE has the final word - so guarding
          # documents alone would leave the one lever this mechanism
          # exists to deny wide open.
          env_checkreserved(ref, reserved)
          out[rest == 'ACTIVE' ? 'active' : 'inactive'] << ref
        end
        next
      end

      enc = encoded.find { |e| rest == e || rest.start_with?("#{e}_") }
      next if enc.nil?              # not for any ref this host holds

      ref = byencoded[enc][0]
      env_checkreserved(ref, reserved)

      next if rest == enc           # a ref with no path sets nothing

      path = rest[(enc.length + 1)..].downcase.split('_')

      node = out['options'][ref]
      unless node.is_a?(Hash)
        node = {}
        out['options'][ref] = node
      end
      path[0...-1].each do |step|
        child = node[step]
        unless child.is_a?(Hash)
          child = {}
          node[step] = child
        end
        node = child
      end
      node[path[-1]] = env_parsevalue(env[key])
    end

    out
  end

  def self.env_split(value)
    value.to_s.split(',').map(&:strip).reject(&:empty?)
  end

  def self.env_checkreserved(ref, reserved)
    return if reserved.empty?
    return unless reserved.include?(refname(ref))

    fail_with('plugin_ref_reserved', "ref is reserved by the host: #{ref}",
              { 'ref' => ref })
  end

  # Values parse as JSON, FALLING BACK TO STRING - so `8080` is a number,
  # `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
  # looks like rather than a parse error.
  #
  # `quirks_mode` is belt-and-braces for a bare scalar. The json gem
  # shipped with ruby 3.x (2.x) parses `8080` and `true` at the top level
  # without it - RFC 7159 admits them - so on any supported ruby this
  # option changes nothing, and a mutation removing it survives the
  # corpus. It stays because json 1.x did reject them, and because the
  # cost of being wrong about that is every environment scalar silently
  # becoming a string.
  def self.env_parsevalue(value)
    JSON.parse(value, quirks_mode: true)
  rescue StandardError
    value
  end
end

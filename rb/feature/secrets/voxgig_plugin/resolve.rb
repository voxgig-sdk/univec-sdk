# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/resolve.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# Dynamic resolution (section 10.2) - name to candidate module ids.
#
# PURE. It returns the ids a host WOULD try, in order; it does not load
# anything. That separation is what lets the corpus pin resolution in
# every language including those with no dynamic loading at all, and it
# is why section 15.4 puts real module loading in per-port integration
# tests rather than here.

module VoxgigPlugin
  DEFAULT_SOURCES = [
    { 'kind' => 'module',
      'prefix' => ['@voxgig/plugin-', 'voxgig-plugin-', 'plugin-', ''] }
  ].freeze

  def self.resolve_candidates(name, sources = nil)
    out = []

    # A SCOPED NAME RESOLVES VERBATIM ONLY (section 10.2). `@acme/thing`
    # is already a package id; prefixing it produces
    # `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
    return [name] if name.start_with?('@')

    list = sources.nil? || sources.empty? ? DEFAULT_SOURCES : sources

    list.each do |src|
      case src['kind']
      when 'module'
        prefixes = src['prefix']
        prefixes = [''] if prefixes.nil? || prefixes.empty?
        prefixes.each do |p|
          id = p + name
          out << id unless out.include?(id)
        end
      when 'path'
        id = "#{src['dir'].sub(%r{/+\z}, '')}/#{name}"
        out << id unless out.include?(id)
      end
    end

    out
  end

  # A MODULE PATH IS NOT A NAME (section 10.2). The ref grammar starts a
  # name with a letter or `@`, so `./local/thing` is not a ref and never
  # reaches candidate generation - seneca allows a path where a plugin
  # name goes, and this design deliberately does not, because a ref is an
  # ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.
  def self.resolve_from(from)
    [from]
  end
end

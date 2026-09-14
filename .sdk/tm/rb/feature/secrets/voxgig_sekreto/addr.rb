# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ruby/lib/voxgig_sekreto/addr.rb)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The plaintext-address guard, in the core because it is pure - a handful
# of string steps, no socket - and because it is on the spec: every port
# answers the same for every address in spec/def/store.aon. The plugins
# that dial an address call `checkaddr` before they do.
#
# A port of typescript/src/provider/addr.ts, which is canonical.

require_relative 'sekreto'

module VoxgigSekreto
  module_function

  # An address with any userinfo replaced by `[redacted]`, for messages.
  #
  # Every refusal below names the address it refused, and one of them fires
  # precisely because the address carries a credential - so printing it
  # verbatim wrote the password to stderr and into the logs. It cannot be
  # cleaned up afterwards either: that password was never resolved as a
  # secret, so redact() has never seen it and never will. The host is what a
  # reader needs to identify which chain entry is at fault; the userinfo is
  # not.
  def safeaddr(addr)
    mark = addr.index('://')
    return addr if mark.nil?

    rest = addr[(mark + 3)..]
    stop = rest.index(%r{[/?#]})
    authority = stop.nil? ? rest : rest[0...stop]

    at = authority.rindex('@')
    return addr if at.nil?

    addr[0...(mark + 3)] + '[redacted]' + addr[(mark + 3 + at)..]
  end

  # Refuse to send a secret-bearing credential in the clear.
  #
  # A vault API is HTTPS in any real deployment; plaintext is a dev-mode
  # convenience. Sending a token over http to anything but the local
  # machine puts both the token and the secret it fetches on the wire for
  # anyone on the path, so sekreto will not do it. Loopback stays allowed:
  # that is `vault server -dev`, `boru vault serve`, and this repo's own
  # test harness.
  #
  # The address is read by hand, in the same handful of steps in every
  # port, rather than by each platform's URL parser. That is deliberate.
  # Twelve parsers disagree about malformed input - where userinfo ends,
  # whether `0177.0.0.1` is loopback, what an unclosed bracket means - and
  # a check that answers differently in different ports is not a check.
  #
  # The rule this parse obeys, and the reason it can be trusted: it is
  # never more permissive than the HTTP client that will dial the address.
  # It ends the authority at `/`, `?` or `#` only, so a client that also
  # breaks on `\` (WHATWG does) can only ever see a SHORTER host than this
  # does. It refuses userinfo outright rather than locating its end. It
  # compares the host literally, so a numeric form no parser here agrees
  # on is refused rather than guessed at.
  def checkaddr(addr)
    scheme =
      if addr.start_with?('https://')
        'https://'
      elsif addr.start_with?('http://')
        'http://'
      else
        raise SekretoError, 'sekreto: not an http(s) address: ' + safeaddr(addr)
      end

    rest = addr[scheme.length..]
    end_at = rest.index(%r{[/?#]})
    authority = end_at.nil? ? rest : rest[0...end_at]

    # Userinfo is refused outright rather than parsed around, and on https
    # as well as http. No store this library speaks authenticates by
    # userinfo - they take a token or a signature - so an address carrying
    # one is a mistake at best. At worst it is the attack this whole
    # method exists to stop: `http://localhost:8200@evil.example.com/` is
    # a request to evil.example.com that reads, to anything that splits
    # the authority on ':', as loopback.
    if authority.include?('@')
      raise SekretoError, 'sekreto: refusing an address with embedded credentials: ' + safeaddr(addr)
    end

    # An opening bracket with no closing one is not an address at all.
    if authority.start_with?('[') && !authority.include?(']')
      raise SekretoError, 'sekreto: not a valid http(s) address: ' + safeaddr(addr)
    end

    return if 'https://' == scheme

    # A bracketed IPv6 literal keeps its brackets. Splitting the authority
    # on the first colon yields '[', so `http://[::1]:8200` could never
    # match - which made the '[::1]' entry below unreachable, and refused
    # a legitimate local vault.
    host =
      if authority.start_with?('[')
        authority[0..authority.index(']')]
      else
        authority.split(':')[0].to_s
      end

    return if ['localhost', '127.0.0.1', '::1', '[::1]'].include?(host.downcase)

    raise SekretoError,
          'sekreto: refusing to send a token in plaintext to ' + safeaddr(addr) + ' (use https)'
  end
end

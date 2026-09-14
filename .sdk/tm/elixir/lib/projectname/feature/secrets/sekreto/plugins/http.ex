# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/http.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# One HTTP round-trip, framed in-tree over OTP's own sockets - and
# OUTSIDE THE CORE, because a socket is what makes a kind a plugin. Seven
# of the ten plugin kinds reach a vault over HTTPS; a chain of the four
# built-ins never loads this module at all, and the BEAM never loads a
# module nothing calls.
#
# `:httpc` is in the distribution and is not used. Three of this library's
# rules are not expressible through it: the 8 MiB body bound (httpc
# buffers whatever arrives before the caller sees a byte), the single
# ten-second deadline across connect, send and read, and the guarantee
# that no proxy is consulted - httpc's proxy, cookie and redirect settings
# live on a shared profile that the host application may already have
# configured. So the request line, the headers and the chunked body are
# assembled and read here, over `:gen_tcp` and `:ssl` directly.
#
# Response headers are decoded by OTP's `{:packet, :http_bin}` mode, which
# is part of the runtime rather than a dependency.
#
# TLS is NOT hand-rolled: `:ssl` is OTP's, and it is the audit surface.
#
# THE URL FUNCTIONS LIVE HERE, not with the signer that also needs them.
# Splitting a URL and escaping a query parameter is what a client does on
# every request; SigV4 canonicalises the same pieces, so it calls these -
# the other way round would make every HTTPS kind reach a hash function
# for a string function. Ruby's port draws the same line.
#
# The models are rust/src/http.rs and the framing recipe every port
# without a client follows.

defmodule Sekreto.Plugins.Http do
  @moduledoc """
  The HTTP/1.1 client sekreto carries, and the TLS binding with it.

  A plugin module: nothing under `src/` names it. See
  docs/design/plugin-providers.md.
  """

  alias Sekreto.Error

  # How long any single vault round-trip may take before the store is
  # treated as unreachable. Ports carry the same bound, and it covers the
  # whole trip - connect, send and read - not each step, because a deadline
  # per step is no deadline at all when the name resolves to many addresses.
  @timeout 10_000

  # How much of a response body will be read before the store is treated as
  # having answered incoherently. Far above anything real: the largest
  # legitimate payload this library fetches is Doppler's whole-config
  # download, measured in kilobytes. A bound is needed because the timeout
  # is not one - ten seconds on a loopback or datacentre link is gigabytes,
  # and this runs on an application's startup path, so the failure is the
  # application never starting.
  @maxbody 8 * 1024 * 1024

  # Headers are bounded too, and much harder: nothing legitimate sends more.
  @maxhead 64 * 1024

  @doc "A URL without its query string, for a message that must not leak one."
  def bare(url), do: url |> :binary.split("?") |> hd()

  @doc """
  RFC 3986 escaping, which is stricter than the usual URL encoder: AWS
  wants everything but unreserved characters escaped, with uppercase hex.
  """
  def uriescape(text) do
    text
    |> :binary.bin_to_list()
    |> Enum.map_join("", fn ch ->
      if (?A <= ch and ?Z >= ch) or (?a <= ch and ?z >= ch) or (?0 <= ch and ?9 >= ch) or
           ch in [?-, ?_, ?., ?~] do
        <<ch>>
      else
        # UPPERCASE hex, deliberately: RFC 3986 and AWS SigV4 both
        # specify uppercase percent-escapes, and Integer.to_string/2
        # already gives that. src/json.ex uses the same call and must
        # LOWERCASE it -- the two are opposite requirements, which is
        # exactly how one gets copied onto the other by mistake.
        #
        # THE SPLIT MOVED THIS, TWICE, AND THE PAIRING SURVIVED BOTH:
        # `uriescape` was in src/sigv4.ex, went to plugins/ with the
        # signer, and then came here so that a kind which signs nothing
        # does not reach a hash function to escape a query parameter.
        # src/json.ex stayed in the core. Neither file is beside the
        # other any more, so each names the other outright, and
        # `hexcase` in test/plugins_test.exs pins the pair: no
        # conformance group and no integration check can see a flip.
        "%" <> String.pad_leading(Integer.to_string(ch, 16), 2, "0")
      end
    end)
  end

  @doc "Percent-decode, and nothing else: `+` stays `+`, as on the wire."
  def uridecode(text), do: uridecode(text, [])

  defp uridecode(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp uridecode(<<?%, hi, lo, rest::binary>> = text, acc) do
    case Integer.parse(<<hi, lo>>, 16) do
      {code, ""} ->
        uridecode(rest, [<<code>> | acc])

      # A stray % is kept as-is, the way a browser would.
      _other ->
        <<head, more::binary>> = text
        uridecode(more, [<<head>> | acc])
    end
  end

  defp uridecode(<<head, rest::binary>>, acc), do: uridecode(rest, [<<head>> | acc])

  @doc """
  The `host` header value for a URL: the WHATWG `URL.host` - hostname
  lowercased, userinfo stripped, and the port appended only when it is not
  the scheme's default.

  Hand-split, like `checkaddr`: a platform URL type is free to disagree,
  and `Host: example.com:443` is not what a signature covering `host`
  was computed over.
  """
  def urlhost(url) do
    {scheme, authority, _path, _query} = urlparts(url)

    authority =
      case String.split(authority, "@") do
        [only] -> only
        many -> List.last(many)
      end

    {host, port} =
      if String.starts_with?(authority, "[") do
        case :binary.match(authority, "]") do
          {at, _len} ->
            {binary_part(authority, 0, at + 1),
             binary_part(authority, at + 1, byte_size(authority) - at - 1)}

          :nomatch ->
            {authority, ""}
        end
      else
        case :binary.split(authority, ":") do
          [only] -> {only, ""}
          [head, tail] -> {head, ":" <> tail}
        end
      end

    port =
      cond do
        ":" == port -> ""
        "https://" == scheme and ":443" == port -> ""
        "http://" == scheme and ":80" == port -> ""
        true -> port
      end

    String.downcase(host, :ascii) <> port
  end

  @doc """
  A URL split into scheme, authority, raw path and raw query - by hand, so
  that every port cuts it in the same place.
  """
  def urlparts(url) do
    {scheme, rest} =
      cond do
        String.starts_with?(url, "https://") -> {"https://", binary_part(url, 8, byte_size(url) - 8)}
        String.starts_with?(url, "http://") -> {"http://", binary_part(url, 7, byte_size(url) - 7)}
        true -> {"", url}
      end

    {authority, tail} =
      case cutat(rest, [?/, ??, ?#]) do
        nil -> {rest, ""}
        at -> {binary_part(rest, 0, at), binary_part(rest, at, byte_size(rest) - at)}
      end

    {tail, _fragment} =
      case cutat(tail, [?#]) do
        nil -> {tail, ""}
        at -> {binary_part(tail, 0, at), binary_part(tail, at, byte_size(tail) - at)}
      end

    {path, query} =
      case :binary.split(tail, "?") do
        [only] -> {only, ""}
        [head, more] -> {head, more}
      end

    {scheme, authority, path, query}
  end

  defp cutat(text, chars), do: cutat(text, chars, 0)

  defp cutat(text, chars, at) do
    case text do
      <<_::binary-size(at), ch, _::binary>> ->
        if ch in chars, do: at, else: cutat(text, chars, at + 1)

      _other ->
        nil
    end
  end

  @doc """
  One request. Answers `%{status: integer, body: binary}`.

  Every failure to complete the trip raises: an unreachable store is a
  store that could not answer, never a store that did not have the secret.

  Redirects are never followed. A followed redirect would carry
  `X-Vault-Token` to a host `checkaddr` never saw, and could downgrade
  https to http.
  """
  def fetch(method, url, headers \\ [], body \\ nil) do
    deadline = now() + @timeout

    {scheme, authority, rawpath, rawquery} = urlparts(url)
    tls = "https://" == scheme

    {host, port} = hostport(authority, tls)

    path = if "" == rawpath, do: "/", else: rawpath
    target = if "" == rawquery, do: path, else: path <> "?" <> rawquery

    request = [
      String.upcase(method, :ascii),
      " ",
      target,
      " HTTP/1.1\r\n",
      # A default port stays implicit: a SigV4 signature covers `host`, and
      # `Host: example.com:443` is not what was signed.
      "Host: ",
      urlhost(url),
      "\r\n",
      "Accept: application/json\r\n",
      "Connection: close\r\n",
      Enum.map(headers, fn {key, value} -> [key, ": ", value, "\r\n"] end),
      if(nil == body, do: [], else: ["Content-Length: ", Integer.to_string(byte_size(body)), "\r\n"]),
      "\r\n",
      body || ""
    ]

    {kind, sock} = connect(url, host, port, tls, deadline)

    try do
      send!(url, kind, sock, request)
      {status, resheaders} = readhead(url, kind, sock, deadline)
      %{status: status, body: readbody(url, kind, sock, deadline, resheaders)}
    after
      close(kind, sock)
    end
  end

  # ------------------------------------------------------------- the wire

  defp now, do: System.monotonic_time(:millisecond)

  defp left(url, deadline) do
    remaining = deadline - now()
    if 0 >= remaining, do: unreachable(url, "timed out")
    remaining
  end

  defp unreachable(url, why) do
    raise Error, message: "sekreto: cannot reach " <> bare(url) <> ": " <> why
  end

  defp reason(why) when is_binary(why), do: why
  defp reason(why) when is_atom(why), do: to_string(:inet.format_error(why))
  defp reason(why), do: inspect(why)

  # The authority, split by hand. The port is found by a REVERSE search for
  # `:` so that an IPv6 literal's own colons are not read as one; the bare
  # host - brackets stripped - is what is dialled and what the certificate
  # is checked against.
  defp hostport(authority, tls) do
    authority =
      case String.split(authority, "@") do
        [only] -> only
        many -> List.last(many)
      end

    {host, port} =
      if String.starts_with?(authority, "[") do
        case :binary.match(authority, "]") do
          {at, _len} ->
            {binary_part(authority, 1, at - 1),
             binary_part(authority, at + 1, byte_size(authority) - at - 1)}

          :nomatch ->
            {authority, ""}
        end
      else
        case :binary.matches(authority, ":") do
          [] ->
            {authority, ""}

          found ->
            {at, _len} = List.last(found)
            {binary_part(authority, 0, at), binary_part(authority, at, byte_size(authority) - at)}
        end
      end

    number =
      case port do
        ":" <> digits ->
          case Integer.parse(digits) do
            {value, ""} -> value
            _other -> if tls, do: 443, else: 80
          end

        _other ->
          if tls, do: 443, else: 80
      end

    {host, number}
  end

  defp connect(url, host, port, false, deadline) do
    opts = [:binary, active: false, packet: :raw, nodelay: true]

    case :gen_tcp.connect(dial(host), port, opts, left(url, deadline)) do
      {:ok, sock} -> {:tcp, sock}
      {:error, why} -> unreachable(url, reason(why))
    end
  end

  defp connect(url, host, port, true, deadline) do
    start()

    case :ssl.connect(dial(host), port, tlsopts(host), left(url, deadline)) do
      {:ok, sock} ->
        checkpeer(url, host, sock)
        {:tls, sock}

      {:error, why} ->
        unreachable(url, reason(why))
    end
  end

  # An IP literal is dialled as an address tuple, a name as a charlist:
  # `:gen_tcp.connect` then resolves the name itself, under the ONE
  # deadline, rather than this code giving each returned address a fresh
  # ten seconds.
  defp dial(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> address
      {:error, _why} -> String.to_charlist(host)
    end
  end

  # The four obligations of a TLS binding, spelled out. A binding that
  # connects without verifying is worse than no TLS, because it looks like
  # it works.
  defp tlsopts(host) do
    literal = match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))

    [
      :binary,
      active: false,
      packet: :raw,
      # (1) verify the chain, against the system trust store plus whatever
      # SEKRETO_CA_BUNDLE adds.
      verify: :verify_peer,
      cacerts: roots(),
      depth: 10,
      versions: [:"tlsv1.2", :"tlsv1.3"],
      # (2) verify the hostname. Separate from the chain, and the half
      # people forget.
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      # (3) send SNI - but never for an IP literal, which RFC 6066 forbids.
      server_name_indication: if(literal, do: :disable, else: String.to_charlist(host)),
      # A refused handshake is reported by the error this raises; OTP's own
      # notice would put a second copy of it on the host application's
      # stderr, which is not this library's to write on.
      log_level: :none
    ]
  end

  # (2), continued. OTP matches a DNS name for us; an IP literal is checked
  # here, explicitly, against the certificate's iPAddress SAN. `SSL_set1_host`
  # and its equivalents do DNS-name matching and will not match an address,
  # and this repository's only TLS test endpoint is an address.
  defp checkpeer(url, host, sock) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:error, _why} ->
        :ok

      {:ok, address} ->
        with {:ok, der} <- :ssl.peercert(sock),
             cert <- :public_key.pkix_decode_cert(der, :otp),
             true <- :public_key.pkix_verify_hostname(cert, [{:ip, address}]) do
          :ok
        else
          _other -> unreachable(url, "certificate does not name " <> host)
        end
    end
  end

  @doc """
  The trust roots: the platform's, plus any certificate `SEKRETO_CA_BUNDLE`
  names.

  ADDITIVE, never a replacement, and it fails open in silence - an
  unreadable file or an unparseable certificate adds no roots and raises
  nothing, exactly as in every other port.
  """
  def roots do
    system = platformroots()
    system ++ pemcerts(System.get_env("SEKRETO_CA_BUNDLE"))
  end

  defp platformroots do
    Code.ensure_loaded(:public_key)

    got =
      if function_exported?(:public_key, :cacerts_get, 0) do
        try do
          :public_key.cacerts_get()
        rescue
          _err -> []
        catch
          _kind, _err -> []
        end
      else
        []
      end

    if [] == got, do: pemcerts("/etc/ssl/certs/ca-certificates.crt"), else: got
  end

  defp pemcerts(nil), do: []
  defp pemcerts(""), do: []

  defp pemcerts(path) do
    case File.read(path) do
      {:ok, pem} ->
        try do
          pem
          |> :public_key.pem_decode()
          |> Enum.filter(fn {label, _der, _cipher} -> :Certificate == label end)
          |> Enum.map(fn {_label, der, _cipher} -> der end)
        rescue
          _err -> []
        catch
          _kind, _err -> []
        end

      {:error, _why} ->
        []
    end
  end

  defp send!(url, kind, sock, data) do
    case tsend(kind, sock, data) do
      :ok -> :ok
      {:error, why} -> unreachable(url, reason(why))
    end
  end

  defp tsend(:tcp, sock, data), do: :gen_tcp.send(sock, data)
  defp tsend(:tls, sock, data), do: :ssl.send(sock, data)

  defp trecv(:tcp, sock, len, timeout), do: :gen_tcp.recv(sock, len, timeout)
  defp trecv(:tls, sock, len, timeout), do: :ssl.recv(sock, len, timeout)

  defp tsetopts(:tcp, sock, opts), do: :inet.setopts(sock, opts)
  defp tsetopts(:tls, sock, opts), do: :ssl.setopts(sock, opts)

  defp close(:tcp, sock), do: :gen_tcp.close(sock)
  defp close(:tls, sock), do: :ssl.close(sock)

  # The status line and the headers, decoded by OTP's own HTTP packet mode.
  defp readhead(url, kind, sock, deadline) do
    tsetopts(kind, sock, packet: :http_bin)

    status =
      case trecv(kind, sock, 0, left(url, deadline)) do
        {:ok, {:http_response, _version, code, _phrase}} -> code
        {:ok, other} -> unreachable(url, "not an http response: " <> inspect(other))
        {:error, why} -> unreachable(url, reason(why))
      end

    {status, readheaders(url, kind, sock, deadline, [], 0)}
  end

  defp readheaders(url, kind, sock, deadline, acc, taken) do
    if @maxhead < taken do
      raise Error, message: "sekreto: oversized response from " <> bare(url)
    end

    case trecv(kind, sock, 0, left(url, deadline)) do
      {:ok, :http_eoh} ->
        acc

      {:ok, {:http_header, _len, name, _reserved, value}} ->
        key = String.downcase(to_string(name), :ascii)
        text = to_string(value)
        readheaders(url, kind, sock, deadline, [{key, text} | acc], taken + byte_size(text) + 32)

      {:ok, _other} ->
        readheaders(url, kind, sock, deadline, acc, taken)

      {:error, why} ->
        unreachable(url, reason(why))
    end
  end

  defp readbody(url, kind, sock, deadline, resheaders) do
    tsetopts(kind, sock, packet: :raw)

    chunked =
      case List.keyfind(resheaders, "transfer-encoding", 0) do
        {_key, value} -> String.contains?(String.downcase(value, :ascii), "chunked")
        nil -> false
      end

    length =
      case List.keyfind(resheaders, "content-length", 0) do
        {_key, value} ->
          case Integer.parse(String.trim(value)) do
            {count, ""} -> count
            _other -> nil
          end

        nil ->
          nil
      end

    cond do
      chunked ->
        unchunk(url, drain(url, kind, sock, deadline, nil))

      nil != length ->
        if @maxbody < length do
          raise Error, message: "sekreto: oversized response from " <> bare(url)
        end

        drain(url, kind, sock, deadline, length)

      true ->
        # `Connection: close` was sent, so the server ends the body by
        # ending the connection.
        drain(url, kind, sock, deadline, nil)
    end
  end

  # Read `want` bytes, or everything up to the close when `want` is nil.
  # One byte over the bound is enough to know it was exceeded; an endless
  # body is a store that could not answer, so this raises rather than
  # answering a miss on an attacker's cue.
  defp drain(url, kind, sock, deadline, want), do: drain(url, kind, sock, deadline, want, [], 0)

  defp drain(url, kind, sock, deadline, want, acc, taken) do
    cond do
      @maxbody < taken ->
        raise Error, message: "sekreto: oversized response from " <> bare(url)

      nil != want and taken >= want ->
        acc |> Enum.reverse() |> IO.iodata_to_binary() |> binary_part(0, want)

      true ->
        ask = if nil == want, do: 0, else: min(want - taken, @maxbody + 1 - taken)

        case trecv(kind, sock, ask, left(url, deadline)) do
          {:ok, piece} ->
            drain(url, kind, sock, deadline, want, [piece | acc], taken + byte_size(piece))

          {:error, :closed} when nil == want ->
            acc |> Enum.reverse() |> IO.iodata_to_binary()

          {:error, why} ->
            unreachable(url, reason(why))
        end
    end
  end

  # Chunked bodies, by hand: a hex length (any `;`-separated extension
  # dropped), CRLF, that many BYTES, CRLF. Bytes, not characters: a chunk
  # boundary may fall inside a multibyte character, and a secret holding
  # one would otherwise take the process down.
  defp unchunk(url, body), do: unchunk(url, body, [])

  defp unchunk(url, body, acc) do
    case :binary.split(body, "\r\n") do
      [head, rest] ->
        size =
          head
          |> :binary.split(";")
          |> hd()
          |> String.trim()
          |> Integer.parse(16)

        case size do
          {0, ""} ->
            acc |> Enum.reverse() |> IO.iodata_to_binary()

          {count, ""} when byte_size(rest) >= count ->
            piece = binary_part(rest, 0, count)
            tail = binary_part(rest, count, byte_size(rest) - count)

            tail =
              case tail do
                "\r\n" <> more -> more
                _other -> tail
              end

            unchunk(url, tail, [piece | acc])

          _other ->
            raise Error, message: "sekreto: malformed response from " <> bare(url)
        end

      [_only] ->
        raise Error, message: "sekreto: malformed response from " <> bare(url)
    end
  end

  @doc "The applications a round-trip needs, started explicitly."
  def start do
    {:ok, _apps} = :application.ensure_all_started(:ssl)
    :ok
  end
end

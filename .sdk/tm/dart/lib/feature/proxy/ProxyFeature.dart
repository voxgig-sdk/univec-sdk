// ignore_for_file: non_constant_identifier_names

import 'dart:io';

import '../base/BaseFeature.dart';

// Outbound HTTP(S) proxy support. Wraps the active transport and attaches
// proxy routing to each request's fetch definition. The proxy target comes
// from options (`url`) or, when `fromEnv` is set, the standard
// HTTPS_PROXY / HTTP_PROXY / NO_PROXY environment variables. Constructing a
// concrete proxied client is transport-specific, so a factory may be
// supplied via `options.agent`; when absent the request is annotated with
// `fetchdef.proxy` for the transport to honour. Hosts matching `noProxy`
// bypass the proxy.
class ProxyFeature extends BaseFeature {
  dynamic _client;
  dynamic _url;
  List<String> _noProxy = [];

  ProxyFeature() {
    version = '0.0.1';
    name = 'proxy';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];

    if (!active) {
      return null;
    }

    _url = options['url'];
    dynamic noProxy = options['noProxy'];

    if (true == options['fromEnv']) {
      final env = Platform.environment;
      _url = _url ??
          env['HTTPS_PROXY'] ??
          env['https_proxy'] ??
          env['HTTP_PROXY'] ??
          env['http_proxy'];
      noProxy = noProxy ?? env['NO_PROXY'] ?? env['no_proxy'];
    }

    _noProxy = (noProxy is String
            ? noProxy.split(RegExp(r'\s*,\s*'))
            : (noProxy is List ? noProxy.map((s) => s.toString()).toList() : <String>[]))
        .where((s) => '' != s)
        .map((s) => s.toString())
        .toList();

    final self = this;
    final utility = ctx.utility;
    final inner = utility.fetcher;

    utility.fetcher = (dynamic ctx2, dynamic url, dynamic fetchdef) async {
      fetchdef = self._route(url, fetchdef);
      return inner(ctx2, url, fetchdef);
    };
    return null;
  }

  dynamic _route(dynamic url, dynamic fetchdef) {
    if (null == _url || _bypass(url.toString())) {
      return fetchdef;
    }

    final out = <String, dynamic>{};
    if (fetchdef is Map) {
      fetchdef.forEach((k, v) => out[k.toString()] = v);
    }
    out['proxy'] = _url;

    final agent = options['agent'];
    if (agent is Function) {
      // Factory returns a transport-specific agent/dispatcher.
      final made = agent(_url, url);
      out['dispatcher'] = made;
      out['agent'] = made;
    }

    _track(url);
    return out;
  }

  bool _bypass(String url) {
    if (0 == _noProxy.length) {
      return false;
    }
    var host = url;
    final m = RegExp(r'^[a-z]+://([^/:]+)', caseSensitive: false).firstMatch(url);
    if (null != m) {
      host = m.group(1)!;
    }
    for (final np in _noProxy) {
      if ('*' == np) {
        return true;
      }
      if (host == np ||
          host.endsWith('.' + np.replaceFirst(RegExp(r'^\.'), ''))) {
        return true;
      }
    }
    return false;
  }

  void _track(dynamic url) {
    final track = _client.track;
    if (null == track['proxy']) {
      track['proxy'] = {'routed': 0, 'url': _url};
    }
    track['proxy']['routed']++;
  }
}

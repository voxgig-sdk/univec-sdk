// ignore_for_file: non_constant_identifier_names

import '../../utility/voxgig_struct.dart' as vs;

import '../base/BaseFeature.dart';

// Pagination support for list operations. On the way out (PreRequest) it
// stamps page/limit (or a cursor) into the request query; on the way back
// (PreResult) it reads the server's pagination signals — a `Link:
// rel="next"` header, `X-Next-Page`/`X-Total-Count` headers, or `next`/
// `cursor`/`hasMore` fields in the body — and records them on
// `ctx.result.paging`. Generated SDKs build auto-iteration on top of this
// (advance the cursor/page and re-issue the list call until `hasMore` is
// false). Parameter names and page size are configurable.
class PagingFeature extends BaseFeature {
  dynamic _client;

  PagingFeature() {
    version = '0.0.1';
    name = 'paging';
    active = true;
  }

  @override
  dynamic init(dynamic ctx, dynamic opts) {
    _client = ctx.client;
    options = opts is Map ? Map<String, dynamic>.from(opts) : {};
    active = true == options['active'];
    return null;
  }

  @override
  dynamic PreRequest(dynamic ctx) {
    if (!_isList(ctx)) {
      return null;
    }
    final spec = ctx.spec;
    if (null == spec) {
      return null;
    }
    spec.query ??= {};

    final pageParam = options['pageParam'] ?? 'page';
    final limitParam = options['limitParam'] ?? 'limit';
    final cursorParam = options['cursorParam'] ?? 'cursor';

    // A per-call cursor/page from ctrl takes priority (used by auto-iteration).
    final paging = (ctx.ctrl is Map ? ctx.ctrl['paging'] : null) ?? {};

    // GraphQL paginates through operation VARIABLES, not the query string.
    // This hook runs after makeSpec, so spec.body already holds the
    // { query, variables } envelope, and before makeFetchDef serialises it.
    if ('graphql' == ctx.point?.kind) {
      _graphqlPreRequest(ctx, paging);
      return null;
    }

    if (null != paging['cursor']) {
      spec.query[cursorParam] = paging['cursor'];
    } else if (null == spec.query[pageParam]) {
      spec.query[pageParam] =
          null != paging['page'] ? paging['page'] : (options['startPage'] ?? 1);
    }

    if (null != options['limit'] && null == spec.query[limitParam]) {
      spec.query[limitParam] = options['limit'];
    }
    return null;
  }

  // Relay pagination: the cursor is the `after` variable (or whatever the
  // model named it), and the page size is `first`.
  void _graphqlPreRequest(dynamic ctx, dynamic paging) {
    final body = ctx.spec.body;
    if (body is! Map) {
      return;
    }

    var variables = body['variables'];
    if (variables is! Map) {
      variables = <String, dynamic>{};
      body['variables'] = variables;
    }

    final afterVar = options['afterVar'] ?? 'after';
    final firstVar = options['firstVar'] ?? 'first';

    // Only bind variables the operation actually declares, or the server
    // rejects the document.
    final declared = <String>{};
    final varlist = vs.getprop(ctx.point?.graphql, 'vars');
    if (varlist is List) {
      for (final v in varlist) {
        final name = vs.getprop(v, 'name');
        if (null != name) {
          declared.add(name.toString());
        }
      }
    }

    if (null != paging['cursor'] && declared.contains(afterVar)) {
      variables[afterVar] = paging['cursor'];
    }

    if (null != options['limit'] && null == variables[firstVar] &&
        declared.contains(firstVar)) {
      variables[firstVar] = options['limit'];
    }
  }

  @override
  dynamic PreResult(dynamic ctx) {
    if (!_isList(ctx)) {
      return null;
    }
    final result = ctx.result;
    if (null == result) {
      return null;
    }

    final headers = result.headers ?? {};
    final body = result.body;

    final paging = <String, dynamic>{
      'page': _num(_header(headers, 'x-page')),
      'totalCount': _num(_header(headers, 'x-total-count')),
      'nextPage': _num(_header(headers, 'x-next-page')),
      'next': null,
      'cursor': null,
      'hasMore': false,
    };

    // Link: <...>; rel="next"
    final link = _header(headers, 'link');
    if (null != link) {
      final m = RegExp(r'<([^>]+)>\s*;\s*rel="?next"?', caseSensitive: false)
          .firstMatch(link.toString());
      if (null != m) {
        paging['next'] = m.group(1);
      }
    }

    // Set when the response states hasMore outright, rather than leaving it
    // to be inferred from the presence of a cursor.
    var explicitMore = false;

    // Relay connections carry the cursor in pageInfo, at the path the model
    // recorded for this op.
    final page = vs.getprop(ctx.point?.graphql, 'page');
    if (page is Map && body is Map) {
      // `connpath` locates the connection object inside the response
      // envelope (data.<field>); the cursor/more paths are relative to it.
      var conn = body;
      final connpath = page['connpath'];
      if (connpath is String && '' != connpath) {
        final sub = vs.getpath(body, connpath);
        if (sub is Map) {
          conn = sub;
        }
      }

      final cursorpath = page['cursor'];
      if (cursorpath is String && '' != cursorpath) {
        final cursor = vs.getpath(conn, cursorpath);
        if (null != cursor) {
          paging['cursor'] = cursor;
        }
      }

      final morepath = page['more'];
      if (morepath is String && '' != morepath) {
        final more = vs.getpath(conn, morepath);
        if (more is bool) {
          paging['hasMore'] = more;
          explicitMore = true;
        }
      }
    }

    // Body-level cursors.
    if (body is Map) {
      if (null != body['next']) {
        paging['next'] = paging['next'] ?? body['next'];
      }
      if (null != body['cursor']) {
        paging['cursor'] = body['cursor'];
      }
      if (null != body['nextCursor']) {
        paging['cursor'] = body['nextCursor'];
      }
      if (body['hasMore'] is bool) {
        paging['hasMore'] = body['hasMore'];
        explicitMore = true;
      }
    }

    // Cursor presence only INFERS another page. When the server stated the
    // answer outright — relay's `hasNextPage: false`, or a body `hasMore` —
    // that wins: a final page normally carries both an end cursor and
    // hasNextPage false, and inferring from the cursor there would send the
    // caller back for a page that does not exist, forever.
    if (!explicitMore) {
      paging['hasMore'] = true == paging['hasMore'] ||
          null != paging['next'] ||
          null != paging['cursor'] ||
          null != paging['nextPage'];
    }

    result.paging = paging;

    final track = _client.track;
    track['paging'] = <String, dynamic>{'last': paging};
    return null;
  }

  bool _isList(dynamic ctx) {
    final ops = options['ops'] ?? ['list'];
    return (ops as List).contains(null == ctx.op ? null : ctx.op.name);
  }

  dynamic _header(dynamic headers, String name) {
    final lower = name.toLowerCase();
    if (headers is! Map) {
      return null;
    }
    for (final k in headers.keys) {
      if (k.toString().toLowerCase() == lower) {
        return headers[k];
      }
    }
    return null;
  }

  num? _num(dynamic v) {
    if (null == v) {
      return null;
    }
    return v is num ? v : num.tryParse(v.toString());
  }
}

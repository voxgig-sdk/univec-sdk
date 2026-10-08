import 'dart:async';

import '../UnivecError.dart';

const previewLength = 160;

Future<dynamic> resultBody(dynamic ctx) async {
  final response = ctx.response;
  final result = ctx.result;

  if (null != result) {
    if (null != response && null != response.jsonFn && null != response.body) {
      final json = await response.json();
      result.body = json;
    }
    if (null != response && true == response.unreadable) {
      final spec = ctx.spec;
      result.err = unreadableBody(ctx, result.status, result.headers,
          response.body, null == spec ? null : spec.headers, result.err);
    }
  }

  return result;
}

// A body that is not JSON. An HTTP failure keeps its own error, with the
// response described; otherwise the code tells a wrong content type from
// malformed JSON.
dynamic unreadableBody(dynamic ctx, dynamic status, dynamic headers,
    dynamic text, dynamic sent, dynamic failed) {
  final type = _headerValue(headers, 'content-type');
  final agent = _clean(ctx, _headerValue(sent, 'user-agent'));
  final detail = 'HTTP $status, content-type ${'' == type ? 'none' : type}'
      ', user-agent ${'' == agent ? 'transport default' : agent}'
      '${null == text ? '' : ', body: ${_preview(ctx, text)}'}';

  if (failed is UnivecError) {
    failed.message = '${failed.message} ($detail)';
    return failed;
  }
  if (null != failed) {
    return ctx.error('', '$failed ($detail)');
  }

  return '' == type || type.toLowerCase().contains('json')
      ? ctx.error(
          'response_json_invalid', 'response: body is not valid JSON ($detail)')
      : ctx.error('response_content_type',
          'response: expected JSON, got $type ($detail)');
}

String _headerValue(dynamic headers, String name) {
  if (headers is Map) {
    for (final key in headers.keys) {
      if (name == key.toString().toLowerCase()) {
        return headers[key].toString();
      }
    }
  }
  return '';
}

String _clean(dynamic ctx, String text) {
  final cleaned = ctx.utility.clean(ctx, text);
  return null == cleaned ? text : cleaned.toString();
}

// Cleaned whole: a secret the bound would split could leave its prefix.
String _preview(dynamic ctx, dynamic text) {
  final flat = _clean(ctx, text.toString().replaceAll(RegExp(r'\s+'), ' ').trim());
  final runes = flat.runes;
  return runes.length <= previewLength
      ? flat
      : String.fromCharCodes(runes.take(previewLength)) + '...';
}

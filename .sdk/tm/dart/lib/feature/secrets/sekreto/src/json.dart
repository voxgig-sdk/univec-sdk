// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/src/json.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Minimal JSON support for sekreto.
//
// `dart:convert` is part of the SDK, so the scanner itself is not
// hand-rolled here as it is in the ports whose standard library has none.
// What is written out is everything around it: a closed value model, a
// parse that says "this text is not JSON" without saying "this text is the
// literal null", a depth bound, a rejection of non-finite numbers, and a
// writer whose output is byte-identical to every other port's.
//
// A sealed class rather than plain `dynamic`: a vault answering `null`,
// `false`, `0` and "no such key" means four different things, and a closed
// model keeps them apart at compile time rather than by convention.
//
// A port of typescript/src/Json.ts, which is canonical.

import 'dart:convert';

/// How deep a response body may nest before it is refused. A body arrives
/// before any trust check has been made of what sent it, and `[[[[...`
/// costs nothing to write; the walk below is recursive, so the bound is
/// what keeps a hostile body from taking the process down with it.
const int MAXDEPTH = 128;

/// Thrown while converting malformed JSON; never escapes [jsonparse].
class _JsonError implements Exception {
  final String message;
  _JsonError(this.message);
  @override
  String toString() => message;
}

/// A JSON value: exactly six shapes, and no seventh.
sealed class Json {
  const Json();

  /// The string, or nothing when this is not a string.
  String? get asstr => null;

  /// The number, or nothing when this is not a number.
  double? get asnum => null;

  /// The array, or nothing when this is not an array.
  List<Json>? get asarr => null;

  /// The object, or nothing when this is not an object.
  Map<String, Json>? get asobj => null;

  /// This value as the text a caller would print, or nothing when there is
  /// no value at all. A JSON null is "no value": every provider here treats
  /// it as a miss rather than as the string "null".
  String? get text => jsonstringify(this);

  /// Walk nested objects; nothing the moment a step is not there.
  Json? dig(String key, [String? key2, String? key3]) {
    Json? at = this;

    for (final step in [key, key2, key3]) {
      if (null == step) {
        break;
      }
      final fields = at?.asobj;
      at = null == fields ? null : fields[step];
    }

    return at;
  }
}

class JsonNull extends Json {
  const JsonNull();
  @override
  String? get text => null;
}

class JsonBool extends Json {
  final bool value;
  const JsonBool(this.value);
  @override
  String? get text => value ? 'true' : 'false';
}

class JsonNum extends Json {
  final double value;
  const JsonNum(this.value);
  @override
  double? get asnum => value;
  @override
  String? get text => numstr(value);
}

class JsonStr extends Json {
  final String value;
  const JsonStr(this.value);
  @override
  String? get asstr => value;
  @override
  String? get text => value;
}

class JsonArr extends Json {
  final List<Json> value;
  const JsonArr(this.value);
  @override
  List<Json>? get asarr => value;
}

class JsonObj extends Json {
  /// Insertion-ordered: Dart map literals and `jsonDecode` both answer a
  /// LinkedHashMap, and a payload's field order is signed.
  final Map<String, Json> value;
  const JsonObj(this.value);
  @override
  Map<String, Json>? get asobj => value;
}

/// The same reads on a value that may not be there at all - a response body
/// is `Json?`, because a store may not have answered with JSON - so a
/// provider can walk it without unwrapping at every step.
extension JsonMaybe on Json? {
  Json? dig(String key, [String? key2, String? key3]) =>
      this?.dig(key, key2, key3);
  String? get text => this?.text;
  String? get asstr => this?.asstr;
  double? get asnum => this?.asnum;
  List<Json>? get asarr => this?.asarr;
  Map<String, Json>? get asobj => this?.asobj;
}

/// Parse JSON text. Nothing for anything unreadable - which the caller must
/// tell apart from a literal `null` body, since only the first means the
/// store could not answer coherently.
///
/// `jsonDecode` drives its own explicit stack, so a deeply nested body does
/// not recurse until it arrives here; [_convert] is what bounds it.
Json? jsonparse(String? text) {
  if (null == text || text.isEmpty) {
    return null;
  }

  try {
    return _convert(jsonDecode(text), 0);
  } catch (_) {
    // No error escapes: "not JSON" is a value, not an exception.
    return null;
  }
}

Json _convert(Object? value, int depth) {
  if (MAXDEPTH < depth) {
    throw _JsonError('sekreto: json: too deeply nested');
  }

  if (null == value) {
    return const JsonNull();
  }

  if (value is bool) {
    return JsonBool(value);
  }

  if (value is num) {
    final asdouble = value.toDouble();
    // JSON has no infinity, and `1e999` decodes to one. Left alone it
    // reaches a token-expiry computation as a number that is not a number.
    if (asdouble.isNaN || asdouble.isInfinite) {
      throw _JsonError('sekreto: json: number is not finite');
    }
    return JsonNum(asdouble);
  }

  if (value is String) {
    return JsonStr(value);
  }

  if (value is List) {
    return JsonArr(
      value.map<Json>((entry) => _convert(entry, depth + 1)).toList(),
    );
  }

  if (value is Map) {
    final out = <String, Json>{};
    value.forEach((key, entry) => out['$key'] = _convert(entry, depth + 1));
    return JsonObj(out);
  }

  throw _JsonError('sekreto: json: unreadable value');
}

/// Render a value as compact JSON: no spaces, no newlines.
String jsonstringify(Json value) {
  final out = StringBuffer();
  _write(value, out);
  return out.toString();
}

void _write(Json value, StringBuffer out) {
  switch (value) {
    case JsonNull():
      out.write('null');
    case JsonBool(value: final entry):
      out.write(entry ? 'true' : 'false');
    case JsonNum(value: final entry):
      out.write(numstr(entry));
    case JsonStr(value: final entry):
      out.write(jsonquote(entry));
    case JsonArr(value: final entries):
      out.write('[');
      for (var at = 0; at < entries.length; at++) {
        if (0 < at) {
          out.write(',');
        }
        _write(entries[at], out);
      }
      out.write(']');
    case JsonObj(value: final entries):
      out.write('{');
      var first = true;
      entries.forEach((key, entry) {
        if (!first) {
          out.write(',');
        }
        first = false;
        out.write(jsonquote(key));
        out.write(':');
        _write(entry, out);
      });
      out.write('}');
  }
}

/// Render a string as a JSON string literal, quotes included. Public
/// because the CLI assembles its one line of output field by field.
String jsonquote(String text) {
  final out = StringBuffer('"');

  for (final unit in text.codeUnits) {
    if (0x22 == unit) {
      out.write(r'\"');
    } else if (0x5c == unit) {
      out.write(r'\\');
    } else if (0x0a == unit) {
      out.write(r'\n');
    } else if (0x0d == unit) {
      out.write(r'\r');
    } else if (0x09 == unit) {
      out.write(r'\t');
    } else if (0x20 > unit) {
      out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }

  out.write('"');
  return out.toString();
}

/// Render a number the way every other port does: a whole number has no
/// fractional tail, so a JSON `1` read back and printed stays `1`. Dart
/// prints an integral double as `1.0`, which would diverge from every other
/// port's output and from the shared spec.
String numstr(double value) {
  if (value.isNaN || value.isInfinite) {
    return 'null';
  }

  if (value == value.truncateToDouble() && 9007199254740992.0 > value.abs()) {
    return value.toInt().toString();
  }

  return value.toString();
}

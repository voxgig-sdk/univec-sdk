// Error helpers for the Univec SDK.
//
// The donor (ts) pipeline distinguishes error values from results with
// `instanceof Error`; Dart splits throwables into Error and Exception, so
// `iserr` accepts both. `errmsg`/`errcode` read the conventional members
// (message/code) from any error-ish value, falling back to toString().

import '../UnivecError.dart';

bool iserr(dynamic v) => v is Error || v is Exception;

String errmsg(dynamic err) {
  if (null == err) {
    return 'unknown error';
  }
  if (err is Map) {
    final m = err['message'];
    return (m is String && '' != m) ? m : 'unknown error';
  }
  try {
    final m = (err as dynamic).message;
    if (m is String && '' != m) {
      return m;
    }
  } catch (_e) {
    // No message member: fall through to toString.
  }
  return err.toString();
}

String errcode(dynamic err) {
  if (null == err) {
    return '';
  }
  if (err is Map) {
    final c = err['code'];
    return c is String ? c : '';
  }
  try {
    final c = (err as dynamic).code;
    if (c is String) {
      return c;
    }
  } catch (_e) {
    // No code member.
  }
  return '';
}

// A foreign error cannot be edited, so before it is cleaned it becomes the
// SDK's own, keeping its code and message; the SDK's own passes through.
UnivecError sdkerror(dynamic err, dynamic ctx) => err is UnivecError
    ? err
    : UnivecError(
        '' == errcode(err) ? 'unexpected' : errcode(err), errmsg(err), ctx);

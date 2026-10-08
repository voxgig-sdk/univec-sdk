// Univec SDK utility: media - the media types a point declares:
// `response` (the model's `rs`) for the Accept header, and `body` (the
// model's `rb`) for the request body.

import Foundation

// The data key holding a raw request body. Like `$action`, it can never be a
// declared argument name.
let rawBodyKey = "$body"

func isJsonMedia(_ v: Value) -> Bool {
  let m = (v.asString ?? "").components(separatedBy: ";")[0]
    .trimmingCharacters(in: .whitespaces).lowercased()
  return m == "application/json" || m == "text/json" || m.hasSuffix("+json")
}

// The declared JSON type alone, else every declared type in the model's
// order; nil when no success response declares a body.
func acceptOf(_ point: VMap?) -> String? {
  let res = gp(point, "response")
  guard let media = gp(res, "media").asString, media != "" else { return nil }
  if gp(res, "kind").asString == "json" { return media }
  var types = [media]
  for alt in gp(res, "alternatives").asList?.items ?? [] {
    if let m = gp(alt, "media").asString, m != "" { types.append(m) }
  }
  return types.joined(separator: ", ")
}

func isRawRequest(_ point: VMap?) -> Bool {
  gpath(point, "body", "kind").asString == "raw"
}

func isJsonRequest(_ point: VMap?) -> Bool {
  gpath(point, "body", "kind").asString == "json"
}

// Bytes or a stream go as given. A map or a list is JSON, and so is a scalar
// on a point that declares a JSON body.
func requestBody(_ point: VMap?, _ body: Value) -> Value {
  if case .native = body { return body }
  if body.isNode || isJsonRequest(point) {
    return .string(jsonify(body, indent: 0))
  }
  return body
}

private func hasMediaHeader(_ headers: VMap, _ name: String) -> Bool {
  headers.entries.keys.contains { $0.lowercased() == name }
}

// A caller's accept wins. A declared request type replaces each JSON
// content-type, the SDK default, and leaves any other the caller set.
func mediaHeaders(_ point: VMap?, _ headers: VMap) -> VMap {
  if let accept = acceptOf(point), !hasMediaHeader(headers, "accept") {
    headers.entries["accept"] = .string(accept)
  }

  let body = gp(point, "body")
  let kind = gp(body, "kind").asString
  if kind == "raw" || kind == "json", let media = gp(body, "media").asString, media != "" {
    for k in headers.entries.keys
    where k.lowercased() == "content-type" && isJsonMedia(headers.entries[k] ?? .noval) {
      _ = headers.entries.removeValue(forKey: k)
    }
    if !hasMediaHeader(headers, "content-type") {
      headers.entries["content-type"] = .string(media)
    }
  }
  return headers
}

// A String, or Data or [UInt8] as a native value, sent as it is.
func rawBodyOf(_ reqdata: VMap) -> Value {
  reqdata.entries[rawBodyKey] ?? .noval
}

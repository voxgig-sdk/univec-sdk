// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Sigv4.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Sigv4.hpp"

#include <algorithm>
#include <cstdio>

#include "Crypto.hpp"
#include "Httpjson.hpp"

namespace sekreto {

std::string sha256hex(const std::string& text) {
  return hex(sha256(tobytes(text)));
}

namespace {

Bytes hmactext(const Bytes& key, const std::string& text) {
  return hmacsha256(key, tobytes(text));
}

}  // namespace

std::string canonicalquery(const std::string& query) {
  if (query.empty()) return "";

  std::vector<std::pair<std::string, std::string>> pairs;
  size_t start = 0;

  while (true) {
    size_t at = query.find('&', start);
    std::string pair =
        (std::string::npos == at) ? query.substr(start) : query.substr(start, at - start);

    // Split on the FIRST `=`; a pair with none has an empty value and is
    // still emitted with its `=`.
    size_t eq = pair.find('=');
    std::string key = (std::string::npos == eq) ? pair : pair.substr(0, eq);
    std::string value = (std::string::npos == eq) ? "" : pair.substr(eq + 1);

    pairs.emplace_back(uriescape(uridecode(key)), uriescape(uridecode(value)));

    if (std::string::npos == at) break;
    start = at + 1;
  }

  std::stable_sort(pairs.begin(), pairs.end(),
                   [](const std::pair<std::string, std::string>& left,
                      const std::pair<std::string, std::string>& right) {
                     if (left.first != right.first) return left.first < right.first;
                     return left.second < right.second;
                   });

  std::string out;
  for (size_t index = 0; index < pairs.size(); index++) {
    if (0 < index) out += "&";
    out += pairs[index].first + "=" + pairs[index].second;
  }

  return out;
}

namespace {

/// A URL, split by hand.
///
/// Not a platform URL type: what SigV4 signs must match what checkaddr saw
/// and what the client will dial, and a URL parser is free to normalise
/// any of the three differently. `host` follows the WHATWG rule the AWS
/// SDKs use - lowercased, userinfo stripped, the port present only when it
/// is not the scheme's default.
struct Urlparts {
  std::string scheme;
  std::string host;
  std::string path;
  std::string query;
};

Urlparts urlparts(const std::string& url) {
  Urlparts out;

  std::string rest = url;
  size_t mark = url.find("://");

  if (std::string::npos != mark) {
    out.scheme = asciilower(url.substr(0, mark));
    rest = url.substr(mark + 3);
  }

  std::string authority = rest;
  std::string tail;

  size_t stop = rest.find_first_of("/?#");
  if (std::string::npos != stop) {
    authority = rest.substr(0, stop);
    tail = rest.substr(stop);
  }

  // Userinfo is not part of the host, and never part of a signature.
  size_t at = authority.rfind('@');
  if (std::string::npos != at) authority = authority.substr(at + 1);

  std::string hostname = authority;
  std::string port;

  if (!authority.empty() && '[' == authority[0]) {
    size_t close = authority.find(']');
    if (std::string::npos != close) {
      hostname = authority.substr(0, close + 1);
      std::string after = authority.substr(close + 1);
      if (!after.empty() && ':' == after[0]) port = after.substr(1);
    }
  } else {
    size_t colon = authority.rfind(':');
    if (std::string::npos != colon) {
      hostname = authority.substr(0, colon);
      port = authority.substr(colon + 1);
    }
  }

  hostname = asciilower(hostname);

  // A default port is implicit: `Host: example.com:443` is not what an AWS
  // SDK signs, and a signature over the wrong host is refused.
  if (("https" == out.scheme && "443" == port) || ("http" == out.scheme && "80" == port)) {
    port = "";
  }

  out.host = port.empty() ? hostname : hostname + ":" + port;
  out.path = "/";

  if (!tail.empty()) {
    std::string pathpart = tail;

    size_t hash = pathpart.find('#');
    if (std::string::npos != hash) pathpart = pathpart.substr(0, hash);

    size_t question = pathpart.find('?');
    if (std::string::npos != question) {
      out.query = pathpart.substr(question + 1);
      pathpart = pathpart.substr(0, question);
    }

    if (!pathpart.empty()) out.path = pathpart;
  }

  return out;
}

/// Trim, and collapse every internal run of spaces and tabs to one space.
///
/// AWS folds sequential whitespace before signing, so a header value like
/// `a  b\tc` must sign as `a b c` or the service refuses the request.
std::string foldspace(const std::string& text) {
  std::string out;
  bool pending = false;
  bool started = false;

  for (char ch : text) {
    if (' ' == ch || '\t' == ch || '\n' == ch || '\r' == ch) {
      if (started) pending = true;
      continue;
    }
    if (pending) {
      out.push_back(' ');
      pending = false;
    }
    out.push_back(ch);
    started = true;
  }

  return out;
}

}  // namespace

Ordered sigv4(const Signing& input) {
  Urlparts parts = urlparts(input.url);

  std::string date = input.datetime.substr(0, std::min<size_t>(8, input.datetime.size()));

  // Every header that will be signed: the caller's extras, plus host and
  // x-amz-date (and the session token when present). The built-in three go
  // in AFTER the caller's, so they win over anything passed in.
  Ordered headers;

  for (const auto& entry : input.headers.pairs) {
    headers.set(asciilower(entry.first), foldspace(entry.second));
  }

  headers.set("host", parts.host);
  headers.set("x-amz-date", input.datetime);
  if (!input.session.empty()) headers.set("x-amz-security-token", input.session);

  std::vector<std::pair<std::string, std::string>> sorted = headers.pairs;
  std::stable_sort(sorted.begin(), sorted.end(),
                   [](const std::pair<std::string, std::string>& left,
                      const std::pair<std::string, std::string>& right) {
                     return left.first < right.first;
                   });

  std::string canonicalheaders;
  std::string signedheaders;

  for (size_t index = 0; index < sorted.size(); index++) {
    canonicalheaders += sorted[index].first + ":" + sorted[index].second + "\n";
    if (0 < index) signedheaders += ";";
    signedheaders += sorted[index].first;
  }

  // Six lines. `canonicalheaders` already ends with a newline, which is
  // what produces the blank line the algorithm calls for.
  std::string canonicalrequest = asciiupper(input.method) + "\n" + parts.path + "\n" +
                                 canonicalquery(parts.query) + "\n" + canonicalheaders + "\n" +
                                 signedheaders + "\n" + sha256hex(input.body);

  std::string scope = date + "/" + input.region + "/" + input.service + "/aws4_request";

  std::string stringtosign = "AWS4-HMAC-SHA256\n" + input.datetime + "\n" + scope + "\n" +
                             sha256hex(canonicalrequest);

  Bytes kdate = hmactext(tobytes("AWS4" + input.secret), date);
  Bytes kregion = hmactext(kdate, input.region);
  Bytes kservice = hmactext(kregion, input.service);
  Bytes ksigning = hmactext(kservice, "aws4_request");
  std::string signature = hex(hmactext(ksigning, stringtosign));

  Ordered out;

  out.set("authorization", "AWS4-HMAC-SHA256 Credential=" + input.keyid + "/" + scope +
                               ", SignedHeaders=" + signedheaders +
                               ", Signature=" + signature);
  out.set("x-amz-date", input.datetime);

  if (!input.session.empty()) out.set("x-amz-security-token", input.session);

  return out;
}

}  // namespace sekreto

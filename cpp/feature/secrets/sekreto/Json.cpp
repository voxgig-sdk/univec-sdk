// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/src/Json.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Json.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace sekreto {

namespace {

// A response body arrives before anything has been trusted, so `[[[[...`
// must not walk the stack off the end.
const int MAXDEPTH = 128;

struct Reader {
  const std::string& text;
  size_t pos = 0;
  int depth = 0;
  bool ok = true;

  explicit Reader(const std::string& src) : text(src) {}

  void skipws() {
    while (pos < text.size()) {
      char ch = text[pos];
      if (' ' == ch || '\t' == ch || '\n' == ch || '\r' == ch) {
        pos++;
      } else {
        break;
      }
    }
  }

  bool word(const std::string& want) {
    // Matched WHOLE, never by first letter: `nul` and `truthy` are not
    // JSON, and a first-letter dispatch would accept both.
    if (text.compare(pos, want.size(), want)) {
      return false;
    }
    pos += want.size();
    return true;
  }

  Json value() {
    skipws();

    if (pos >= text.size() || MAXDEPTH < depth) {
      ok = false;
      return Json();
    }

    char ch = text[pos];

    if ('{' == ch) return object();
    if ('[' == ch) return array();
    if ('"' == ch) {
      std::string out;
      if (!string(out)) return Json();
      return Json::str(out);
    }
    if ('t' == ch) {
      if (word("true")) return Json::boolean(true);
      ok = false;
      return Json();
    }
    if ('f' == ch) {
      if (word("false")) return Json::boolean(false);
      ok = false;
      return Json();
    }
    if ('n' == ch) {
      if (word("null")) return Json::null();
      ok = false;
      return Json();
    }

    return number();
  }

  Json object() {
    pos++;
    depth++;

    std::vector<std::pair<std::string, Json>> entries;

    skipws();
    if (pos < text.size() && '}' == text[pos]) {
      pos++;
      depth--;
      return Json::obj(entries);
    }

    while (ok) {
      skipws();

      std::string key;
      if (!string(key)) return Json();

      skipws();
      if (pos >= text.size() || ':' != text[pos]) {
        ok = false;
        return Json();
      }
      pos++;

      Json val = value();
      if (!ok) return Json();

      entries.emplace_back(key, val);

      skipws();
      if (pos >= text.size()) {
        ok = false;
        return Json();
      }
      if (',' == text[pos]) {
        pos++;
        continue;
      }
      if ('}' == text[pos]) {
        pos++;
        depth--;
        return Json::obj(entries);
      }

      ok = false;
      return Json();
    }

    return Json();
  }

  Json array() {
    pos++;
    depth++;

    std::vector<Json> entries;

    skipws();
    if (pos < text.size() && ']' == text[pos]) {
      pos++;
      depth--;
      return Json::arr(entries);
    }

    while (ok) {
      Json val = value();
      if (!ok) return Json();

      entries.push_back(val);

      skipws();
      if (pos >= text.size()) {
        ok = false;
        return Json();
      }
      if (',' == text[pos]) {
        pos++;
        continue;
      }
      if (']' == text[pos]) {
        pos++;
        depth--;
        return Json::arr(entries);
      }

      ok = false;
      return Json();
    }

    return Json();
  }

  // A UTF-16 code unit, appended as UTF-8. No surrogate-pair
  // recombination, in this port or in any other: a lone surrogate is
  // encoded as it stands rather than guessed at.
  void utf8(unsigned int code, std::string& out) {
    if (0x80 > code) {
      out.push_back(static_cast<char>(code));
    } else if (0x800 > code) {
      out.push_back(static_cast<char>(0xc0 | (code >> 6)));
      out.push_back(static_cast<char>(0x80 | (code & 0x3f)));
    } else {
      out.push_back(static_cast<char>(0xe0 | (code >> 12)));
      out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
      out.push_back(static_cast<char>(0x80 | (code & 0x3f)));
    }
  }

  bool string(std::string& out) {
    if (pos >= text.size() || '"' != text[pos]) {
      ok = false;
      return false;
    }
    pos++;

    out.clear();

    while (pos < text.size()) {
      char ch = text[pos];

      if ('"' == ch) {
        pos++;
        return true;
      }

      if ('\\' != ch) {
        out.push_back(ch);
        pos++;
        continue;
      }

      pos++;
      if (pos >= text.size()) break;

      char esc = text[pos];
      pos++;

      switch (esc) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        case 'u': {
          if (pos + 4 > text.size()) {
            ok = false;
            return false;
          }
          unsigned int code = 0;
          for (int step = 0; step < 4; step++) {
            char digit = text[pos + static_cast<size_t>(step)];
            unsigned int val = 0;
            if ('0' <= digit && '9' >= digit) {
              val = static_cast<unsigned int>(digit - '0');
            } else if ('a' <= digit && 'f' >= digit) {
              val = static_cast<unsigned int>(digit - 'a' + 10);
            } else if ('A' <= digit && 'F' >= digit) {
              val = static_cast<unsigned int>(digit - 'A' + 10);
            } else {
              ok = false;
              return false;
            }
            code = (code << 4) | val;
          }
          pos += 4;
          utf8(code, out);
          break;
        }
        default:
          ok = false;
          return false;
      }
    }

    ok = false;
    return false;
  }

  Json number() {
    size_t start = pos;

    if (pos < text.size() && ('-' == text[pos] || '+' == text[pos])) pos++;

    while (pos < text.size()) {
      char ch = text[pos];
      bool part = ('0' <= ch && '9' >= ch) || '.' == ch || 'e' == ch || 'E' == ch ||
                  '-' == ch || '+' == ch;
      if (!part) break;
      pos++;
    }

    if (start == pos) {
      ok = false;
      return Json();
    }

    std::string span = text.substr(start, pos - start);

    char* stop = nullptr;
    double val = std::strtod(span.c_str(), &stop);

    // A span the float parser did not consume whole is not a number, and
    // 1e999 parses to infinity - which JSON has no literal for and which
    // would blow up a token-expiry computation later.
    if (nullptr == stop || '\0' != *stop || !std::isfinite(val)) {
      ok = false;
      return Json();
    }

    return Json::num(val);
  }
};

}  // namespace

Json Json::null() { return Json(); }

Json Json::boolean(bool val) {
  Json out;
  out.type = Type::Bool;
  out.boolval = val;
  return out;
}

Json Json::num(double val) {
  Json out;
  out.type = Type::Num;
  out.numval = val;
  return out;
}

Json Json::str(const std::string& val) {
  Json out;
  out.type = Type::Str;
  out.strval = val;
  return out;
}

Json Json::arr(std::vector<Json> entries) {
  Json out;
  out.type = Type::Arr;
  out.arrval = std::move(entries);
  return out;
}

Json Json::obj(std::vector<std::pair<std::string, Json>> entries) {
  Json out;
  out.type = Type::Obj;
  out.objval = std::move(entries);
  return out;
}

Json Json::get(const std::string& key) const {
  if (Type::Obj != type) return Json();

  for (const auto& entry : objval) {
    if (key == entry.first) return entry.second;
  }

  return Json();
}

bool Json::asstr(std::string& out) const {
  if (Type::Str != type) return false;
  out = strval;
  return true;
}

bool Json::asnum(double& out) const {
  if (Type::Num != type) return false;
  out = numval;
  return true;
}

bool Json::text(std::string& out) const {
  switch (type) {
    case Type::Str:
      out = strval;
      return true;
    case Type::Num:
      out = numstr(numval);
      return true;
    case Type::Bool:
      out = boolval ? "true" : "false";
      return true;
    default:
      // Null, and both containers: nothing printable, so a null field
      // reads as a miss.
      return false;
  }
}

bool Json::parse(const std::string& text, Json& out) {
  if (text.empty()) return false;

  Reader reader(text);
  Json val = reader.value();

  if (!reader.ok) return false;

  reader.skipws();

  // Trailing content after the top-level value is not one JSON document.
  if (reader.pos != text.size()) return false;

  out = val;
  return true;
}

std::string Json::quote(const std::string& text) {
  std::string out = "\"";

  for (unsigned char ch : text) {
    switch (ch) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (0x20 > ch) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", ch);
          out += buf;
        } else {
          // `/` is accepted on input and never escaped on output, and
          // non-ASCII passes through as the UTF-8 it already is.
          out.push_back(static_cast<char>(ch));
        }
    }
  }

  out += "\"";
  return out;
}

std::string Json::numstr(double val) {
  if (!std::isfinite(val)) return "null";

  if (val == std::floor(val) && 9007199254740992.0 > std::fabs(val)) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.0f", val);
    return buf;
  }

  char buf[40];
  std::snprintf(buf, sizeof(buf), "%.17g", val);

  // The shortest rendering that round-trips, which is what every other
  // port's default float printer gives.
  for (int digits = 1; digits < 17; digits++) {
    char probe[40];
    std::snprintf(probe, sizeof(probe), "%.*g", digits, val);
    if (std::strtod(probe, nullptr) == val) return probe;
  }

  return buf;
}

std::string Json::stringify(const Json& val) {
  switch (val.type) {
    case Type::Null: return "null";
    case Type::Bool: return val.boolval ? "true" : "false";
    case Type::Num: return numstr(val.numval);
    case Type::Str: return quote(val.strval);
    case Type::Arr: {
      std::string out = "[";
      for (size_t index = 0; index < val.arrval.size(); index++) {
        if (0 < index) out += ",";
        out += stringify(val.arrval[index]);
      }
      return out + "]";
    }
    case Type::Obj: {
      std::string out = "{";
      for (size_t index = 0; index < val.objval.size(); index++) {
        if (0 < index) out += ",";
        out += quote(val.objval[index].first);
        out += ":";
        out += stringify(val.objval[index].second);
      }
      return out + "}";
    }
  }

  return "null";
}

}  // namespace sekreto

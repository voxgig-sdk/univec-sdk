// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/value.cpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The dynamic value, and the JSON reader. See value.hpp. */

#include "value.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace plugin {

V vnull() {
  auto v = std::make_shared<Value>();
  v->kind = Kind::Null;
  return v;
}

V vbool(bool b) {
  auto v = std::make_shared<Value>();
  v->kind = Kind::Bool;
  v->boolean = b;
  return v;
}

V vnum(double n) {
  auto v = std::make_shared<Value>();
  v->kind = Kind::Num;
  v->num = n;
  return v;
}

V vstr(const std::string& s) {
  auto v = std::make_shared<Value>();
  v->kind = Kind::Str;
  v->str = s;
  return v;
}

V vlist() {
  auto v = std::make_shared<Value>();
  v->kind = Kind::List;
  return v;
}

V vmap() {
  auto v = std::make_shared<Value>();
  v->kind = Kind::Map;
  return v;
}

/* A nullptr is "nothing", and nothing is null-shaped for every question
 * a caller can ask about a kind. Only `has` tells the two apart. */
bool isnull(const V& v) { return !v || Kind::Null == v->kind; }
bool isbool(const V& v) { return v && Kind::Bool == v->kind; }
bool isnum(const V& v) { return v && Kind::Num == v->kind; }
bool isstr(const V& v) { return v && Kind::Str == v->kind; }
bool islist(const V& v) { return v && Kind::List == v->kind; }
bool ismap(const V& v) { return v && Kind::Map == v->kind; }

V get(const V& m, const std::string& key) {
  if (!ismap(m)) return vnull();
  for (const auto& e : m->entries) {
    if (e.first == key) return e.second ? e.second : vnull();
  }
  return vnull();
}

bool has(const V& m, const std::string& key) {
  if (!ismap(m)) return false;
  for (const auto& e : m->entries) {
    if (e.first == key) return true;
  }
  return false;
}

void set(const V& m, const std::string& key, const V& val) {
  if (!ismap(m)) return;
  for (auto& e : m->entries) {
    if (e.first == key) { e.second = val ? val : vnull(); return; }
  }
  m->entries.emplace_back(key, val ? val : vnull());
}

void del(const V& m, const std::string& key) {
  if (!ismap(m)) return;
  for (size_t i = 0; i < m->entries.size(); i++) {
    if (m->entries[i].first == key) {
      m->entries.erase(m->entries.begin() + static_cast<long>(i));
      return;
    }
  }
}

V at(const V& l, size_t i) {
  if (!islist(l) || i >= l->items.size()) return vnull();
  return l->items[i] ? l->items[i] : vnull();
}

void push(const V& l, const V& item) {
  if (!islist(l)) return;
  l->items.push_back(item ? item : vnull());
}

size_t len(const V& v) {
  if (!v) return 0;
  if (Kind::List == v->kind) return v->items.size();
  if (Kind::Map == v->kind) return v->entries.size();
  return 0;
}

std::string asstr(const V& v) { return isstr(v) ? v->str : std::string(); }
double asnum(const V& v) { return isnum(v) ? v->num : 0.0; }
bool asbool(const V& v) { return isbool(v) && v->boolean; }

std::vector<std::string> keys(const V& m) {
  std::vector<std::string> out;
  if (!ismap(m)) return out;
  out.reserve(m->entries.size());
  for (const auto& e : m->entries) out.push_back(e.first);
  return out;
}

std::vector<std::string> sortedkeys(const V& m) {
  auto out = keys(m);
  /* BYTE-WISE, not locale-aware: std::sort on std::string compares by
   * char value, which is what every other port's sort does. A
   * locale-collating comparison would order mixed-case refs differently
   * per machine. */
  std::sort(out.begin(), out.end());
  return out;
}

bool truthy(const V& v) {
  if (!v) return false;
  switch (v->kind) {
    case Kind::Null: return false;
    case Kind::Bool: return v->boolean;
    /* §4 rule 4: JSON truthiness. 0 and "" are FALSE, matching every
     * other port's `truthy`, not C++'s "any nonzero scalar". */
    case Kind::Num: return 0.0 != v->num;
    case Kind::Str: return !v->str.empty();
    default: return true;
  }
}

bool same(const V& a, const V& b) {
  bool anull = isnull(a), bnull = isnull(b);
  if (anull || bnull) return anull && bnull;
  /* TYPE FIRST. `true` and `1` are different values, and
   * `capability/match` is the entry that says so. */
  if (a->kind != b->kind) return false;
  switch (a->kind) {
    case Kind::Bool: return a->boolean == b->boolean;
    case Kind::Num: return a->num == b->num;
    case Kind::Str: return a->str == b->str;
    case Kind::List: {
      if (a->items.size() != b->items.size()) return false;
      for (size_t i = 0; i < a->items.size(); i++) {
        if (!same(at(a, i), at(b, i))) return false;
      }
      return true;
    }
    case Kind::Map: {
      if (a->entries.size() != b->entries.size()) return false;
      for (const auto& e : a->entries) {
        if (!has(b, e.first)) return false;
        if (!same(e.second, get(b, e.first))) return false;
      }
      return true;
    }
    default: return true;
  }
}

V clone(const V& v) {
  if (!v) return nullptr;
  switch (v->kind) {
    case Kind::List: {
      V out = vlist();
      for (const auto& i : v->items) push(out, clone(i));
      return out;
    }
    case Kind::Map: {
      V out = vmap();
      for (const auto& e : v->entries) set(out, e.first, clone(e.second));
      return out;
    }
    default: return std::make_shared<Value>(*v);
  }
}

/* --- json ----------------------------------------------------------- */

std::string numstr(double n) {
  char tmp[64];
  /* An integral double renders as an integer: the corpus's expected
   * values are written `1`, not `1.0`, and a port that emits the latter
   * fails every comparison for a reason that has nothing to do with the
   * behaviour under test. */
  if (std::isfinite(n) && n == static_cast<double>(static_cast<long long>(n))) {
    std::snprintf(tmp, sizeof(tmp), "%lld", static_cast<long long>(n));
  }
  else {
    std::snprintf(tmp, sizeof(tmp), "%.17g", n);
  }
  return tmp;
}

static void escape(const std::string& s, std::string& out) {
  out += '"';
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      default:
        if (0x20 > c) {
          char tmp[8];
          std::snprintf(tmp, sizeof(tmp), "\\u%04x", c);
          out += tmp;
        }
        else {
          out += static_cast<char>(c);
        }
    }
  }
  out += '"';
}

static void render(const V& v, std::string& out) {
  if (isnull(v)) { out += "null"; return; }
  switch (v->kind) {
    case Kind::Bool: out += v->boolean ? "true" : "false"; break;
    case Kind::Num: out += numstr(v->num); break;
    case Kind::Str: escape(v->str, out); break;
    case Kind::List: {
      out += '[';
      for (size_t i = 0; i < v->items.size(); i++) {
        if (0 < i) out += ',';
        render(at(v, i), out);
      }
      out += ']';
      break;
    }
    case Kind::Map: {
      out += '{';
      /* SORTED, so two values that are `same` render identically. */
      auto ks = sortedkeys(v);
      for (size_t i = 0; i < ks.size(); i++) {
        if (0 < i) out += ',';
        escape(ks[i], out);
        out += ':';
        render(get(v, ks[i]), out);
      }
      out += '}';
      break;
    }
    default: out += "null";
  }
}

std::string json(const V& v) {
  std::string out;
  render(v, out);
  return out;
}

namespace {

struct Parser {
  const std::string& text;
  size_t i = 0;
  std::string err;

  explicit Parser(const std::string& t) : text(t) {}

  void skip() {
    while (i < text.size() &&
           (' ' == text[i] || '\t' == text[i] || '\n' == text[i] ||
            '\r' == text[i])) {
      i++;
    }
  }

  bool lit(const char* word) {
    size_t n = std::char_traits<char>::length(word);
    if (text.compare(i, n, word) != 0) return false;
    i += n;
    return true;
  }

  int hex4() {
    if (i + 4 > text.size()) return -1;
    int acc = 0;
    for (int k = 0; k < 4; k++) {
      char c = text[i + static_cast<size_t>(k)];
      int d;
      if ('0' <= c && '9' >= c) d = c - '0';
      else if ('a' <= c && 'f' >= c) d = c - 'a' + 10;
      else if ('A' <= c && 'F' >= c) d = c - 'A' + 10;
      else return -1;
      acc = acc * 16 + d;
    }
    i += 4;
    return acc;
  }

  static void utf8(unsigned cp, std::string& out) {
    if (0x80 > cp) {
      out += static_cast<char>(cp);
    }
    else if (0x800 > cp) {
      out += static_cast<char>(0xC0 | (cp >> 6));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    }
    else if (0x10000 > cp) {
      out += static_cast<char>(0xE0 | (cp >> 12));
      out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    }
    else {
      out += static_cast<char>(0xF0 | (cp >> 18));
      out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
      out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    }
  }

  bool string(std::string& out) {
    if (i >= text.size() || '"' != text[i]) { err = "expected a string"; return false; }
    i++;
    while (i < text.size() && '"' != text[i]) {
      char c = text[i];
      if ('\\' != c) { out += c; i++; continue; }
      i++;
      if (i >= text.size()) { err = "unterminated escape"; return false; }
      char e = text[i++];
      switch (e) {
        case '"': out += '"'; break;
        case '\\': out += '\\'; break;
        case '/': out += '/'; break;
        case 'n': out += '\n'; break;
        case 'r': out += '\r'; break;
        case 't': out += '\t'; break;
        case 'b': out += '\b'; break;
        case 'f': out += '\f'; break;
        case 'u': {
          int hi = hex4();
          if (0 > hi) { err = "bad \\u escape"; return false; }
          unsigned cp = static_cast<unsigned>(hi);
          if (0xD800 <= cp && 0xDBFF >= cp && i + 1 < text.size() &&
              '\\' == text[i] && 'u' == text[i + 1]) {
            i += 2;
            int lo = hex4();
            if (0 > lo) { err = "bad \\u escape"; return false; }
            cp = 0x10000 + ((cp - 0xD800) << 10) +
                 (static_cast<unsigned>(lo) - 0xDC00);
          }
          utf8(cp, out);
          break;
        }
        default: err = "bad escape"; return false;
      }
    }
    if (i >= text.size()) { err = "unterminated string"; return false; }
    i++;
    return true;
  }

  V value() {
    skip();
    if (i >= text.size()) { err = "unexpected end of input"; return nullptr; }
    char c = text[i];

    if ('n' == c) {
      if (!lit("null")) { err = "bad literal"; return nullptr; }
      return vnull();
    }
    if ('t' == c) {
      if (!lit("true")) { err = "bad literal"; return nullptr; }
      return vbool(true);
    }
    if ('f' == c) {
      if (!lit("false")) { err = "bad literal"; return nullptr; }
      return vbool(false);
    }
    if ('"' == c) {
      std::string s;
      if (!string(s)) return nullptr;
      return vstr(s);
    }
    if ('[' == c) {
      i++;
      V out = vlist();
      skip();
      if (i < text.size() && ']' == text[i]) { i++; return out; }
      for (;;) {
        V item = value();
        if (!item) return nullptr;
        push(out, item);
        skip();
        if (i < text.size() && ',' == text[i]) { i++; continue; }
        if (i < text.size() && ']' == text[i]) { i++; return out; }
        err = "expected , or ] in array";
        return nullptr;
      }
    }
    if ('{' == c) {
      i++;
      V out = vmap();
      skip();
      if (i < text.size() && '}' == text[i]) { i++; return out; }
      for (;;) {
        skip();
        std::string key;
        if (!string(key)) return nullptr;
        skip();
        if (i >= text.size() || ':' != text[i]) {
          err = "expected : in object";
          return nullptr;
        }
        i++;
        V val = value();
        if (!val) return nullptr;
        set(out, key, val);
        skip();
        if (i < text.size() && ',' == text[i]) { i++; continue; }
        if (i < text.size() && '}' == text[i]) { i++; return out; }
        err = "expected , or } in object";
        return nullptr;
      }
    }

    /* JSON's number grammar is STRICT, and §9.5 makes that observable:
       env values "parse as JSON, falling back to string", so anything
       this reader accepts loosely silently becomes a number where the
       canonical keeps the authored string. `1e`, `1.`, `01`, `.5` and a
       bare `-` are all errors to JSON.parse; only `-0` and `1e5` are
       not.

         number = [ '-' ] int [ frac ] [ exp ]
         int    = '0' | digit1-9 *digit
         frac   = '.' 1*digit
         exp    = ('e'|'E') [ '+' | '-' ] 1*digit
     */
    auto digit = [this]() {
      return i < text.size() && '0' <= text[i] && '9' >= text[i];
    };
    size_t start = i;
    if (i < text.size() && '-' == text[i]) i++;
    if (!digit()) { err = "bad number"; return nullptr; }
    if ('0' == text[i]) i++;
    else while (digit()) i++;
    if (i < text.size() && '.' == text[i]) {
      i++;
      if (!digit()) { err = "bad number"; return nullptr; }
      while (digit()) i++;
    }
    if (i < text.size() && ('e' == text[i] || 'E' == text[i])) {
      i++;
      if (i < text.size() && ('+' == text[i] || '-' == text[i])) i++;
      if (!digit()) { err = "bad number"; return nullptr; }
      while (digit()) i++;
    }
    std::string piece = text.substr(start, i - start);
    char* end = nullptr;
    double n = std::strtod(piece.c_str(), &end);
    if (nullptr == end || '\0' != *end) { err = "bad number"; return nullptr; }
    return vnum(n);
  }
};

}  // namespace

V parsejson(const std::string& text, std::string& err) {
  Parser p(text);
  V out = p.value();
  if (!out) { err = p.err; return nullptr; }
  p.skip();
  if (p.i != text.size()) { err = "trailing content"; return nullptr; }
  return out;
}

}  // namespace plugin

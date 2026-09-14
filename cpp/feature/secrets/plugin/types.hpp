// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (cpp/src/types.hpp)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Errors, and the raise mechanism (§12).
 *
 * A REAL EXCEPTION, which is the whole difference from the `c` port.
 * The canonical RAISES: a failing call abandons the rest of the
 * function, and the corpus is full of entries that assert exactly what
 * survived a raise mid-sequence (`resource/unwind`, `lifecycle/fail`).
 * c reaches that with setjmp/longjmp and pays for it in `volatile`
 * locals and an arena; C++ has the construct, so it is used, and the
 * destructors run on the way out.
 *
 * Ports compare by CODE and never by message: wording is a port's own
 * business. The FORMAT is pinned, because a parseable message is what
 * makes a log searchable across twenty languages. */

#ifndef VOXGIG_PLUGIN_TYPES_HPP
#define VOXGIG_PLUGIN_TYPES_HPP

#include <exception>
#include <string>

#include "value.hpp"

namespace plugin {

class PluginError : public std::exception {
 public:
  std::string code;
  std::string text;
  V details;
  std::string message;

  PluginError(std::string c, std::string t, V d);
  const char* what() const noexcept override { return message.c_str(); }
};

/* Raise. Never returns — declared [[noreturn]] so the compiler knows a
 * `fail` ends a branch and no caller needs a dead return after it. */
[[noreturn]] void fail(const std::string& code, const std::string& text,
                       const V& details = nullptr);

/* §12's detail fields render in a FIXED ORDER — part of the contract,
 * not a formatting preference, because otherwise each port invents its
 * own and message parity is gone. */
std::string formaterror(const std::string& code, const std::string& text,
                        const V& details);

/* Convenience: small details maps. */
V details1(const std::string& k, const V& v);
V details2(const std::string& k1, const V& v1, const std::string& k2,
           const V& v2);

/* Deep merge, struct's semantics: maps merge, everything else replaces.
 * §16 permits voxgig/struct for this and C++ has no port of it. */
V mergevalue(const V& a, const V& b);

/* §11.1's partial match: every leaf in `want` must be present and equal
 * in `have`; keys not mentioned are not checked. */
bool matchvalue(const V& want, const V& have);

}  // namespace plugin

#endif

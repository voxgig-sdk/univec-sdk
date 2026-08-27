// Univec SDK — paging feature (mirrors java feature/PagingFeature.java).
// Pagination for list operations. On the way out (PreRequest) it stamps
// page/limit (or a cursor) into the request query; on the way back
// (PreResult) it reads the server's pagination signals — a `Link` rel="next"
// header, `X-Page`/`X-Next-Page`/`X-Total-Count` headers, or
// `next`/`cursor`/`nextCursor`/`hasMore` body fields — onto ctx.result.paging.
// A per-call cursor/page from ctrl takes priority (auto-iteration).

#ifndef SDK_FEATURE_PAGING_HPP
#define SDK_FEATURE_PAGING_HPP

#include <regex>
#include <string>
#include <vector>

#include "../core/types.hpp"
#include "base.hpp"
#include "options.hpp"

namespace sdk {

class PagingFeature : public BaseFeature {
public:
  SdkClient* client = nullptr;
  Value options = Value::undef();

  // Activity tracking (mirrors the ts client._paging record).
  Value last = Value::undef();

  PagingFeature() : BaseFeature("paging", "0.0.1", true) {}

  void init(CtxPtr ctx, const Value& options_) override {
    client = ctx->client;
    options = options_;
    active = fopt::foptBool(options, "active", false);
  }

  void preRequest(CtxPtr ctx) override {
    if (!active || !isList(ctx)) return;
    SpecPtr spec = ctx->spec;
    if (!spec) return;
    if (!spec->query.is_map()) spec->query = vmap();

    std::string pageParam = fopt::foptStr(options, "pageParam", "page");
    std::string limitParam = fopt::foptStr(options, "limitParam", "limit");
    std::string cursorParam = fopt::foptStr(options, "cursorParam", "cursor");

    // A per-call cursor/page from ctrl takes priority (auto-iteration).
    Value paging = ctx->ctrl ? ctx->ctrl->paging : Value::undef();
    if (!paging.is_map()) paging = vmap();

    // GraphQL paginates through operation VARIABLES, not the query string.
    // This hook runs after makeSpec, so spec->body already holds the
    // { query, variables } envelope, and before makeFetchDef serialises it.
    if ("graphql" == as_str(getp(ctx->point, "kind"))) {
      graphqlPreRequest(ctx, paging);
      return;
    }

    Value cursor = getp(paging, "cursor");
    if (!is_nullish(cursor)) {
      map_put(spec->query, cursorParam, cursor);
    } else if (is_nullish(getp(spec->query, pageParam))) {
      Value page = getp(paging, "page");
      if (!is_nullish(page)) {
        map_put(spec->query, pageParam, page);
      } else {
        map_put(spec->query, pageParam, Value(fopt::foptInt(options, "startPage", 1)));
      }
    }

    if (!is_nullish(getp(options, "limit")) && is_nullish(getp(spec->query, limitParam))) {
      map_put(spec->query, limitParam, Value(fopt::foptInt(options, "limit", 0)));
    }
  }

  // Relay pagination: the cursor is the `after` variable (or whatever the
  // model named it), and the page size is `first`.
  void graphqlPreRequest(CtxPtr ctx, const Value& paging) {
    Value body = ctx->spec->body;
    if (!body.is_map()) return;

    Value variables = getp(body, "variables");
    if (!variables.is_map()) {
      variables = vmap();
      map_put(body, "variables", variables);
    }

    std::string afterVar = fopt::foptStr(options, "afterVar", "after");
    std::string firstVar = fopt::foptStr(options, "firstVar", "first");

    // Only bind variables the operation actually declares, or the server
    // rejects the document.
    bool afterDeclared = false, firstDeclared = false;
    Value varlist = Struct::getpath(ctx->point, {"graphql", "vars"});
    if (varlist.is_list()) {
      for (const auto& v : *varlist.as_list()) {
        std::string n = as_str(getp(v, "name"));
        if (n == afterVar) afterDeclared = true;
        if (n == firstVar) firstDeclared = true;
      }
    }

    Value cursor = getp(paging, "cursor");
    if (afterDeclared && !is_nullish(cursor)) {
      map_put(variables, afterVar, cursor);
    }

    if (firstDeclared && !is_nullish(getp(options, "limit")) &&
        is_nullish(getp(variables, firstVar))) {
      map_put(variables, firstVar, Value(fopt::foptInt(options, "limit", 0)));
    }
  }

  void preResult(CtxPtr ctx) override {
    if (!active || !isList(ctx)) return;
    ResultPtr result = ctx->result;
    if (!result) return;

    Value headers = result->headers;
    Value body = result->body;

    Value paging = vmap();
    map_put(paging, "hasMore", Value(false));
    headerNum(headers, "x-page", paging, "page");
    headerNum(headers, "x-total-count", paging, "totalCount");
    headerNum(headers, "x-next-page", paging, "nextPage");

    // Link: <...>; rel="next"
    Value link = fopt::fheaderGet(headers, "link");
    if (link.is_string()) {
      static const std::regex LINK_NEXT_RE(
          "<([^>]+)>\\s*;\\s*rel=\"?next\"?", std::regex::icase);
      std::smatch mm;
      std::string ls = link.as_string();
      if (std::regex_search(ls, mm, LINK_NEXT_RE)) {
        map_put(paging, "next", Value(mm[1].str()));
      }
    }

    // Set when the response states hasMore outright, rather than leaving it
    // to be inferred from the presence of a cursor.
    bool explicitMore = false;

    // Relay connections carry the cursor in pageInfo, at the path the model
    // recorded for this op.
    Value page = Struct::getpath(ctx->point, {"graphql", "page"});
    if (page.is_map() && body.is_map()) {
      // `connpath` locates the connection object inside the response
      // envelope (data.<field>); the cursor/more paths are relative to it.
      Value conn = body;
      std::string connpath = as_str(getp(page, "connpath"));
      if (!connpath.empty()) {
        Value sub = Struct::getpath(body, splitDots(connpath));
        if (!is_nullish(sub)) conn = sub;
      }

      std::string cursorpath = as_str(getp(page, "cursor"));
      if (!cursorpath.empty()) {
        Value c = Struct::getpath(conn, splitDots(cursorpath));
        if (!is_nullish(c)) map_put(paging, "cursor", c);
      }

      std::string morepath = as_str(getp(page, "more"));
      if (!morepath.empty()) {
        Value m = Struct::getpath(conn, splitDots(morepath));
        if (m.is_bool()) {
          map_put(paging, "hasMore", m);
          explicitMore = true;
        }
      }
    }

    // Body-level cursors.
    if (body.is_map()) {
      Value bnext = getp(body, "next");
      if (!is_nullish(bnext) && is_nullish(getp(paging, "next"))) {
        map_put(paging, "next", bnext);
      }
      Value bcursor = getp(body, "cursor");
      if (!is_nullish(bcursor)) {
        map_put(paging, "cursor", bcursor);
      }
      Value bnextCursor = getp(body, "nextCursor");
      if (!is_nullish(bnextCursor)) {
        map_put(paging, "cursor", bnextCursor);
      }
      Value bhasMore = getp(body, "hasMore");
      if (bhasMore.is_bool()) {
        map_put(paging, "hasMore", bhasMore);
        explicitMore = true;
      }
    }

    // Cursor presence only INFERS another page. When the server stated the
    // answer outright — relay's `hasNextPage: false`, or a body `hasMore` —
    // that wins: a final page normally carries both an end cursor and
    // hasNextPage false, and inferring from the cursor there would send the
    // caller back for a page that does not exist, forever.
    if (!explicitMore && !is_true(getp(paging, "hasMore")) &&
        (!is_nullish(getp(paging, "next")) || !is_nullish(getp(paging, "cursor")) ||
         !is_nullish(getp(paging, "nextPage")))) {
      map_put(paging, "hasMore", Value(true));
    }

    result->paging = paging;
    last = paging;
  }

private:
  // The model records connection/cursor/more as dot paths; Struct::getpath
  // takes pre-split segments.
  static std::vector<std::string> splitDots(const std::string& path) {
    std::vector<std::string> out;
    size_t start = 0;
    while (true) {
      size_t dot = path.find('.', start);
      if (std::string::npos == dot) {
        out.push_back(path.substr(start));
        break;
      }
      out.push_back(path.substr(start, dot - start));
      start = dot + 1;
    }
    return out;
  }

  bool isList(CtxPtr ctx) {
    std::string opname = "";
    if (ctx->op) opname = ctx->op->name;
    std::vector<std::string> ops = fopt::foptStrList(options, "ops");
    if (!fopt::foptList(options, "ops").is_list()) {
      ops = {"list"};
    }
    for (const auto& o : ops) {
      if (o == opname) return true;
    }
    return false;
  }

  void headerNum(const Value& headers, const std::string& name,
                 const Value& paging, const std::string& key) {
    Value v = fopt::fheaderGet(headers, name);
    if (is_nullish(v)) return;
    if (v.is_string()) {
      int n = fopt::fparseInt(v.as_string(), -1);
      if (n >= 0) map_put(paging, key, Value(n));
      return;
    }
    if (v.is_number()) {
      map_put(paging, key, Value((int) v.as_int()));
    }
  }
};

} // namespace sdk

#endif // SDK_FEATURE_PAGING_HPP

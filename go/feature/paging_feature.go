package feature

import (
	"regexp"

	vs "github.com/voxgig-sdk/univec-sdk/go/utility/struct"

	"github.com/voxgig-sdk/univec-sdk/go/core"
)

// Pagination support for list operations. On the way out (PreRequest) it
// stamps page/limit (or a cursor) into the request query; on the way back
// (PreResult) it reads the server's pagination signals — a `Link:
// rel="next"` header, `X-Page`/`X-Next-Page`/`X-Total-Count` headers, or
// `next`/`cursor`/`nextCursor`/`hasMore` fields in the body — and records
// them on `ctx.Result.Paging`. A per-call cursor/page from ctrl takes
// priority (used by auto-iteration). Parameter names (`pageParam`,
// `limitParam`, `cursorParam`), the page size (`limit`) and the start page
// (`startPage`, default 1) are configurable.
type PagingFeature struct {
	BaseFeature
	client  *core.UnivecSDK
	options map[string]any

	// Activity tracking (mirrors the ts client._paging record).
	Last map[string]any
}

var pagingLinkNextRe = regexp.MustCompile(`(?i)<([^>]+)>\s*;\s*rel="?next"?`)

func NewPagingFeature() *PagingFeature {
	return &PagingFeature{
		BaseFeature: BaseFeature{
			Version: "0.0.1",
			Name:    "paging",
			Active:  true,
		},
	}
}

func (f *PagingFeature) Init(ctx *core.Context, options map[string]any) {
	f.client = ctx.Client
	f.options = options
	f.Active = foptBool(options, "active", false)
}

func (f *PagingFeature) PreRequest(ctx *core.Context) {
	if !f.Active || !f.isList(ctx) {
		return
	}
	spec := ctx.Spec
	if spec == nil {
		return
	}
	if spec.Query == nil {
		spec.Query = map[string]any{}
	}

	pageParam := foptStr(f.options, "pageParam", "page")
	limitParam := foptStr(f.options, "limitParam", "limit")
	cursorParam := foptStr(f.options, "cursorParam", "cursor")

	// A per-call cursor/page from ctrl takes priority (auto-iteration).
	var paging map[string]any
	if ctx.Ctrl != nil {
		paging = ctx.Ctrl.Paging
	}

	// GraphQL paginates through operation VARIABLES, not the query string.
	// This hook runs after makeSpec, so spec.Body already holds the
	// { query, variables } envelope, and before makeFetchDef serialises it.
	if kind, _ := vs.GetProp(ctx.Point, "kind").(string); kind == "graphql" {
		f.graphqlPreRequest(ctx, paging)
		return
	}

	if cursor, has := paging["cursor"]; has && cursor != nil {
		spec.Query[cursorParam] = cursor
	} else if spec.Query[pageParam] == nil {
		if page, has := paging["page"]; has && page != nil {
			spec.Query[pageParam] = page
		} else {
			spec.Query[pageParam] = foptInt(f.options, "startPage", 1)
		}
	}

	if f.options["limit"] != nil && spec.Query[limitParam] == nil {
		spec.Query[limitParam] = foptInt(f.options, "limit", 0)
	}
}

// Relay pagination: the cursor is the `after` variable (or whatever the
// model named it), and the page size is `first`.
func (f *PagingFeature) graphqlPreRequest(ctx *core.Context, paging map[string]any) {
	body, ok := ctx.Spec.Body.(map[string]any)
	if !ok {
		return
	}

	vars, ok := body["variables"].(map[string]any)
	if !ok {
		vars = map[string]any{}
		body["variables"] = vars
	}

	afterVar := foptStr(f.options, "afterVar", "after")
	firstVar := foptStr(f.options, "firstVar", "first")

	// Only bind variables the operation actually declares, or the server
	// rejects the document.
	declared := map[string]bool{}
	if varlist, ok := vs.GetPath([]any{"graphql", "vars"}, ctx.Point).([]any); ok {
		for _, v := range varlist {
			if name, ok := vs.GetProp(v, "name").(string); ok {
				declared[name] = true
			}
		}
	}

	if cursor, has := paging["cursor"]; has && cursor != nil && declared[afterVar] {
		vars[afterVar] = cursor
	}

	if f.options["limit"] != nil && vars[firstVar] == nil && declared[firstVar] {
		vars[firstVar] = foptInt(f.options, "limit", 0)
	}
}

func (f *PagingFeature) PreResult(ctx *core.Context) {
	if !f.Active || !f.isList(ctx) {
		return
	}
	result := ctx.Result
	if result == nil {
		return
	}

	headers := result.Headers
	body := result.Body

	paging := map[string]any{
		"hasMore": false,
	}
	f.headerNum(headers, "x-page", paging, "page")
	f.headerNum(headers, "x-total-count", paging, "totalCount")
	f.headerNum(headers, "x-next-page", paging, "nextPage")

	// Link: <...>; rel="next"
	if link, has := fheaderGet(headers, "link"); has {
		if ls, ok := link.(string); ok {
			if m := pagingLinkNextRe.FindStringSubmatch(ls); m != nil {
				paging["next"] = m[1]
			}
		}
	}

	// Set when the response states hasMore outright, rather than leaving it
	// to be inferred from the presence of a cursor.
	explicitMore := false

	// Relay connections carry the cursor in pageInfo, at the path the model
	// recorded for this op.
	page := vs.GetPath([]any{"graphql", "page"}, ctx.Point)
	if pm, ok := page.(map[string]any); ok {
		if _, isMap := body.(map[string]any); isMap {
			// `connpath` locates the connection object inside the response
			// envelope (data.<field>); the cursor/more paths are relative
			// to it.
			conn := body
			if cp, ok := pm["connpath"].(string); ok && cp != "" {
				if sub := vs.GetPath(cp, body); sub != nil {
					conn = sub
				}
			}

			if cp, ok := pm["cursor"].(string); ok && cp != "" {
				if cursor := vs.GetPath(cp, conn); cursor != nil {
					paging["cursor"] = cursor
				}
			}
			if mp, ok := pm["more"].(string); ok && mp != "" {
				if more, ok := vs.GetPath(mp, conn).(bool); ok {
					paging["hasMore"] = more
					explicitMore = true
				}
			}
		}
	}

	// Body-level cursors.
	if bm, ok := body.(map[string]any); ok {
		if bm["next"] != nil && paging["next"] == nil {
			paging["next"] = bm["next"]
		}
		if bm["cursor"] != nil {
			paging["cursor"] = bm["cursor"]
		}
		if bm["nextCursor"] != nil {
			paging["cursor"] = bm["nextCursor"]
		}
		if hasMore, ok := bm["hasMore"].(bool); ok {
			paging["hasMore"] = hasMore
			explicitMore = true
		}
	}

	// Cursor presence only INFERS another page. When the server stated the
	// answer outright — relay's `hasNextPage: false`, or a body `hasMore` —
	// that wins: a final page normally carries both an end cursor and
	// hasNextPage false, and inferring from the cursor there would send the
	// caller back for a page that does not exist, forever.
	if !explicitMore && paging["hasMore"] != true &&
		(paging["next"] != nil || paging["cursor"] != nil || paging["nextPage"] != nil) {
		paging["hasMore"] = true
	}

	result.Paging = paging
	f.Last = paging
}

func (f *PagingFeature) isList(ctx *core.Context) bool {
	opname := ""
	if ctx.Op != nil {
		opname = ctx.Op.Name
	}
	ops := foptStrList(f.options, "ops")
	if ops == nil {
		ops = []string{"list"}
	}
	for _, o := range ops {
		if o == opname {
			return true
		}
	}
	return false
}

func (f *PagingFeature) headerNum(headers map[string]any, name string,
	paging map[string]any, key string) {

	v, has := fheaderGet(headers, name)
	if !has {
		return
	}
	if s, ok := v.(string); ok {
		if n := fparseInt(s, -1); n >= 0 {
			paging[key] = n
		}
		return
	}
	switch n := v.(type) {
	case int:
		paging[key] = n
	case int64:
		paging[key] = int(n)
	case float64:
		paging[key] = int(n)
	}
}

package feature

import (
	"strconv"
	"strings"

	vs "github.com/voxgig/struct"

	"GOMODULE/core"
)

type CostFeature struct {
	BaseFeature
	client  *core.UnivecSDK
	options map[string]any

	// Aggregates (mirrors the ts client._cost record).
	Currency string
	Total    *CostTotal
	Ops      map[string]*CostBucket
	Actors   map[string]*CostBucket
	Budget   *CostBudget
	Last     map[string]any

	seq int
}

type CostTotal struct {
	Calls     int
	Attempts  int
	Amount    float64
	Reported  float64
	Estimated float64
}

type CostBucket struct {
	Calls  int
	Amount float64
}

type CostBudget struct {
	Limit     float64
	Spent     float64
	Remaining float64
	Exceeded  bool
}

// Per-operation accumulator, carried on ctx.Out between the transport wrap
// and PreDone.
type costPending struct {
	attempts  int
	amount    float64
	reported  float64
	estimated float64
	source    string
	// Set by PrePoint. Its absence means the call never entered the pipeline
	// (direct/graphql), so charge commits the spend itself.
	piped bool
}

const costPendingKey = "cost_pending"

func NewCostFeature() *CostFeature {
	return &CostFeature{
		BaseFeature: BaseFeature{
			Version: "0.0.1",
			Name:    "cost",
			Active:  true,
		},
	}
}

func (f *CostFeature) Init(ctx *core.Context, options map[string]any) {
	f.client = ctx.Client
	f.options = options
	f.Active = foptBool(options, "active", false)

	limit := foptNum(options, "budget", 0)

	f.Currency = foptStr(options, "currency", "USD")
	f.Total = &CostTotal{}
	f.Ops = map[string]*CostBucket{}
	f.Actors = map[string]*CostBucket{}
	f.Budget = &CostBudget{Limit: limit, Remaining: limit}
	f.seq = 0

	if !f.Active {
		return
	}

	inner := ctx.Utility.Fetcher

	ctx.Utility.Fetcher = func(ctx2 *core.Context, url string, fetchdef map[string]any) (any, error) {
		return f.charge(ctx2, url, fetchdef, inner)
	}
}

// PrePoint is the budget gate. It runs before endpoint resolution, so a
// refused call costs nothing at all.
func (f *CostFeature) PrePoint(ctx *core.Context) {
	if !f.Active {
		return
	}

	pending, ok := ctx.Out[costPendingKey].(*costPending)
	if !ok || pending == nil {
		pending = &costPending{source: "none"}
		ctx.Out[costPendingKey] = pending
	}
	pending.piped = true

	limit := f.Budget.Limit
	if limit <= 0 {
		return
	}
	if f.Total.Amount < limit {
		return
	}

	f.Budget.Exceeded = true

	if foptStr(f.options, "onBudget", "warn") != "deny" {
		return
	}

	err := ctx.MakeError("cost_budget",
		"Cost budget of "+fcostNumStr(limit)+" "+f.Currency+" is spent ("+
			fcostNumStr(f.Total.Amount)+" "+f.Currency+" used)")

	// Short-circuit endpoint resolution; MakePoint surfaces this error
	// before any network activity.
	ctx.Out["point"] = err
}

func (f *CostFeature) charge(ctx *core.Context, url string, fetchdef map[string]any,
	inner core.FetcherFunc) (any, error) {

	res, err := inner(ctx, url, fetchdef)

	amount, source := f.price(ctx, res)

	pending, ok := ctx.Out[costPendingKey].(*costPending)
	if !ok || pending == nil {
		pending = &costPending{source: "none"}
		ctx.Out[costPendingKey] = pending
	}

	pending.attempts++

	pending.amount += amount
	if source == "header" || source == "body" {
		pending.reported += amount
	} else {
		pending.estimated += amount
	}
	pending.source = source

	f.Total.Attempts++

	if !pending.piped {
		f.commit(ctx, pending, "_", "direct")
		delete(ctx.Out, costPendingKey)
	}

	return res, err
}

// PreDone attributes the operation's spend once the call is finished.
func (f *CostFeature) PreDone(ctx *core.Context) {
	f.finish(ctx, true)
}

// PreUnexpected commits a FAILED operation's spend. When the pipeline errors,
// PreDone never runs, so without this the attempts are counted and the spend
// is not, and a budget could never see the cost of a failed call. Whichever
// hook fires first consumes the pending entry, so it commits exactly once.
func (f *CostFeature) PreUnexpected(ctx *core.Context) {
	f.finish(ctx, false)
}

func (f *CostFeature) finish(ctx *core.Context, done bool) {
	if !f.Active {
		return
	}
	pending, ok := ctx.Out[costPendingKey].(*costPending)
	if !ok || pending == nil {
		return
	}
	delete(ctx.Out, costPendingKey)

	if !done && pending.attempts == 0 {
		return
	}

	entity := "_"
	opname := "_"
	if ctx.Op != nil {
		entity = ctx.Op.Entity
		opname = ctx.Op.Name
	}

	f.commit(ctx, pending, entity, opname)
}

func (f *CostFeature) commit(ctx *core.Context, pending *costPending, entity, opname string) {
	amount := pending.amount
	reported := pending.reported
	estimated := pending.estimated
	source := pending.source

	// A body figure prices the whole call, so it replaces the per-attempt
	// estimate rather than adding to it, and being server-stated the whole
	// amount counts as reported.
	if body, has := f.body(ctx); has {
		amount = body
		reported = body
		estimated = 0
		source = "body"
	}

	f.spend(amount, reported, estimated)

	actor := "anonymous"
	if a := foptStr(f.options, "actor", ""); a != "" {
		actor = a
	}
	if ctx.Ctrl != nil && ctx.Ctrl.Actor != "" {
		actor = ctx.Ctrl.Actor
	}

	f.Total.Calls++
	f.bump(f.Ops, entity+"."+opname, amount)
	f.bump(f.Actors, actor, amount)

	f.seq++
	record := fclean(ctx, map[string]any{
		"seq":      f.seq,
		"entity":   entity,
		"op":       opname,
		"actor":    actor,
		"amount":   amount,
		"currency": f.Currency,
		"source":   source,
		"attempts": pending.attempts,
	})
	f.Last = record

	if sink, ok := f.options["sink"].(func(map[string]any)); ok {
		sink(record)
	}
}

// price returns the cost of one attempt: a reported header figure, else the
// rate table, else the flat unit.
func (f *CostFeature) price(ctx *core.Context, res any) (float64, string) {
	if header := foptStr(f.options, "header", ""); header != "" {
		if s, ok := fresHeader(res, header); ok {
			if n, err := strconv.ParseFloat(strings.TrimSpace(s), 64); err == nil {
				return n * f.perUnit(), "header"
			}
		}
	}

	if rate, ok := f.rate(ctx); ok {
		return rate, "table"
	}

	if unit := foptNum(f.options, "unit", 0); unit != 0 {
		return unit, "unit"
	}

	return 0, "none"
}

// rate uses the same lookup grammar as rbac's rules: `<entity>.<op>`, then
// `<op>`, then `*`.
func (f *CostFeature) rate(ctx *core.Context) (float64, bool) {
	rates := foptMap(f.options, "rates")
	if rates == nil {
		return 0, false
	}

	entity := ""
	if ctx.Entity != nil {
		entity = ctx.Entity.GetName()
	} else if ctx.Op != nil {
		entity = ctx.Op.Entity
	}
	opname := ""
	if ctx.Op != nil {
		opname = ctx.Op.Name
	}

	for _, key := range []string{entity + "." + opname, opname, "*"} {
		if v, has := rates[key]; has {
			switch n := v.(type) {
			case int:
				return float64(n), true
			case int64:
				return float64(n), true
			case float64:
				return n, true
			case float32:
				return float64(n), true
			}
		}
	}
	return 0, false
}

// body reads a usage figure from the parsed result body, priced by perUnit.
// Read here, not at the transport seam, because the body is one-shot.
func (f *CostFeature) body(ctx *core.Context) (float64, bool) {
	path := foptStr(f.options, "path", "")
	if path == "" || ctx.Result == nil || ctx.Result.Body == nil {
		return 0, false
	}

	switch n := vs.GetPath(ctx.Result.Body, path).(type) {
	case int:
		return float64(n) * f.perUnit(), true
	case int64:
		return float64(n) * f.perUnit(), true
	case float64:
		return n * f.perUnit(), true
	case float32:
		return float64(n) * f.perUnit(), true
	case string:
		if v, err := strconv.ParseFloat(strings.TrimSpace(n), 64); err == nil {
			return v * f.perUnit(), true
		}
	}
	return 0, false
}

func (f *CostFeature) spend(amount, reported, estimated float64) {
	f.Total.Amount += amount
	f.Total.Reported += reported
	f.Total.Estimated += estimated

	limit := f.Budget.Limit
	f.Budget.Spent = f.Total.Amount
	if limit > 0 {
		f.Budget.Remaining = limit - f.Total.Amount
		if f.Budget.Remaining < 0 {
			f.Budget.Remaining = 0
		}
		if f.Total.Amount >= limit {
			f.Budget.Exceeded = true
		}
	} else {
		f.Budget.Remaining = 0
	}
}

func (f *CostFeature) bump(bucket map[string]*CostBucket, key string, amount float64) {
	b := bucket[key]
	if b == nil {
		b = &CostBucket{}
		bucket[key] = b
	}
	b.Calls++
	b.Amount += amount
}

func (f *CostFeature) perUnit() float64 {
	return foptNum(f.options, "perUnit", 0)
}

// fcostNumStr renders a money amount without an exponent or trailing zeros.
func fcostNumStr(n float64) string {
	return strconv.FormatFloat(n, 'f', -1, 64)
}

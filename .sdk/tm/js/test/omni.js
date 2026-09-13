// The corpus test runner: vendored @voxgig/omni driven through its NATIVE
// API (`makeRunner(specref, provider)`), presented to the corpus tests in
// the struct-runner shape they already use (`R.spec`, `R.runset`,
// `R.runsetflags`, `R.client`). No compat shim is vendored: the adapter
// below IS the whole bridge, per language, per the vendor-tag rollout
// (docs/design/vendor-tag-rollout.md, Decision 4).
//
// Two local decisions, both required (mirroring tm/ts/test/omni.ts):
//
// 1. SPEC PATH. omni's own spec resolution expects the caller to hand it a
//    usable path — its docs say a port must resolve the path itself. This
//    module lives at test/omni.js, the same depth as the old
//    test/runner.js, so the existing TEST_JSON_FILE constant keeps working
//    verbatim: a relative path is absolutized against __dirname.
//
// 2. PROVIDER DELEGATION. Corpus-driven contexts get `ctx.client` set to
//    the runner's provider (omni overwrites it on any ctx/args map entry).
//    A five-hook provider object HIDES the live SDK from the generated
//    utilities that reach through it — prepareHeaders via client.options(),
//    fetcher via client._mode, the feature helpers via client._rootctx and
//    even ASSIGNING client._features. So the provider here is built by
//    PROTOTYPE DELEGATION over the live SDK instance: every SDK member
//    resolves, while the omni hooks sit on top. (Upstream omni#56 tracks
//    giving the stock provider the same shape.)
//
// ZERO-ARGUMENT ENTRIES, checked and deliberately NOT corrected here: six
// of omni's eight upstream compat shims rewrite entries with no in/args/ctx
// to a true zero-argument call. The javascript shim carries no such
// correction, because JavaScript cannot tell `subject(undefined)` from
// `subject()` (default parameters fire either way), and omni's native rule
// (`args = [clone(entry.in)]`) is byte-identical to what the retired
// tm/js/test/runner.js already did. There is nothing to port, and the
// shared corpus keeps asserting exactly what it asserted before the swap.
//
// THE VENDORED JS PORT LACKS THE omni#54 RUNNER FIXES the TypeScript port
// has at this tag (upstream omni#57 tracks porting them). Vendored files
// are resynced, never edited, so each gap is worked around HERE instead:
//
// a. `errify`/`errmessage` collapse non-Error throwables to `String(err)`
//    = '[object Object]'. The shared corpus throws error-shaped plain maps
//    (generated makeError rethrows the fixture's err verbatim), which the
//    retired runner matched by `.message` regardless of class. Every
//    subject is therefore wrapped (`wrapsubject`) to rethrow such a map as
//    a real Error carrying the map's own properties — errmessage() then
//    reads the right message, and the native errify's spread preserves the
//    map's fields for `match.err`.
//
// b. `match()` clones its base, and the vendored clone() has no cycle
//    guard, so any ctx-carrying `match` entry — the corpus has fourteen —
//    would blow the stack. The live cycles reach the match base on three
//    edges, every one of them runner/SDK bookkeeping the corpus never
//    asserts on, so the resolver makes exactly those NON-ENUMERABLE —
//    invisible to clone()/fixjson()'s Object.keys() walks while every
//    property READ still works:
//      - `ctx.client` (assigned by the runner after contextify): the
//        provider, whose `sdk._rootctx.client` reaches the SDK again;
//      - the provider's own `sdk`: same cycle, one hop earlier;
//      - `err.ctx` on Error objects a subject returns or throws:
//        generated `ctx.error()` attaches the LIVE context to every error
//        it makes, so `ctx.result.err.ctx === ctx` — a cycle entirely
//        inside the entry's own result (`sanitizeerrs`, applied at the
//        subject boundary by `wrapsubject`).
//    This also keeps the unguarded jsonstr() away from cyclic values:
//    failure messages only ever render acyclic data.

const { isAbsolute, join } = require('node:path')

const {
  EXISTSMARK,
  NULLMARK,
  UNDEFMARK,
  OmniError,
  nullmodifier,
  makeRunner: omnimakerunner,
} = require('./vendor/omni/index')


// Keep a property readable and writable but invisible to Object.keys(),
// which is how the vendored clone()/fixjson() walk. A later plain
// assignment (the runner does `ctx.client = provider`) updates the value
// and keeps the non-enumerability.
function hideprop(obj, key) {
  Object.defineProperty(obj, key, {
    value: obj[key],
    enumerable: false,
    writable: true,
    configurable: true,
  })
}


// Workaround (a): rethrow an error-shaped plain map as a real Error so the
// vendored errmessage() reads `.message` instead of '[object Object]'. The
// map's own properties ride along for the native errify's spread. Real
// Errors and everything else pass through untouched.
function normthrown(err) {
  if (err instanceof Error) {
    return err
  }
  if (null != err && 'object' === typeof err && 'string' === typeof err.message) {
    return Object.assign(new Error(err.message), err)
  }
  return err
}

// Workaround (b), third edge: generated `ctx.error()` attaches the live
// Context to the errors it makes (`err.ctx`), so a returned result or a
// thrown error can carry a cycle entirely inside itself
// (ctx.result.err.ctx === ctx). Walk a subject's outcome and hide that
// bookkeeping on every Error found; the corpus never asserts on `err.ctx`.
function sanitizeerrs(val, seen) {
  if (null == val || 'object' !== typeof val) {
    return val
  }

  seen = seen || new Set()
  if (seen.has(val)) {
    return val
  }
  seen.add(val)

  if (val instanceof Error && Object.prototype.propertyIsEnumerable.call(val, 'ctx')) {
    hideprop(val, 'ctx')
  }

  for (const key of Object.keys(val)) {
    sanitizeerrs(val[key], seen)
  }

  return val
}

function wrapsubject(subject) {
  if ('function' !== typeof subject) {
    return subject
  }
  return async function (...args) {
    try {
      return sanitizeerrs(await subject.apply(this, args))
    }
    catch (err) {
      throw sanitizeerrs(normthrown(err))
    }
  }
}


// The omni hooks for an SDK subject — what the retired compat shim called
// `structprovider`, inlined here because this resolver is the one consumer.
function sdkhooks(sdk) {
  return {
    // A subject is resolved from the utility, or from utility.struct.
    subject: (name) => {
      const utility = sdk.utility()
      return wrapsubject(utility[name] || (utility.struct && utility.struct[name]))
    },

    // A DEF.client entry becomes another SDK instance — rewrapped with the
    // same delegating shape, not a plain hook object.
    client: async (options) => sdkprovider(await sdk.tester(options)),

    // The SDK supplies its own context wrapper.
    contextify: (val) => {
      const utility = sdk.utility()
      const hook =
        'function' === typeof utility.contextify ? utility.contextify
          : 'function' === typeof utility.makeContext ? utility.makeContext
            : null
      const ctx = null == hook ? val : hook.call(utility, val)
      if (null != ctx && 'object' === typeof ctx) {
        ctx.utility = utility

        // Workaround (b): the runner assigns the provider here right after
        // this hook returns; hidden, the cycle never enters clone()'s walk.
        hideprop(ctx, 'client')
      }
      return ctx
    },

    // Client options may reference the runner store.
    inject: (options, store) => {
      const structutils = sdk.utility().struct
      if (structutils && 'function' === typeof structutils.inject) {
        return structutils.inject(options, store)
      }
      return options
    },

    utility: () => sdk.utility(),
    tester: (options) => sdk.tester(options),
    sdk,
  }
}


// Wrap the SDK as an omni provider WITHOUT hiding it: hooks from sdkhooks,
// everything else through the prototype chain.
function sdkprovider(sdk) {
  const provider = Object.assign(Object.create(sdk), sdkhooks(sdk))

  // Workaround (b), second edge: `provider.sdk` stays readable (tests
  // unwrap the live SDK through it) but leaves clone()'s walk.
  hideprop(provider, 'sdk')

  return provider
}


// struct's makeRunner(testfile, client) signature, backed by vendored omni.
// Also accepts an already-parsed spec object (omni's own capability), which
// keeps smoke tests free of fixture files.
async function makeRunner(testfile, client) {
  const specref = 'string' !== typeof testfile ? testfile
    : isAbsolute(testfile) ? testfile
      : join(__dirname, testfile)

  const provider = sdkprovider(client)
  const runner = await omnimakerunner(specref, provider)

  return async function structrunner(name, store) {
    const runpack = await runner(name, store)

    return {
      spec: runpack.spec,

      // Explicitly passed subjects need workaround (a) too — the corpus
      // tests hand most subjects in per-set rather than by name.
      runset: async (testspec, testsubject) =>
        runpack.runset(testspec, wrapsubject(testsubject)),
      runsetflags: async (testspec, flags, testsubject) =>
        runpack.runsetflags(testspec, flags, wrapsubject(testsubject)),

      subject: runpack.subject,
      client: provider,
    }
  }
}


// struct's flag-modifier name, served from native omni.
const nullModifier = nullmodifier


module.exports = {
  EXISTSMARK,
  NULLMARK,
  UNDEFMARK,
  OmniError,
  makeRunner,
  nullModifier,
}

package SCALAPACKAGE.core

// Shared function-value type aliases for the pipeline utility fields.
// Mirrors the @FunctionalInterface set in the java donor's Utility class,
// but expressed as idiomatic Scala function types.

import java.util.{Map => JMap}

// A context-consuming pipeline step producing a T.
type CtxFn[T] = Context => T

// The transport function: (ctx, fullurl, fetchdef) -> response-ish value.
type FetcherFn = (Context, String, JMap[String, Object]) => Object

// clean(ctx, val) -> val
type CleanFn = (Context, Object) => Object

// makeError(ctx, err) -> value (throws, or returns fallback)
type MakeErrorFn = (Context, RuntimeException) => Object

// feature add/init: (ctx, feature) -> unit
type FeatureFn = (Context, Feature) => Unit

// featureHook: (ctx, hookName) -> unit
type HookFn = (Context, String) => Unit

// makeContext: (ctxmap, basectx) -> Context
type MakeContextFn = (JMap[String, Object], Context) => Context

// param(ctx, paramdef) -> value
type ParamFn = (Context, Object) => Object

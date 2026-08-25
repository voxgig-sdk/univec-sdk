// Univec SDK utility: feature wiring - featureAdd (with ordering),
// featureHook (dispatch by name), featureInit.

import Foundation

// FeatureAddUtil appends a feature to the client's feature list. A feature can
// instead position itself relative to an already-added feature with
// "__before__", "__after__" or "__replace__" (via addOptions) naming that
// feature. The first match wins; when no ordering option matches, the feature
// is appended.
func featureAddUtil(_ ctx: Context, _ f: BaseFeature) {
  let client = ctx.client!

  if let fopts = f.addOptions() {
    let before = fopts.entries["__before__"]?.asString
    let after = fopts.entries["__after__"]?.asString
    let replace = fopts.entries["__replace__"]?.asString

    let nonEmpty = (before != nil && before != "")
      || (after != nil && after != "")
      || (replace != nil && replace != "")

    if nonEmpty {
      for i in 0..<client.features.count {
        let name = client.features[i].getName()
        if before == name { client.features.insert(f, at: i); return }
        if after == name { client.features.insert(f, at: i + 1); return }
        if replace == name { client.features[i] = f; return }
      }
    }
  }

  client.features.append(f)
}

// FeatureHookUtil dispatches a named hook to every feature. Iterating a copy of
// the feature array is safe against a hook mutating the list.
func featureHookUtil(_ ctx: Context, _ name: String) {
  guard let client = ctx.client else { return }
  for f in client.features {
    f.dispatch(name, ctx)
  }
}

func featureInitUtil(_ ctx: Context, _ f: BaseFeature) {
  let fname = f.getName()
  var fopts = VMap()

  if let fm = gp(ctx.options, "feature").asMap, let fom = gp(fm, fname).asMap {
    fopts = fom
  }

  if fopts.entries["active"]?.asBool == true {
    f.initFeature(ctx, fopts)
  }
}

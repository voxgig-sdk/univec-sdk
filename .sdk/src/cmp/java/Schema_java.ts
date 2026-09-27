import {
  Content,
  File,
  cmp,
  entitySpecMap,
  optionSpec,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


import {
  javaPackage,
  jsonAppendLines,
} from './utility_java'


const Schema = cmp(async function Schema(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model
  const javapackage = javaPackage(model)

  const optspec = optionSpec(model, target.name)
  const entityspec = entitySpecMap(model, target.name) || {}

  // Beside Config.java, and for the same reason: core owns the generated
  // data, so nothing in utility or feature has to reach up for it.
  File({ name: 'Schema.' + target.ext }, () => {

    Content(`package ${javapackage}.core;

import java.util.Map;

import ${javapackage}.utility.Json;

/**
 * ${model.const.Name} ${target.Name} SDK: generated schemas. Do not edit.
 *
 * <p>Generated from the model: {@code main.kit.optspec} and each feature's
 * {@code config.options} for OPTSPEC; entity {@code fields{}.type} for
 * ENTITYSPEC.
 */
@SuppressWarnings({"unchecked"})
public final class Schema {

  private Schema() {}

  // Parsed ONCE, on first use. The spec is read on every client construction
  // and never mutated, so a per-call parse would be pure waste — and a shared
  // map is safe for the same reason the spec is a constant: MakeOptions
  // validates AGAINST it and writes into the options, never into the spec.
  //
  // Initialization-on-demand holder, as Config.sharedConfig uses: the JLS
  // guarantees the class initializer runs once, lazily, and safely under
  // concurrency, with no locking on the read path.
  private static final class OptHolder {
    static final Map<String, Object> VALUE =
        (Map<String, Object>) Json.parse(optspecJson());
  }

  private static final class EntityHolder {
    static final Map<String, Object> VALUE =
        (Map<String, Object>) Json.parse(entityspecJson());
  }

  /** The option spec MakeOptions validates client options against. */
  public static Map<String, Object> optspec() {
    return OptHolder.VALUE;
  }

  /** Per-entity data and request specs, keyed by entity name. */
  public static Map<String, Object> entityspec() {
    return EntityHolder.VALUE;
  }

  private static String optspecJson() {
    StringBuilder b = new StringBuilder();
`)

    Content(jsonAppendLines(optspec, 'b'))

    Content(`    return b.toString();
  }

  private static String entityspecJson() {
    StringBuilder b = new StringBuilder();
`)

    Content(jsonAppendLines(entityspec, 'b'))

    Content(`    return b.toString();
  }
}
`)
  })
})


export {
  Schema
}

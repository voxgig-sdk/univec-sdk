// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (swift/src/Catalog.swift)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/// The definition catalog (section 10.1).
///
/// A definition is registered once and may back many instances. Option shapes
/// are validated AT REGISTRATION, not when a document happens to exercise a key
/// - so a malformed shape fails once, and in the same place everywhere
/// (section 9.4).
///
/// A CLASS, not a struct: the host and its caller share one catalog, and the
/// driver's section 6.5 nest case adds to a live host's. A struct would be
/// copied at the boundary and the addition would land nowhere.
public final class Catalog {

    private var defs: [String: Definition] = [:]

    public init() {}

    public func add(_ definition: Definition) throws {
        guard Refs.checkName(.str(definition.name)) else {
            throw Types.fail(
                "plugin_definition_name", "invalid definition name: \(definition.name)"
            )
        }
        // Validate the shape HERE. Deferring it to resolution time means a
        // malformed shape surfaces at a different moment in every host that
        // loads it, which is the divergence the stated domain exists to prevent.
        if !definition.shape.isNull { try Config.checkShape(definition.shape) }
        defs[definition.name] = definition
    }

    public func get(_ name: String) -> Definition? { return defs[name] }

    public func has(_ name: String) -> Bool { return defs[name] != nil }

    public func names() -> [String] { return defs.keys.sorted() }
}

/// A plugin definition. A STRUCT WITH NAMED CALLBACKS, not a `Value` map: swift
/// cannot hold a closure in the JSON enum, and pretending otherwise would mean
/// an `.opaque` per callback and a cast at every call. The shape is the same
/// one every port has - a name, four lifecycle callbacks, `reconfigure`, and an
/// option shape - written in the type system rather than in a comment.
public struct Definition {
    public let name: String
    public var define: ((Inst) throws -> Void)?
    public var activate: ((Inst) throws -> Void)?
    public var deactivate: ((Inst) throws -> Void)?
    public var close: ((Inst) throws -> Void)?
    public var reconfigure: ((Inst, Value, Value) throws -> Void)?
    public var shape: Value

    public init(
        name: String,
        define: ((Inst) throws -> Void)? = nil,
        activate: ((Inst) throws -> Void)? = nil,
        deactivate: ((Inst) throws -> Void)? = nil,
        close: ((Inst) throws -> Void)? = nil,
        reconfigure: ((Inst, Value, Value) throws -> Void)? = nil,
        shape: Value = .null
    ) {
        self.name = name
        self.define = define
        self.activate = activate
        self.deactivate = deactivate
        self.close = close
        self.reconfigure = reconfigure
        self.shape = shape
    }

    public func callback(_ at: String) -> ((Inst) throws -> Void)? {
        switch at {
        case "define": return define
        case "activate": return activate
        case "deactivate": return deactivate
        case "close": return close
        default: return nil
        }
    }
}

public func makeCatalog(_ definitions: [Definition] = []) throws -> Catalog {
    let catalog = Catalog()
    for d in definitions { try catalog.add(d) }
    return catalog
}

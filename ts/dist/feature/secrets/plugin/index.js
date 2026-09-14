"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/index.ts)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The canonical surface `make parity` checks (AGENTS.md §4). Small on
 * purpose (§19): everything else is methods on the host and instance
 * types, because a library that grows a second public entry point per
 * feature is a library twenty ports pay for twice. */
Object.defineProperty(exports, "__esModule", { value: true });
exports.PluginError = exports.featurepoints = exports.featuredefinition = exports.STATION_HOOKS = exports.SDK_HOOKS = exports.REQUEST_POINT = exports.resolveexport = exports.provider = exports.compose = exports.emit = exports.resolvegraph = exports.matches = exports.resolvecapability = exports.satisfies = exports.parseversion = exports.parserange = exports.encoderef = exports.applyenv = exports.resolvefrom = exports.resolvecandidates = exports.resolveorder = exports.checkshape = exports.resolveoptions = exports.normalizeconfig = exports.tryref = exports.canonref = exports.checktag = exports.checkname = exports.formatref = exports.parseref = exports.makecatalog = exports.makehost = void 0;
var Host_1 = require("./Host");
Object.defineProperty(exports, "makehost", { enumerable: true, get: function () { return Host_1.makehost; } });
var Catalog_1 = require("./Catalog");
Object.defineProperty(exports, "makecatalog", { enumerable: true, get: function () { return Catalog_1.makecatalog; } });
var Ref_1 = require("./Ref");
Object.defineProperty(exports, "parseref", { enumerable: true, get: function () { return Ref_1.parseref; } });
Object.defineProperty(exports, "formatref", { enumerable: true, get: function () { return Ref_1.formatref; } });
Object.defineProperty(exports, "checkname", { enumerable: true, get: function () { return Ref_1.checkname; } });
Object.defineProperty(exports, "checktag", { enumerable: true, get: function () { return Ref_1.checktag; } });
Object.defineProperty(exports, "canonref", { enumerable: true, get: function () { return Ref_1.canonref; } });
Object.defineProperty(exports, "tryref", { enumerable: true, get: function () { return Ref_1.tryref; } });
var Config_1 = require("./Config");
Object.defineProperty(exports, "normalizeconfig", { enumerable: true, get: function () { return Config_1.normalizeconfig; } });
Object.defineProperty(exports, "resolveoptions", { enumerable: true, get: function () { return Config_1.resolveoptions; } });
Object.defineProperty(exports, "checkshape", { enumerable: true, get: function () { return Config_1.checkshape; } });
var Order_1 = require("./Order");
Object.defineProperty(exports, "resolveorder", { enumerable: true, get: function () { return Order_1.resolveorder; } });
var Resolve_1 = require("./Resolve");
Object.defineProperty(exports, "resolvecandidates", { enumerable: true, get: function () { return Resolve_1.resolvecandidates; } });
Object.defineProperty(exports, "resolvefrom", { enumerable: true, get: function () { return Resolve_1.resolvefrom; } });
var Env_1 = require("./Env");
Object.defineProperty(exports, "applyenv", { enumerable: true, get: function () { return Env_1.applyenv; } });
Object.defineProperty(exports, "encoderef", { enumerable: true, get: function () { return Env_1.encoderef; } });
var Version_1 = require("./Version");
Object.defineProperty(exports, "parserange", { enumerable: true, get: function () { return Version_1.parserange; } });
Object.defineProperty(exports, "parseversion", { enumerable: true, get: function () { return Version_1.parseversion; } });
Object.defineProperty(exports, "satisfies", { enumerable: true, get: function () { return Version_1.satisfies; } });
var Capability_1 = require("./Capability");
Object.defineProperty(exports, "resolvecapability", { enumerable: true, get: function () { return Capability_1.resolvecapability; } });
Object.defineProperty(exports, "matches", { enumerable: true, get: function () { return Capability_1.matches; } });
var Graph_1 = require("./Graph");
Object.defineProperty(exports, "resolvegraph", { enumerable: true, get: function () { return Graph_1.resolvegraph; } });
var Point_1 = require("./Point");
Object.defineProperty(exports, "emit", { enumerable: true, get: function () { return Point_1.emit; } });
Object.defineProperty(exports, "compose", { enumerable: true, get: function () { return Point_1.compose; } });
Object.defineProperty(exports, "provider", { enumerable: true, get: function () { return Point_1.provider; } });
var Export_1 = require("./Export");
Object.defineProperty(exports, "resolveexport", { enumerable: true, get: function () { return Export_1.resolveexport; } });
var FeatureHost_1 = require("./FeatureHost");
Object.defineProperty(exports, "REQUEST_POINT", { enumerable: true, get: function () { return FeatureHost_1.REQUEST_POINT; } });
Object.defineProperty(exports, "SDK_HOOKS", { enumerable: true, get: function () { return FeatureHost_1.SDK_HOOKS; } });
Object.defineProperty(exports, "STATION_HOOKS", { enumerable: true, get: function () { return FeatureHost_1.STATION_HOOKS; } });
Object.defineProperty(exports, "featuredefinition", { enumerable: true, get: function () { return FeatureHost_1.featuredefinition; } });
Object.defineProperty(exports, "featurepoints", { enumerable: true, get: function () { return FeatureHost_1.featurepoints; } });
var Types_1 = require("./Types");
Object.defineProperty(exports, "PluginError", { enumerable: true, get: function () { return Types_1.PluginError; } });
//# sourceMappingURL=index.js.map
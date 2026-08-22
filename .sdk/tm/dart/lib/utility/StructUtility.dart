// Struct utility surface for the Univec SDK.
//
// Wraps the vendored voxgig struct port (voxgig_struct.dart) as an instance
// whose members mirror the donor (ts) StructUtility class shape. Function
// values are plain fields so tests and custom code can pass them around;
// `byName` supports the string-keyed lookup the corpus test runner needs.

import 'voxgig_struct.dart' as vs;

export 'voxgig_struct.dart' show StructError;

class StructUtility {
  final clone = vs.clone;
  final delprop = vs.delprop;
  final escre = vs.escre;
  final escurl = vs.escurl;
  final filter = vs.filter;
  final flatten = vs.flatten;
  final getdef = vs.getdef;
  final getelem = vs.getelem;
  final getpath = vs.getpath;
  final getprop = vs.getprop;
  final haskey = vs.haskey;
  final inject = vs.inject;
  final isempty = vs.isempty;
  final isfunc = vs.isfunc;
  final iskey = vs.iskey;
  final islist = vs.islist;
  final ismap = vs.ismap;
  final isnode = vs.isnode;
  final items = vs.items;
  final join = vs.join;
  final joinurl = vs.joinurl;
  final jsonify = vs.jsonify;
  final keysof = vs.keysof;
  final merge = vs.merge;
  final pad = vs.pad;
  final pathify = vs.pathify;
  final select = vs.select;
  final setpath = vs.setpath;
  final setprop = vs.setprop;
  final size = vs.size;
  final strkey = vs.strkey;
  final stringify = vs.stringify;
  final transform = vs.transform;
  final typify = vs.typify;
  final typename = vs.typename;
  final validate = vs.validate;

  // The donor walk takes the apply functions positionally (before, after).
  final walk = _walk;

  // slice has an optional mutate flag in the port; expose donor arity.
  final slice = _slice;

  final SKIP = vs.SKIP;
  final DELETE = vs.DELETE;

  final T_any = vs.T_any;
  final T_noval = vs.T_noval;
  final T_boolean = vs.T_boolean;
  final T_decimal = vs.T_decimal;
  final T_integer = vs.T_integer;
  final T_number = vs.T_number;
  final T_string = vs.T_string;
  final T_function = vs.T_function;
  // The dart struct port has no symbol type; keep the donor bit slot.
  final T_symbol = 1 << 23;
  final T_null = vs.T_null;
  final T_list = vs.T_list;
  final T_map = vs.T_map;
  final T_instance = vs.T_instance;
  final T_scalar = vs.T_scalar;
  final T_node = vs.T_node;

  // String-keyed lookup for the corpus test runner (Dart has no dynamic
  // property access, so subjects are resolved through this map).
  dynamic byName(String name) => _byname[name];

  late final Map<String, dynamic> _byname = {
    'clone': clone,
    'delprop': delprop,
    'escre': escre,
    'escurl': escurl,
    'filter': filter,
    'flatten': flatten,
    'getdef': getdef,
    'getelem': getelem,
    'getpath': getpath,
    'getprop': getprop,
    'haskey': haskey,
    'inject': inject,
    'isempty': isempty,
    'isfunc': isfunc,
    'iskey': iskey,
    'islist': islist,
    'ismap': ismap,
    'isnode': isnode,
    'items': items,
    'join': join,
    'joinurl': joinurl,
    'jsonify': jsonify,
    'keysof': keysof,
    'merge': merge,
    'pad': pad,
    'pathify': pathify,
    'select': select,
    'setpath': setpath,
    'setprop': setprop,
    'size': size,
    'slice': slice,
    'strkey': strkey,
    'stringify': stringify,
    'transform': transform,
    'typify': typify,
    'typename': typename,
    'validate': validate,
    'walk': walk,
  };
}

dynamic _walk(dynamic val,
        [Function? before, Function? after, dynamic maxdepth]) =>
    vs.walk(val, before: before, after: after, maxdepth: maxdepth);

dynamic _slice(dynamic val, [dynamic start, dynamic end]) =>
    vs.slice(val, start, end);

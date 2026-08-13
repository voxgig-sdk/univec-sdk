"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.Point = void 0;
const StructUtility_1 = require("./utility/StructUtility");
class Point {
    args;
    rename;
    method;
    orig;
    parts;
    params;
    select;
    active;
    relations;
    alias;
    transform;
    constructor(altmap) {
        this.args = (0, StructUtility_1.getprop)(altmap, 'args', { params: [] });
        this.rename = (0, StructUtility_1.getprop)(altmap, 'rename', { params: {} });
        this.method = (0, StructUtility_1.getprop)(altmap, 'method', '');
        this.orig = (0, StructUtility_1.getprop)(altmap, 'orig', '');
        this.parts = (0, StructUtility_1.getprop)(altmap, 'parts', []);
        this.params = (0, StructUtility_1.getprop)(altmap, 'params', []);
        this.select = (0, StructUtility_1.getprop)(altmap, 'select');
        this.active = (0, StructUtility_1.getprop)(altmap, 'active', false);
        this.relations = (0, StructUtility_1.getprop)(altmap, 'relations', []);
        this.alias = (0, StructUtility_1.getprop)(altmap, 'alias', {});
        this.transform = (0, StructUtility_1.getprop)(altmap, 'transform', { req: undefined, res: undefined });
    }
}
exports.Point = Point;
//# sourceMappingURL=Point.js.map
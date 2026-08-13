"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.transformRequest = transformRequest;
/* Convert entity data or match query into a srtucture suitable for use as request data.
 *
 * The operation (op) property `reqform` is used to perform the data preparation.
 */
function transformRequest(ctx) {
    const spec = ctx.spec;
    const utility = ctx.utility;
    const point = ctx.point;
    const isfunc = utility.struct.isfunc;
    const transform = utility.struct.transform;
    if (spec) {
        spec.step = 'reqform';
    }
    try {
        const reqform = point.transform.req;
        const reqdata = isfunc(reqform) ? reqform(ctx) : transform({
            reqdata: ctx.reqdata
        }, reqform);
        return reqdata;
    }
    catch (err) {
        return utility.makeError(ctx, err);
    }
}
//# sourceMappingURL=TransformRequestUtility.js.map
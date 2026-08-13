"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.UnivecError = void 0;
class UnivecError extends Error {
    isUnivecError = true;
    sdk = 'Univec';
    code;
    ctx;
    constructor(code, msg, ctx) {
        super(msg);
        this.code = code;
        this.ctx = ctx;
    }
}
exports.UnivecError = UnivecError;
//# sourceMappingURL=UnivecError.js.map
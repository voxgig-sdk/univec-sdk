"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.UnivecError = void 0;
class UnivecError extends Error {
    isUnivecError = true;
    sdk = 'Univec';
    code;
    ctx;
    status = -1;
    // `err.notFound` rather than a magic number at every call site.
    get notFound() { return 404 === this.status; }
    constructor(code, msg, ctx) {
        super(msg);
        this.code = code;
        this.ctx = ctx;
    }
}
exports.UnivecError = UnivecError;
//# sourceMappingURL=UnivecError.js.map
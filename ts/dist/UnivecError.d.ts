import { Context } from './Context';
declare class UnivecError extends Error {
    isUnivecError: boolean;
    sdk: string;
    code: string;
    ctx: Context;
    constructor(code: string, msg: string, ctx: Context);
}
export { UnivecError };

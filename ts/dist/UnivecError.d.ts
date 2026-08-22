import { Context } from './Context';
declare class UnivecError extends Error {
    isUnivecError: boolean;
    sdk: string;
    code: string;
    ctx: Context;
    status: number;
    get notFound(): boolean;
    constructor(code: string, msg: string, ctx: Context);
}
export { UnivecError };

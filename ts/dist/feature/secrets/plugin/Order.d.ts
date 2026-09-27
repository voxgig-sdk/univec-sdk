import { OrderBlock } from './Types';
export type Binding = {
    ref: string;
    pos: number;
    order?: OrderBlock;
};
export type Pin = {
    [name: string]: 'outermost' | 'innermost' | 'first' | 'last';
};
export declare function resolveorder(bindings: Binding[], pin?: Pin): string[];

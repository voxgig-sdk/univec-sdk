import { OrderBlock } from './Types';
export type Binding = {
    ref: string;
    pos: number;
    order?: OrderBlock;
};
/** Where a host has pinned a binding. Positional, not ordinal: §6.2
 * composes b1(b2(b3(base))) with the FIRST binding OUTERMOST, so
 * `first` and `innermost` are opposites, and a pin spelled in sort
 * terms would be read backwards by exactly the people it protects. */
export type Pin = {
    [name: string]: 'outermost' | 'innermost' | 'first' | 'last';
};
export declare function resolveorder(bindings: Binding[], pin?: Pin): string[];

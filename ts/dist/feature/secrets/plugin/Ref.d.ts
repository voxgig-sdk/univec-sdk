import { Ref } from './Types';
export declare function checkname(name: string): boolean;
export declare function checktag(tag: string): boolean;
/** `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both
 * give tag ''. */
export declare function parseref(str: string): Ref;
/** The pair -> `name$tag`. An empty tag NEVER writes the separator,
 * which is the half of canonicalization formatref owns: parse tolerates
 * `stripe$`, format never produces it, so a round trip is idempotent. */
export declare function formatref(name: string, tag?: string): string;
/** The canonical spelling of a ref. §4 rule 5: ports must canonicalize
 * before comparison. */
export declare function canonref(str: string): string;
/** The canonical ref this string denotes, or `undefined` if it denotes
 * none — the TOLERANT half of `canonref`, and the one a requirement
 * name needs.
 *
 * A REQUIREMENT NAME IS A CAPABILITY NAME FIRST (§11.1), and capability
 * names are free-form: the design puts no grammar on them, so `2fa` and
 * `my cap` are perfectly good ones and neither is a well-formed ref.
 * `canonref` RAISES on those, so asking it "is this a ref?" made a legal
 * document kill the host at the first requirement whose name no ref
 * could have. Answering `undefined` is the whole difference. */
export declare function tryref(str: string): string | undefined;

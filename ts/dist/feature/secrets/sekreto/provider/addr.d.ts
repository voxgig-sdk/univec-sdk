/** An address with any userinfo replaced by `[redacted]`, for messages.
 *
 * Every refusal below names the address it refused, and one of them fires
 * precisely because the address carries a credential — so printing it
 * verbatim wrote the password to stderr and into the logs. It cannot be
 * cleaned up afterwards either: that password was never resolved as a
 * secret, so `redact()` has never seen it and never will. The host is what
 * a reader needs to identify which chain entry is at fault; the userinfo
 * is not. */
export declare function safeaddr(addr: string): string;
/** Refuse to send a secret-bearing credential in the clear.
 *
 * A vault API is HTTPS in any real deployment; plaintext is a dev-mode
 * convenience. Sending a token over http to anything but the local
 * machine puts both the token and the secret it fetches on the wire for
 * anyone on the path, so sekreto will not do it. Loopback stays allowed:
 * that is `vault server -dev`, `boru vault serve`, and this repo's own
 * test harness.
 *
 * The address is read by hand, in the same handful of steps in every
 * port, rather than by each platform's URL parser. That is deliberate.
 * Twelve parsers disagree about malformed input — where userinfo ends,
 * whether `0177.0.0.1` is loopback, what an unclosed bracket means — and
 * a check that answers differently in different ports is not a check.
 *
 * The rule this parse obeys, and the reason it can be trusted: it is
 * never more permissive than the HTTP client that will dial the address.
 * It ends the authority at `/`, `?` or `#` only, so a client that also
 * breaks on `\` (WHATWG does) can only ever see a SHORTER host than this
 * does. It refuses userinfo outright rather than locating its end. It
 * compares the host literally, so a numeric form no parser here agrees on
 * is refused rather than guessed at. Each of those can refuse an address
 * that would in fact have been safe; none can allow one that is not. */
export declare function checkaddr(addr: string): void;
/** How long any single vault round-trip may take before it is treated as
 * unreachable. Ports carry the same bound. */
/** One JSON round-trip. Network failure is always an error - an
 * unreachable store is a store that could not answer. */

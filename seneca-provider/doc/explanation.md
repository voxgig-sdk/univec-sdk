# Explanation

This document discusses why `@seneca/univec-provider` is built the way it is.
It does not tell you how to do anything — for that see the
[tutorial](tutorial.md) and the [how-to guides](how-to.md), and for the exact
patterns, entities and options, the [reference](reference.md). The whole set is
indexed in [doc/README.md](README.md).


## The provider convention

Seneca applications talk to the outside world through *providers*. A provider
is a plugin that makes a third-party API look like a Seneca data source, so
application code uses the entity API it already knows instead of learning a
client library per service.

The payoff is uniformity. An application reading from UniVec, a
payment processor and a CRM uses one access pattern for all three:

```js
await seneca.entity('provider/univec/convert').list$()
await seneca.entity('provider/stripe/charge').list$()
```

Because these are ordinary Seneca entities, everything built on the entity API
— logging, tracing, message interception, test doubles — applies to remote
calls without any special support for HTTP.


## What entityBuilder buys

The convention is more than a naming scheme. `@seneca/provider` exports
`provider/entityBuilder`, and this plugin hands it exactly one thing: a map
from entity name to a small set of cmd actions. Recognising the
`provider/univec/` canon, registering the `role:entity` messages
that sit behind `list$`, `load$`, `save$` and `remove$`, and turning
whatever an action returns into an entity of the right canon — none of that is
written here. It arrives with the convention.

What remains is a handful of async functions, each a few lines long, whose
whole job is to call the SDK and hand the result back through the `entize`
function entityBuilder supplies. That thinness is the point rather than an
accident of effort: a provider that is nearly all glue can be read at a glance,
generated in full, and regenerated when the API moves. Cleverness added here is
cleverness that has to be maintained against a moving target.


## Two layers of the same idea

This provider is unusual among Seneca providers in that the thing it wraps is
*already* entity-shaped. The UniVec SDK exposes accessors like
`client.Convert()` — carrying
`create` —
rather than raw HTTP routes, for much the same reason Seneca does. A small,
uniform surface is easier for people and for agents to reason about than a set
of URL templates.

So the provider is mostly a translation between two entity models that already
agree on the important things. Where they *disagree* is where this plugin has
to do real work, and each disagreement is discussed below.


## Where the SDK and Seneca disagree

### Four commands, five operations

Seneca's store commands are `list`, `load`, `save` and `remove`. The
SDK's operations are `list`, `load`, `create`, `update` and `remove`.
Four of the five line up. `save` is the join, and it dispatches on the id: an
entity carrying one is an update, an entity without one is a create.

That is Seneca's convention rather than this plugin's invention, and it is a
good one. Exposing create and update separately would push the HTTP verb back
into application code — the caller who loaded a record, changed a field and
called `save$` would have to know whether that becomes a POST or a PUT. The
presence of the id already answers the question. Asking the caller to answer it
again only adds a way to be wrong.

Which commands exist at all is decided per entity, from the operations the API
declares, rather than from an assumption that everything is CRUD.
`convert` carries
`save$`.
The other entities carry whatever their own operations support; the
[reference](reference.md) lists them all.
An entity whose API has no create and no update simply has no `save$`, which
is a better answer than a `save$` that exists and then fails at the HTTP
layer.

Where an entity declares only one of create and update there is nothing to
dispatch on, and `save$` means that operation whether an id is present or not:

- `convert`: `save$` always creates
- `embed`: `save$` always creates
- `ephemeral_key`: `save$` always creates

### Entity instances versus plain data

Every SDK operation resolves to an SDK entity instance, never to raw data:
`list` to a list of them, and each single-record operation to one. The record
is absorbed into the instance and read back through `.data()`.

Seneca's `entize` wants plain data, so the provider takes the `.data()` hop
on everything the SDK hands back, before it goes anywhere near an entity. That
is the whole of the `plain` helper in the source, and it is the only place in
the plugin that knows the SDK deals in instances at all.

The hop earns its keep for a second reason. An SDK instance carries its own
serialisation marker, and that marker must not survive into a Seneca entity:
Seneca reads `entity$` on a data object as the *canon*. A marker landing on
that key would be taken as a canon, and the record would come back under the
wrong one — or under none. The SDK namespaces its marker so the collision
cannot happen by accident, but normalising at this boundary is still the right
call. It is what makes the data plain, and it keeps the provider independent of
whatever the SDK decides to carry alongside a record.

### Query directives

Seneca store queries can carry directives such as `sort$` and `limit$`.
These are instructions to a *store*, and the API has no equivalent, so the
provider strips any key ending in `$` before the query becomes an API match.

Passing them through would be worse than dropping them: the SDK would forward
them as ordinary match fields, and the API would either ignore them or reject
the request outright. Dropping them is imperfect too — a caller who writes
`list$({ sort$: 'name' })` gets unsorted results and no complaint — but it is
the behaviour least likely to produce a wrong answer, and the limitation is
documented rather than hidden. Sorting and limiting belong on the caller's
side, or in the API's own query fields where it has them.


## Why writes are supported here

The read-only question is worth asking of every provider, and the answer here
follows from the API rather than from taste.

Writes map cleanly onto entities only when the API's notion of "save" is
unambiguous. For a CMS with draft states, localised fields and a separate
publish step, `save$` would have to pick one interpretation and would mislead
whoever guessed differently. Here the write operations are plain whole-record
ones, so `save$` can mean exactly one thing for each of
`convert`, `embed`, `ephemeral_key`, and the store surface those
operations support is implemented in full.

One wrinkle does not map cleanly. Seneca's model lets a caller choose an id;
many APIs assign ids themselves and ignore any id sent on create. The provider
does not try to paper over that, because it cannot make a server honour an id
it did not issue. Code that predicts the id of a record it is about to create
will be wrong on such an API, and the remedy is to read the id back from what
`save$` returns rather than to guess it beforehand.


## Credentials, whether or not the API needs them

At startup the plugin asks `@seneca/provider` for the keymap of
`univec` and sends the `apikey` as a bearer token when one is
configured.

The key is *optional*. Absent, unconfigured and empty all mean "send no
header", and none of them is an error. For an API that needs no credential this
looks like ceremony, and it is worth keeping anyway: the shape of a Seneca
application should not depend on whether a particular service happens to need a
key. An application that moves from an open endpoint to an authenticated
deployment then changes one configuration value rather than restructuring how
the plugin loads — and a provider that demanded a key from an API that has none
would force every user to invent a fake one.


## Depending on a published SDK

The SDK is an ordinary published dependency: `@voxgig-sdk/univec` at
`^0.1.1`, resolved by npm like anything else.

The alternative is vendoring — copying the generated client into this
repository. That is tempting, since both artefacts come from the same model and
change together. It is also wrong. It makes a second copy of something that is
regenerated whenever the API moves, and it puts this plugin's release cycle in
charge of the API's. As a dependency, the SDK carries its own semantic version:
when the API changes, the SDK is versioned, and this plugin either follows the
range or pins until it is ready. Keeping them separable also matters to the
people who use the SDK with no Seneca anywhere in sight.

One consequence of depending on generated code is worth stating plainly. The
SDK is regenerated as the API model changes, so its surface can shift in ways a
hand-written library's would not. That argues for keeping this plugin thin, and
for pinning behaviour in tests. Everything this plugin knows about the SDK's
shapes is concentrated in three small functions — the `.data()` hop, the query
cleaner and the not-found translation — plus the construction of the client, so
an SDK change is absorbed in one place and surfaces as a failing offline test
rather than as a surprise in production.

The API definition declares no server, so this plugin has no default host: the
base URL arrives through the `sdk.base` option, supplied by whoever configures
the plugin for a particular deployment. The tests therefore run entirely
against the SDK's mock transport, which is the one host that is always
available.


## A generated plugin

Nothing in this repository is hand-written. The plugin source, its tests, its CI
workflow, its manifest and these documents are all emitted by
[@voxgig/sdkgen](https://github.com/voxgig/sdkgen) from the UniVec API
model — the same model the SDK is generated from, which is why the two cannot
disagree about entity names, id fields, or which operations exist.

There is one blunt consequence for anyone reading the code and reaching for an
edit: the edit will not survive. The next generation run overwrites this
repository, without a merge and without a warning. A fix applied here is a fix
that has to be applied again, silently, forever.

The source of truth is the SDK project's model — `..` from
here, if both are checked out — together with the sdkgen component that emits
this target. A change to *what* the API offers belongs in the model; a change to
*how* the provider expresses it belongs in the component. Both are versioned,
both regenerate every provider built this way rather than just this one, and
both are where a fix is worth making. See
[Contributing](../README.md#contributing).


## How the tests are arranged

The suite runs offline by default. It needs no credentials and no network.

The **offline** tests use the SDK's own mock transport, reached through this
plugin's own options:

```js
.use('@seneca/univec-provider', {
  test: true,
  testopts: { entity: { convert: { 'convert0': { ... } } } },
})
```

This is better than the usual provider-testing compromise. Rather than checking
only that the plugin loads and answers
`sys:provider,provider:univec,get:info`, the tests exercise the
entity commands themselves
through the real code path, from a Seneca entity call down to the transport and
back. The only thing replaced is the socket. And because the mock belongs to the
SDK, it stays honest as the SDK changes: a regeneration that alters a return
shape breaks a test here rather than someone's production run.

Seeding the mock is not decoration either. The seed is generated from the same
model as the entities, so the records the tests read carry the fields the API
would really return.


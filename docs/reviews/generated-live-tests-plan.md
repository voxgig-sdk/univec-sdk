# Generated live tests: review and improvement plan

Reviewed 14 September 2026. Scope: the TypeScript Univec SDK, its generated-test sources, and the apidef/sdkgen pipeline. The TS/JS implementation now includes execution, operation contracts, input recipes, dependent scenarios, and generated regression coverage. The user-provided Boru terminal run confirms all eight Univec routes passed against the real service. The cross-language scenario rollout remains incomplete, as detailed below.

The accepted execution rule is to maximize coverage after failures: continue independent operations, block only work whose prerequisites are unavailable, and attempt supported cleanup. Record all outcomes before producing a failing exit status. A failed assertion must not end unrelated work or prevent cleanup of an identified resource created by the run.

## Implementation and verification update

The five workstreams have the following status:

| Stage | Implemented | Remaining boundary |
| --- | --- | --- |
| 1. Execution and coverage | Independent steps continue, ordinary dependencies require validated outputs, cleanup can use an identity published before an assertion failure, aggregate verdict and sanitized request ledger | Existing non-TS/JS runners retain their prior execution behavior |
| 2. Operation contracts | Versioned lossless point facts in apidef TS and Go; request/response/security/provenance kept separate; OpenAPI, Swagger, QUERY, and GraphQL fact tests | Unknown/unsupported request constraints are reported rather than guessed |
| 3. Recipes and workflows | TS/JS schema candidates, nested input validation, discovery joins, output/credential bindings, cycle/missing-input reporting; scaffold integer fix and separate request-contract fixtures | Other language scenario interpreters are not implemented |
| 4. Univec coverage | Distinct guide actions and recipes for all eight routes, account and issued credential scopes, real embedding-to-conversion bindings, dimension/count/identity assertions, shared canonical and focused live entry | All eight routes passed in the user-provided authenticated terminal run |
| 5. Regression and rollout | Regenerated Univec TS; generated TS/JS loopback matrix; existing CRUD/nested/singleton/direct tests; apidef TS/Go parity; tool and language-pack suites | Other targets emit an explicit unsupported scenario marker; this is not a completed cross-language rollout |

Operation facts use `point.contract: { version: 1, id, source, json }`. The JSON
payload intentionally preserves empty request objects, public `security: []`,
nulls, and nested schema keywords through aontu and model cleanup. Existing
entity field metadata remains available. Corrections and live relationships
live in `guide.aon`; sdkgen does not parse the OpenAPI definition.

The generated scenario suite runs under `UNIVEC_TEST_LIVE=TRUE npm test`.
`npm run test:live` invokes the same suite separately. The old GET-only entry
now delegates to the scenario suite. Entity/direct live tests delegated to
the consolidated plan are visibly skipped, while their offline tests remain.
The final summary covers eight modelled routes. Failed or blocked required
steps produce a nonzero exit after independent work and cleanup.

For Univec, public calls omit Authorization, account calls use the Boru-injected
account key, and ephemeral calls use the issued key. The suite issues one key
and reuses it for three requests, with no invented deletion endpoint. Request
logs omit headers, bodies, and query strings; response values and issued keys
are never serialized into the report. The model selects a conversion pair
whose source embedding model appears in the catalogue, and conversion consumes
that source model's actual vector output.

Verification as of this update:

- Apidef: **833 TS tests passed, 1 existing skip**; Go build/tests and canonical TS/Go model snapshots passed.
- Sdkgen: **1,309 passed, 8 existing toolchain-dependent skips** in the full suite. Final build/test and documentation checks are tracked in `/private/tmp/sdkgen-scenarios-all-final.log`.
- Create-sdkgen: **54 tests passed** after build; sdkgen-langpack: **31 tests passed** after build.
- Univec TS: **311 offline tests passed**, with the live-only test skipped. Its loopback suite passes **12 cases**, including all eight routes, 401/422/429/500, disconnection, invalid JSON, bad vectors, bad response types, incorrect bridge fields, and failed discovery/key issuance.
- Freshly generated upstream TS **and** JS clients pass the same 12-case route matrix. Existing generated CRUD, cleanup, nested/singleton/list and direct bootstrap regressions also pass.
- A real public `GET /v1/models` returned **118 entries**, including two bridge capability descriptors absent from the original response schema. A guide-owned response correction now models these descriptors alongside ordinary models. **32 conversion pairs** have an available source embedding model. The first compatible pair is Alibaba GTE large (1024 dimensions) to Nomic embed (768 dimensions).
- A subsequent real-service run passed all **five public/ephemeral routes**: public model discovery, key issuance, ephemeral embedding, ephemeral conversion using the actual 1024-dimensional source vector, and ephemeral bridge with a 768-dimensional target vector. Its final report was **8 planned, 5 attempted, 5 passed, 0 failed, 3 blocked**, and correctly exited nonzero. That earlier assistant run lacked the account credential. Keys were held in memory and never printed or persisted.
- Real requests exposed two inaccuracies in the authored definition: the catalogue includes bridge capability descriptors, and bridge responses return `bridge_model`, not `source_model`. Both are now explicit per-operation guide corrections, tracked by `contract.factSources`; the source definition was not edited. The loopback fixtures reproduce both cases.
- The user subsequently supplied the canonical Boru terminal result: **8 planned, 8 attempted, 8 passed, 0 failed, 0 blocked, 0 excluded**. All eight requests returned HTTP 200, including account embedding, conversion, and bridge calls. The complete invocation reported **312 tests, 307 passed, 0 failed, 5 skipped**; the five skips are older entity/direct tests delegated to the consolidated live suite. This closes Univec TS real-service acceptance for the eight modelled scenarios, not exhaustive coverage of every model, input, or failure condition.
- The verified canonical command is:

```bash
cd ts
UNIVEC_TEST_LIVE=TRUE boru vault --folder="$HOME/.vxgboru01" --suffix=sdk01 \
  exec sdk:univec=UNIVEC_APIKEY -- npm test
```

The sanitized real-service result is saved in `docs/reviews/live-verification.json`.

The working SDK generation uses local packed apidef/sdkgen builds; no package
was published, no version was bumped, and no dependency manifest was changed
to a temporary filesystem path. The upstream sources and this SDK's model,
templates, and components are the reviewable changes. Reinstalling the
published tool versions before these changes are released would replace those
local tool builds.

## Stage 1 implementation

The sdkgen TS/JS templates now share an execution design that records step outcomes, continues independent work, and runs cleanup after ordinary operations. Live entity execution no longer requires an unrelated ENTID override. It validates supplied identity maps and selects a usable route's prerequisites, allowing a parameter-free alternative when a nested route lacks its parent ID.

The runner reports planned, attempted, passed, failed, blocked, and excluded counts. Missing prerequisites and zero-attempt flows cannot produce a successful result. A resource published before an assertion failure remains available for supported cleanup. Request records omit headers, query strings, and bodies; error reports omit raw SDK error payloads. Native fetch attempts have a 30-second timeout.

TS direct requests assert HTTP success and list shape by default; failed list discovery can no longer return as a pass. The shared strictness default also applies to the existing Go direct-test generator. JS direct discovery no longer returns successfully for unusable list data. The new execution runner has not been ported to the other target languages yet.

Changes live in `~/Projects/voxgig/sdkgen` and this SDK's `.sdk` source templates/components. Univec TS was regenerated and explicitly built. Its project model sets `test.live.strict: true`, retaining the behavior with the currently published sdkgen package while the upstream default change is unreleased. Apidef and create-sdkgen are unchanged in this stage.

Final verification:

- Sdkgen `make all`: **1,302 passed, 0 failed, 8 existing toolchain-dependent skips**. Scaffold hashes were regenerated and reviewed. Prose checks passed; Vale remains unavailable.
- **19 new regressions passed**, including real generated TS/JS clients against a loopback HTTP server. Cases cover failed creates, continued reads, failed updates, continued load/cleanup, cleanup failures, disconnected transport, nested-route prerequisites, direct discovery errors, invalid JSON/list responses, dependency ordering/cycles, redacted errors, and zero-work plans.
- Regenerated Univec TS: **311 offline tests passed, 0 failed, 0 skipped**.
- With every network request deliberately blocked, Univec now attempts all three generated POSTs and both models GET tests, then exits unsuccessfully: **5 failed, 5 passed, 0 skipped**. The previous behavior was 6 passed, 4 skipped, and exit success. No Univec request was transmitted by this probe.

Stage-1 logs: `/private/tmp/sdkgen-live-make-all-final.log`, `/private/tmp/sdkgen-live-regression.log`, `/private/tmp/univec-live-offline.log`, and `/private/tmp/univec-live-after-probe.log`.

This section records the earlier stage-1 milestone. The operation contracts and Univec scenario changes are described in the implementation update above.

## Baseline update and verification

At the review baseline, both tool checkouts were clean, and `git pull --ff-only` reported them already up to date with `origin/main`. Both remained clean after the baseline build and tests; the subsequent stage 1 work modifies sdkgen.

| Project | Checked version/revision | Result |
| --- | --- | --- |
| `~/Projects/voxgig/apidef` | npm 8.5.2, `9f3e58d48fcceb5783b373916d65e83bc0cabea4` | `make all` passed: TS 829 passed, 0 failed, 1 skipped; Go build and tests passed |
| `~/Projects/voxgig/sdkgen` | npm 4.16.0, `f30ec270716cae433c913193842f8c1d26486a2e` | `make all` passed with supported Python on PATH: 1,283 passed, 0 failed, 8 skipped |
| This SDK | Installed apidef 8.5.2, sdkgen 4.16.0, model 11.0.1 | TS generation, explicit build, and tests passed: 311 passed, 0 failed, 0 skipped |

The SDK's installed tool versions already match those releases; no dependency bump was necessary. Generation used this project's installed npm packages and retained its existing source customizations. No upstream source changes were needed for the checks.

Verification qualifications:

- Apidef has an existing skipped `full-solar` TS test due to fixture drift; its Go benchmark is opt-in (`BENCH=1`) and skipped. Some Go results came from the normal test cache.
- Sdkgen's first run failed two Python probes because `python3` resolved to Python 3.9.6. Re-running with `PATH=/opt/homebrew/bin:$PATH make all` selected installed Python 3.14 and passed. This was an environment correction, without changing tests or code.
- Sdkgen's eight skips were Lua secrets (Lua 5.4 unavailable), C/C++/OCaml secrets (development headers unavailable), Perl secrets (interpreter too old), Kotlin auth-null (Gradle unavailable), Python cost corpus (pytest unavailable), and PHP cost corpus (PHPUnit unavailable).
- Both projects passed their Python prose checks; their Makefiles explicitly skipped Vale because it is not installed. These results do not establish coverage for the skipped checks.
- No Univec API request or account mutation was made during this review. The user's earlier public models GET remains the observed real-service result.

Logs: `/private/tmp/apidef-review-make-all.log`, `/private/tmp/sdkgen-review-make-all-supported-python.log`, and `/private/tmp/univec-review-{generate,build,test}.log`.

## Baseline findings

### 1. P1 — Live entity flows are gated on an unrelated ENTID override

[TestEntity_ts.ts](../../.sdk/src/cmp/ts/TestEntity_ts.ts:177) defines `syntheticOnly` from the presence of an ENTID environment string starting with `{`. [The basic test](../../.sdk/src/cmp/ts/TestEntity_ts.ts:249) then skips the entire flow when that flag is true. The same code is in sdkgen's `ts/project/.sdk/src/cmp/ts/TestEntity_ts.ts`.

Univec's model list and three create operations need no pre-existing path IDs. All four still skip. Conversely, supplying `{}` passes this gate without supplying any usable IDs or improving request data. This prevents exactly the stateless POST and key-issuance operations the live suite should exercise.

Fix direction: resolve prerequisites per step from its actual operation, route, and dependencies. Only a genuinely missing prerequisite should block a step. Parameter-free lists and valid standalone creates must run without ENTID overrides.

### 2. P1 — Failed live requests can be counted as passes, including a strict-mode bootstrap path

[TestDirect_ts.ts](../../.sdk/src/cmp/ts/TestDirect_ts.ts:599) emits early returns for unsuccessful live requests and unusable response shapes under the default policy. Node's test runner counts a normal return as a pass.

The existing [liveStrict helper](/Users/richard/Projects/voxgig/sdkgen/ts/src/helpers/testPolicy.ts:38) allows project-wide and per-target strictness, but defaults to false. Enabling it alone is insufficient: [load bootstrap](../../.sdk/src/cmp/ts/TestDirect_ts.ts:422) returns on failed list discovery before reaching the strict response assertions.

Reproduction against the regenerated SDK: preload a fake credential, set `UNIVEC_TEST_LIVE=TRUE`, leave ENTID overrides absent, and replace global fetch with a function that records the method/path and throws. Run the generated entity test files. Result: **10 tests, 6 passed, 4 skipped, 0 failed**. The sole attempted request is `GET /v1/models`; the probe prevents it from leaving the process. See `/private/tmp/univec-review-live-probe.log`.

Fix direction: attempted requests must fail on transport, authentication, unexpected HTTP status, decoding, or contract errors. Discovery steps obey the same rule. Deliberate exclusions must be reported as exclusions, never ordinary success. Live coverage must be reported separately from offline tests and instance checks.

### 3. P1 — Entity fixtures cannot serve as valid operation request bodies

[BuildSDK.ts](../../.sdk/src/BuildSDK.ts:166) generates fields from the aggregate entity shape, using hexadecimal strings and empty containers. It uses those fields for both stored mock records and new request data. Its type switch handles `$NUMBER` but omits `$INTEGER`.

This is a scaffold responsibility too: the same implementation lives in `~/Projects/voxgig/create-sdkgen/project/standard/.sdk/src/BuildSDK.ts`. Updating sdkgen's test renderer alone would leave the bad inputs in place.

Examples from the generated fixtures:

| Operation | Generated request problem | API definition |
| --- | --- | --- |
| Embed | `model: "s79"`, `texts: []`, response field `embeddings: []` | Requires a usable model and text inputs; provides a meaningful request example |
| Convert | Fake model names, empty vectors, and fields merged from embed-bridge | Conversion and embed-bridge have different request contracts |
| Ephemeral key | Sends response fields `dailyLimit`, `dailyUsed`, `key`, `resetsAt`; integers become strings | Request is an optional empty object with `additionalProperties: false` |

A second blocked-fetch probe supplied `{}` for each ENTID override. It reached all three POSTs with these synthetic bodies, confirming that the skip is masking a separate fixture defect. No request was transmitted. See `/private/tmp/univec-review-fixture-probe.log`.

Apidef already preserves useful field facts such as requiredness, read/write flags, format, and some parameter examples; it also infers fields from response examples. However, [field extraction](/Users/richard/Projects/voxgig/apidef/ts/src/transform/field.ts:1036) merges request and response properties, and the resulting Univec model does not retain enough operation-specific request schema/example information for valid live fixtures. A response field need not be explicitly marked `readOnly` to be absent from the request contract.

Fix direction: preserve operation/point request and response contracts separately through apidef, and create separate deterministic mock fixtures and validated live input recipes. Examples are candidates, not guarantees: Univec's illustrative three-number conversion vector must not be used when the source model requires a different dimension.

### 4. P1 — Four entity operations hide eight routes and two credential workflows

The current model groups four routes under `convert.create` and two under `embed.create`. Their effective selectors are empty. [MakePointUtility.ts](../../.sdk/tm/ts/src/utility/MakePointUtility.ts:81) selects the first match, so a normal create reaches `/v1/convert` or `/v1/embed`. The bridge and ephemeral variants are not independently exercised.

[Direct test generation](../../.sdk/src/cmp/ts/TestDirect_ts.ts:82) only covers load/list and selects the first point. [Apidef's basic flow generation](/Users/richard/Projects/voxgig/apidef/ts/src/transform/flowstep.ts:76) builds per-entity operation sequences; the emitted Univec flows have no cross-entity binding from issued key to ephemeral requests, or from embedding output to conversion input.

Fix direction: give points stable identities and distinguishable invocation semantics in the model. Preserve per-point payload and security facts. Add a dependency-aware scenario representation capable of binding discovery results, credentials, and operation outputs. Test the entity's route selection as well as any direct route coverage; direct requests must not conceal an unreachable SDK operation.

### 5. P2 — A successful public GET and non-null responses do not establish useful live coverage

The local [OpenAPI definition](../../.sdk/def/univec-openapi.json) explicitly declares `security: []` for `/v1/models` and `/v1/ephemeral/key`. The previous dedicated `test:live` models check demonstrates connectivity and response decoding, but requiring an outgoing Authorization header does not prove the account key was accepted by a public endpoint.

For ID-less creates, [the basic assertion](../../.sdk/src/cmp/ts/TestEntity_ts.ts:340) is merely non-null data. The generic list's existence assertions are correctly conditional on a prior create and usable identity, but that leaves Univec's standalone list without a substantive content assertion.

Fix direction: assert the operation's contract and domain invariants. Preserve the SDK's entity-instance return contract and validate `.data()` contents. Report public, account-authenticated, and ephemeral-authenticated coverage separately.

## Existing coverage to retain

Sdkgen already tests generation across targets, actual generated builds and runtime probes, feature corpora, server-variable/live-client wiring, per-SDK control-file preservation, and strictness selection. Apidef has field-fact, GraphQL, QUERY, naming, envelope, and TS/Go parity coverage. These should be extended.

One existing expectation needs an intentional migration: [generate.test.ts](/Users/richard/Projects/voxgig/sdkgen/ts/test/generate.test.ts:1735) explicitly checks that live leniency remains the default, largely through generated-source inspection. Preserving every current assertion would preserve the defect. Keep existing API cases, but replace the false-success expectation with executable behavior tests.

## Proposed implementation sequence

### 1. Define and test the live execution contract

Owner: sdkgen test policy, shared test helpers, TS/JS test components.

- Keep `UNIVEC_TEST_LIVE=TRUE npm test` as the canonical switch. It runs the generated live scenarios, including supported writes. Utility and feature unit tests can remain deterministic and offline in the same invocation.
- Record failures in attempted requests, including bootstrap/discovery, and continue independent operations. Fail the suite after collecting outcomes and attempting supported cleanup. Preserve separate offline mock assertions; live tests must not compare against synthetic IDs or mock call counts.
- Replace the blanket ENTID gate with per-step prerequisites. Parse and validate overrides rather than treating any object string as proof of readiness.
- Report planned, attempted, passed, failed, blocked, and explicitly excluded live operations, with actual method/path and sanitized status. Count prerequisite calls separately from coverage of target operations.
- Required work blocked by missing credentials/data or zero live execution produces a nonzero result. Modelled optional exclusions can be reported as partial coverage, with reasons. If exploratory leniency remains useful, make it explicit and identify the result as exploratory rather than full verification.
- Add regressions that execute the generated suite against a loopback HTTP server, checking its request ledger and process exit code. Include unavailable server, 401, 422, 429, 500, invalid JSON, wrong shapes, and failed list bootstrap. Do not rely only on searching generated source strings.

### 2. Preserve the facts needed to generate valid inputs

Owner: apidef's TS transforms/builders/model, mirrored Go implementation, shared parity fixtures.

- Add versioned model facts for each point's request body/media type, required fields, constraints, examples, response contracts, security alternatives/public access, and source provenance. Retain existing entity fields for compatibility.
- Carry nested types, enums, nullable values, integer/number distinctions, composition, and request/response direction. Keep absence distinct from an explicit empty request contract.
- Preserve operation and point identity through modelling. Diagnose indistinguishable alternatives rather than silently treating the first as complete coverage.
- Extend the supported guide schema for live input hints and semantic relationships that the definition cannot express. Guide corrections feed the model; sdkgen must continue consuming the model rather than parsing OpenAPI itself.
- Test OpenAPI 3 and Swagger 2 representations, GraphQL query/mutation inputs, and QUERY separately. Unknown or illustrative inputs must retain that status rather than becoming claimed live-valid fixtures.

### 3. Generate reusable input recipes and dependent scenarios

Owner: shared test-plan model/planner, create-sdkgen fixture scaffold, sdkgen consumers.

- Separate mock-record generation from request generation; fix integer handling and prohibit request fields absent from the applicable request contract.
- Resolve live inputs from explicit guide recipes, prior-step outputs, capability discovery, and validated example/default candidates. Define deterministic precedence and provenance. Fail preparation when no valid required input can be constructed.
- Model bindings for IDs, parent resources, compound keys, model selections, vectors, and scoped credentials. Detect cycles and unresolved references during preparation.
- Preserve conventional create/list/update/load/remove flows and list-to-load discovery. Add stateless POST, action, credential-issuance, and cross-entity flows.
- Track resources created by the run and perform supported cleanup in a finally phase. Keep existing read-only behavior for discovered external resources unless the project explicitly models a mutation. Report cleanup failures and resources that have no deletion API.
- Retain existing control-file skips, client options, and pacing, but account for their coverage impact. Bound requests, retries, and payload size; avoid automatically replaying non-idempotent writes.

### 4. Use Univec as an end-to-end fixture

Owner: Univec guide/project model and reusable apidef/sdkgen fixtures.

The complete modelled scenario should cover these eight routes:

| Scenario | Input/dependency | Assertion |
| --- | --- | --- |
| `GET /v1/models` | Public request | Parse model catalogue; identify usable embedding models and supported conversion pairs |
| `POST /v1/embed` | Account key resolved from Boru `sdk:univec`; selected model; one short text | One finite numeric vector per input; expected model dimension where available |
| `POST /v1/convert` | Account key; supported pair; actual source-model embedding | Correct output count, target dimension, and source/target identity |
| `POST /v1/embed-bridge` | Account key; supported bridge/target pair; short text | Contract, vector count, and target dimension |
| `POST /v1/ephemeral/key` | Public request with an empty/omitted body | Usable key and correctly typed allowance fields; keep key out of logs |
| `POST /v1/ephemeral/embed` | Issued ephemeral key | Embedding assertions through the ephemeral route |
| `POST /v1/ephemeral/convert` | Issued key and compatible source embedding | Conversion assertions through the ephemeral route |
| `POST /v1/ephemeral/embed-bridge` | Issued key and compatible model pair | Bridge assertions through the ephemeral route |

Public calls should exercise public authentication semantics; account routes use the Boru account credential, and ephemeral routes use the issued credential. The published definition says ephemeral keys are restricted to ephemeral routes. Do not substitute the account key for them.

Use current catalogue capabilities and any necessary guide constraints. If account entitlement, model compatibility, or ephemeral allowance prevents required coverage, report the specific failure/block instead of claiming the whole API passed. Ephemeral key issuance is rate-limited; reuse its result within the run. These routes have no resource-deletion endpoint to invent as cleanup.

The existing `test:live` models smoke check can become a focused scenario selection from this same machinery. It must not be the only route to live execution. Authenticated POST success and the recorded route coverage establish what ran; dashboard changes are corroborating evidence, not a generic test oracle.

### 5. Expand regression coverage and roll out through generation

| Cases retained or added | Required evidence |
| --- | --- |
| Full CRUD, nested parents, singleton, list-only, load-only, create-only, ID-less responses | Correct prerequisites, mutations, identity binding, assertions, and cleanup |
| Renamed/composite IDs, wire-name casing, envelopes, direct arrays, pagination, empty collections | Existing routing/decoding remains correct; an empty valid collection is not automatically an error |
| Required path/query/body values, request examples, integers, enums, nested arrays, read/write-only fields | Generated request satisfies its own operation contract |
| Multiple points, custom actions, server variables, public/account/issued credentials | Actual method, URL, body, and credential role match the selected point |
| GraphQL queries/mutations, QUERY, OpenAPI and Swagger inputs | Model facts survive and generated invocation uses the appropriate protocol |
| Offline mocks, feature and utility corpora, docs examples, SDK return types | Existing deterministic suites remain green |
| HTTP failures, wrong shapes, missing prerequisites, discovery failure, all skipped | Honest exit status and coverage; no successful zero-work live run |

Implement the first executable coverage in TS/JS, then carry the shared semantics through the other supported target renderers and sdkgen-langpack. Retain language-specific build/runtime checks and report unsupported lanes explicitly. Mirror apidef changes in Go before declaring that phase complete.

Update scaffold sources upstream, migrate this SDK's `.sdk` sources with its Boru/customization overlay preserved, and regenerate TS. Run apidef and sdkgen `make all`, the generated offline suite, and the loopback scenario suite. Finally run the canonical `UNIVEC_TEST_LIVE=TRUE` suite with Boru in a passphrase-capable terminal and review its route/operation report. Completion requires the supported Univec POST workflows to execute and failure-path regressions to fail reliably when their server misbehaves.


### Cross-API validation (2026-09-14)

The latest apidef-validate and sdkgen-validate corpora were run against the modified tools. Final results cover 18 TS apidef cases (including three GraphQL schemas), 14 Go REST cases, and 98 generated test suites across 14 APIs and seven languages. Contract-only golden additions were reviewed in an isolated validator copy; all prior entity content remains unchanged.

The corpus exposed recursive-schema, GraphQL memory, Go escaping, runtime-metadata duplication, and PHP example/output-memory problems. Those fixes pass the tool suites and the regenerated SDK checks. The final PHP rerun passes every API, and 21,298 non-PHP source/data/documentation fingerprints remain identical to the passing test run after regeneration with isolated PR tools. Existing corpus skips and PHP no-assertion notices remain; this is offline regression evidence, not live-network acceptance for the other services.

See [the complete corpus verification record](tool-corpus-verification.json) for revisions, commands, per-API results, fixes, and limitations.

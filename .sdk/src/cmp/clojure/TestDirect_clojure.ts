
import {
  Content,
  cmp,
  isAuthActive,
} from '@voxgig/sdkgen'


// Emit per-entity direct()/prepare() checks INTO the shared gentest run body
// (the clojure test runner drives a single sdk.gentest/run). Only entities
// with a read op get a check — matching the py/elixir TestDirect gate — so an
// op-less entity does not fabricate a request path. The checks exercise the
// raw-HTTP escape hatch: prepare() builds a fetchdef without sending, and
// direct() runs a live-mode client against an in-test mock system.fetch.
const TestDirect = cmp(function TestDirect(props: any) {
  const { model } = props.ctx$
  const entity = props.entity

  const opnames = Object.keys(entity.op || {})
  const hasLoad = opnames.includes('load')
  const hasList = opnames.includes('list')
  if (!hasLoad && !hasList) {
    return
  }

  const ename = entity.name
  // A live-mode client must satisfy prepare-auth when auth is active, so pass a
  // dummy apikey; otherwise prepare() (and thus direct()) would throw.
  const apikeyOpt = isAuthActive(model) ? ` "apikey" "test-key"` : ''

  // prepare(): pure request-definition build, no transport.
  Content(`  (t/run-check rec "gen-prepare-${ename}"
    (fn [] (let [client (api/make-sdk (vs/jm "base" "http://example.test"${apikeyOpt}))
                 fetchdef (api/prepare client (vs/jm "path" "/api/${ename}" "method" "GET"))]
             (t/is-true (vs/ismap fetchdef) "prepare returns a fetchdef map")
             (t/is-some (vs/getprop fetchdef "url") "fetchdef carries a url")
             (t/is-eq (vs/getprop fetchdef "method") "GET" "fetchdef preserves the method"))))
`)

  // direct(): live-mode client wired to a recording mock system.fetch. The
  // mock returns a 200 JSON response, so direct() reports ok=true.
  Content(`  (t/run-check rec "gen-direct-${ename}"
    (fn [] (let [fetch (fn [_url _fetchdef]
                         [(vs/jm "status" 200 "statusText" "OK" "headers" (vs/jm)
                                 "json" (fn [] (vs/jm "id" "d1"))) nil])
                 client (api/make-sdk (vs/jm "base" "http://example.test"${apikeyOpt}
                                             "system" (vs/jm "fetch" fetch)))
                 result (api/direct client (vs/jm "path" "/api/${ename}" "method" "GET"))]
             (t/is-true (vs/ismap result) "direct returns a result map")
             (t/is-true (vs/getprop result "ok") "direct 200 => ok true")
             (t/is-eq (vs/getprop result "status") 200 "direct surfaces the status"))))
`)
})


export {
  TestDirect
}

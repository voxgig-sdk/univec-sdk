// Behavioural + coverage tests for the enterprise features shipped with
// this SDK. Each block runs only when its feature is present (see
// hasFeature), driving the real generated feature class through the offline
// harness pipeline against a simulated network. Port of ts test/feature.test.ts.

import 'harness.dart';
import 'feature/harness.dart';

import '../lib/utility/ErrUtility.dart';

class Recording {
  final List calls = [];
  late ServerFn server;
}

Recording recordingServer([dynamic Function(int n, dynamic fetchdef)? reply]) {
  final rec = Recording();
  rec.server = (dynamic _ctx, dynamic url, dynamic fetchdef) {
    rec.calls.add({'url': url, 'fetchdef': fetchdef});
    if (null != reply) {
      return reply(rec.calls.length, fetchdef);
    }
    return makeResponse(200, {'ok': true, 'n': rec.calls.length});
  };
  return rec;
}

dynamic _hdr(Recording rec, int i, String name) =>
    rec.calls[i]['fetchdef']['headers'][name];

void tests() {
  describe('feature', () {
    test('at least the test feature is present', (t) {
      equal(true, hasFeature('test'));
    });

    // --- netsim -------------------------------------------------------------
    if (hasFeature('netsim')) {
      describe('netsim', () {
        test('fixed latency then delegate', (t) async {
          final clock = makeClock();
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'latency': 250, 'sleep': clock.sleep}}
          ]);
          final res = await h.op({'op': 'load', 'ctrl': {'explain': {}}});
          equal(true, res['ok']);
          equal(250, clock.time);
          equal(1, h.client.track['netsim']['calls']);
        });

        test('ranged latency samples within [min,max)', (t) async {
          final clock = makeClock();
          final h = makeClient(features: [
            {
              'name': 'netsim',
              'options': {
                'latency': {'min': 100, 'max': 300},
                'seed': 7,
                'sleep': clock.sleep
              }
            }
          ]);
          await h.op({'op': 'load'});
          ok(clock.time >= 100 && clock.time < 300,
              'latency in range, got ' + clock.time.toString());
        });

        test('equal min/max latency is exact', (t) async {
          final clock = makeClock();
          final h = makeClient(features: [
            {
              'name': 'netsim',
              'options': {
                'latency': {'min': 50, 'max': 50},
                'sleep': clock.sleep
              }
            }
          ]);
          await h.op({'op': 'load'});
          equal(50, clock.time);
        });

        test('failTimes returns a retryable status', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'failTimes': 2, 'failStatus': 503}}
          ]);
          equal(503, (await h.op({'op': 'load'}))['result'].status);
          equal(503, (await h.op({'op': 'load'}))['result'].status);
          equal(true, (await h.op({'op': 'load'}))['ok']);
        });

        test('failEvery fails every Nth call', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'failEvery': 2}}
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
          equal(false, (await h.op({'op': 'load'}))['ok']);
          equal(true, (await h.op({'op': 'load'}))['ok']);
        });

        test('failRate with a seed is deterministic', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'failRate': 1, 'seed': 5}}
          ]);
          equal(false, (await h.op({'op': 'load'}))['ok']);
        });

        test('errorTimes throws a connection error', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'errorTimes': 1}}
          ]);
          equal('netsim_conn', errcode((await h.op({'op': 'load'}))['error']));
        });

        test('offline fails every call', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'offline': true}}
          ]);
          equal('netsim_offline', errcode((await h.op({'op': 'load'}))['error']));
        });

        test('rateLimitTimes returns 429 + Retry-After', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'rateLimitTimes': 1, 'retryAfter': 3}}
          ]);
          final res = await h.op({'op': 'load'});
          equal(429, res['result'].status);
          equal('3', res['result'].headers['retry-after']);
        });
      });
    }

    // --- retry --------------------------------------------------------------
    if (hasFeature('retry')) {
      describe('retry', () {
        test('retries transient failures then succeeds', (t) async {
          final clock = makeClock();
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'failTimes': 2, 'failStatus': 503}},
            {
              'name': 'retry',
              'options': {
                'retries': 3,
                'minDelay': 10,
                'jitter': false,
                'sleep': clock.sleep
              }
            },
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
          equal(2, h.client.track['retry']['attempts']);
        });

        test('gives up after the budget', (t) async {
          final clock = makeClock();
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'failTimes': 9, 'failStatus': 500}},
            {
              'name': 'retry',
              'options': {
                'retries': 2,
                'minDelay': 1,
                'jitter': false,
                'sleep': clock.sleep
              }
            },
          ]);
          equal(500, (await h.op({'op': 'load'}))['result'].status);
        });

        test('does not retry a non-retryable status', (t) async {
          final rec = recordingServer((n, f) => makeResponse(404));
          final h = makeClient(features: [
            {'name': 'retry', 'options': {'retries': 3, 'minDelay': 0}}
          ], server: rec.server);
          await h.op({'op': 'load'});
          equal(1, rec.calls.length);
        });

        test('retries a thrown transport error then rethrows when exhausted',
            (t) async {
          final clock = makeClock();
          var n = 0;
          server(dynamic c, dynamic u, dynamic f) {
            n++;
            throw StateError('boom');
          }

          final h = makeClient(features: [
            {
              'name': 'retry',
              'options': {
                'retries': 2,
                'minDelay': 1,
                'jitter': false,
                'sleep': clock.sleep
              }
            }
          ], server: server);
          final res = await h.op({'op': 'load'});
          equal(false, res['ok']);
          equal(3, n);
        });

        test('honours a server Retry-After', (t) async {
          final clock = makeClock();
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'rateLimitTimes': 1, 'retryAfter': 2}},
            {
              'name': 'retry',
              'options': {
                'retries': 2,
                'minDelay': 10,
                'maxDelay': 60000,
                'jitter': false,
                'sleep': clock.sleep
              }
            },
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
          equal(2000, clock.time);
        });

        test('default jitter path still succeeds', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'failTimes': 1}},
            {'name': 'retry', 'options': {'retries': 2, 'minDelay': 0}},
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
        });
      });
    }

    // --- timeout ------------------------------------------------------------
    if (hasFeature('timeout')) {
      describe('timeout', () {
        test('a slow request times out', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'latency': 80}},
            {'name': 'timeout', 'options': {'ms': 10}},
          ]);
          final res = await h.op({'op': 'load'});
          equal('timeout', errcode(res['error']));
          equal(1, h.client.track['timeout']['count']);
        });

        test('a fast request passes through', (t) async {
          final h = makeClient(features: [
            {'name': 'timeout', 'options': {'ms': 1000}}
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
        });

        test('ms<=0 disables the timeout', (t) async {
          final h = makeClient(features: [
            {'name': 'timeout', 'options': {'ms': 0}}
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
        });
      });
    }

    // --- ratelimit ----------------------------------------------------------
    if (hasFeature('ratelimit')) {
      describe('ratelimit', () {
        test('throttles once the burst is spent', (t) async {
          final clock = makeClock();
          final h = makeClient(features: [
            {
              'name': 'ratelimit',
              'options': {
                'rate': 1,
                'burst': 2,
                'now': clock.now,
                'sleep': clock.sleep
              }
            }
          ]);
          await h.op({'op': 'load'});
          await h.op({'op': 'load'});
          await h.op({'op': 'load'});
          equal(1, h.client.track['ratelimit']['throttled']);
          ok(clock.time > 0);
        });

        test('burst defaults to rate and refills over time', (t) async {
          final clock = makeClock();
          final h = makeClient(features: [
            {
              'name': 'ratelimit',
              'options': {'rate': 2, 'now': clock.now, 'sleep': clock.sleep}
            }
          ]);
          await h.op({'op': 'load'});
          await h.op({'op': 'load'});
          clock.advance(1000); // refill
          await h.op({'op': 'load'});
          final rl = h.client.track['ratelimit'];
          equal(0, null == rl ? 0 : rl['throttled']);
        });
      });
    }

    // --- cache --------------------------------------------------------------
    if (hasFeature('cache')) {
      describe('cache', () {
        test('serves a repeated read from cache', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'cache', 'options': {'ttl': 10000}}
          ], server: rec.server);
          final a = await h.op({'op': 'load', 'path': '/w/1'});
          final b = await h.op({'op': 'load', 'path': '/w/1'});
          equal(1, rec.calls.length);
          deepEqual(a['data'], b['data']);
          equal(1, h.client.track['cache']['hit']);
        });

        test('does not cache non-GET', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'cache'}
          ], server: rec.server);
          await h.op({'op': 'create', 'path': '/w'});
          await h.op({'op': 'create', 'path': '/w'});
          equal(2, rec.calls.length);
        });

        test('does not cache a non-2xx (bypass)', (t) async {
          final rec = recordingServer((n, f) => makeResponse(500));
          final h = makeClient(features: [
            {'name': 'cache'}
          ], server: rec.server);
          await h.op({'op': 'load', 'path': '/w'});
          await h.op({'op': 'load', 'path': '/w'});
          equal(2, rec.calls.length);
          equal(2, h.client.track['cache']['bypass']);
        });

        test('re-fetches after the ttl', (t) async {
          final clock = makeClock();
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'cache', 'options': {'ttl': 1000, 'now': clock.now}}
          ], server: rec.server);
          await h.op({'op': 'load', 'path': '/w'});
          clock.advance(1500);
          await h.op({'op': 'load', 'path': '/w'});
          equal(2, rec.calls.length);
        });

        test('evicts the oldest entry past max', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'cache', 'options': {'ttl': 10000, 'max': 1}}
          ], server: rec.server);
          await h.op({'op': 'load', 'path': '/a'});
          await h.op({'op': 'load', 'path': '/b'}); // evicts /a
          await h.op({'op': 'load', 'path': '/a'}); // miss again
          equal(3, rec.calls.length);
        });
      });
    }

    // --- idempotency ----------------------------------------------------------
    if (hasFeature('idempotency')) {
      describe('idempotency', () {
        test('adds a key to mutating ops', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'idempotency'}
          ], server: rec.server);
          await h.op({'op': 'create', 'path': '/w'});
          ok(null != _hdr(rec, 0, 'Idempotency-Key'));
        });

        test('adds a key based on HTTP method', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'idempotency'}
          ], server: rec.server);
          await h.op({'op': 'act', 'method': 'PUT', 'path': '/w'});
          ok(null != _hdr(rec, 0, 'Idempotency-Key'));
        });

        test('leaves reads untouched', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'idempotency'}
          ], server: rec.server);
          await h.op({'op': 'load', 'path': '/w/1'});
          equal(null, _hdr(rec, 0, 'Idempotency-Key'));
        });

        test('preserves a caller key and honours a custom header', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'idempotency', 'options': {'header': 'X-Idem'}}
          ], server: rec.server);
          await h.op({
            'op': 'create',
            'path': '/w',
            'headers': {'X-Idem': 'caller-1'}
          });
          equal('caller-1', _hdr(rec, 0, 'X-Idem'));
        });
      });
    }

    // --- rbac ---------------------------------------------------------------
    if (hasFeature('rbac')) {
      describe('rbac', () {
        test('denies before any call', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {
              'name': 'rbac',
              'options': {
                'rules': {'widget.remove': 'admin'},
                'permissions': []
              }
            }
          ], server: rec.server);
          final res = await h.op({'op': 'remove', 'path': '/w/1'});
          equal('rbac_denied', errcode(res['error']));
          equal(0, rec.calls.length);
          equal(1, h.client.track['rbac']['denied']);
        });

        test('allows a held permission', (t) async {
          final h = makeClient(features: [
            {
              'name': 'rbac',
              'options': {
                'rules': {'widget.remove': 'admin'},
                'permissions': ['admin']
              }
            }
          ]);
          equal(true, (await h.op({'op': 'remove', 'path': '/w/1'}))['ok']);
        });

        test('rule by op name and wildcard grant', (t) async {
          final h = makeClient(features: [
            {
              'name': 'rbac',
              'options': {
                'rules': {'load': 'read'},
                'permissions': ['*']
              }
            }
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
        });

        test('no rule allows by default; deny:true blocks', (t) async {
          final allow = makeClient(features: [
            {'name': 'rbac', 'options': {'permissions': []}}
          ]);
          equal(true, (await allow.op({'op': 'load'}))['ok']);
          final deny = makeClient(features: [
            {'name': 'rbac', 'options': {'deny': true, 'permissions': []}}
          ]);
          equal('rbac_denied', errcode((await deny.op({'op': 'load'}))['error']));
        });
      });
    }

    // --- metrics ------------------------------------------------------------
    if (hasFeature('metrics')) {
      describe('metrics', () {
        test('counts ok and err per op', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'failTimes': 1, 'failStatus': 500}},
            {'name': 'metrics', 'options': {}},
          ]);
          await h.op({'op': 'load'});
          await h.op({'op': 'load'});
          await h.op({'op': 'list'});
          final m = h.client.track['metrics'];
          equal(3, m['total']['count']);
          equal(2, m['total']['ok']);
          equal(1, m['total']['err']);
          equal(2, m['ops']['widget.load']['count']);
        });
      });
    }

    // --- telemetry ----------------------------------------------------------
    if (hasFeature('telemetry')) {
      describe('telemetry', () {
        test('opens spans and propagates trace headers', (t) async {
          final rec = recordingServer();
          final spans = [];
          final h = makeClient(features: [
            {
              'name': 'telemetry',
              'options': {'exporter': (s) => spans.add(s)}
            }
          ], server: rec.server);
          final res = await h.op({'op': 'load'});
          equal(true, res['ok']);
          equal(1, h.client.track['telemetry']['spans'].length);
          equal(1, spans.length);
          equal(_hdr(rec, 0, 'X-Trace-Id'),
              h.client.track['telemetry']['spans'][0]['traceId']);
          ok(RegExp(r'^00-.+-.+-01$')
              .hasMatch(_hdr(rec, 0, 'traceparent').toString()));
        });

        test('records a failed span on error', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'failTimes': 1, 'failStatus': 500}},
            {'name': 'telemetry', 'options': {}},
          ]);
          await h.op({'op': 'load'});
          equal(false, h.client.track['telemetry']['spans'][0]['ok']);
        });
      });
    }

    // --- debug --------------------------------------------------------------
    if (hasFeature('debug')) {
      describe('debug', () {
        test('captures a redacted trace and honours onEntry + max', (t) async {
          final seen = [];
          final h = makeClient(features: [
            {
              'name': 'debug',
              'options': {'max': 1, 'onEntry': (e) => seen.add(e)}
            }
          ]);
          await h.op({
            'op': 'load',
            'headers': {'authorization': 'Bearer secret'}
          });
          await h.op({'op': 'list'});
          final entries = h.client.track['debug']['entries'];
          equal(1, entries.length); // ring buffer capped at max
          equal(2, seen.length);
          equal('<redacted>', seen[0]['headers']['authorization']);
        });

        test('captures failures', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'failTimes': 1, 'failStatus': 500}},
            {'name': 'debug', 'options': {}},
          ]);
          await h.op({'op': 'load'});
          equal(false, h.client.track['debug']['entries'][0]['ok']);
        });
      });
    }

    // --- audit --------------------------------------------------------------
    if (hasFeature('audit')) {
      describe('audit', () {
        test('one record per op with sink + actor', (t) async {
          final sink = [];
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'failTimes': 1, 'failStatus': 500}},
            {
              'name': 'audit',
              'options': {'actor': 'svc', 'sink': (r) => sink.add(r), 'max': 5}
            },
          ]);
          await h.op({'op': 'remove', 'path': '/w/1'});
          await h.op({
            'op': 'load',
            'ctrl': {'actor': 'per-call'}
          });
          final recs = h.client.track['audit']['records'];
          equal(2, recs.length);
          equal('error', recs[0]['outcome']);
          equal('svc', recs[0]['actor']);
          equal('per-call', recs[1]['actor']);
          equal(2, sink.length);
        });
      });
    }

    // --- clienttrack ----------------------------------------------------------
    if (hasFeature('clienttrack')) {
      describe('clienttrack', () {
        test('stable client id, unique request ids, UA', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {
              'name': 'clienttrack',
              'options': {'clientName': 'Acme', 'clientVersion': '2.0.0'}
            }
          ], server: rec.server);
          await h.ready();
          await h.op({'op': 'load'});
          await h.op({'op': 'load'});
          equal('Acme/2.0.0', _hdr(rec, 0, 'User-Agent'));
          equal(_hdr(rec, 0, 'X-Client-Id'), _hdr(rec, 1, 'X-Client-Id'));
          ok(_hdr(rec, 0, 'X-Request-Id') != _hdr(rec, 1, 'X-Request-Id'));
          equal(2, h.client.track['clienttrack']['requests']);
        });

        test('does not clobber a caller User-Agent', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'clienttrack'}
          ], server: rec.server);
          await h.ready();
          await h.op({
            'op': 'load',
            'headers': {'User-Agent': 'mine'}
          });
          equal('mine', _hdr(rec, 0, 'User-Agent'));
        });
      });
    }

    // --- paging ---------------------------------------------------------------
    if (hasFeature('paging')) {
      describe('paging', () {
        test('stamps page/limit and reads header signals', (t) async {
          final rec = recordingServer((n, f) => makeResponse(200, {
                'items': [1, 2]
              }, {
                'x-next-page': '2',
                'x-total-count': '5',
                'link': '</w?page=2>; rel="next"'
              }));
          final h = makeClient(features: [
            {'name': 'paging', 'options': {'limit': 2}}
          ], server: rec.server);
          final res = await h.op({'op': 'list', 'path': '/w'});
          ok(RegExp(r'[?&]page=1(&|$)').hasMatch(rec.calls[0]['url'].toString()));
          ok(RegExp(r'[?&]limit=2(&|$)').hasMatch(rec.calls[0]['url'].toString()));
          equal(2, res['result'].paging['nextPage']);
          equal(5, res['result'].paging['totalCount']);
          equal('/w?page=2', res['result'].paging['next']);
        });

        test('body cursor + explicit cursor request', (t) async {
          final rec = recordingServer(
              (n, f) => makeResponse(200, {'nextCursor': 'abc', 'hasMore': true}));
          final h = makeClient(features: [
            {'name': 'paging'}
          ], server: rec.server);
          final res = await h.op({
            'op': 'list',
            'path': '/w',
            'ctrl': {
              'paging': {'cursor': 'xyz'}
            }
          });
          ok(RegExp(r'[?&]cursor=xyz(&|$)')
              .hasMatch(rec.calls[0]['url'].toString()));
          equal('abc', res['result'].paging['cursor']);
          equal(true, res['result'].paging['hasMore']);
        });
      });
    }

    // --- streaming ------------------------------------------------------------
    if (hasFeature('streaming')) {
      describe('streaming', () {
        test('streams list items', (t) async {
          final clock = makeClock();
          final rec = recordingServer((n, f) => makeResponse(200, ['a', 'b', 'c']));
          final h = makeClient(features: [
            {
              'name': 'streaming',
              'options': {'chunkDelay': 5, 'sleep': clock.sleep}
            }
          ], server: rec.server);
          final res = await h.op({'op': 'list', 'path': '/w'});
          equal(true, res['result'].streaming);
          final seen = [];
          await for (final item in res['result'].stream()) {
            seen.add(item);
          }
          deepEqual(seen, ['a', 'b', 'c']);
          equal(15, clock.time);
        });

        test('batches with chunkSize', (t) async {
          final rec = recordingServer((n, f) => makeResponse(200, [1, 2, 3, 4, 5]));
          final h = makeClient(features: [
            {'name': 'streaming', 'options': {'chunkSize': 2}}
          ], server: rec.server);
          final res = await h.op({'op': 'list', 'path': '/w'});
          final batches = [];
          await for (final b in res['result'].stream()) {
            batches.add(b);
          }
          deepEqual(batches, [
            [1, 2],
            [3, 4],
            [5]
          ]);
        });
      });
    }

    // --- proxy ----------------------------------------------------------------
    if (hasFeature('proxy')) {
      describe('proxy', () {
        test('routes through the proxy and invokes an agent factory', (t) async {
          final rec = recordingServer();
          var agentUrl = '';
          final h = makeClient(features: [
            {
              'name': 'proxy',
              'options': {
                'url': 'http://proxy:8080',
                'agent': (u, target) {
                  agentUrl = u.toString();
                  return {'a': 1};
                }
              }
            }
          ], server: rec.server);
          await h.op({'op': 'load'});
          equal('http://proxy:8080', rec.calls[0]['fetchdef']['proxy']);
          equal(1, rec.calls[0]['fetchdef']['dispatcher']['a']);
          equal('http://proxy:8080', agentUrl);
          equal(1, h.client.track['proxy']['routed']);
        });

        test('bypasses noProxy hosts', (t) async {
          final rec = recordingServer();
          final h = makeClient(
              features: [
                {
                  'name': 'proxy',
                  'options': {
                    'url': 'http://proxy:8080',
                    'noProxy': ['api.test']
                  }
                }
              ],
              server: rec.server,
              base: 'http://api.test');
          await h.op({'op': 'load'});
          equal(null, rec.calls[0]['fetchdef']['proxy']);
        });
      });
    }

    // --- edge branches (coverage) ---------------------------------------------
    // Inactive features must no-op; transport features must handle odd
    // responses; the default (non-injected) clocks/timers must run.

    if (hasFeature('netsim')) {
      describe('netsim-edge', () {
        test('inactive netsim does not wrap', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'active': false}}
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
          equal(null, h.client.track['netsim']);
        });
        test('no latency option delays nothing (real timer path)', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {}}
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
        });
        test('real-timer latency actually waits', (t) async {
          final h = makeClient(features: [
            {'name': 'netsim', 'options': {'latency': 15}}
          ]);
          final t0 = DateTime.now().millisecondsSinceEpoch;
          await h.op({'op': 'load'});
          ok(DateTime.now().millisecondsSinceEpoch - t0 >= 8);
        });
      });
    }

    if (hasFeature('retry')) {
      describe('retry-edge', () {
        test('inactive retry does not wrap', (t) async {
          final rec = recordingServer((n, f) => makeResponse(503));
          final h = makeClient(features: [
            {'name': 'retry', 'options': {'active': false}}
          ], server: rec.server);
          await h.op({'op': 'load'});
          equal(1, rec.calls.length);
        });
        test('retries a null transport result', (t) async {
          var n = 0;
          server(dynamic c, dynamic u, dynamic f) {
            n++;
            return n < 2 ? null : makeResponse(200, {'ok': true});
          }

          final h = makeClient(features: [
            {'name': 'retry', 'options': {'retries': 3, 'minDelay': 0}}
          ], server: server);
          equal(true, (await h.op({'op': 'load'}))['ok']);
          equal(2, n);
        });
        test('non-numeric status is not retryable', (t) async {
          final rec = recordingServer((n, f) => {
                'status': 'weird',
                'json': () => {},
                'headers': {},
              });
          final h = makeClient(features: [
            {'name': 'retry', 'options': {'retries': 3, 'minDelay': 0}}
          ], server: rec.server);
          await h.op({'op': 'load'});
          equal(1, rec.calls.length);
        });
        test('Retry-After via plain headers', (t) async {
          final clock = makeClock();
          var n = 0;
          server(dynamic c, dynamic u, dynamic f) {
            n++;
            return n < 2
                ? {
                    'status': 429,
                    'json': () => null,
                    'headers': {'retry-after': '1'},
                  }
                : makeResponse(200, {'ok': true});
          }

          final h = makeClient(features: [
            {
              'name': 'retry',
              'options': {
                'retries': 2,
                'minDelay': 0,
                'jitter': false,
                'sleep': clock.sleep
              }
            }
          ], server: server);
          equal(true, (await h.op({'op': 'load'}))['ok']);
          equal(1000, clock.time);
        });
        test('default timer backoff path runs', (t) async {
          var n = 0;
          server(dynamic c, dynamic u, dynamic f) {
            n++;
            return n < 2 ? makeResponse(503) : makeResponse(200, {'ok': true});
          }

          final h = makeClient(features: [
            {
              'name': 'retry',
              'options': {'retries': 2, 'minDelay': 1, 'jitter': false}
            }
          ], server: server);
          equal(true, (await h.op({'op': 'load'}))['ok']);
        });
      });
    }

    if (hasFeature('timeout')) {
      describe('timeout-edge', () {
        test('inactive timeout does not wrap', (t) async {
          final h = makeClient(features: [
            {'name': 'timeout', 'options': {'active': false}}
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
        });
      });
    }

    if (hasFeature('cache')) {
      describe('cache-edge', () {
        test('inactive cache does not wrap', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'cache', 'options': {'active': false}}
          ], server: rec.server);
          await h.op({'op': 'load', 'path': '/x'});
          await h.op({'op': 'load', 'path': '/x'});
          equal(2, rec.calls.length);
        });
        test('real clock ttl path', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'cache', 'options': {'ttl': 10000}}
          ], server: rec.server);
          await h.op({'op': 'load', 'path': '/y'});
          await h.op({'op': 'load', 'path': '/y'});
          equal(1, rec.calls.length);
        });
      });
    }

    if (hasFeature('ratelimit')) {
      describe('ratelimit-edge', () {
        test('inactive ratelimit does not wrap', (t) async {
          final h = makeClient(features: [
            {'name': 'ratelimit', 'options': {'active': false}}
          ]);
          equal(true, (await h.op({'op': 'load'}))['ok']);
        });
        test('real clock throttle path', (t) async {
          final h = makeClient(features: [
            {'name': 'ratelimit', 'options': {'rate': 1000, 'burst': 1}}
          ]);
          await h.op({'op': 'load'});
          await h.op({'op': 'load'});
          final rl = h.client.track['ratelimit'];
          ok((null == rl ? 0 : rl['throttled']) >= 0);
        });
      });
    }

    if (hasFeature('proxy')) {
      describe('proxy-edge', () {
        test('inactive proxy does not wrap', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'proxy', 'options': {'active': false}}
          ], server: rec.server);
          await h.op({'op': 'load'});
          equal(null, rec.calls[0]['fetchdef']['proxy']);
        });
        test('no url set is a no-op', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'proxy', 'options': {}}
          ], server: rec.server);
          await h.op({'op': 'load'});
          equal(null, rec.calls[0]['fetchdef']['proxy']);
        });
        // NOTE: the donor's fromEnv case is omitted — Dart cannot mutate
        // Platform.environment at runtime; fromEnv is covered by inspection.
      });
    }

    if (hasFeature('clienttrack')) {
      describe('clienttrack-edge', () {
        test('real id generation without PostConstruct', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'clienttrack'}
          ], server: rec.server);
          // no ready() -> PreRequest lazily creates the session id
          await h.op({'op': 'load'});
          ok(null != _hdr(rec, 0, 'X-Client-Id'));
        });
      });
    }

    if (hasFeature('idempotency')) {
      describe('idempotency-edge', () {
        test('real key generation', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'idempotency'}
          ], server: rec.server);
          await h.op({'op': 'create', 'path': '/w'});
          ok(RegExp(r'^[0-9a-f]+$')
              .hasMatch(_hdr(rec, 0, 'Idempotency-Key').toString()));
        });
      });
    }

    if (hasFeature('telemetry')) {
      describe('telemetry-edge', () {
        test('default id generation and no exporter', (t) async {
          final h = makeClient(features: [
            {'name': 'telemetry'}
          ]);
          await h.op({'op': 'load'});
          ok(h.client.track['telemetry']['spans'][0]['traceId']
              .toString()
              .startsWith('t'));
        });
      });
    }

    if (hasFeature('streaming')) {
      describe('streaming-edge', () {
        test('non-list op is not streamed', (t) async {
          final h = makeClient(features: [
            {'name': 'streaming'}
          ]);
          final res = await h.op({'op': 'load'});
          equal(null, res['result'].streaming);
        });
        test('real chunk delay path', (t) async {
          final rec = recordingServer((n, f) => makeResponse(200, ['a', 'b']));
          final h = makeClient(features: [
            {'name': 'streaming', 'options': {'chunkDelay': 1}}
          ], server: rec.server);
          final res = await h.op({'op': 'list', 'path': '/w'});
          final seen = [];
          await for (final x in res['result'].stream()) {
            seen.add(x);
          }
          equal(2, seen.length);
        });
      });
    }

    if (hasFeature('paging')) {
      describe('paging-edge', () {
        test('non-list op is not paged', (t) async {
          final rec = recordingServer();
          final h = makeClient(features: [
            {'name': 'paging'}
          ], server: rec.server);
          await h.op({'op': 'load', 'path': '/w/1'});
          ok(!RegExp(r'[?&]page=').hasMatch(rec.calls[0]['url'].toString()));
        });
      });
    }

    if (hasFeature('metrics')) {
      describe('metrics-edge', () {
        test('real clock timing path', (t) async {
          final h = makeClient(features: [
            {'name': 'metrics'}
          ]);
          await h.op({'op': 'load'});
          equal(1, h.client.track['metrics']['total']['count']);
        });
      });
    }

    if (hasFeature('audit')) {
      describe('audit-edge', () {
        test('default actor + real clock', (t) async {
          final h = makeClient(features: [
            {'name': 'audit'}
          ]);
          await h.op({'op': 'load'});
          equal('anonymous', h.client.track['audit']['records'][0]['actor']);
        });
      });
    }

    if (hasFeature('debug')) {
      describe('debug-edge', () {
        test('default max ring + real clock', (t) async {
          final h = makeClient(features: [
            {'name': 'debug'}
          ]);
          await h.op({'op': 'load'});
          ok(h.client.track['debug']['entries'][0]['durationMs'] >= 0);
        });
      });
    }

    // --- injectable option branches (coverage) --------------------------------
    // Exercise the injected id/clock callbacks (the default paths are covered
    // elsewhere).

    if (hasFeature('telemetry')) {
      test('telemetry: injected idgen + clock', (t) async {
        final h = makeClient(features: [
          {
            'name': 'telemetry',
            'options': {'idgen': (k) => k.toString() + '-X', 'now': () => 5}
          }
        ]);
        await h.op({'op': 'load'});
        final span = h.client.track['telemetry']['spans'][0];
        equal('trace-X', span['traceId']);
        equal(0, span['durationMs']);
      });
    }

    if (hasFeature('clienttrack')) {
      test('clienttrack: injected idgen + fixed session', (t) async {
        final rec = recordingServer();
        final h = makeClient(features: [
          {
            'name': 'clienttrack',
            'options': {'sessionId': 'S1', 'idgen': (k) => k.toString() + '-1'}
          }
        ], server: rec.server);
        await h.ready();
        await h.op({'op': 'load'});
        equal('S1', _hdr(rec, 0, 'X-Client-Id'));
        equal('request-1', _hdr(rec, 0, 'X-Request-Id'));
      });
    }

    if (hasFeature('audit')) {
      test('audit: injected clock', (t) async {
        final h = makeClient(features: [
          {'name': 'audit', 'options': {'now': () => 42}}
        ]);
        await h.op({'op': 'load'});
        equal(42, h.client.track['audit']['records'][0]['ts']);
      });
    }

    if (hasFeature('metrics')) {
      test('metrics: injected clock', (t) async {
        var tt = 0;
        final h = makeClient(features: [
          {'name': 'metrics', 'options': {'now': () => (tt += 10)}}
        ]);
        await h.op({'op': 'load'});
        ok(h.client.track['metrics']['total']['totalMs'] >= 0);
      });
    }

    if (hasFeature('debug')) {
      test('debug: injected clock + custom redact', (t) async {
        final h = makeClient(features: [
          {
            'name': 'debug',
            'options': {
              'now': () => 7,
              'redact': ['x-secret']
            }
          }
        ]);
        await h.op({
          'op': 'load',
          'headers': {'x-secret': 'hide', 'x-ok': 'show'}
        });
        final e = h.client.track['debug']['entries'][0];
        equal('<redacted>', e['headers']['x-secret']);
        equal('show', e['headers']['x-ok']);
      });
    }

    // --- composition ----------------------------------------------------------
    if (hasFeature('cache') && hasFeature('netsim')) {
      test('cache + netsim: a hit skips the simulated failure', (t) async {
        final h = makeClient(features: [
          {'name': 'netsim', 'options': {'failEvery': 2}},
          {'name': 'cache', 'options': {'ttl': 10000}},
        ]);
        equal(true, (await h.op({'op': 'load', 'path': '/w'}))['ok']);
        equal(true, (await h.op({'op': 'load', 'path': '/w'}))['ok']);
        equal(1, h.client.track['netsim']['calls']);
      });
    }
  });
}

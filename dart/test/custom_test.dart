// Custom utility injection. Port of ts test/utility/Custom.test.ts: user
// options.utility entries become reachable through the client's utility
// (via byName, Dart's analogue of dynamic property access).

import 'harness.dart';

import '../lib/UnivecSDK.dart';

void tests() {
  describe('Custom', () {
    test('basic', (t) async {
      final client = UnivecSDK.test({}, {
        'apikey': 'APIKEY01',

        // NOTE: original utility members must remain in place.
        'utility': {
          'auth': () => {'util': 'AUTH'},
          'body': () => {'util': 'BODY'},
          'contextify': () => {'util': 'CONTEXTIFY'},
          'findparam': () => {'util': 'FINDPARAM'},
          'fullurl': () => {'util': 'FULLURL'},
          'headers': () => {'util': 'HEADERS'},
          'method': () => {'util': 'METHOD'},
          'operator': () => {'util': 'OPERATOR'},
          'params': () => {'util': 'PARAMS'},
          'query': () => {'util': 'QUERY'},
          'reqform': () => {'util': 'REQFORM'},
          'request': () => {'util': 'REQUEST'},
          'resbasic': () => {'util': 'RESBASIC'},
          'resbody': () => {'util': 'RESBODY'},
          'resform': () => {'util': 'RESFORM'},
          'resheaders': () => {'util': 'RESHEADERS'},
          'response': () => {'util': 'RESPONSE'},
          'result': () => {'util': 'RESULT'},
          'spec': () => {'util': 'SPEC'},
        }
      });

      final u = client.utility();

      equal('AUTH', u.byName('auth')()['util']);
      equal('BODY', u.byName('body')()['util']);
      equal('CONTEXTIFY', u.byName('contextify')()['util']);
      equal('FINDPARAM', u.byName('findparam')()['util']);
      equal('FULLURL', u.byName('fullurl')()['util']);
      equal('HEADERS', u.byName('headers')()['util']);
      equal('METHOD', u.byName('method')()['util']);
      equal('OPERATOR', u.byName('operator')()['util']);
      equal('PARAMS', u.byName('params')()['util']);
      equal('QUERY', u.byName('query')()['util']);
      equal('REQFORM', u.byName('reqform')()['util']);
      equal('RESBASIC', u.byName('resbasic')()['util']);
      equal('RESBODY', u.byName('resbody')()['util']);
      equal('RESFORM', u.byName('resform')()['util']);
      equal('RESHEADERS', u.byName('resheaders')()['util']);
      equal('RESPONSE', u.byName('response')()['util']);
      equal('RESULT', u.byName('result')()['util']);
      equal('SPEC', u.byName('spec')()['util']);

      // Standard members are untouched.
      ok(null != u.byName('makeSpec'));
      ok(null != u.byName('fetcher'));
    });
  });
}

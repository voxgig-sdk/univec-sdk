import 'utility/voxgig_struct.dart' as vs;

class Spec {
  dynamic parts;
  dynamic headers;
  dynamic alias;
  dynamic base;
  dynamic prefix;
  dynamic suffix;
  dynamic params;
  dynamic query;
  dynamic step;
  dynamic method;
  dynamic body;
  dynamic url;
  dynamic path;

  Spec(dynamic specmap) {
    parts = vs.getprop(specmap, 'parts', []);
    headers = vs.getprop(specmap, 'headers', {});
    alias = vs.getprop(specmap, 'alias', {});
    base = vs.getprop(specmap, 'base', '');
    prefix = vs.getprop(specmap, 'prefix', '');
    suffix = vs.getprop(specmap, 'suffix', '');
    params = vs.getprop(specmap, 'params', {});
    query = vs.getprop(specmap, 'query', {});
    step = vs.getprop(specmap, 'step', '');
    method = vs.getprop(specmap, 'method', 'GET');
    body = vs.getprop(specmap, 'body');
    url = vs.getprop(specmap, 'url');
    path = vs.getprop(specmap, 'path');
  }

  Map<String, dynamic> toJSON() => {
        'parts': parts,
        'headers': headers,
        'alias': alias,
        'base': base,
        'prefix': prefix,
        'suffix': suffix,
        'params': params,
        'query': query,
        'step': step,
        'method': method,
        'body': body,
        'url': url,
        'path': path,
      };
}

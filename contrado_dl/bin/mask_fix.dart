import 'dart:convert';
import 'dart:io';

import 'package:contrado_dl/common.dart';

void main() {
  var jsContents = File('input.js').readAsStringSync();
  var inputJsParams = jsonDecode(
      RegExp(r'(\{[\S\s]+})\);', multiLine: true).firstMatch(jsContents)![1]!);
  var reqBody = inputJsParams['body'] as String;

  final decoded = Uri.splitQueryString(reqBody);
  final productDesign = jsonDecode(decoded['productDesign']!);

  print(pretty.convert(productDesign));

  for (var i = 0; i < productDesign['fields'].length; i++) {
    final maskx = productDesign['fields'][i]['editablefield']['mask']['x0']
        .toDouble() as double;
    final masky = productDesign['fields'][i]['editablefield']['mask']['y0']
        .toDouble() as double;
    final maskw = productDesign['fields'][i]['editablefield']['mask']['width']
        .toDouble() as double;
    final maskh = productDesign['fields'][i]['editablefield']['mask']['height']
        .toDouble() as double;

    final framew = (productDesign['PreviewSize'] as num).toDouble();

    final y = -masky / maskh;
    final scalex = framew / maskw;
    final scaley = framew / maskh;
    final x = -maskx / maskw;

    print('[$i].x = $x');
    print('[$i].y = $y');
    print('[$i].width = $scalex');
    print('[$i].height = $scaley');

    if (productDesign['fields'][i]['editablefield']['designobjects'].length >
        0) {
      productDesign['fields'][i]['editablefield']['designobjects'][0]['x'] = x;
      productDesign['fields'][i]['editablefield']['designobjects'][0]['y'] = y;
      productDesign['fields'][i]['editablefield']['designobjects'][0]['width'] =
          scalex;
      productDesign['fields'][i]['editablefield']['designobjects'][0]
          ['height'] = scaley;
    }
  }

  final query = Uri(queryParameters: {
    ...decoded,
    'productDesign': jsonEncode(productDesign),
  }).query;

  jsContents = jsContents.replaceFirst(
    RegExp(r'"body": ".*"'),
    '"body": "$query"',
  );

  File('output.js').writeAsStringSync(jsContents);
}

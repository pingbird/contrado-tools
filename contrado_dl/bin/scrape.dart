import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:contrado_dl/common.dart';
import 'package:contrado_dl/http.dart';
import 'package:html/parser.dart' as h;
import 'package:puppeteer/protocol/fetch.dart';
import 'package:puppeteer/protocol/network.dart' as net;
import 'package:puppeteer/puppeteer.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:uuid/uuid.dart';

final linksFile = cacheDir.childFile('links.txt');
final productsDir = cacheDir.childDirectory('products');

final defaultHeaders = {
  'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36',
};

final chromeExecutable =
    r'C:\Program Files\Google\Chrome\Application\chrome.exe';

void main() async {
  Chain.capture(run);
}

void run() async {
  final links = <Uri>{};

  Future<void> visit(Uri uri) async {
    if (uri.hasQuery) {
      uri = uri.replace(queryParameters: {});
      final str = '$uri';
      if (str.endsWith('?')) {
        uri = Uri.parse(str.substring(0, str.length - 1));
      }
      assert(!uri.hasQuery);
    }
    if (!uri.isScheme('https')) return;
    if (uri.authority != 'www.contrado.com') return;
    if (uri.pathSegments.isNotEmpty && uri.pathSegments.last.contains('.')) {
      return;
    }
    if (uri.pathSegments.contains('blog')) return;
    if (uri.hasFragment) {
      uri = uri.removeFragment();
    }
    if ('$uri'.contains('#')) return;
    if (links.contains(uri)) return;
    links.add(uri);
    final response = await client.get(uri, headers: defaultHeaders);
    if (response.statusCode != 200) {
      print('Failed to visit $uri: ${response.statusCode}');
      return;
    }
    final mime = response.headers['content-type'];
    if (mime == null) {
      print('Failed to visit $uri: no mime');
      return;
    } else if (!mime.startsWith('text/html')) {
      print('Failed to visit $uri: bad mime $mime');
      return;
    }
    final html = h.parse(response.body);
    for (final anchor in html.querySelectorAll('a')) {
      final href = anchor.attributes['href'];
      if (href == null) continue;
      final link = uri.resolve(href);
      await visit(link);
    }
  }

  if (linksFile.existsSync()) {
    for (final line in await linksFile.readAsLines()) {
      links.add(Uri.parse(line));
    }
  } else {
    await visit(Uri.parse('https://www.contrado.com/'));

    if (!linksFile.parent.existsSync()) {
      linksFile.parent.createSync(recursive: true);
    }
    await linksFile.writeAsString(links.map((e) => '$e\n').join());
  }

  final productIds = <int>[
    for (final link in links)
      if (link.path.startsWith('/estore/startdesign/'))
        int.parse(link.pathSegments.last),
  ];

  productIds.sort();

  print('productIds: $productIds');

  if (!productsDir.existsSync()) {
    productsDir.createSync(recursive: true);
  }

  print('Connecting...');
  final browser = await puppeteer.launch(
    executablePath: chromeExecutable,
  );
  print('Connected');
  final page = await browser.newPage();

  Future<void> waitNetworkIdle() async {
    final completer = Completer<void>();
    var timer = Timer(Duration(seconds: 5), completer.complete);
    void onTick() {
      if (completer.isCompleted) return;
      completer.complete();
    }

    final sub1 = page.devTools.network.onRequestWillBeSent.listen((event) {
      timer.cancel();
      timer = Timer(Duration(seconds: 2), onTick);
    });

    final sub2 = page.devTools.network.onResponseReceived.listen((event) {
      timer.cancel();
      timer = Timer(Duration(seconds: 2), onTick);
    });

    await completer.future;

    sub1.cancel();
    sub2.cancel();
  }

  Future<String?> fetch(String url) async {
    return await page.evaluate(
        "async x => { let res = await fetch(x); return res.text() }",
        args: [url]).onError((error, stackTrace) => null);
  }

  print('Got page');

  await page.devTools.network.enable();
  await page.devTools.fetch.enable(patterns: [
    RequestPattern(urlPattern: '*://www.google-analytics.com/*'),
    RequestPattern(urlPattern: '*://www.gstatic.com/*'),
    RequestPattern(urlPattern: '*://bat.bing.com/*'),
    RequestPattern(urlPattern: '*://s.clarity.ms/*'),
    RequestPattern(urlPattern: '*://www.facebook.com/*'),
    RequestPattern(urlPattern: '*://*/*', resourceType: ResourceType.image),
    RequestPattern(urlPattern: '*://*/*', resourceType: ResourceType.font),
    RequestPattern(urlPattern: '*://*/*', resourceType: ResourceType.media),
    RequestPattern(
      urlPattern: '*://*/*',
      resourceType: ResourceType.stylesheet,
    ),
  ]);
  page.devTools.fetch.onRequestPaused.listen((event) {
    page.devTools.fetch.failRequest(
      event.requestId,
      ErrorReason.blockedByClient,
    );
  });
  final pageRequests = <String, net.RequestData>{};
  final pageResponses = <String, net.ResponseData>{};
  page.devTools.network.onRequestWillBeSent.listen((event) {
    print('req: ${event.request.url}');
    pageRequests[event.requestId.value] = event.request;
  });
  page.devTools.network.onResponseReceived.listen((event) async {
    print('res: ${event.response.url}');
    pageResponses[event.requestId.value] = event.response;
  });
  Future<List<Uint8List>> getResponses(String prefix) async {
    final result = <Uint8List>[];
    for (final entry in pageResponses.entries.toList().reversed) {
      if (!entry.value.url.startsWith(prefix)) continue;
      if (entry.value.status ~/ 100 != 2) {
        throw 'Bad status: ${entry.value.url} ${entry.value.status}';
      }
      final response = await page.devTools.network.getResponseBody(
        net.RequestId(entry.key),
      );
      if (response.base64Encoded) {
        result.add(base64.decode(response.body));
      } else {
        result.add(utf8.encode(response.body));
      }
    }
    return result;
  }

  for (final id in productIds) {
    final productFolder = productsDir.childDirectory('$id');
    if (productFolder.existsSync()) continue;
    final tmpFolder = productsDir.childDirectory('${id}_tmp');
    if (tmpFolder.existsSync()) {
      tmpFolder.deleteSync(recursive: true);
    }
    if (!tmpFolder.existsSync()) {
      tmpFolder.createSync(recursive: true);
    }
    print('id: $id');
    final tid = Uuid().v4();

    await page.devTools.network.disable();
    await page.devTools.network.enable();
    pageRequests.clear();
    pageResponses.clear();

    print('Goto https://www.contrado.com/estore/design/$id?tid=$tid');
    await page.goto(
      'https://www.contrado.com/estore/design/$id?tid=$tid',
      wait: Until.networkIdle,
    );
    print('Loaded');

    final optionsFile = tmpFolder.childFile('options.html');
    final modelConfigFile = tmpFolder.childFile('model_config.json');

    final optionsResponses = await getResponses(
        'https://www.contrado.com/estore/productoption/getproductoptions');
    if (optionsResponses.isEmpty) {
      final pageContent = await page.content;
      if (pageContent!.contains('Product Discontinued')) {
        print('Product $id no longer available');
        tmpFolder.renameSync(productFolder.path);
        continue;
      } else if (pageContent.contains(
          '<span id="faceliftBtnFinalPreview">Add to Basket</span>')) {
        print('Product $id has no variations');
        tmpFolder.renameSync(productFolder.path);
        continue;
      }
    }
    optionsFile.writeAsBytesSync(optionsResponses.single);

    final modelConfigResponse = await fetch(
      'https://www.contrado.com/estore/optimizedcontrado3d/getproduct3dconfiguration?productId=$id',
    );
    if (modelConfigResponse != null) {
      dynamic modelConfig;
      try {
        modelConfig = json.decode(modelConfigResponse);
        modelConfigFile.writeAsStringSync(pretty.convert(modelConfig));
      } catch (e, bt) {
        stderr.writeln(
            'Failed to parse $id model config: $e\n$bt\nResponse:\n$modelConfigResponse');
        continue;
      }

      final optionsDocument = h.parse(utf8.decode(optionsResponses.single));
      final options = <String, Set<String>>{};
      final optionNames = <String, String>{};
      final optionValueTitles = <String, String>{};
      final optionIds = <String, String>{};
      final optionValueIds = <String, String>{};
      final optionSelected = <String, String>{};
      final optionKind = <String, String>{};
      for (final optionDiv
          in optionsDocument.querySelectorAll('div[data-opt-id]')) {
        if (!optionDiv.attributes.containsKey('id')) continue;
        if (optionDiv.attributes['data-preview-affected']?.toLowerCase() !=
            'true') continue;
        if (optionDiv.classes.contains('Hidden')) continue;
        print('attrs: ${optionDiv.attributes}');
        final optId = optionDiv.attributes['data-opt-id']!;
        optionIds[optId] = optionDiv.id;
        print('optId: $optId');
        var optName = optionDiv.attributes['data-opt-name'];
        if (optName == null) {
          var prev = optionDiv.previousElementSibling!;
          if (prev.localName == 'br') {
            prev = prev.previousElementSibling!;
            assert(prev.localName == 'span');
            optName = prev.text.trim();
          } else {
            optName = optionDiv.attributes['data-systemname']!;
          }
        }
        if (optName.endsWith(':')) {
          optName = optName.substring(0, optName.length - 1);
        }
        optionNames[optId] = optName;
        final optValues = <String>{};
        for (final valueDiv
            in optionDiv.querySelectorAll('[data-optvalue],[value]')) {
          final optValue = (valueDiv.attributes['data-optvalue'] ??
              valueDiv.attributes['value'])!;
          if (int.tryParse(optValue) == null) continue;
          final valueTitle = (valueDiv.text.isEmpty ? null : valueDiv.text) ??
              valueDiv.attributes['title'] ??
              valueDiv.attributes['data-systemname'];
          optValues.add(optValue);
          assert(valueTitle != null);
          assert(!optionValueTitles.containsKey(optValue) ||
              optionValueTitles[optValue] == valueTitle);
          optionValueTitles[optValue] = valueTitle!;
          optionValueIds[optValue] = valueDiv.id;
          if (valueDiv.classes.contains('selected') ||
              valueDiv.attributes['selected'] == 'selected') {
            assert(!optionSelected.containsKey(optId));
            optionSelected[optId] = optValue;
          }
        }
        if (optionDiv.querySelector('select') != null) {
          optionKind[optId] = 'dropdown';
        } else {
          optionKind[optId] = 'button';
        }
        assert(!options.containsKey(optId), 'Duplicate option: $optId');
        options[optId] = optValues;
      }

      print('options: $options');
      print('optionNames: $optionNames');
      print('optionValueTitles: $optionValueTitles');
      print('optionIds: $optionValueIds');

      for (final option in options.entries) {
        print(
            '${optionNames[option.key]}: ${option.value.map((e) => optionValueTitles[e]).join(', ')}');
      }

      String sanitizeName(String name) {
        name = name
            .replaceAll("'", '_')
            .replaceAll('"', '_')
            .replaceAll('.', '_')
            .replaceAll('+', '_')
            .replaceAll(' ', '_')
            .replaceAll('(', '_')
            .replaceAll(')', '_')
            .replaceAll('-', '_')
            .replaceAll('/', '_')
            .replaceAll('\\', '_')
            .replaceAll(':', '_')
            .replaceAll(RegExp(r'_+$'), '')
            .replaceAll(RegExp(r'^_+'), '')
            .replaceAll(RegExp(r'_+'), '_')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        return name;
      }

      Future<void> dumpLastModel(String name) async {
        final sizeFolder = tmpFolder.childDirectory(name);
        if (!sizeFolder.existsSync()) {
          sizeFolder.createSync(recursive: true);
        }
        final templateFile = sizeFolder.childFile('template.json');
        final templateResponseBody = (await getResponses(
          'https://www.contrado.com/estore/preview/gettemplateforoptionvalues',
        ))
            .last;
        final templateData = json.decode(utf8.decode(templateResponseBody));
        templateFile.writeAsStringSync(pretty.convert(templateData));

        final count = <String, int>{};
        for (final model
            in (templateData['Product3DModelsModels'] as List?) ?? []) {
          var name = sanitizeName(model['TabName'] ?? 'Model');
          if (name == 'null') {
            name = 'Model';
          }
          final url = Uri.parse(page.url!).resolve(
            model['ModelPath'] as String,
          );
          if (count.containsKey(name)) {
            count[name] = count[name]! + 1;
            name = '$name${count[name]}';
          } else {
            count[name] = 1;
          }
          print('Downloading $name $url');
          final response = await client.get(url, headers: defaultHeaders);
          HttpException.ensureSuccess(response);
          final file = sizeFolder.childFile('$name.glb');
          assert(!file.existsSync(), 'Duplicate model: $name $url');
          await file.writeAsBytes(response.bodyBytes);
        }

        pageRequests.clear();
        pageResponses.clear();
      }

      Future<void> dumpSize(String name, String optId, String valueId) async {
        name = sanitizeName(name);
        print('optId: $optId');
        print('valueId: $valueId');
        print('optionSelected[optId]: ${optionSelected[optId]}');

        await page.evaluate('''
          document.querySelectorAll('.optionvalue-icon-disable').forEach(element => {
            element.classList.remove('optionvalue-icon-disable');
          });
          
          document.querySelectorAll('.out-stock-opv').forEach(element => {
            element.classList.remove('out-stock-opv');
          });
        ''');

        if (optionSelected[optId] != valueId) {
          final divId = optionValueIds[valueId]!;
          print('looking for #$divId');
          // await page.waitForSelector('#$divId');
          if (optionKind[optId] == 'dropdown') {
            print('selecting #${optionIds[optId]} select $valueId');
            await page.evaluate('''(() => {
                let sel = document.querySelector("[id='${htmlEscape.convert(optionIds[optId]!)}'] select");
                sel.value = '$valueId';
                sel.dispatchEvent(new Event('change'));
            })()
            ''');
          } else {
            print('clicking #$divId');
            await page.evaluate('''(() => {
                document.querySelector("[id='$divId']").click();
            })()
            ''');
          }
          await waitNetworkIdle();
          optionSelected[optId] = valueId;
        }
        await dumpLastModel(name);
      }

      final modelOptIndex = (modelConfig['ProductOptions'] as List)
          .indexWhere((e) => e['Product3DOptionConfigurationType'] == 0);
      if (modelOptIndex != -1) {
        final firstOpt = modelConfig['ProductOptions'][modelOptIndex];
        if (firstOpt['OptionValues'][0]['ModelS3Path'] != null) {
          if (firstOpt['OptionValues'].length == 1) {
            await dumpLastModel('Default');
          } else {
            final sizeOptionId = 'bas-${firstOpt['OptionId']}';
            final sizeOptions = options[sizeOptionId]!;
            for (final size in sizeOptions) {
              print(
                  'OptionValues: ${pretty.convert(firstOpt['OptionValues'])}');
              print('id: $size');
              await dumpSize(
                  (firstOpt['OptionValues'] as List).firstWhere(
                      (e) => e['Id'].toString() == size)["Description"]!,
                  sizeOptionId,
                  size);
            }
          }
        }
      }
    }

    tmpFolder.renameSync(productFolder.path);
  }

  print('Done');
  browser.process!.kill();
  await browser.close();
}

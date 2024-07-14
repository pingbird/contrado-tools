import 'dart:convert';

import 'package:file/local.dart';

const fs = LocalFileSystem();

final productConfigJsonFile = fs.file('product_config.json');

final cacheDir = fs.directory('cache');

final pretty = JsonEncoder.withIndent('  ');

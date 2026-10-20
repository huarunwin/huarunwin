import 'dart:io';

import 'package:crypto/crypto.dart';

/// Called in an isolate so hashing large installers does not block rendering.
Future<String> packageSha256(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

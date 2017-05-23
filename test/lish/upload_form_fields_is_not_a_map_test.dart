// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:shelf_test_handler/shelf_test_handler';
import 'package:test/test.dart';

import '../descriptor.dart' as d;
import '../test_pub.dart';
import 'utils.dart';

main() {
  setUp(d.validPackage.create);

  test('upload form fields is not a map', () async {
    var server = await ShelfTestServer.start();
    await d.credentialsFile(server, 'access token').create();
    var pub = await startPublish(server);

    await confirmPublish(pub);

    var body = {'url': 'http://example.com/upload', 'fields': 12};
    await handleUploadForm(server, body);
    expect(pub.stderr, emits('Invalid server response:'));
    expect(pub.stderr, emits(JSON.encode(body)));
    await pub.shouldExit(1);
  });
}

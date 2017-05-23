// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_test_handler/shelf_test_handler';
import 'package:test/test.dart';

import '../descriptor.dart' as d;
import '../test_pub.dart';

main() {
  setUp(d.validPackage.create);

  test('upload form provides an error', () async {
    var server = await ShelfTestServer.start();
    await d.credentialsFile(server, 'access token').create();
    var pub = await startPublish(server);

    await confirmPublish(pub);

    await server.handle('GET', '/api/packages/versions/new', (request) {
      return new shelf.Response.notFound(JSON.encode({
        'error': {'message': 'your request sucked'}
      }));
    });

    expect(pub.stderr, emits('your request sucked'));
    await pub.shouldExit(1);
  });
}

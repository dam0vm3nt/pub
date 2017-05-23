// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_test_handler/shelf_test_handler.dart';
import 'package:test/test.dart';

import '../descriptor.dart' as d;
import '../test_pub.dart';
import 'utils.dart';

main() {
  setUp(d.validPackage.create);

  test('package creation provides an error', () async {
    var server = await ShelfTestServer.start();
    await d.credentialsFile(server, 'access token').create();
    var pub = await startPublish(server);

    await confirmPublish(pub);
    await handleUploadForm(server);
    await handleUpload(server);

    await server.handle('GET', '/create', (request) {
      return new shelf.Response.notFound(JSON.encode({
        'error': {'message': 'Your package was too boring.'}
      }));
    });

    expect(pub.stderr, emits('Your package was too boring.'));
    await pub.shouldExit(1);
  });
}

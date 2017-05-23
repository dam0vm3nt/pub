// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_test_handler/shelf_test_handler';
import 'package:test/test.dart';

import '../descriptor.dart' as d;
import '../test_pub.dart';
import 'utils.dart';

main() {
  test(
      'with no credentials.json, authenticates and saves '
      'credentials.json', () async {
    await d.validPackage.create();

    var server = await ShelfTestServer.start();
    var pub = await startPublish(server);
    await confirmPublish(pub);
    await authorizePub(pub, server);

    await server.handle('GET', '/api/packages/versions/new', (request) {
      expect(request.headers,
          containsPair('authorization', 'Bearer access token'));

      return new shelf.Response(200);
    });

    // After we give pub an invalid response, it should crash. We wait for it to
    // do so rather than killing it so it'll write out the credentials file.
    await pub.shouldExit(1);

    await d.credentialsFile(server, 'access token').validate();
  });
}

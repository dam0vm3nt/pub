// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_test_handler/shelf_test_handler';
import 'package:test/test.dart';

import '../descriptor.dart' as d;
import '../test_pub.dart';

main() {
  test(
      'with an expired credentials.json, refreshes and saves the '
      'refreshed access token to credentials.json', () async {
    await d.validPackage.create();

    var server = await ShelfTestServer.start();
    await d
        .credentialsFile(server, 'access token',
            refreshToken: 'refresh token',
            expiration: new DateTime.now().subtract(new Duration(hours: 1)))
        .create();

    var pub = await startPublish(server);
    await confirmPublish(pub);

    await server.handle('POST', '/token', (request) {
      return request.readAsString().then((body) {
        expect(body,
            matches(new RegExp(r'(^|&)refresh_token=refresh\+token(&|$)')));

        return new shelf.Response.ok(
            JSON.encode(
                {"access_token": "new access token", "token_type": "bearer"}),
            headers: {'content-type': 'application/json'});
      });
    });

    await server.handle('GET', '/api/packages/versions/new', (request) {
      expect(request.headers,
          containsPair('authorization', 'Bearer new access token'));

      return new shelf.Response(200);
    });

    await pub.shouldExit();

    await d
        .credentialsFile(server, 'new access token',
            refreshToken: 'refresh token')
        .validate();
  });
}

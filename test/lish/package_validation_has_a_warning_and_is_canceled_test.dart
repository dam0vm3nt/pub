// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:shelf_test_handler/shelf_test_handler.dart';
import 'package:test/test.dart';

import '../descriptor.dart' as d;
import '../test_pub.dart';

main() {
  setUp(d.validPackage.create);

  test('package validation has a warning and is canceled', () async {
    var pkg = packageMap("test_pkg", "1.0.0");
    pkg["author"] = "Natalie Weizenbaum";
    await d.dir(appPath, [d.pubspec(pkg)]).create();

    var server = await ShelfTestServer.start();
    var pub = await startPublish(server);

    await pub.writeLine("n");
    await pub.shouldExit(exit_codes.DATA);
    expect(pub.stderr, emitsThrough("Package upload canceled."));
  });
}

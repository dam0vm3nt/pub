// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS d.file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test/test.dart';

import '../descriptor.dart' as d;
import '../serve/utils.dart';
import '../test_pub.dart';

main() {
  test("loads a transformer defined in an exported library", () async {
    await serveBarback();

    await d.dir(appPath, [
      d.pubspec({
        "name": "myapp",
        "transformers": ["myapp"],
        "dependencies": {"barback": "any"}
      }),
      d.dir("lib", [
        d.file("myapp.dart", "export 'src/transformer.dart';"),
        d.dir("src", [d.file("transformer.dart", REWRITE_TRANSFORMER)])
      ]),
      d.dir("web", [d.file("foo.txt", "foo")])
    ]).create();

    await pubGet();
    await pubServe();
    await requestShouldSucceed("foo.out", "foo.out");
    await endPubServe();
  });
}

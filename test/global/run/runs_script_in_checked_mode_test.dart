// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test/test.dart';

import '../../descriptor.dart' as d;
import '../../test_pub.dart';

main() {
  test('runs a script in checked mode', () async {
    await servePackages((builder) {
      builder.serve("foo", "1.0.0", contents: [
        d.dir("bin", [d.file("script.dart", "main() { int a = true; }")])
      ]);
    });

    await runPub(args: ["global", "activate", "foo"]);

    var pub = await pubRun(global: true, args: ["--checked", "foo:script"]);
    await expectLater(pub.stderr,
        emitsThrough(contains("'bool' is not a subtype of type 'int' of 'a'")));
    await pub.shouldExit(255);
  });
}

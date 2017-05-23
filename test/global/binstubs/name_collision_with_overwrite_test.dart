// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test/test.dart';

import '../../descriptor.dart' as d;
import '../../test_pub.dart';

main() {
  test("overwrites an existing binstub if --overwrite is passed", () async {
    await d.dir("foo", [
      d.pubspec({
        "name": "foo",
        "executables": {"foo": "foo", "collide1": "foo", "collide2": "foo"}
      }),
      d.dir("bin", [d.file("foo.dart", "main() => print('ok');")])
    ]).create();

    await d.dir("bar", [
      d.pubspec({
        "name": "bar",
        "executables": {"bar": "bar", "collide1": "bar", "collide2": "bar"}
      }),
      d.dir("bin", [d.file("bar.dart", "main() => print('ok');")])
    ]).create();

    await runPub(args: ["global", "activate", "-spath", "../foo"]);

    var pub = await startPub(
        args: ["global", "activate", "-spath", "../bar", "--overwrite"]);
    await expectLater(pub.stdout,
        emitsThrough("Installed executables bar, collide1 and collide2."));
    await expectLater(
        pub.stderr, emits("Replaced collide1 previously installed from foo."));
    await expectLater(
        pub.stderr, emits("Replaced collide2 previously installed from foo."));
    await pub.shouldExit();

    await d.dir(cachePath, [
      d.dir("bin", [
        d.matcherFile(binStubName("foo"), contains("foo:foo")),
        d.matcherFile(binStubName("bar"), contains("bar:bar")),
        d.matcherFile(binStubName("collide1"), contains("bar:bar")),
        d.matcherFile(binStubName("collide2"), contains("bar:bar"))
      ])
    ]).validate();
  });
}

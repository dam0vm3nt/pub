// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Dart2js can take a long time to compile dart code, so we increase the timeout
// to cope with that.
@Timeout.factor(3)
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:pub/src/exit_codes.dart' as exit_codes;

import '../descriptor.dart' as d;
import '../test_pub.dart';
import 'utils.dart';

main() {
  testWithCompiler("reports Dart parse errors", (compiler) async {
    await d.dir(appPath, [
      d.appPubspec(),
      d.dir('web', [
        d.file('file.txt', 'contents'),
        d.file('file.dart', 'void main() {}; void void;'),
        d.dir('subdir', [d.file('subfile.dart', 'void main() {}; void void;')])
      ])
    ]).create();

    await pubGet();
    var pub = await startPub(args: ["build", "--compiler", compiler.name]);
    await expectLater(
        pub.stdout, emits(startsWith("Loading source assets...")));
    await expectLater(pub.stdout, emits(startsWith("Building myapp...")));

    var consumeFile;
    var consumeSubfile;
    switch (compiler) {
      case Compiler.dart2JS:
        consumeFile = emitsThrough(inOrder([
          "[Error from Dart2JS]:",
          startsWith(p.join("web", "file.dart") + ":")
        ]));
        consumeSubfile = emitsThrough(inOrder([
          "[Error from Dart2JS]:",
          startsWith(p.join("web", "subdir", "subfile.dart") + ":")
        ]));
        break;
      case Compiler.dartDevc:
        consumeFile = emitsThrough(inOrder([
          startsWith("Error compiling dartdevc module:"),
          contains(p.join("web", "file.dart"))
        ]));
        consumeSubfile = emitsThrough(inOrder([
          startsWith("Error compiling dartdevc module:"),
          contains(p.join("web", "subdir", "subfile.dart"))
        ]));
        break;
    }

    // It's nondeterministic what order the dart2js transformers start running,
    // so we allow the error messages to be emitted in either order.
    await expectLater(
        pub.stderr, emitsInAnyOrder([consumeFile, consumeSubfile]));

    await pub.shouldExit(exit_codes.DATA);

    // Doesn't output anything if an error occurred.
    await d.dir(appPath, [
      d.dir('build', [d.nothing('web')])
    ]).validate();
  });
}

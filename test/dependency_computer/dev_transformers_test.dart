// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../descriptor.dart' as d;
import '../test_pub.dart';
import 'utils.dart';

void main() {
  integration("doesn't return a dependency's transformer that can't run on lib",
      () {
    d.dir(appPath, [
      d.pubspec({
        "name": "myapp",
        "dependencies": {
          "foo": {"path": "../foo"}
        }
      })
    ]).create();

    d.dir("foo", [
      d.pubspec({
        "name": "foo",
        "version": "1.0.0",
        "transformers": [
          {
            "foo": {"\$include": "test/foo_test.dart"}
          }
        ]
      }),
      d.dir("lib", [d.file("foo.dart", transformer())]),
      d.dir("test", [d.file("foo_test.dart", "")])
    ]).create();

    expectDependencies({});
  });

  integration(
      "does return the root package's transformer that can't run on "
      "lib", () {
    d.dir(appPath, [
      d.pubspec({
        "name": "myapp",
        "transformers": [
          {
            "myapp": {"\$include": "test/myapp_test.dart"}
          }
        ]
      }),
      d.dir("lib", [d.file("myapp.dart", transformer())]),
      d.dir("test", [d.file("myapp_test.dart", "")])
    ]).create();

    expectDependencies({"myapp": []});
  });

  integration(
      "does return a dependency's transformer that the root package "
      "uses", () {
    d.dir(appPath, [
      d.pubspec({
        "name": "myapp",
        "dependencies": {
          "foo": {"path": "../foo"}
        },
        "transformers": [
          {
            "foo": {"\$include": "test/myapp_test.dart"}
          }
        ]
      }),
      d.dir("test", [d.file("myapp_test.dart", "")])
    ]).create();

    d.dir("foo", [
      d.pubspec({"name": "foo", "version": "1.0.0"}),
      d.dir("lib", [d.file("foo.dart", transformer())])
    ]).create();

    expectDependencies({"foo": []});
  });

  integration("doesn't return a dependency's transformer that can run on bin",
      () {
    d.dir(appPath, [
      d.pubspec({
        "name": "myapp",
        "dependencies": {
          "foo": {"path": "../foo"}
        }
      })
    ]).create();

    d.dir("foo", [
      d.pubspec({
        "name": "foo",
        "version": "1.0.0",
        "transformers": [
          {
            "foo": {"\$include": "bin/foo.dart"}
          }
        ]
      }),
      d.dir("lib", [d.file("foo.dart", transformer())]),
      d.dir("test", [d.file("foo_test.dart", "")])
    ]).create();

    expectDependencies({"foo": []});
  });

  // Regression test for #1291
  integration(
      "doesn't return a dependency's transformer that can't run on lib "
      "when the app's transformer imports the dependency's", () {
    d.dir(appPath, [
      d.pubspec({
        "name": "myapp",
        "dependencies": {
          "foo": {"path": "../foo"}
        },
        "transformers": ["myapp"]
      }),
      d.dir("lib", [
        d.file("myapp.dart", transformer(['package:foo/foo.dart']))
      ])
    ]).create();

    d.dir("foo", [
      d.pubspec({
        "name": "foo",
        "version": "1.0.0",
        "transformers": [
          ["foo/bar"],
          [
            {
              "foo": {"\$include": "test/foo_test.dart"}
            }
          ]
        ]
      }),
      d.dir("lib", [
        d.file("foo.dart", transformer()),
        d.file("bar.dart", transformer())
      ]),
      d.dir("test", [d.file("foo_test.dart", "")])
    ]).create();

    expectDependencies({
      'foo/bar': [],
      'myapp': ['foo/bar']
    });
  });
}

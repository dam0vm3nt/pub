// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Test infrastructure for testing pub.
///
/// Unlike typical unit tests, most pub tests are integration tests that stage
/// some stuff on the file system, run pub, and then validate the results. This
/// library provides an API to build tests like that.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:async/async.dart';
import 'package:http/testing.dart';
import 'package:package_resolver/package_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:shelf_test_handler/shelf_test_handler.dart';
import 'package:test/test.dart' hide fail;
import 'package:test_process/test_process.dart';

import 'package:pub/src/entrypoint.dart';
import 'package:pub/src/exit_codes.dart' as exit_codes;
// TODO(rnystrom): Using "gitlib" as the prefix here is ugly, but "git" collides
// with the git descriptor method. Maybe we should try to clean up the top level
// scope a bit?
import 'package:pub/src/git.dart' as gitlib;
import 'package:pub/src/http.dart';
import 'package:pub/src/io.dart';
import 'package:pub/src/lock_file.dart';
import 'package:pub/src/log.dart' as log;
import 'package:pub/src/source_registry.dart';
import 'package:pub/src/system_cache.dart';
import 'package:pub/src/utils.dart';
import 'package:pub/src/validator.dart';

import 'descriptor.dart' as d;
import 'descriptor_server.dart';

export 'descriptor_server.dart';
export 'package_server.dart';

/// A [Matcher] that matches JavaScript generated by dart2js with minification
/// enabled.
Matcher isMinifiedDart2JSOutput =
    isNot(contains("// The code supports the following hooks"));

/// A [Matcher] that matches JavaScript generated by dart2js with minification
/// disabled.
Matcher isUnminifiedDart2JSOutput =
    contains("// The code supports the following hooks");

/// The entrypoint for pub itself.
final _entrypoint = new Entrypoint(pubRoot, new SystemCache(isOffline: true));

/// Converts [value] into a YAML string.
String yaml(value) => JSON.encode(value);

/// The path of the package cache directory used for tests, relative to the
/// sandbox directory.
final String cachePath = "cache";

/// The path of the mock app directory used for tests, relative to the sandbox
/// directory.
final String appPath = "myapp";

/// The path of the packages directory in the mock app used for tests, relative
/// to the sandbox directory.
final String packagesPath = "$appPath/packages";

/// The path of the ".packages" file in the mock app used for tests, relative
/// to the sandbox directory.
final String packagesFilePath = "$appPath/.packages";

/// Set to true when the current batch of scheduled events should be aborted.
bool _abortScheduled = false;

/// Enum identifying a pub command that can be run with a well-defined success
/// output.
class RunCommand {
  static final get = new RunCommand(
      'get', new RegExp(r'Got dependencies!|Changed \d+ dependenc(y|ies)!'));
  static final upgrade = new RunCommand(
      'upgrade',
      new RegExp(
          r'(No dependencies changed\.|Changed \d+ dependenc(y|ies)!)$'));
  static final downgrade = new RunCommand(
      'downgrade',
      new RegExp(
          r'(No dependencies changed\.|Changed \d+ dependenc(y|ies)!)$'));

  final String name;
  final RegExp success;
  RunCommand(this.name, this.success);
}

/// Runs the tests defined within [callback] using both pub get and pub upgrade.
///
/// Many tests validate behavior that is the same between pub get and
/// upgrade have the same behavior. Instead of duplicating those tests, this
/// takes a callback that defines get/upgrade agnostic tests and runs them
/// with both commands.
void forBothPubGetAndUpgrade(void callback(RunCommand command)) {
  group(RunCommand.get.name, () => callback(RunCommand.get));
  group(RunCommand.upgrade.name, () => callback(RunCommand.upgrade));
}

/// Invokes the pub [command] and validates that it completes in an expected
/// way.
///
/// By default, this validates that the command completes successfully and
/// understands the normal output of a successful pub command. If [warning] is
/// given, it expects the command to complete successfully *and* print [warning]
/// to stderr. If [error] is given, it expects the command to *only* print
/// [error] to stderr. [output], [error], [silent], and [warning] may be
/// strings, [RegExp]s, or [Matcher]s.
///
/// If [exitCode] is given, expects the command to exit with that code.
// TODO(rnystrom): Clean up other tests to call this when possible.
Future pubCommand(RunCommand command,
    {Iterable<String> args,
    output,
    error,
    silent,
    warning,
    int exitCode,
    Map<String, String> environment}) async {
  if (error != null && warning != null) {
    throw new ArgumentError("Cannot pass both 'error' and 'warning'.");
  }

  var allArgs = [command.name];
  if (args != null) allArgs.addAll(args);

  if (output == null) output = command.success;

  if (error != null && exitCode == null) exitCode = 1;

  // No success output on an error.
  if (error != null) output = null;
  if (warning != null) error = warning;

  await runPub(
      args: allArgs,
      output: output,
      error: error,
      silent: silent,
      exitCode: exitCode,
      environment: environment);
}

Future pubGet(
        {Iterable<String> args,
        output,
        error,
        warning,
        int exitCode,
        Map<String, String> environment}) =>
    pubCommand(RunCommand.get,
        args: args,
        output: output,
        error: error,
        warning: warning,
        exitCode: exitCode,
        environment: environment);

Future pubUpgrade(
        {Iterable<String> args,
        output,
        error,
        warning,
        int exitCode,
        Map<String, String> environment}) =>
    pubCommand(RunCommand.upgrade,
        args: args,
        output: output,
        error: error,
        warning: warning,
        exitCode: exitCode,
        environment: environment);

Future pubDowngrade(
        {Iterable<String> args,
        output,
        error,
        warning,
        int exitCode,
        Map<String, String> environment}) =>
    pubCommand(RunCommand.downgrade,
        args: args,
        output: output,
        error: error,
        warning: warning,
        exitCode: exitCode,
        environment: environment);

/// Schedules starting the "pub [global] run" process and validates the
/// expected startup output.
///
/// If [global] is `true`, this invokes "pub global run", otherwise it does
/// "pub run".
///
/// Returns the `pub run` process.
Future<PubProcess> pubRun({bool global: false, Iterable<String> args}) async {
  var pubArgs = global ? ["global", "run"] : ["run"];
  pubArgs.addAll(args);
  var pub = await startPub(args: pubArgs);

  // Loading sources and transformers isn't normally printed, but the pub test
  // infrastructure runs pub in verbose mode, which enables this.
  expect(pub.stdout, mayEmitMultiple(startsWith("Loading")));

  return pub;
}

/// Schedules renaming (moving) the directory at [from] to [to], both of which
/// are assumed to be relative to [d.sandbox].
void renameInSandbox(String from, String to) {
  renameDir(_pathInSandbox(from), _pathInSandbox(to));
}

/// Schedules creating a symlink at path [symlink] that points to [target],
/// both of which are assumed to be relative to [d.sandbox].
void symlinkInSandbox(String target, String symlink) {
  createSymlink(_pathInSandbox(target), _pathInSandbox(symlink));
}

/// Runs Pub with [args] and validates that its results match [output] (or
/// [outputJson]), [error], [silent] (for logs that are silent by default), and
/// [exitCode].
///
/// [output], [error], and [silent] can be [String]s, [RegExp]s, or [Matcher]s.
///
/// If [outputJson] is given, validates that pub outputs stringified JSON
/// matching that object, which can be a literal JSON object or any other
/// [Matcher].
///
/// If [environment] is given, any keys in it will override the environment
/// variables passed to the spawned process.
Future runPub(
    {List<String> args,
    output,
    error,
    outputJson,
    silent,
    int exitCode: exit_codes.SUCCESS,
    Map<String, String> environment}) async {
  // Cannot pass both output and outputJson.
  assert(output == null || outputJson == null);

  var pub = await startPub(args: args, environment: environment);
  await pub.shouldExit(exitCode);

  expect(() async {
    var actualOutput = (await pub.stdoutStream().toList()).join("\n");
    var actualError = (await pub.stderrStream().toList()).join("\n");
    var actualSilent = (await pub.silentStream().toList()).join("\n");

    var failures = <String>[];
    if (outputJson == null) {
      _validateOutput(failures, 'stdout', output, actualOutput);
    } else {
      _validateOutputJson(failures, 'stdout', outputJson, actualOutput);
    }

    _validateOutput(failures, 'stderr', error, actualError);
    _validateOutput(failures, 'silent', silent, actualSilent);

    if (!failures.isEmpty) throw new TestFailure(failures.join('\n'));
  }(), completes);
}

/// Like [startPub], but runs `pub lish` in particular with [server] used both
/// as the OAuth2 server (with "/token" as the token endpoint) and as the
/// package server.
///
/// Any futures in [args] will be resolved before the process is started.
Future<PubProcess> startPublish(ShelfTestServer server,
    {List<String> args}) async {
  var tokenEndpoint = server.url.resolve('/token').toString();
  if (args == null) args = [];
  args = ['lish', '--server', tokenEndpoint]..addAll(args);
  return await startPub(args: args, tokenEndpoint: tokenEndpoint);
}

/// Handles the beginning confirmation process for uploading a packages.
///
/// Ensures that the right output is shown and then enters "y" to confirm the
/// upload.
Future confirmPublish(TestProcess pub) async {
  // TODO(rnystrom): This is overly specific and inflexible regarding different
  // test packages. Should validate this a little more loosely.
  await expectLater(
      pub.stdout, emits(startsWith('Publishing test_pkg 1.0.0 to ')));
  await expectLater(pub.stdout,
      emitsThrough("Looks great! Are you ready to upload your package (y/n)?"));
  await pub.stdin.writeln("y");
}

/// Gets the absolute path to [relPath], which is a relative path in the test
/// sandbox.
String _pathInSandbox(String relPath) => p.join(d.sandbox, relPath);

/// Gets the environment variables used to run pub in a test context.
Map<String, String> getPubTestEnvironment([String tokenEndpoint]) {
  var environment = {
    '_PUB_TESTING': 'true',
    'PUB_CACHE': _pathInSandbox(cachePath),

    // Ensure a known SDK version is set for the tests that rely on that.
    '_PUB_TEST_SDK_VERSION': "0.1.2+3"
  };

  if (tokenEndpoint != null) {
    environment['_PUB_TEST_TOKEN_ENDPOINT'] = tokenEndpoint;
  }

  if (globalServer != null) {
    environment['PUB_HOSTED_URL'] = "http://localhost:${globalServer.port}";
  }

  return environment;
}

/// Starts a Pub process and returns a [PubProcess] that supports interaction
/// with that process.
///
/// Any futures in [args] will be resolved before the process is started.
///
/// If [environment] is given, any keys in it will override the environment
/// variables passed to the spawned process.
Future<PubProcess> startPub(
    {Iterable<String> args,
    String tokenEndpoint,
    Map<String, String> environment}) async {
  args ??= [];

  ensureDir(_pathInSandbox(appPath));

  // Find a Dart executable we can use to spawn. Use the same one that was
  // used to run this script itself.
  var dartBin = Platform.executable;

  // If the executable looks like a path, get its full path. That way we
  // can still find it when we spawn it with a different working directory.
  if (dartBin.contains(Platform.pathSeparator)) {
    dartBin = p.absolute(dartBin);
  }

  // If there's a snapshot available, use it. The user is responsible for
  // ensuring this is up-to-date..
  //
  // TODO(nweiz): When the test runner supports plugins, create one to
  // auto-generate the snapshot before each run.
  var pubPath = p.absolute(p.join(pubRoot, 'bin/pub.dart'));
  if (fileExists('$pubPath.snapshot')) pubPath += '.snapshot';

  var dartArgs = [
    await PackageResolver.current.processArgument,
    pubPath,
    '--verbose'
  ]..addAll(args);

  return await PubProcess.start(dartBin, dartArgs,
      environment: getPubTestEnvironment(tokenEndpoint)..addAll(environment ?? {}),
      workingDirectory: _pathInSandbox(appPath),
      description: args.isEmpty ? 'pub' : 'pub ${args.first}');
}

/// A subclass of [TestProcess] that parses pub's verbose logging output and
/// makes [stdout] and [stderr] work as though pub weren't running in verbose
/// mode.
class PubProcess extends TestProcess {
  StreamSplitter<Pair<log.Level, String>> get _logSplitter {
    __logSplitter ??= new StreamSplitter(StreamGroup.merge([
      _outputToLog(super.stdoutStream(), log.Level.MESSAGE),
      _outputToLog(super.stderrStream(), log.Level.ERROR)
    ]));
    return __logSplitter;
  }

  StreamSplitter<Pair<log.Level, String>> __logSplitter;

  static Future<PubProcess> start(String executable, Iterable<String> arguments,
      {String workingDirectory,
      Map<String, String> environment,
      bool includeParentEnvironment: true,
      bool runInShell: false,
      String description,
      Encoding encoding,
      bool forwardStdio: false}) async {
    var process = await Process.start(executable, arguments.toList(),
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell);

    if (description == null) {
      var humanExecutable = p.isWithin(p.current, executable)
          ? p.relative(executable)
          : executable;
      description = "$humanExecutable ${arguments.join(" ")}";
    }

    encoding ??= UTF8;
    return new PubProcess(process, description,
        encoding: encoding, forwardStdio: forwardStdio);
  }

  /// This is protected.
  PubProcess(process, description,
      {Encoding encoding, bool forwardStdio: false})
      : super(process, description,
            encoding: encoding, forwardStdio: forwardStdio) {}

  final _logLineRegExp = new RegExp(r"^([A-Z ]{4})[:|] (.*)$");
  final Map<String, log.Level> _logLevels = [
    log.Level.ERROR,
    log.Level.WARNING,
    log.Level.MESSAGE,
    log.Level.IO,
    log.Level.SOLVER,
    log.Level.FINE
  ].fold({}, (levels, level) {
    levels[level.name] = level;
    return levels;
  });

  Stream<Pair<log.Level, String>> _outputToLog(
      Stream<String> stream, log.Level defaultLevel) {
    var lastLevel;
    return stream.map((line) {
      var match = _logLineRegExp.firstMatch(line);
      if (match == null) return new Pair<log.Level, String>(defaultLevel, line);

      var level = _logLevels[match[1]];
      if (level == null) level = lastLevel;
      lastLevel = level;
      return new Pair<log.Level, String>(level, match[2]);
    });
  }

  Stream<String> stdoutStream() {
    return _logSplitter.split().expand((entry) {
      if (entry.first != log.Level.MESSAGE) return [];
      return [entry.last];
    });
  }

  Stream<String> stderrStream() {
    return _logSplitter.split().expand((entry) {
      if (entry.first != log.Level.ERROR && entry.first != log.Level.WARNING) {
        return [];
      }
      return [entry.last];
    });
  }

  /// A stream of log messages that are silent by default.
  Stream<String> silentStream() {
    return _logSplitter.split().expand((entry) {
      if (entry.first == log.Level.MESSAGE) return [];
      if (entry.first == log.Level.ERROR) return [];
      if (entry.first == log.Level.WARNING) return [];
      return [entry.last];
    });
  }
}

/// Fails the current test if Git is not installed.
///
/// We require machines running these tests to have git installed. This
/// validation gives an easier-to-understand error when that requirement isn't
/// met than just failing in the middle of a test when pub invokes git.
///
/// This also increases the [Schedule] timeout to 30 seconds on Windows,
/// where Git runs really slowly.
void ensureGit() {
  if (!gitlib.isInstalled) fail("Git must be installed to run this test.");
}

/// Creates a lock file for [package] without running `pub get`.
///
/// [sandbox] is a list of path dependencies to be found in the sandbox
/// directory. [pkg] is a list of packages in the Dart repo's "pkg" directory;
/// each package listed here and all its dependencies will be linked to the
/// version in the Dart repo.
///
/// [hosted] is a list of package names to version strings for dependencies on
/// hosted packages.
Future createLockFile(String package,
    {Iterable<String> sandbox, Map<String, String> hosted}) async {
  var cache = new SystemCache(rootDir: _pathInSandbox(cachePath));

  var lockFile =
      _createLockFile(cache.sources, sandbox: sandbox, hosted: hosted);

  await d.dir(package, [
    d.file('pubspec.lock', lockFile.serialize(null)),
    d.file('.packages', lockFile.packagesFile(cache, package))
  ]).create();
}

/// Like [createLockFile], but creates only a `.packages` file without a
/// lockfile.
Future createPackagesFile(String package,
    {Iterable<String> sandbox, Map<String, String> hosted}) async {
  var cache = new SystemCache(rootDir: _pathInSandbox(cachePath));
  var lockFile =
      _createLockFile(cache.sources, sandbox: sandbox, hosted: hosted);

  await d.dir(package,
      [d.file('.packages', lockFile.packagesFile(cache, package))]).create();
}

/// Creates a lock file for [package] without running `pub get`.
///
/// [sandbox] is a list of path dependencies to be found in the sandbox
/// directory. [pkg] is a list of packages in the Dart repo's "pkg" directory;
/// each package listed here and all its dependencies will be linked to the
/// version in the Dart repo.
///
/// [hosted] is a list of package names to version strings for dependencies on
/// hosted packages.
LockFile _createLockFile(SourceRegistry sources,
    {Iterable<String> sandbox, Map<String, String> hosted}) {
  var dependencies = {};

  if (sandbox != null) {
    for (var package in sandbox) {
      dependencies[package] = '../$package';
    }
  }

  var packages = dependencies.keys.map((name) {
    var dependencyPath = dependencies[name];
    return sources.path.idFor(name, new Version(0, 0, 0), dependencyPath);
  }).toList();

  if (hosted != null) {
    hosted.forEach((name, version) {
      var id = sources.hosted.idFor(name, new Version.parse(version));
      packages.add(id);
    });
  }

  return new LockFile(packages);
}

/// Returns the path to the version of [package] used by pub.
String packagePath(String package) {
  if (runningFromDartRepo) {
    return dirExists(p.join(dartRepoRoot, 'pkg', package))
        ? p.join(dartRepoRoot, 'pkg', package)
        : p.join(dartRepoRoot, 'third_party', 'pkg', package);
  }

  var id = _entrypoint.lockFile.packages[package];
  if (id == null) {
    throw new StateError(
        'The tests rely on "$package", but it\'s not in the lockfile.');
  }

  return p.join(
      SystemCache.defaultDir, 'hosted/pub.dartlang.org/$package-${id.version}');
}

/// Uses [client] as the mock HTTP client for this test.
///
/// Note that this will only affect HTTP requests made via http.dart in the
/// parent process.
void useMockClient(MockClient client) {
  var oldInnerClient = innerHttpClient;
  innerHttpClient = client;
  addTearDown(() {
    innerHttpClient = oldInnerClient;
  });
}

/// Describes a map representing a library package with the given [name],
/// [version], and [dependencies].
Map packageMap(
  String name,
  String version, [
  Map dependencies,
  Map devDependencies,
]) {
  var package = <String, dynamic>{
    "name": name,
    "version": version,
    "author": "Natalie Weizenbaum <nweiz@google.com>",
    "homepage": "http://pub.dartlang.org",
    "description": "A package, I guess."
  };

  if (dependencies != null) package["dependencies"] = dependencies;
  if (devDependencies != null) package["dev_dependencies"] = devDependencies;
  return package;
}

/// Resolves [target] relative to the path to pub's `test/asset` directory.
String testAssetPath(String target) => p.join(pubRoot, 'test', 'asset', target);

/// Returns a Map in the format used by the pub.dartlang.org API to represent a
/// package version.
///
/// [pubspec] is the parsed pubspec of the package version. If [full] is true,
/// this returns the complete map, including metadata that's only included when
/// requesting the package version directly.
Map packageVersionApiMap(Map pubspec, {bool full: false}) {
  var name = pubspec['name'];
  var version = pubspec['version'];
  var map = {
    'pubspec': pubspec,
    'version': version,
    'url': '/api/packages/$name/versions/$version',
    'archive_url': '/packages/$name/versions/$version.tar.gz',
    'new_dartdoc_url': '/api/packages/$name/versions/$version'
        '/new_dartdoc',
    'package_url': '/api/packages/$name'
  };

  if (full) {
    map.addAll({
      'downloads': 0,
      'created': '2012-09-25T18:38:28.685260',
      'libraries': ['$name.dart'],
      'uploader': ['nweiz@google.com']
    });
  }

  return map;
}

/// Returns the name of the shell script for a binstub named [name].
///
/// Adds a ".bat" extension on Windows.
String binStubName(String name) => Platform.isWindows ? '$name.bat' : name;

/// Compares the [actual] output from running pub with [expected].
///
/// If [expected] is a [String], ignores leading and trailing whitespace
/// differences and tries to report the offending difference in a nice way.
///
/// If it's a [RegExp] or [Matcher], just reports whether the output matches.
void _validateOutput(
    List<String> failures, String pipe, expected, String actual) {
  if (expected == null) return;

  if (expected is String) {
    _validateOutputString(failures, pipe, expected, actual);
  } else {
    if (expected is RegExp) expected = matches(expected);
    expect(actual, expected);
  }
}

void _validateOutputString(
    List<String> failures, String pipe, String expected, String actual) {
  var actualLines = actual.split("\n");
  var expectedLines = expected.split("\n");

  // Strip off the last line. This lets us have expected multiline strings
  // where the closing ''' is on its own line. It also fixes '' expected output
  // to expect zero lines of output, not a single empty line.
  if (expectedLines.last.trim() == '') {
    expectedLines.removeLast();
  }

  var results = <String>[];
  var failed = false;

  // Compare them line by line to see which ones match.
  var length = max(expectedLines.length, actualLines.length);
  for (var i = 0; i < length; i++) {
    if (i >= actualLines.length) {
      // Missing output.
      failed = true;
      results.add('? ${expectedLines[i]}');
    } else if (i >= expectedLines.length) {
      // Unexpected extra output.
      failed = true;
      results.add('X ${actualLines[i]}');
    } else {
      var expectedLine = expectedLines[i].trim();
      var actualLine = actualLines[i].trim();

      if (expectedLine != actualLine) {
        // Mismatched lines.
        failed = true;
        results.add('X ${actualLines[i]}');
      } else {
        // Output is OK, but include it in case other lines are wrong.
        results.add('| ${actualLines[i]}');
      }
    }
  }

  // If any lines mismatched, show the expected and actual.
  if (failed) {
    failures.add('Expected $pipe:');
    failures.addAll(expectedLines.map((line) => '| $line'));
    failures.add('Got:');
    failures.addAll(results);
  }
}

/// Validates that [actualText] is a string of JSON that matches [expected],
/// which may be a literal JSON object, or any other [Matcher].
void _validateOutputJson(
    List<String> failures, String pipe, expected, String actualText) {
  var actual;
  try {
    actual = JSON.decode(actualText);
  } on FormatException {
    failures.add('Expected $pipe JSON:');
    failures.add(expected);
    failures.add('Got invalid JSON:');
    failures.add(actualText);
  }

  // Match against the expectation.
  expect(actual, expected);
}

/// A function that creates a [Validator] subclass.
typedef Validator ValidatorCreator(Entrypoint entrypoint);

/// Schedules a single [Validator] to run on the [appPath].
///
/// Returns a scheduled Future that contains the errors and warnings produced
/// by that validator.
Future<Pair<List<String>, List<String>>> validatePackage(
    ValidatorCreator fn) async {
  var cache = new SystemCache(rootDir: _pathInSandbox(cachePath));
  var validator = fn(new Entrypoint(_pathInSandbox(appPath), cache));
  await validator.validate();
  return new Pair(validator.errors, validator.warnings);
}

/// A matcher that matches a Pair.
Matcher pairOf(Matcher firstMatcher, Matcher lastMatcher) =>
    new _PairMatcher(firstMatcher, lastMatcher);

class _PairMatcher extends Matcher {
  final Matcher _firstMatcher;
  final Matcher _lastMatcher;

  _PairMatcher(this._firstMatcher, this._lastMatcher);

  bool matches(item, Map matchState) {
    if (item is! Pair) return false;
    return _firstMatcher.matches(item.first, matchState) &&
        _lastMatcher.matches(item.last, matchState);
  }

  Description describe(Description description) {
    return description.addAll("(", ", ", ")", [_firstMatcher, _lastMatcher]);
  }
}

/// Returns a matcher that asserts that a string contains [times] distinct
/// occurrences of [pattern], which must be a regular expression pattern.
Matcher matchesMultiple(String pattern, int times) {
  var buffer = new StringBuffer(pattern);
  for (var i = 1; i < times; i++) {
    buffer.write(r"(.|\n)*");
    buffer.write(pattern);
  }
  return matches(buffer.toString());
}

/// A [StreamMatcher] that matches multiple lines of output.
StreamMatcher emitsLines(String output) => emitsInOrder(output.split("\n"));

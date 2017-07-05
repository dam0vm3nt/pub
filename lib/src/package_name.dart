// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

import 'package.dart';
import 'source.dart';
import 'utils.dart';

/// The equality to use when comparing the feature sets of two package names.
final _featureEquality = const SetEquality<String>();

/// The base class of [PackageRef], [PackageId], and [PackageRange].
abstract class PackageName {
  /// The name of the package being identified.
  final String name;

  /// The [Source] used to look up this package.
  ///
  /// If this is a root package, this will be `null`.
  final Source source;

  /// The metadata used by the package's [source] to identify and locate it.
  ///
  /// It contains whatever [Source]-specific data it needs to be able to get
  /// the package. For example, the description of a git sourced package might
  /// by the URL "git://github.com/dart/uilib.git".
  final description;

  /// Whether this is a name for a magic package.
  ///
  /// Magic packages are unversioned pub constructs that have special semantics.
  /// For example, a magic package named "pub itself" is inserted into the
  /// dependency graph when any package depends on barback. This packages has
  /// dependencies that represent the versions of barback and related packages
  /// that pub is compatible with.
  final bool isMagic;

  /// Whether this package is the root package.
  bool get isRoot => source == null && !isMagic;

  PackageName._(this.name, this.source, this.description) : isMagic = false;

  PackageName._magic(this.name)
      : source = null,
        description = null,
        isMagic = true;

  String toString() {
    if (isRoot) return "$name (root)";
    if (isMagic) return name;
    return "$name from $source";
  }

  /// Returns a [PackageRef] with this one's [name], [source], and
  /// [description].
  PackageRef toRef() => isMagic
      ? new PackageRef.magic(name)
      : new PackageRef(name, source, description);

  /// Returns a [PackageRange] for this package with the given version constraint.
  PackageRange withConstraint(VersionConstraint constraint) =>
      new PackageRange(name, source, constraint, description);

  /// Returns whether this refers to the same package as [other].
  ///
  /// This doesn't compare any constraint information; it's equivalent to
  /// `this.toRef() == other.toRef()`.
  bool samePackage(PackageName other) {
    if (other.name != name) return false;
    if (source == null) return other.source == null;

    return other.source == source &&
        source.descriptionsEqual(description, other.description);
  }

  int get hashCode {
    if (source == null) return name.hashCode;
    return name.hashCode ^
        source.hashCode ^
        source.hashDescription(description);
  }
}

/// A reference to a [Package], but not any particular version(s) of it.
class PackageRef extends PackageName {
  /// Creates a reference to a package with the given [name], [source], and
  /// [description].
  ///
  /// Since an ID's description is an implementation detail of its source, this
  /// should generally not be called outside of [Source] subclasses. A reference
  /// can be obtained from a user-supplied description using [Source.parseRef].
  PackageRef(String name, Source source, description)
      : super._(name, source, description);

  /// Creates a reference to a magic package (see [isMagic]).
  PackageRef.magic(String name) : super._magic(name);

  bool operator ==(other) => other is PackageRef && samePackage(other);
}

/// A reference to a specific version of a package.
///
/// A package ID contains enough information to correctly get the package.
///
/// It's possible for multiple distinct package IDs to point to different
/// packages that have identical contents. For example, the same package may be
/// available from multiple sources. As far as Pub is concerned, those packages
/// are different.
///
/// Note that a package ID's [description] field has a different structure than
/// the [PackageRef.description] or [PackageRange.description] fields for some
/// sources. For example, the `git` source adds revision information to the
/// description to ensure that the same ID always points to the same source.
class PackageId extends PackageName {
  /// The package's version.
  final Version version;

  /// Creates an ID for a package with the given [name], [source], [version],
  /// and [description].
  ///
  /// Since an ID's description is an implementation detail of its source, this
  /// should generally not be called outside of [Source] subclasses.
  PackageId(String name, Source source, this.version, description)
      : super._(name, source, description);

  /// Creates an ID for a magic package (see [isMagic]).
  PackageId.magic(String name)
      : version = Version.none,
        super._magic(name);

  /// Creates an ID for the given root package.
  PackageId.root(Package package)
      : version = package.version,
        super._(package.name, null, package.name);

  int get hashCode => super.hashCode ^ version.hashCode;

  bool operator ==(other) =>
      other is PackageId && samePackage(other) && other.version == version;

  String toString() {
    if (isRoot) return "$name $version (root)";
    if (isMagic) return name;
    return "$name $version from $source";
  }
}

/// A reference to a constrained range of versions of one package.
class PackageRange extends PackageName {
  /// The allowed package versions.
  final VersionConstraint constraint;

  /// The features that are required.
  final Set<String> features;

  /// Creates a reference to package with the given [name], [source],
  /// [constraint], and [description].
  ///
  /// Since an ID's description is an implementation detail of its source, this
  /// should generally not be called outside of [Source] subclasses.
  PackageRange(String name, Source source, this.constraint, description,
      {Iterable<String> features})
      : features = features == null
            ? const UnmodifiableSetView.empty()
            : new UnmodifiableSetView(features.toSet()),
        super._(name, source, description);

  PackageRange.magic(String name)
      : constraint = Version.none,
        features = const UnmodifiableSetView.empty(),
        super._magic(name);

  String toString() {
    if (isRoot) return "$name $constraint (root)";
    if (isMagic) return name;
    var prefix = "$name $constraint from $source";
    if (features.isNotEmpty) prefix += " with ${toSentence(features)}";
    return "$prefix ($description)";
  }

  /// Returns a new [PackageRange] with [features] merged with [this.features].
  PackageRange withFeatures(Set<String> features) {
    if (features.isEmpty) return this;
    return new PackageRange(name, source, constraint, description,
        features: this.features.union(features));
  }

  /// Whether [id] satisfies this dependency.
  ///
  /// Specifically, whether [id] refers to the same package as [this] *and*
  /// [constraint] allows `id.version`.
  bool allows(PackageId id) => samePackage(id) && constraint.allows(id.version);

  int get hashCode =>
      super.hashCode ^ constraint.hashCode ^ _featureEquality.hash(features);

  bool operator ==(other) =>
      other is PackageRange &&
      samePackage(other) &&
      other.constraint == constraint &&
      _featureEquality.equals(other.features, features);
}

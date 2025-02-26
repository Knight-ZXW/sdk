// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.source_library_builder;

import 'dart:convert' show jsonEncode;

import 'package:kernel/ast.dart'
    show
        Arguments,
        Class,
        Constructor,
        ConstructorInvocation,
        DartType,
        DynamicType,
        Expression,
        Extension,
        Field,
        FunctionNode,
        FunctionType,
        InterfaceType,
        Library,
        LibraryDependency,
        LibraryPart,
        ListLiteral,
        MapLiteral,
        Member,
        Name,
        Procedure,
        ProcedureKind,
        SetLiteral,
        StaticInvocation,
        StringLiteral,
        Supertype,
        Typedef,
        TypeParameter,
        TypeParameterType,
        VariableDeclaration,
        VoidType;

import 'package:kernel/class_hierarchy.dart' show ClassHierarchy;

import 'package:kernel/clone.dart' show CloneVisitor;

import 'package:kernel/src/bounds_checks.dart'
    show
        TypeArgumentIssue,
        findTypeArgumentIssues,
        findTypeArgumentIssuesForInvocation,
        getGenericTypeName;

import 'package:kernel/type_algebra.dart' show substitute;

import 'package:kernel/type_environment.dart' show TypeEnvironment;

import '../../base/resolve_relative_uri.dart' show resolveRelativeUri;

import '../../scanner/token.dart' show Token;

import '../builder/builder.dart'
    show
        ClassBuilder,
        ConstructorReferenceBuilder,
        Builder,
        EnumConstantInfo,
        FormalParameterBuilder,
        FunctionTypeBuilder,
        LibraryBuilder,
        MemberBuilder,
        MetadataBuilder,
        NameIterator,
        PrefixBuilder,
        FunctionBuilder,
        QualifiedName,
        Scope,
        TypeBuilder,
        TypeDeclarationBuilder,
        TypeVariableBuilder,
        UnresolvedType,
        flattenName;

import '../builder/extension_builder.dart';

import '../combinator.dart' show Combinator;

import '../configuration.dart' show Configuration;

import '../export.dart' show Export;

import '../fasta_codes.dart'
    show
        FormattedMessage,
        LocatedMessage,
        Message,
        messageConflictsWithTypeVariableCause,
        messageConstructorWithWrongName,
        messageExpectedUri,
        messageMemberWithSameNameAsClass,
        messageGenericFunctionTypeInBound,
        messageGenericFunctionTypeUsedAsActualTypeArgument,
        messageIncorrectTypeArgumentVariable,
        messageLanguageVersionInvalidInDotPackages,
        messageLanguageVersionMismatchInPart,
        messagePartExport,
        messagePartExportContext,
        messagePartInPart,
        messagePartInPartLibraryContext,
        messagePartOfSelf,
        messagePartOfTwoLibraries,
        messagePartOfTwoLibrariesContext,
        messageTypeVariableDuplicatedName,
        messageTypeVariableSameNameAsEnclosing,
        noLength,
        templateConflictsWithMember,
        templateConflictsWithSetter,
        templateConflictsWithTypeVariable,
        templateConstructorWithWrongNameContext,
        templateCouldNotParseUri,
        templateDeferredPrefixDuplicated,
        templateDeferredPrefixDuplicatedCause,
        templateDuplicatedDeclaration,
        templateDuplicatedDeclarationCause,
        templateDuplicatedExport,
        templateDuplicatedExportInType,
        templateDuplicatedImport,
        templateDuplicatedImportInType,
        templateExportHidesExport,
        templateGenericFunctionTypeInferredAsActualTypeArgument,
        templateImportHidesImport,
        templateIncorrectTypeArgument,
        templateIncorrectTypeArgumentInReturnType,
        templateIncorrectTypeArgumentInferred,
        templateIncorrectTypeArgumentQualified,
        templateIncorrectTypeArgumentQualifiedInferred,
        templateIntersectionTypeAsTypeArgument,
        templateLanguageVersionTooHigh,
        templateLoadLibraryHidesMember,
        templateLocalDefinitionHidesExport,
        templateLocalDefinitionHidesImport,
        templateMissingPartOf,
        templateNotAPrefixInTypeAnnotation,
        templatePartOfInLibrary,
        templatePartOfLibraryNameMismatch,
        templatePartOfUriMismatch,
        templatePartOfUseUri,
        templatePartTwice,
        templatePatchInjectionFailed,
        templateTypeVariableDuplicatedNameCause;

import '../import.dart' show Import;

import '../kernel/kernel_builder.dart'
    show
        AccessErrorBuilder,
        BuiltinTypeBuilder,
        ClassBuilder,
        ConstructorReferenceBuilder,
        Builder,
        DynamicTypeBuilder,
        EnumConstantInfo,
        FormalParameterBuilder,
        FunctionTypeBuilder,
        ImplicitFieldType,
        InvalidTypeBuilder,
        ConstructorBuilder,
        EnumBuilder,
        FunctionBuilder,
        TypeAliasBuilder,
        FieldBuilder,
        MixinApplicationBuilder,
        NamedTypeBuilder,
        ProcedureBuilder,
        RedirectingFactoryBuilder,
        LibraryBuilder,
        LoadLibraryBuilder,
        MemberBuilder,
        MetadataBuilder,
        NameIterator,
        PrefixBuilder,
        QualifiedName,
        Scope,
        TypeBuilder,
        TypeDeclarationBuilder,
        TypeVariableBuilder,
        UnresolvedType,
        VoidTypeBuilder,
        compareProcedures,
        toKernelCombinators;

import '../kernel/metadata_collector.dart';

import '../kernel/type_algorithms.dart'
    show
        calculateBounds,
        findGenericFunctionTypes,
        getNonSimplicityIssuesForDeclaration,
        getNonSimplicityIssuesForTypeVariables;

import '../loader.dart' show Loader;

import '../modifier.dart'
    show
        abstractMask,
        constMask,
        finalMask,
        hasConstConstructorMask,
        hasInitializerMask,
        initializingFormalMask,
        mixinDeclarationMask,
        namedMixinApplicationMask,
        staticMask;

import '../names.dart' show indexSetName;

import '../problems.dart' show unexpected, unhandled;

import '../severity.dart' show Severity;

import '../type_inference/type_inferrer.dart' show TypeInferrerImpl;

import 'source_class_builder.dart' show SourceClassBuilder;

import 'source_extension_builder.dart' show SourceExtensionBuilder;

import 'source_loader.dart' show SourceLoader;

class SourceLibraryBuilder extends LibraryBuilder {
  static const String MALFORMED_URI_SCHEME = "org-dartlang-malformed-uri";

  final SourceLoader loader;

  final TypeParameterScopeBuilder libraryDeclaration;

  final List<ConstructorReferenceBuilder> constructorReferences =
      <ConstructorReferenceBuilder>[];

  final List<SourceLibraryBuilder> parts = <SourceLibraryBuilder>[];

  // Can I use library.parts instead? See SourceLibraryBuilder.addPart.
  final List<int> partOffsets = <int>[];

  final List<Import> imports = <Import>[];

  final List<Export> exports = <Export>[];

  final Scope importScope;

  final Uri fileUri;

  final List<ImplementationInfo> implementationBuilders =
      <ImplementationInfo>[];

  final List<Object> accessors = <Object>[];

  final bool legacyMode;

  String documentationComment;

  String name;

  String partOfName;

  Uri partOfUri;

  List<MetadataBuilder> metadata;

  /// The current declaration that is being built. When we start parsing a
  /// declaration (class, method, and so on), we don't have enough information
  /// to create a builder and this object records its members and types until,
  /// for example, [addClass] is called.
  TypeParameterScopeBuilder currentTypeParameterScopeBuilder;

  bool canAddImplementationBuilders = false;

  /// Non-null if this library causes an error upon access, that is, there was
  /// an error reading its source.
  Message accessProblem;

  final Library library;

  final SourceLibraryBuilder actualOrigin;

  final List<FunctionBuilder> nativeMethods = <FunctionBuilder>[];

  final List<TypeVariableBuilder> boundlessTypeVariables =
      <TypeVariableBuilder>[];

  // A list of alternating forwarders and the procedures they were generated
  // for.  Note that it may not include a forwarder-origin pair in cases when
  // the former does not need to be updated after the body of the latter was
  // built.
  final List<Procedure> forwardersOrigins = <Procedure>[];

  // List of types inferred in the outline.  Errors in these should be reported
  // differently than for specified types.
  // TODO(dmitryas):  Find a way to mark inferred types.
  final Set<DartType> inferredTypes = new Set<DartType>.identity();

  // A library to use for Names generated when compiling code in this library.
  // This allows code generated in one library to use the private namespace of
  // another, for example during expression compilation (debugging).
  Library get nameOrigin => _nameOrigin ?? library;
  final Library _nameOrigin;

  /// Exports that can't be serialized.
  ///
  /// The key is the name of the exported member.
  ///
  /// If the name is `dynamic` or `void`, this library reexports the
  /// corresponding type from `dart:core`, and the value is null.
  ///
  /// Otherwise, this represents an error (an ambiguous export). In this case,
  /// the error message is the corresponding value in the map.
  Map<String, String> unserializableExports;

  List<FormalParameterBuilder> untypedInitializingFormals;

  List<FieldBuilder> implicitlyTypedFields;

  bool languageVersionExplicitlySet = false;

  bool postponedProblemsIssued = false;
  List<PostponedProblem> postponedProblems;

  SourceLibraryBuilder.internal(SourceLoader loader, Uri fileUri, Scope scope,
      SourceLibraryBuilder actualOrigin, Library library, Library nameOrigin)
      : this.fromScopes(
            loader,
            fileUri,
            new TypeParameterScopeBuilder.library(),
            scope ?? new Scope.top(),
            actualOrigin,
            library,
            nameOrigin);

  SourceLibraryBuilder.fromScopes(
      this.loader,
      this.fileUri,
      this.libraryDeclaration,
      this.importScope,
      this.actualOrigin,
      this.library,
      this._nameOrigin)
      : currentTypeParameterScopeBuilder = libraryDeclaration,
        legacyMode = loader.target.legacyMode,
        super(
            fileUri, libraryDeclaration.toScope(importScope), new Scope.top());

  SourceLibraryBuilder(
      Uri uri, Uri fileUri, Loader loader, SourceLibraryBuilder actualOrigin,
      {Scope scope, Library target, Library nameOrigin})
      : this.internal(
            loader,
            fileUri,
            scope,
            actualOrigin,
            target ??
                (actualOrigin?.library ?? new Library(uri, fileUri: fileUri)),
            nameOrigin);

  @override
  bool get isPart => partOfName != null || partOfUri != null;

  List<UnresolvedType> get types => libraryDeclaration.types;

  @override
  bool get isSynthetic => accessProblem != null;

  TypeBuilder addType(TypeBuilder type, int charOffset) {
    currentTypeParameterScopeBuilder
        .addType(new UnresolvedType(type, charOffset, fileUri));
    return type;
  }

  @override
  void setLanguageVersion(int major, int minor,
      {int offset: 0, int length: noLength, bool explicit}) {
    if (languageVersionExplicitlySet) return;
    if (explicit) languageVersionExplicitlySet = true;

    if (major == null || minor == null) {
      addPostponedProblem(
          messageLanguageVersionInvalidInDotPackages, offset, length, fileUri);
      return;
    }

    // If no language version has been set, the default is used.
    // If trying to set a langauge version that is higher than the "already-set"
    // version it's an error.
    if (major > library.languageVersionMajor ||
        (major == library.languageVersionMajor &&
            minor > library.languageVersionMinor)) {
      addPostponedProblem(
          templateLanguageVersionTooHigh.withArguments(
              library.languageVersionMajor, library.languageVersionMinor),
          offset,
          length,
          fileUri);
      return;
    }
    library.setLanguageVersion(major, minor);
  }

  ConstructorReferenceBuilder addConstructorReference(Object name,
      List<TypeBuilder> typeArguments, String suffix, int charOffset) {
    ConstructorReferenceBuilder ref = new ConstructorReferenceBuilder(
        name, typeArguments, suffix, this, charOffset);
    constructorReferences.add(ref);
    return ref;
  }

  void beginNestedDeclaration(TypeParameterScopeKind kind, String name,
      {bool hasMembers: true}) {
    currentTypeParameterScopeBuilder =
        currentTypeParameterScopeBuilder.createNested(kind, name, hasMembers);
  }

  TypeParameterScopeBuilder endNestedDeclaration(
      TypeParameterScopeKind kind, String name) {
    assert(
        currentTypeParameterScopeBuilder.kind == kind,
        "Unexpected declaration. "
        "Trying to end a ${currentTypeParameterScopeBuilder.kind} as a $kind.");
    assert(
        (name?.startsWith(currentTypeParameterScopeBuilder.name) ??
                (name == currentTypeParameterScopeBuilder.name)) ||
            currentTypeParameterScopeBuilder.name == "operator" ||
            identical(name, "<syntax-error>"),
        "${name} != ${currentTypeParameterScopeBuilder.name}");
    TypeParameterScopeBuilder previous = currentTypeParameterScopeBuilder;
    currentTypeParameterScopeBuilder = currentTypeParameterScopeBuilder.parent;
    return previous;
  }

  bool uriIsValid(Uri uri) => uri.scheme != MALFORMED_URI_SCHEME;

  Uri resolve(Uri baseUri, String uri, int uriOffset, {isPart: false}) {
    if (uri == null) {
      addProblem(messageExpectedUri, uriOffset, noLength, this.uri);
      return new Uri(scheme: MALFORMED_URI_SCHEME);
    }
    Uri parsedUri;
    try {
      parsedUri = Uri.parse(uri);
    } on FormatException catch (e) {
      // Point to position in string indicated by the exception,
      // or to the initial quote if no position is given.
      // (Assumes the directive is using a single-line string.)
      addProblem(templateCouldNotParseUri.withArguments(uri, e.message),
          uriOffset + 1 + (e.offset ?? -1), 1, this.uri);
      return new Uri(
          scheme: MALFORMED_URI_SCHEME, query: Uri.encodeQueryComponent(uri));
    }
    if (isPart && baseUri.scheme == "dart") {
      // Resolve using special rules for dart: URIs
      return resolveRelativeUri(baseUri, parsedUri);
    } else {
      return baseUri.resolveUri(parsedUri);
    }
  }

  String computeAndValidateConstructorName(Object name, int charOffset,
      {isFactory: false}) {
    String className = currentTypeParameterScopeBuilder.name;
    String prefix;
    String suffix;
    if (name is QualifiedName) {
      prefix = name.qualifier;
      suffix = name.name;
    } else {
      prefix = name;
      suffix = null;
    }
    if (prefix == className) {
      return suffix ?? "";
    }
    if (suffix == null && !isFactory) {
      // A legal name for a regular method, but not for a constructor.
      return null;
    }

    addProblem(
        messageConstructorWithWrongName, charOffset, prefix.length, fileUri,
        context: [
          templateConstructorWithWrongNameContext
              .withArguments(currentTypeParameterScopeBuilder.name)
              .withLocation(uri, currentTypeParameterScopeBuilder.charOffset,
                  currentTypeParameterScopeBuilder.name.length)
        ]);

    return suffix;
  }

  void addExport(
      List<MetadataBuilder> metadata,
      String uri,
      List<Configuration> configurations,
      List<Combinator> combinators,
      int charOffset,
      int uriOffset) {
    if (configurations != null) {
      for (Configuration config in configurations) {
        if (lookupImportCondition(config.dottedName) == config.condition) {
          uri = config.importUri;
          break;
        }
      }
    }

    var exportedLibrary = loader
        .read(resolve(this.uri, uri, uriOffset), charOffset, accessor: this);
    exportedLibrary.addExporter(this, combinators, charOffset);
    exports.add(new Export(this, exportedLibrary, combinators, charOffset));
  }

  String lookupImportCondition(String dottedName) {
    const String prefix = "dart.library.";
    if (!dottedName.startsWith(prefix)) return "";
    dottedName = dottedName.substring(prefix.length);
    if (!loader.target.uriTranslator.isLibrarySupported(dottedName)) return "";

    LibraryBuilder imported =
        loader.builders[new Uri(scheme: "dart", path: dottedName)];

    if (imported == null) {
      LibraryBuilder coreLibrary = loader.read(
          resolve(
              this.uri, new Uri(scheme: "dart", path: "core").toString(), -1),
          -1);
      imported = coreLibrary
          .loader.builders[new Uri(scheme: 'dart', path: dottedName)];
    }
    return imported != null ? "true" : "";
  }

  void addImport(
      List<MetadataBuilder> metadata,
      String uri,
      List<Configuration> configurations,
      String prefix,
      List<Combinator> combinators,
      bool deferred,
      int charOffset,
      int prefixCharOffset,
      int uriOffset,
      int importIndex) {
    if (configurations != null) {
      for (Configuration config in configurations) {
        if (lookupImportCondition(config.dottedName) == config.condition) {
          uri = config.importUri;
          break;
        }
      }
    }

    LibraryBuilder builder = null;

    Uri resolvedUri;
    String nativePath;
    const String nativeExtensionScheme = "dart-ext:";
    if (uri.startsWith(nativeExtensionScheme)) {
      String strippedUri = uri.substring(nativeExtensionScheme.length);
      if (strippedUri.startsWith("package")) {
        resolvedUri = resolve(
            this.uri, strippedUri, uriOffset + nativeExtensionScheme.length);
        resolvedUri = loader.target.translateUri(resolvedUri);
        nativePath = resolvedUri.toString();
      } else {
        resolvedUri = new Uri(scheme: "dart-ext", pathSegments: [uri]);
        nativePath = uri;
      }
    } else {
      resolvedUri = resolve(this.uri, uri, uriOffset);
      builder = loader.read(resolvedUri, uriOffset, accessor: this);
    }

    imports.add(new Import(this, builder, deferred, prefix, combinators,
        configurations, charOffset, prefixCharOffset, importIndex,
        nativeImportPath: nativePath));
  }

  void addPart(List<MetadataBuilder> metadata, String uri, int charOffset) {
    Uri resolvedUri;
    Uri newFileUri;
    resolvedUri = resolve(this.uri, uri, charOffset, isPart: true);
    newFileUri = resolve(fileUri, uri, charOffset);
    parts.add(loader.read(resolvedUri, charOffset,
        fileUri: newFileUri, accessor: this));
    partOffsets.add(charOffset);

    // TODO(ahe): [metadata] should be stored, evaluated, and added to [part].
    LibraryPart part = new LibraryPart(<Expression>[], uri)
      ..fileOffset = charOffset;
    library.addPart(part);
  }

  void addPartOf(
      List<MetadataBuilder> metadata, String name, String uri, int uriOffset) {
    partOfName = name;
    if (uri != null) {
      partOfUri = resolve(this.uri, uri, uriOffset);
      Uri newFileUri = resolve(fileUri, uri, uriOffset);
      LibraryBuilder library = loader.read(partOfUri, uriOffset,
          fileUri: newFileUri, accessor: this);
      if (loader.first == this) {
        // This is a part, and it was the first input. Let the loader know
        // about that.
        loader.first = library;
      }
    }
  }

  void addFields(String documentationComment, List<MetadataBuilder> metadata,
      int modifiers, TypeBuilder type, List<FieldInfo> fieldInfos) {
    for (FieldInfo info in fieldInfos) {
      bool isConst = modifiers & constMask != 0;
      bool isFinal = modifiers & finalMask != 0;
      bool potentiallyNeedInitializerInOutline = isConst || isFinal;
      Token startToken;
      if (potentiallyNeedInitializerInOutline ||
          (type == null && !legacyMode)) {
        startToken = info.initializerToken;
      }
      if (startToken != null) {
        // Extract only the tokens for the initializer expression from the
        // token stream.
        Token endToken = info.beforeLast;
        endToken.setNext(new Token.eof(endToken.next.offset));
        new Token.eof(startToken.previous.offset).setNext(startToken);
      }
      bool hasInitializer = info.initializerToken != null;
      addField(documentationComment, metadata, modifiers, type, info.name,
          info.charOffset, info.charEndOffset, startToken, hasInitializer,
          constInitializerToken:
              potentiallyNeedInitializerInOutline ? startToken : null);
    }
  }

  Builder addBuilder(String name, Builder declaration, int charOffset) {
    // TODO(ahe): Set the parent correctly here. Could then change the
    // implementation of MemberBuilder.isTopLevel to test explicitly for a
    // LibraryBuilder.
    if (name == null) {
      unhandled("null", "name", charOffset, fileUri);
    }
    if (currentTypeParameterScopeBuilder == libraryDeclaration) {
      if (declaration is MemberBuilder) {
        declaration.parent = this;
      } else if (declaration is TypeDeclarationBuilder) {
        declaration.parent = this;
      } else if (declaration is PrefixBuilder) {
        assert(declaration.parent == this);
      } else {
        return unhandled(
            "${declaration.runtimeType}", "addBuilder", charOffset, fileUri);
      }
    } else {
      assert(currentTypeParameterScopeBuilder.parent == libraryDeclaration);
    }
    bool isConstructor = declaration is FunctionBuilder &&
        (declaration.isConstructor || declaration.isFactory);
    if (!isConstructor && name == currentTypeParameterScopeBuilder.name) {
      addProblem(
          messageMemberWithSameNameAsClass, charOffset, noLength, fileUri);
    }
    Map<String, Builder> members = isConstructor
        ? currentTypeParameterScopeBuilder.constructors
        : (declaration.isSetter
            ? currentTypeParameterScopeBuilder.setters
            : currentTypeParameterScopeBuilder.members);
    Builder existing = members[name];
    if (declaration.next != null && declaration.next != existing) {
      unexpected(
          "${declaration.next.fileUri}@${declaration.next.charOffset}",
          "${existing?.fileUri}@${existing?.charOffset}",
          declaration.charOffset,
          declaration.fileUri);
    }
    declaration.next = existing;
    if (declaration is PrefixBuilder && existing is PrefixBuilder) {
      assert(existing.next is! PrefixBuilder);
      Builder deferred;
      Builder other;
      if (declaration.deferred) {
        deferred = declaration;
        other = existing;
      } else if (existing.deferred) {
        deferred = existing;
        other = declaration;
      }
      if (deferred != null) {
        addProblem(templateDeferredPrefixDuplicated.withArguments(name),
            deferred.charOffset, noLength, fileUri,
            context: [
              templateDeferredPrefixDuplicatedCause
                  .withArguments(name)
                  .withLocation(fileUri, other.charOffset, noLength)
            ]);
      }
      return existing
        ..exportScope.merge(declaration.exportScope,
            (String name, Builder existing, Builder member) {
          return computeAmbiguousDeclaration(
              name, existing, member, charOffset);
        });
    } else if (isDuplicatedDeclaration(existing, declaration)) {
      String fullName = name;
      if (isConstructor) {
        if (name.isEmpty) {
          fullName = currentTypeParameterScopeBuilder.name;
        } else {
          fullName = "${currentTypeParameterScopeBuilder.name}.$name";
        }
      }
      addProblem(templateDuplicatedDeclaration.withArguments(fullName),
          charOffset, fullName.length, declaration.fileUri,
          context: <LocatedMessage>[
            templateDuplicatedDeclarationCause
                .withArguments(fullName)
                .withLocation(
                    existing.fileUri, existing.charOffset, fullName.length)
          ]);
    }
    return members[name] = declaration;
  }

  bool isDuplicatedDeclaration(Builder existing, Builder other) {
    if (existing == null) return false;
    Builder next = existing.next;
    if (next == null) {
      if (existing.isGetter && other.isSetter) return false;
      if (existing.isSetter && other.isGetter) return false;
    } else {
      if (next is ClassBuilder && !next.isMixinApplication) return true;
    }
    if (existing is ClassBuilder && other is ClassBuilder) {
      // We allow multiple mixin applications with the same name. An
      // alternative is to share these mixin applications. This situation can
      // happen if you have `class A extends Object with Mixin {}` and `class B
      // extends Object with Mixin {}` in the same library.
      return !existing.isMixinApplication || !other.isMixinApplication;
    }
    return true;
  }

  Library build(LibraryBuilder coreLibrary, {bool modifyTarget}) {
    assert(implementationBuilders.isEmpty);
    canAddImplementationBuilders = true;
    Iterator<Builder> iterator = this.iterator;
    while (iterator.moveNext()) {
      buildBuilder(iterator.current, coreLibrary);
    }
    for (ImplementationInfo info in implementationBuilders) {
      String name = info.name;
      Builder declaration = info.declaration;
      int charOffset = info.charOffset;
      addBuilder(name, declaration, charOffset);
      buildBuilder(declaration, coreLibrary);
    }
    canAddImplementationBuilders = false;

    scope.setters.forEach((String name, Builder setter) {
      Builder member = scopeBuilder[name];
      if (member == null ||
          !member.isField ||
          member.isFinal ||
          member.isConst) {
        return;
      }
      addProblem(templateConflictsWithMember.withArguments(name),
          setter.charOffset, noLength, fileUri);
      // TODO(ahe): Context to previous message?
      addProblem(templateConflictsWithSetter.withArguments(name),
          member.charOffset, noLength, fileUri);
    });

    if (modifyTarget == false) return library;

    library.isSynthetic = isSynthetic;
    addDependencies(library, new Set<SourceLibraryBuilder>());

    loader.target.metadataCollector
        ?.setDocumentationComment(library, documentationComment);

    library.name = name;
    library.procedures.sort(compareProcedures);

    if (unserializableExports != null) {
      library.addMember(new Field(new Name("_exports#", library),
          initializer: new StringLiteral(jsonEncode(unserializableExports)),
          isStatic: true,
          isConst: true));
    }

    return library;
  }

  /// Used to add implementation builder during the call to [build] above.
  /// Currently, only anonymous mixins are using implementation builders (see
  /// [MixinApplicationBuilder]
  /// (../kernel/kernel_mixin_application_builder.dart)).
  void addImplementationBuilder(
      String name, Builder declaration, int charOffset) {
    assert(canAddImplementationBuilders, "$uri");
    implementationBuilders
        .add(new ImplementationInfo(name, declaration, charOffset));
  }

  void validatePart(SourceLibraryBuilder library, Set<Uri> usedParts) {
    if (library != null && parts.isNotEmpty) {
      // If [library] is null, we have already reported a problem that this
      // part is orphaned.
      List<LocatedMessage> context = <LocatedMessage>[
        messagePartInPartLibraryContext.withLocation(library.fileUri, -1, 1),
      ];
      for (int offset in partOffsets) {
        addProblem(messagePartInPart, offset, noLength, fileUri,
            context: context);
      }
      for (SourceLibraryBuilder part in parts) {
        // Mark this part as used so we don't report it as orphaned.
        usedParts.add(part.uri);
      }
    }
    parts.clear();
    if (exporters.isNotEmpty) {
      List<LocatedMessage> context = <LocatedMessage>[
        messagePartExportContext.withLocation(fileUri, -1, 1),
      ];
      for (Export export in exporters) {
        export.exporter.addProblem(
            messagePartExport, export.charOffset, "export".length, null,
            context: context);
      }
    }
  }

  void includeParts(Set<Uri> usedParts) {
    Set<Uri> seenParts = new Set<Uri>();
    for (int i = 0; i < parts.length; i++) {
      SourceLibraryBuilder part = parts[i];
      int partOffset = partOffsets[i];
      if (part == this) {
        addProblem(messagePartOfSelf, -1, noLength, fileUri);
      } else if (seenParts.add(part.fileUri)) {
        if (part.partOfLibrary != null) {
          addProblem(messagePartOfTwoLibraries, -1, noLength, part.fileUri,
              context: [
                messagePartOfTwoLibrariesContext.withLocation(
                    part.partOfLibrary.fileUri, -1, noLength),
                messagePartOfTwoLibrariesContext.withLocation(
                    this.fileUri, -1, noLength)
              ]);
        } else {
          if (isPatch) {
            usedParts.add(part.fileUri);
          } else {
            usedParts.add(part.uri);
          }
          includePart(part, usedParts, partOffset);
        }
      } else {
        addProblem(templatePartTwice.withArguments(part.fileUri), -1, noLength,
            fileUri);
      }
    }
  }

  bool includePart(
      SourceLibraryBuilder part, Set<Uri> usedParts, int partOffset) {
    if (part.partOfUri != null) {
      if (uriIsValid(part.partOfUri) && part.partOfUri != uri) {
        // This is an error, but the part is not removed from the list of parts,
        // so that metadata annotations can be associated with it.
        addProblem(
            templatePartOfUriMismatch.withArguments(
                part.fileUri, uri, part.partOfUri),
            partOffset,
            noLength,
            fileUri);
        return false;
      }
    } else if (part.partOfName != null) {
      if (name != null) {
        if (part.partOfName != name) {
          // This is an error, but the part is not removed from the list of
          // parts, so that metadata annotations can be associated with it.
          addProblem(
              templatePartOfLibraryNameMismatch.withArguments(
                  part.fileUri, name, part.partOfName),
              partOffset,
              noLength,
              fileUri);
          return false;
        }
      } else {
        // This is an error, but the part is not removed from the list of parts,
        // so that metadata annotations can be associated with it.
        addProblem(
            templatePartOfUseUri.withArguments(
                part.fileUri, fileUri, part.partOfName),
            partOffset,
            noLength,
            fileUri);
        return false;
      }
    } else {
      // This is an error, but the part is not removed from the list of parts,
      // so that metadata annotations can be associated with it.
      assert(!part.isPart);
      if (uriIsValid(part.fileUri)) {
        addProblem(templateMissingPartOf.withArguments(part.fileUri),
            partOffset, noLength, fileUri);
      }
      return false;
    }

    // Language versions have to match.
    if ((this.languageVersionExplicitlySet !=
            part.languageVersionExplicitlySet) ||
        (this.library.languageVersionMajor !=
                part.library.languageVersionMajor ||
            this.library.languageVersionMinor !=
                part.library.languageVersionMinor)) {
      // This is an error, but the part is not removed from the list of
      // parts, so that metadata annotations can be associated with it.
      addProblem(
          messageLanguageVersionMismatchInPart, partOffset, noLength, fileUri);
      return false;
    }

    part.validatePart(this, usedParts);
    NameIterator partDeclarations = part.nameIterator;
    while (partDeclarations.moveNext()) {
      String name = partDeclarations.name;
      Builder declaration = partDeclarations.current;

      if (declaration.next != null) {
        List<Builder> duplicated = <Builder>[];
        while (declaration.next != null) {
          duplicated.add(declaration);
          partDeclarations.moveNext();
          declaration = partDeclarations.current;
        }
        duplicated.add(declaration);
        // Handle duplicated declarations in the part.
        //
        // Duplicated declarations are handled by creating a linked list using
        // the `next` field. This is preferred over making all scope entries be
        // a `List<Declaration>`.
        //
        // We maintain the linked list so that the last entry is easy to
        // recognize (it's `next` field is null). This means that it is
        // reversed with respect to source code order. Since kernel doesn't
        // allow duplicated declarations, we ensure that we only add the first
        // declaration to the kernel tree.
        //
        // Since the duplicated declarations are stored in reverse order, we
        // iterate over them in reverse order as this is simpler and normally
        // not a problem. However, in this case we need to call [addBuilder] in
        // source order as it would otherwise create cycles.
        //
        // We also need to be careful preserving the order of the links. The
        // part library still keeps these declarations in its scope so that
        // DietListener can find them.
        for (int i = duplicated.length; i > 0; i--) {
          Builder declaration = duplicated[i - 1];
          addBuilder(name, declaration, declaration.charOffset);
        }
      } else {
        addBuilder(name, declaration, declaration.charOffset);
      }
    }
    types.addAll(part.types);
    constructorReferences.addAll(part.constructorReferences);
    part.partOfLibrary = this;
    part.scope.becomePartOf(scope);
    // TODO(ahe): Include metadata from part?

    nativeMethods.addAll(part.nativeMethods);
    boundlessTypeVariables.addAll(part.boundlessTypeVariables);
    // Check that the targets are different. This is not normally a problem
    // but is for patch files.
    if (target != part.target && part.target.problemsAsJson != null) {
      target.problemsAsJson ??= <String>[];
      target.problemsAsJson.addAll(part.target.problemsAsJson);
    }
    List<FieldBuilder> partImplicitlyTypedFields =
        part.takeImplicitlyTypedFields();
    if (partImplicitlyTypedFields != null) {
      if (implicitlyTypedFields == null) {
        implicitlyTypedFields = partImplicitlyTypedFields;
      } else {
        implicitlyTypedFields.addAll(partImplicitlyTypedFields);
      }
    }
    return true;
  }

  void buildInitialScopes() {
    NameIterator iterator = nameIterator;
    while (iterator.moveNext()) {
      addToExportScope(iterator.name, iterator.current);
    }
  }

  void addImportsToScope() {
    bool explicitCoreImport = this == loader.coreLibrary;
    for (Import import in imports) {
      if (import.imported == loader.coreLibrary) {
        explicitCoreImport = true;
      }
      if (import.imported?.isPart ?? false) {
        addProblem(
            templatePartOfInLibrary.withArguments(import.imported.fileUri),
            import.charOffset,
            noLength,
            fileUri);
      }
      import.finalizeImports(this);
    }
    if (!explicitCoreImport) {
      loader.coreLibrary.exportScope.forEach((String name, Builder member) {
        addToScope(name, member, -1, true);
      });
    }

    exportScope.forEach((String name, Builder member) {
      if (member.parent != this) {
        switch (name) {
          case "dynamic":
          case "void":
            unserializableExports ??= <String, String>{};
            unserializableExports[name] = null;
            break;

          default:
            if (member is InvalidTypeBuilder) {
              unserializableExports ??= <String, String>{};
              unserializableExports[name] = member.message.message;
            } else {
              // Eventually (in #buildBuilder) members aren't added to the
              // library if the have 'next' pointers, so don't add them as
              // additionalExports either. Add the last one only (the one that
              // will eventually be added to the library).
              Builder memberLast = member;
              while (memberLast.next != null) memberLast = memberLast.next;
              library.additionalExports.add(memberLast.target.reference);
            }
        }
      }
    });
  }

  @override
  void addToScope(String name, Builder member, int charOffset, bool isImport) {
    Map<String, Builder> map =
        member.isSetter ? importScope.setters : importScope.local;
    Builder existing = map[name];
    if (existing != null) {
      if (existing != member) {
        map[name] = computeAmbiguousDeclaration(
            name, existing, member, charOffset,
            isImport: isImport);
      }
    } else {
      map[name] = member;
    }
  }

  /// Resolves all unresolved types in [types]. The list of types is cleared
  /// when done.
  int resolveTypes() {
    int typeCount = types.length;
    for (UnresolvedType t in types) {
      t.resolveIn(scope, this);
      if (!loader.target.legacyMode) {
        t.checkType(this);
      } else {
        t.normalizeType();
      }
    }
    types.clear();
    return typeCount;
  }

  @override
  int resolveConstructors(_) {
    int count = 0;
    Iterator<Builder> iterator = this.iterator;
    while (iterator.moveNext()) {
      count += iterator.current.resolveConstructors(this);
    }
    return count;
  }

  @override
  String get fullNameForErrors {
    // TODO(ahe): Consider if we should use relativizeUri here. The downside to
    // doing that is that this URI may be used in an error message. Ideally, we
    // should create a class that represents qualified names that we can
    // relativize when printing a message, but still store the full URI in
    // .dill files.
    return name ?? "<library '$fileUri'>";
  }

  @override
  void recordAccess(int charOffset, int length, Uri fileUri) {
    accessors.add(fileUri);
    accessors.add(charOffset);
    accessors.add(length);
    if (accessProblem != null) {
      addProblem(accessProblem, charOffset, length, fileUri);
    }
  }

  void addProblemAtAccessors(Message message) {
    if (accessProblem == null) {
      if (accessors.isEmpty && this == loader.first) {
        // This is the entry point library, and nobody access it directly. So
        // we need to report a problem.
        loader.addProblem(message, -1, 1, null);
      }
      for (int i = 0; i < accessors.length; i += 3) {
        Uri accessor = accessors[i];
        int charOffset = accessors[i + 1];
        int length = accessors[i + 2];
        addProblem(message, charOffset, length, accessor);
      }
      accessProblem = message;
    }
  }

  @override
  SourceLibraryBuilder get origin => actualOrigin ?? this;

  @override
  Library get target => library;

  Uri get uri => library.importUri;

  void addSyntheticDeclarationOfDynamic() {
    addBuilder(
        "dynamic", new DynamicTypeBuilder(const DynamicType(), this, -1), -1);
  }

  TypeBuilder addNamedType(
      Object name, List<TypeBuilder> arguments, int charOffset) {
    return addType(new NamedTypeBuilder(name, arguments), charOffset);
  }

  TypeBuilder addMixinApplication(
      TypeBuilder supertype, List<TypeBuilder> mixins, int charOffset) {
    return addType(new MixinApplicationBuilder(supertype, mixins), charOffset);
  }

  TypeBuilder addVoidType(int charOffset) {
    return addNamedType("void", null, charOffset)
      ..bind(new VoidTypeBuilder(const VoidType(), this, charOffset));
  }

  /// Add a problem that might not be reported immediately.
  ///
  /// Problems will be issued after source information has been added.
  /// Once the problems has been issued, adding a new "postponed" problem will
  /// be issued immediately.
  void addPostponedProblem(
      Message message, int charOffset, int length, Uri fileUri) {
    if (postponedProblemsIssued) {
      addProblem(message, charOffset, length, fileUri);
    } else {
      postponedProblems ??= <PostponedProblem>[];
      postponedProblems
          .add(new PostponedProblem(message, charOffset, length, fileUri));
    }
  }

  void issuePostponedProblems() {
    postponedProblemsIssued = true;
    if (postponedProblems == null) return;
    for (int i = 0; i < postponedProblems.length; ++i) {
      PostponedProblem postponedProblem = postponedProblems[i];
      addProblem(postponedProblem.message, postponedProblem.charOffset,
          postponedProblem.length, postponedProblem.fileUri);
    }
    postponedProblems = null;
  }

  @override
  FormattedMessage addProblem(
      Message message, int charOffset, int length, Uri fileUri,
      {bool wasHandled: false,
      List<LocatedMessage> context,
      Severity severity,
      bool problemOnLibrary: false}) {
    FormattedMessage formattedMessage = super.addProblem(
        message, charOffset, length, fileUri,
        wasHandled: wasHandled,
        context: context,
        severity: severity,
        problemOnLibrary: true);
    if (formattedMessage != null) {
      target.problemsAsJson ??= <String>[];
      target.problemsAsJson.add(formattedMessage.toJsonString());
    }
    return formattedMessage;
  }

  void addClass(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      String className,
      List<TypeVariableBuilder> typeVariables,
      TypeBuilder supertype,
      List<TypeBuilder> interfaces,
      int startOffset,
      int nameOffset,
      int endOffset,
      int supertypeOffset) {
    _addClass(
        TypeParameterScopeKind.classDeclaration,
        documentationComment,
        metadata,
        modifiers,
        className,
        typeVariables,
        supertype,
        interfaces,
        startOffset,
        nameOffset,
        endOffset,
        supertypeOffset);
  }

  void addMixinDeclaration(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      String className,
      List<TypeVariableBuilder> typeVariables,
      TypeBuilder supertype,
      List<TypeBuilder> interfaces,
      int startOffset,
      int nameOffset,
      int endOffset,
      int supertypeOffset) {
    _addClass(
        TypeParameterScopeKind.mixinDeclaration,
        documentationComment,
        metadata,
        modifiers,
        className,
        typeVariables,
        supertype,
        interfaces,
        startOffset,
        nameOffset,
        endOffset,
        supertypeOffset);
  }

  void _addClass(
      TypeParameterScopeKind kind,
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      String className,
      List<TypeVariableBuilder> typeVariables,
      TypeBuilder supertype,
      List<TypeBuilder> interfaces,
      int startOffset,
      int nameOffset,
      int endOffset,
      int supertypeOffset) {
    // Nested declaration began in `OutlineBuilder.beginClassDeclaration`.
    TypeParameterScopeBuilder declaration =
        endNestedDeclaration(kind, className)
          ..resolveTypes(typeVariables, this);
    assert(declaration.parent == libraryDeclaration);
    Map<String, MemberBuilder> members = declaration.members;
    Map<String, MemberBuilder> constructors = declaration.constructors;
    Map<String, MemberBuilder> setters = declaration.setters;

    Scope classScope = new Scope(members, setters,
        scope.withTypeVariables(typeVariables), "class $className",
        isModifiable: false);

    // When looking up a constructor, we don't consider type variables or the
    // library scope.
    Scope constructorScope =
        new Scope(constructors, null, null, className, isModifiable: false);
    bool isMixinDeclaration = false;
    if (modifiers & mixinDeclarationMask != 0) {
      isMixinDeclaration = true;
      modifiers = (modifiers & ~mixinDeclarationMask) | abstractMask;
    }
    if (declaration.hasConstConstructor) {
      modifiers |= hasConstConstructorMask;
    }
    ClassBuilder cls = new SourceClassBuilder(
        metadata,
        modifiers,
        className,
        typeVariables,
        applyMixins(supertype, startOffset, nameOffset, endOffset, className,
            isMixinDeclaration,
            typeVariables: typeVariables),
        interfaces,
        // TODO(johnniwinther): Add the `on` clause types of a mixin declaration
        // here.
        null,
        classScope,
        constructorScope,
        this,
        new List<ConstructorReferenceBuilder>.from(constructorReferences),
        startOffset,
        nameOffset,
        endOffset,
        isMixinDeclaration: isMixinDeclaration);
    loader.target.metadataCollector
        ?.setDocumentationComment(cls.target, documentationComment);

    constructorReferences.clear();
    Map<String, TypeVariableBuilder> typeVariablesByName =
        checkTypeVariables(typeVariables, cls);
    void setParent(String name, MemberBuilder member) {
      while (member != null) {
        member.parent = cls;
        member = member.next;
      }
    }

    void setParentAndCheckConflicts(String name, MemberBuilder member) {
      if (typeVariablesByName != null) {
        TypeVariableBuilder tv = typeVariablesByName[name];
        if (tv != null) {
          cls.addProblem(templateConflictsWithTypeVariable.withArguments(name),
              member.charOffset, name.length,
              context: [
                messageConflictsWithTypeVariableCause.withLocation(
                    tv.fileUri, tv.charOffset, name.length)
              ]);
        }
      }
      setParent(name, member);
    }

    members.forEach(setParentAndCheckConflicts);
    constructors.forEach(setParentAndCheckConflicts);
    setters.forEach(setParentAndCheckConflicts);
    addBuilder(className, cls, nameOffset);
  }

  Map<String, TypeVariableBuilder> checkTypeVariables(
      List<TypeVariableBuilder> typeVariables, Builder owner) {
    if (typeVariables?.isEmpty ?? true) return null;
    Map<String, TypeVariableBuilder> typeVariablesByName =
        <String, TypeVariableBuilder>{};
    for (TypeVariableBuilder tv in typeVariables) {
      TypeVariableBuilder existing = typeVariablesByName[tv.name];
      if (existing != null) {
        addProblem(messageTypeVariableDuplicatedName, tv.charOffset,
            tv.name.length, fileUri,
            context: [
              templateTypeVariableDuplicatedNameCause
                  .withArguments(tv.name)
                  .withLocation(
                      fileUri, existing.charOffset, existing.name.length)
            ]);
      } else {
        typeVariablesByName[tv.name] = tv;
        if (owner is ClassBuilder) {
          // Only classes and type variables can't have the same name. See
          // [#29555](https://github.com/dart-lang/sdk/issues/29555).
          if (tv.name == owner.name) {
            addProblem(messageTypeVariableSameNameAsEnclosing, tv.charOffset,
                tv.name.length, fileUri);
          }
        }
      }
    }
    return typeVariablesByName;
  }

  void addExtensionDeclaration(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      String extensionName,
      List<TypeVariableBuilder> typeVariables,
      TypeBuilder type,
      int startOffset,
      int nameOffset,
      int endOffset) {
    // Nested declaration began in `OutlineBuilder.beginExtensionDeclaration`.
    TypeParameterScopeBuilder declaration = endNestedDeclaration(
        TypeParameterScopeKind.extensionDeclaration, extensionName)
      ..resolveTypes(typeVariables, this);
    assert(declaration.parent == libraryDeclaration);
    Map<String, MemberBuilder> members = declaration.members;
    Map<String, MemberBuilder> constructors = declaration.constructors;
    Map<String, MemberBuilder> setters = declaration.setters;

    Scope classScope = new Scope(members, setters,
        scope.withTypeVariables(typeVariables), "extension $extensionName",
        isModifiable: false);

    ExtensionBuilder extension = new SourceExtensionBuilder(
        metadata,
        modifiers,
        extensionName,
        typeVariables,
        type,
        classScope,
        this,
        startOffset,
        nameOffset,
        endOffset);
    loader.target.metadataCollector
        ?.setDocumentationComment(extension.target, documentationComment);

    constructorReferences.clear();
    Map<String, TypeVariableBuilder> typeVariablesByName =
        checkTypeVariables(typeVariables, extension);
    void setParent(String name, MemberBuilder member) {
      while (member != null) {
        member.parent = extension;
        member = member.next;
      }
    }

    void setParentAndCheckConflicts(String name, MemberBuilder member) {
      if (typeVariablesByName != null) {
        TypeVariableBuilder tv = typeVariablesByName[name];
        if (tv != null) {
          extension.addProblem(
              templateConflictsWithTypeVariable.withArguments(name),
              member.charOffset,
              name.length,
              context: [
                messageConflictsWithTypeVariableCause.withLocation(
                    tv.fileUri, tv.charOffset, name.length)
              ]);
        }
      }
      setParent(name, member);
    }

    members.forEach(setParentAndCheckConflicts);
    constructors.forEach(setParentAndCheckConflicts);
    setters.forEach(setParentAndCheckConflicts);
    addBuilder(extensionName, extension, nameOffset);
  }

  TypeBuilder applyMixins(TypeBuilder type, int startCharOffset, int charOffset,
      int charEndOffset, String subclassName, bool isMixinDeclaration,
      {String documentationComment,
      List<MetadataBuilder> metadata,
      String name,
      List<TypeVariableBuilder> typeVariables,
      int modifiers,
      List<TypeBuilder> interfaces}) {
    if (name == null) {
      // The following parameters should only be used when building a named
      // mixin application.
      if (documentationComment != null) {
        unhandled("documentationComment", "unnamed mixin application",
            charOffset, fileUri);
      } else if (metadata != null) {
        unhandled("metadata", "unnamed mixin application", charOffset, fileUri);
      } else if (interfaces != null) {
        unhandled(
            "interfaces", "unnamed mixin application", charOffset, fileUri);
      }
    }
    if (type is MixinApplicationBuilder) {
      // Documentation below assumes the given mixin application is in one of
      // these forms:
      //
      //     class C extends S with M1, M2, M3;
      //     class Named = S with M1, M2, M3;
      //
      // When we refer to the subclass, we mean `C` or `Named`.

      /// The current supertype.
      ///
      /// Starts out having the value `S` and on each iteration of the loop
      /// below, it will take on the value corresponding to:
      ///
      /// 1. `S with M1`.
      /// 2. `(S with M1) with M2`.
      /// 3. `((S with M1) with M2) with M3`.
      TypeBuilder supertype = type.supertype ?? loader.target.objectType;

      /// The variable part of the mixin application's synthetic name. It
      /// starts out as the name of the superclass, but is only used after it
      /// has been combined with the name of the current mixin. In the examples
      /// from above, it will take these values:
      ///
      /// 1. `S&M1`
      /// 2. `S&M1&M2`
      /// 3. `S&M1&M2&M3`.
      ///
      /// The full name of the mixin application is obtained by prepending the
      /// name of the subclass (`C` or `Named` in the above examples) to the
      /// running name. For the example `C`, that leads to these full names:
      ///
      /// 1. `_C&S&M1`
      /// 2. `_C&S&M1&M2`
      /// 3. `_C&S&M1&M2&M3`.
      ///
      /// For a named mixin application, the last name has been given by the
      /// programmer, so for the example `Named` we see these full names:
      ///
      /// 1. `_Named&S&M1`
      /// 2. `_Named&S&M1&M2`
      /// 3. `Named`.
      String runningName = extractName(supertype.name);

      /// True when we're building a named mixin application. Notice that for
      /// the `Named` example above, this is only true on the last
      /// iteration because only the full mixin application is named.
      bool isNamedMixinApplication;

      /// The names of the type variables of the subclass.
      Set<String> typeVariableNames;
      if (typeVariables != null) {
        typeVariableNames = new Set<String>();
        for (TypeVariableBuilder typeVariable in typeVariables) {
          typeVariableNames.add(typeVariable.name);
        }
      }

      /// Helper function that returns `true` if a type variable with a name
      /// from [typeVariableNames] is referenced in [type].
      bool usesTypeVariables(TypeBuilder type) {
        if (type is NamedTypeBuilder) {
          if (type.declaration is TypeVariableBuilder) {
            return typeVariableNames.contains(type.declaration.name);
          }

          List<TypeBuilder> typeArguments = type.arguments;
          if (typeArguments != null && typeVariables != null) {
            for (TypeBuilder argument in typeArguments) {
              if (usesTypeVariables(argument)) {
                return true;
              }
            }
          }
        } else if (type is FunctionTypeBuilder) {
          if (type.formals != null) {
            for (FormalParameterBuilder formal in type.formals) {
              if (usesTypeVariables(formal.type)) {
                return true;
              }
            }
          }
          return usesTypeVariables(type.returnType);
        }
        return false;
      }

      /// Iterate over the mixins from left to right. At the end of each
      /// iteration, a new [supertype] is computed that is the mixin
      /// application of [supertype] with the current mixin.
      for (int i = 0; i < type.mixins.length; i++) {
        TypeBuilder mixin = type.mixins[i];
        isNamedMixinApplication = name != null && mixin == type.mixins.last;
        bool isGeneric = false;
        if (!isNamedMixinApplication) {
          if (supertype is NamedTypeBuilder) {
            isGeneric = isGeneric || usesTypeVariables(supertype);
          }
          if (mixin is NamedTypeBuilder) {
            runningName += "&${extractName(mixin.name)}";
            isGeneric = isGeneric || usesTypeVariables(mixin);
          }
        }
        String fullname =
            isNamedMixinApplication ? name : "_$subclassName&$runningName";
        List<TypeVariableBuilder> applicationTypeVariables;
        List<TypeBuilder> applicationTypeArguments;
        if (isNamedMixinApplication) {
          // If this is a named mixin application, it must be given all the
          // declarated type variables.
          applicationTypeVariables = typeVariables;
        } else {
          // Otherwise, we pass the fresh type variables to the mixin
          // application in the same order as they're declared on the subclass.
          if (isGeneric) {
            this.beginNestedDeclaration(
                TypeParameterScopeKind.unnamedMixinApplication,
                "mixin application");

            applicationTypeVariables = copyTypeVariables(
                typeVariables, currentTypeParameterScopeBuilder);

            List<TypeBuilder> newTypes = <TypeBuilder>[];
            if (supertype is NamedTypeBuilder && supertype.arguments != null) {
              for (int i = 0; i < supertype.arguments.length; ++i) {
                supertype.arguments[i] = supertype.arguments[i].clone(newTypes);
              }
            }
            if (mixin is NamedTypeBuilder && mixin.arguments != null) {
              for (int i = 0; i < mixin.arguments.length; ++i) {
                mixin.arguments[i] = mixin.arguments[i].clone(newTypes);
              }
            }
            for (TypeBuilder newType in newTypes) {
              currentTypeParameterScopeBuilder
                  .addType(new UnresolvedType(newType, -1, null));
            }

            TypeParameterScopeBuilder mixinDeclaration = this
                .endNestedDeclaration(
                    TypeParameterScopeKind.unnamedMixinApplication,
                    "mixin application");
            mixinDeclaration.resolveTypes(applicationTypeVariables, this);

            applicationTypeArguments = <TypeBuilder>[];
            for (TypeVariableBuilder typeVariable in typeVariables) {
              applicationTypeArguments
                  .add(addNamedType(typeVariable.name, null, charOffset)..bind(
                      // The type variable types passed as arguments to the
                      // generic class representing the anonymous mixin
                      // application should refer back to the type variables of
                      // the class that extend the anonymous mixin application.
                      typeVariable));
            }
          }
        }
        final int computedStartCharOffset =
            (isNamedMixinApplication ? metadata : null) == null
                ? startCharOffset
                : metadata.first.charOffset;
        SourceClassBuilder application = new SourceClassBuilder(
            isNamedMixinApplication ? metadata : null,
            isNamedMixinApplication
                ? modifiers | namedMixinApplicationMask
                : abstractMask,
            fullname,
            applicationTypeVariables,
            isMixinDeclaration ? null : supertype,
            isNamedMixinApplication
                ? interfaces
                : isMixinDeclaration ? [supertype, mixin] : null,
            null, // No `on` clause types.
            new Scope(<String, MemberBuilder>{}, <String, MemberBuilder>{},
                scope.withTypeVariables(typeVariables),
                "mixin $fullname ", isModifiable: false),
            new Scope(<String, MemberBuilder>{}, null, null, fullname,
                isModifiable: false),
            this,
            <ConstructorReferenceBuilder>[],
            computedStartCharOffset,
            charOffset,
            charEndOffset,
            mixedInType: isMixinDeclaration ? null : mixin);
        if (isNamedMixinApplication) {
          loader.target.metadataCollector?.setDocumentationComment(
              application.target, documentationComment);
        }
        // TODO(ahe, kmillikin): Should always be true?
        // pkg/analyzer/test/src/summary/resynthesize_kernel_test.dart can't
        // handle that :(
        application.cls.isAnonymousMixin = !isNamedMixinApplication;
        addBuilder(fullname, application, charOffset);
        supertype =
            addNamedType(fullname, applicationTypeArguments, charOffset);
      }
      return supertype;
    } else {
      return type;
    }
  }

  void addNamedMixinApplication(
      String documentationComment,
      List<MetadataBuilder> metadata,
      String name,
      List<TypeVariableBuilder> typeVariables,
      int modifiers,
      TypeBuilder mixinApplication,
      List<TypeBuilder> interfaces,
      int startCharOffset,
      int charOffset,
      int charEndOffset) {
    // Nested declaration began in `OutlineBuilder.beginNamedMixinApplication`.
    endNestedDeclaration(TypeParameterScopeKind.namedMixinApplication, name)
        .resolveTypes(typeVariables, this);
    NamedTypeBuilder supertype = applyMixins(mixinApplication, startCharOffset,
        charOffset, charEndOffset, name, false,
        documentationComment: documentationComment,
        metadata: metadata,
        name: name,
        typeVariables: typeVariables,
        modifiers: modifiers,
        interfaces: interfaces);
    checkTypeVariables(typeVariables, supertype.declaration);
  }

  void addField(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      TypeBuilder type,
      String name,
      int charOffset,
      int charEndOffset,
      Token initializerToken,
      bool hasInitializer,
      {Token constInitializerToken}) {
    if (hasInitializer) {
      modifiers |= hasInitializerMask;
    }
    FieldBuilder field = new FieldBuilder(
        metadata, type, name, modifiers, this, charOffset, charEndOffset);
    field.constInitializerToken = constInitializerToken;
    addBuilder(name, field, charOffset);
    if (!legacyMode && type == null && initializerToken != null) {
      field.target.type = new ImplicitFieldType(field, initializerToken);
      (implicitlyTypedFields ??= <FieldBuilder>[]).add(field);
    }
    loader.target.metadataCollector
        ?.setDocumentationComment(field.target, documentationComment);
  }

  void addConstructor(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      TypeBuilder returnType,
      final Object name,
      String constructorName,
      List<TypeVariableBuilder> typeVariables,
      List<FormalParameterBuilder> formals,
      int startCharOffset,
      int charOffset,
      int charOpenParenOffset,
      int charEndOffset,
      String nativeMethodName,
      {Token beginInitializers}) {
    MetadataCollector metadataCollector = loader.target.metadataCollector;
    ConstructorBuilder procedure = new ConstructorBuilder(
        metadata,
        modifiers & ~abstractMask,
        returnType,
        constructorName,
        typeVariables,
        formals,
        this,
        startCharOffset,
        charOffset,
        charOpenParenOffset,
        charEndOffset,
        nativeMethodName);
    metadataCollector?.setDocumentationComment(
        procedure.target, documentationComment);
    metadataCollector?.setConstructorNameOffset(procedure.target, name);
    checkTypeVariables(typeVariables, procedure);
    addBuilder(constructorName, procedure, charOffset);
    if (nativeMethodName != null) {
      addNativeMethod(procedure);
    }
    if (procedure.isConst) {
      currentTypeParameterScopeBuilder?.hasConstConstructor = true;
      // const constructors will have their initializers compiled and written
      // into the outline.
      procedure.beginInitializers = beginInitializers ?? Token.eof(-1);
    }
  }

  void addProcedure(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      TypeBuilder returnType,
      String name,
      List<TypeVariableBuilder> typeVariables,
      List<FormalParameterBuilder> formals,
      ProcedureKind kind,
      int startCharOffset,
      int charOffset,
      int charOpenParenOffset,
      int charEndOffset,
      String nativeMethodName,
      {bool isTopLevel}) {
    MetadataCollector metadataCollector = loader.target.metadataCollector;
    if (returnType == null) {
      if (kind == ProcedureKind.Operator &&
          identical(name, indexSetName.name)) {
        returnType = addVoidType(charOffset);
      } else if (kind == ProcedureKind.Setter) {
        returnType = addVoidType(charOffset);
      }
    }
    FunctionBuilder procedure = new ProcedureBuilder(
        metadata,
        modifiers,
        returnType,
        name,
        typeVariables,
        formals,
        kind,
        this,
        startCharOffset,
        charOffset,
        charOpenParenOffset,
        charEndOffset,
        nativeMethodName);
    metadataCollector?.setDocumentationComment(
        procedure.target, documentationComment);
    checkTypeVariables(typeVariables, procedure);
    addBuilder(name, procedure, charOffset);
    if (nativeMethodName != null) {
      addNativeMethod(procedure);
    }
  }

  void addFactoryMethod(
      String documentationComment,
      List<MetadataBuilder> metadata,
      int modifiers,
      Object name,
      List<FormalParameterBuilder> formals,
      ConstructorReferenceBuilder redirectionTarget,
      int startCharOffset,
      int charOffset,
      int charOpenParenOffset,
      int charEndOffset,
      String nativeMethodName) {
    TypeBuilder returnType = addNamedType(
        currentTypeParameterScopeBuilder.parent.name,
        <TypeBuilder>[],
        charOffset);
    // Nested declaration began in `OutlineBuilder.beginFactoryMethod`.
    TypeParameterScopeBuilder factoryDeclaration = endNestedDeclaration(
        TypeParameterScopeKind.factoryMethod, "#factory_method");

    // Prepare the simple procedure name.
    String procedureName;
    String constructorName =
        computeAndValidateConstructorName(name, charOffset, isFactory: true);
    if (constructorName != null) {
      procedureName = constructorName;
    } else {
      procedureName = name;
    }

    ProcedureBuilder procedure;
    if (redirectionTarget != null) {
      procedure = new RedirectingFactoryBuilder(
          metadata,
          staticMask | modifiers,
          returnType,
          procedureName,
          copyTypeVariables(
              currentTypeParameterScopeBuilder.typeVariables ??
                  const <TypeVariableBuilder>[],
              factoryDeclaration),
          formals,
          this,
          startCharOffset,
          charOffset,
          charOpenParenOffset,
          charEndOffset,
          nativeMethodName,
          redirectionTarget);
    } else {
      procedure = new ProcedureBuilder(
          metadata,
          staticMask | modifiers,
          returnType,
          procedureName,
          copyTypeVariables(
              currentTypeParameterScopeBuilder.typeVariables ??
                  const <TypeVariableBuilder>[],
              factoryDeclaration),
          formals,
          ProcedureKind.Factory,
          this,
          startCharOffset,
          charOffset,
          charOpenParenOffset,
          charEndOffset,
          nativeMethodName);
    }

    var metadataCollector = loader.target.metadataCollector;
    metadataCollector?.setDocumentationComment(
        procedure.target, documentationComment);
    metadataCollector?.setConstructorNameOffset(procedure.target, name);

    TypeParameterScopeBuilder savedDeclaration =
        currentTypeParameterScopeBuilder;
    currentTypeParameterScopeBuilder = factoryDeclaration;
    for (TypeVariableBuilder tv in procedure.typeVariables) {
      NamedTypeBuilder t = procedure.returnType;
      t.arguments.add(addNamedType(tv.name, null, procedure.charOffset));
    }
    currentTypeParameterScopeBuilder = savedDeclaration;

    factoryDeclaration.resolveTypes(procedure.typeVariables, this);
    addBuilder(procedureName, procedure, charOffset);
    if (nativeMethodName != null) {
      addNativeMethod(procedure);
    }
  }

  void addEnum(
      String documentationComment,
      List<MetadataBuilder> metadata,
      String name,
      List<EnumConstantInfo> enumConstantInfos,
      int startCharOffset,
      int charOffset,
      int charEndOffset) {
    MetadataCollector metadataCollector = loader.target.metadataCollector;
    EnumBuilder builder = new EnumBuilder(metadataCollector, metadata, name,
        enumConstantInfos, this, startCharOffset, charOffset, charEndOffset);
    addBuilder(name, builder, charOffset);
    metadataCollector?.setDocumentationComment(
        builder.target, documentationComment);
  }

  void addFunctionTypeAlias(
      String documentationComment,
      List<MetadataBuilder> metadata,
      String name,
      List<TypeVariableBuilder> typeVariables,
      FunctionTypeBuilder type,
      int charOffset) {
    TypeAliasBuilder typedef = new TypeAliasBuilder(
        metadata, name, typeVariables, type, this, charOffset);
    loader.target.metadataCollector
        ?.setDocumentationComment(typedef.target, documentationComment);
    checkTypeVariables(typeVariables, typedef);
    // Nested declaration began in `OutlineBuilder.beginFunctionTypeAlias`.
    endNestedDeclaration(TypeParameterScopeKind.typedef, "#typedef")
        .resolveTypes(typeVariables, this);
    addBuilder(name, typedef, charOffset);
  }

  FunctionTypeBuilder addFunctionType(
      TypeBuilder returnType,
      List<TypeVariableBuilder> typeVariables,
      List<FormalParameterBuilder> formals,
      int charOffset) {
    var builder = new FunctionTypeBuilder(returnType, typeVariables, formals);
    checkTypeVariables(typeVariables, null);
    // Nested declaration began in `OutlineBuilder.beginFunctionType` or
    // `OutlineBuilder.beginFunctionTypedFormalParameter`.
    endNestedDeclaration(TypeParameterScopeKind.functionType, "#function_type")
        .resolveTypes(typeVariables, this);
    return addType(builder, charOffset);
  }

  FormalParameterBuilder addFormalParameter(
      List<MetadataBuilder> metadata,
      int modifiers,
      TypeBuilder type,
      String name,
      bool hasThis,
      int charOffset,
      Token initializerToken) {
    if (hasThis) {
      modifiers |= initializingFormalMask;
    }
    FormalParameterBuilder formal = new FormalParameterBuilder(
        metadata, modifiers, type, name, this, charOffset);
    formal.initializerToken = initializerToken;
    if (legacyMode && hasThis && type == null) {
      (untypedInitializingFormals ??= <FormalParameterBuilder>[]).add(formal);
    }
    return formal;
  }

  TypeVariableBuilder addTypeVariable(
      String name, TypeBuilder bound, int charOffset) {
    var builder = new TypeVariableBuilder(name, this, charOffset, bound: bound);
    boundlessTypeVariables.add(builder);
    return builder;
  }

  @override
  void buildOutlineExpressions() {
    MetadataBuilder.buildAnnotations(library, metadata, this, null, null);
  }

  void buildBuilder(Builder declaration, LibraryBuilder coreLibrary) {
    Class cls;
    Extension extension;
    Member member;
    Typedef typedef;
    if (declaration is SourceClassBuilder) {
      cls = declaration.build(this, coreLibrary);
    } else if (declaration is SourceExtensionBuilder) {
      extension = declaration.build(this, coreLibrary);
    } else if (declaration is FieldBuilder) {
      member = declaration.build(this)..isStatic = true;
    } else if (declaration is ProcedureBuilder) {
      member = declaration.build(this)..isStatic = true;
    } else if (declaration is TypeAliasBuilder) {
      typedef = declaration.build(this);
    } else if (declaration is EnumBuilder) {
      cls = declaration.build(this, coreLibrary);
    } else if (declaration is PrefixBuilder) {
      // Ignored. Kernel doesn't represent prefixes.
      return;
    } else if (declaration is BuiltinTypeBuilder) {
      // Nothing needed.
      return;
    } else {
      unhandled("${declaration.runtimeType}", "buildBuilder",
          declaration.charOffset, declaration.fileUri);
      return;
    }
    if (declaration.isPatch) {
      // The kernel node of a patch is shared with the origin declaration. We
      // have two builders: the origin, and the patch, but only one kernel node
      // (which corresponds to the final output). Consequently, the node
      // shouldn't be added to its apparent kernel parent as this would create
      // a duplicate entry in the parent's list of children/members.
      return;
    }
    if (cls != null) {
      if (declaration.next != null) {
        int count = 0;
        Builder current = declaration.next;
        while (current != null) {
          count++;
          current = current.next;
        }
        cls.name += "#$count";
      }
      library.addClass(cls);
    } else if (extension != null) {
      if (declaration.next == null) {
        library.addExtension(extension);
      }
    } else if (member != null) {
      if (declaration.next == null) {
        library.addMember(member);
      }
    } else if (typedef != null) {
      if (declaration.next == null) {
        library.addTypedef(typedef);
      }
    }
  }

  void addNativeDependency(String nativeImportPath) {
    Builder constructor = loader.getNativeAnnotation();
    Arguments arguments =
        new Arguments(<Expression>[new StringLiteral(nativeImportPath)]);
    Expression annotation;
    if (constructor.isConstructor) {
      annotation = new ConstructorInvocation(constructor.target, arguments)
        ..isConst = true;
    } else {
      annotation = new StaticInvocation(constructor.target, arguments)
        ..isConst = true;
    }
    library.addAnnotation(annotation);
  }

  void addDependencies(Library library, Set<SourceLibraryBuilder> seen) {
    if (!seen.add(this)) {
      return;
    }

    // Merge import and export lists to have the dependencies in source order.
    // This is required for the DietListener to correctly match up metadata.
    int importIndex = 0;
    int exportIndex = 0;
    while (importIndex < imports.length || exportIndex < exports.length) {
      if (exportIndex >= exports.length ||
          (importIndex < imports.length &&
              imports[importIndex].charOffset <
                  exports[exportIndex].charOffset)) {
        // Add import
        Import import = imports[importIndex++];

        // Rather than add a LibraryDependency, we attach an annotation.
        if (import.nativeImportPath != null) {
          addNativeDependency(import.nativeImportPath);
          continue;
        }

        if (import.deferred && import.prefixBuilder?.dependency != null) {
          library.addDependency(import.prefixBuilder.dependency);
        } else {
          library.addDependency(new LibraryDependency.import(
              import.imported.target,
              name: import.prefix,
              combinators: toKernelCombinators(import.combinators))
            ..fileOffset = import.charOffset);
        }
      } else {
        // Add export
        Export export = exports[exportIndex++];
        library.addDependency(new LibraryDependency.export(
            export.exported.target,
            combinators: toKernelCombinators(export.combinators))
          ..fileOffset = export.charOffset);
      }
    }

    for (SourceLibraryBuilder part in parts) {
      part.addDependencies(library, seen);
    }
  }

  @override
  Builder computeAmbiguousDeclaration(
      String name, Builder declaration, Builder other, int charOffset,
      {bool isExport: false, bool isImport: false}) {
    // TODO(ahe): Can I move this to Scope or Prefix?
    if (declaration == other) return declaration;
    if (declaration is InvalidTypeBuilder) return declaration;
    if (other is InvalidTypeBuilder) return other;
    if (declaration is AccessErrorBuilder) {
      AccessErrorBuilder error = declaration;
      declaration = error.builder;
    }
    if (other is AccessErrorBuilder) {
      AccessErrorBuilder error = other;
      other = error.builder;
    }
    bool isLocal = false;
    bool isLoadLibrary = false;
    Builder preferred;
    Uri uri;
    Uri otherUri;
    Uri preferredUri;
    Uri hiddenUri;
    if (scope.local[name] == declaration) {
      isLocal = true;
      preferred = declaration;
      hiddenUri = computeLibraryUri(other);
    } else {
      uri = computeLibraryUri(declaration);
      otherUri = computeLibraryUri(other);
      if (declaration is LoadLibraryBuilder) {
        isLoadLibrary = true;
        preferred = declaration;
        preferredUri = otherUri;
      } else if (other is LoadLibraryBuilder) {
        isLoadLibrary = true;
        preferred = other;
        preferredUri = uri;
      } else if (otherUri?.scheme == "dart" && uri?.scheme != "dart") {
        preferred = declaration;
        preferredUri = uri;
        hiddenUri = otherUri;
      } else if (uri?.scheme == "dart" && otherUri?.scheme != "dart") {
        preferred = other;
        preferredUri = otherUri;
        hiddenUri = uri;
      }
    }
    if (preferred != null) {
      if (isLocal) {
        var template = isExport
            ? templateLocalDefinitionHidesExport
            : templateLocalDefinitionHidesImport;
        addProblem(template.withArguments(name, hiddenUri), charOffset,
            noLength, fileUri);
      } else if (isLoadLibrary) {
        addProblem(templateLoadLibraryHidesMember.withArguments(preferredUri),
            charOffset, noLength, fileUri);
      } else {
        var template =
            isExport ? templateExportHidesExport : templateImportHidesImport;
        addProblem(template.withArguments(name, preferredUri, hiddenUri),
            charOffset, noLength, fileUri);
      }
      return preferred;
    }
    if (declaration.next == null && other.next == null) {
      if (isImport && declaration is PrefixBuilder && other is PrefixBuilder) {
        // Handles the case where the same prefix is used for different
        // imports.
        return declaration
          ..exportScope.merge(other.exportScope,
              (String name, Builder existing, Builder member) {
            return computeAmbiguousDeclaration(
                name, existing, member, charOffset,
                isExport: isExport, isImport: isImport);
          });
      }
    }
    var template =
        isExport ? templateDuplicatedExport : templateDuplicatedImport;
    Message message = template.withArguments(name, uri, otherUri);
    addProblem(message, charOffset, noLength, fileUri);
    var builderTemplate = isExport
        ? templateDuplicatedExportInType
        : templateDuplicatedImportInType;
    message = builderTemplate.withArguments(
        name,
        // TODO(ahe): We should probably use a context object here
        // instead of including URIs in this message.
        uri,
        otherUri);
    // We report the error lazily (setting suppressMessage to false) because the
    // spec 18.1 states that 'It is not an error if N is introduced by two or
    // more imports but never referred to.'
    return new InvalidTypeBuilder(
        name, message.withLocation(fileUri, charOffset, name.length),
        suppressMessage: false);
  }

  int finishDeferredLoadTearoffs() {
    int total = 0;
    for (var import in imports) {
      if (import.deferred) {
        Procedure tearoff = import.prefixBuilder.loadLibraryBuilder.tearoff;
        if (tearoff != null) library.addMember(tearoff);
        total++;
      }
    }
    return total;
  }

  int finishForwarders() {
    int count = 0;
    CloneVisitor cloner = new CloneVisitor();
    for (int i = 0; i < forwardersOrigins.length; i += 2) {
      Procedure forwarder = forwardersOrigins[i];
      Procedure origin = forwardersOrigins[i + 1];

      int positionalCount = origin.function.positionalParameters.length;
      if (forwarder.function.positionalParameters.length != positionalCount) {
        return unexpected(
            "$positionalCount",
            "${forwarder.function.positionalParameters.length}",
            origin.fileOffset,
            origin.fileUri);
      }
      for (int j = 0; j < positionalCount; ++j) {
        VariableDeclaration forwarderParameter =
            forwarder.function.positionalParameters[j];
        VariableDeclaration originParameter =
            origin.function.positionalParameters[j];
        if (originParameter.initializer != null) {
          forwarderParameter.initializer =
              cloner.clone(originParameter.initializer);
          forwarderParameter.initializer.parent = forwarderParameter;
        }
      }

      Map<String, VariableDeclaration> originNamedMap =
          <String, VariableDeclaration>{};
      for (VariableDeclaration originNamed in origin.function.namedParameters) {
        originNamedMap[originNamed.name] = originNamed;
      }
      for (VariableDeclaration forwarderNamed
          in forwarder.function.namedParameters) {
        VariableDeclaration originNamed = originNamedMap[forwarderNamed.name];
        if (originNamed == null) {
          return unhandled(
              "null", forwarder.name.name, origin.fileOffset, origin.fileUri);
        }
        if (originNamed.initializer == null) continue;
        forwarderNamed.initializer = cloner.clone(originNamed.initializer);
        forwarderNamed.initializer.parent = forwarderNamed;
      }

      ++count;
    }
    forwardersOrigins.clear();
    return count;
  }

  void addNativeMethod(FunctionBuilder method) {
    nativeMethods.add(method);
  }

  int finishNativeMethods() {
    for (FunctionBuilder method in nativeMethods) {
      method.becomeNative(loader);
    }
    return nativeMethods.length;
  }

  /// Creates a copy of [original] into the scope of [declaration].
  ///
  /// This is used for adding copies of class type parameters to factory
  /// methods and unnamed mixin applications, and for adding copies of
  /// extension type parameters to extension instance methods.
  ///
  /// If [synthesizeTypeParameterNames] is `true` the names of the
  /// [TypeParameter] are prefix with '#' to indicate that their synthesized.
  List<TypeVariableBuilder> copyTypeVariables(
      List<TypeVariableBuilder> original, TypeParameterScopeBuilder declaration,
      {bool synthesizeTypeParameterNames: false}) {
    List<TypeBuilder> newTypes = <TypeBuilder>[];
    List<TypeVariableBuilder> copy = <TypeVariableBuilder>[];
    for (TypeVariableBuilder variable in original) {
      var newVariable = new TypeVariableBuilder(
          variable.name, this, variable.charOffset,
          bound: variable.bound?.clone(newTypes),
          synthesizeTypeParameterName: synthesizeTypeParameterNames);
      copy.add(newVariable);
      boundlessTypeVariables.add(newVariable);
    }
    for (TypeBuilder newType in newTypes) {
      declaration.addType(new UnresolvedType(newType, -1, null));
    }
    return copy;
  }

  int finishTypeVariables(ClassBuilder object, TypeBuilder dynamicType) {
    int count = boundlessTypeVariables.length;
    for (TypeVariableBuilder builder in boundlessTypeVariables) {
      builder.finish(this, object, dynamicType);
    }
    boundlessTypeVariables.clear();
    return count;
  }

  int computeDefaultTypes(TypeBuilder dynamicType, TypeBuilder bottomType,
      ClassBuilder objectClass) {
    int count = 0;

    int computeDefaultTypesForVariables(
        List<TypeVariableBuilder> variables, bool legacyMode) {
      if (variables == null) return 0;

      bool haveErroneousBounds = false;
      if (!legacyMode) {
        for (int i = 0; i < variables.length; ++i) {
          TypeVariableBuilder variable = variables[i];
          List<TypeBuilder> genericFunctionTypes = <TypeBuilder>[];
          findGenericFunctionTypes(variable.bound,
              result: genericFunctionTypes);
          if (genericFunctionTypes.length > 0) {
            haveErroneousBounds = true;
            addProblem(messageGenericFunctionTypeInBound, variable.charOffset,
                variable.name.length, variable.fileUri);
          }
        }

        if (!haveErroneousBounds) {
          List<TypeBuilder> calculatedBounds =
              calculateBounds(variables, dynamicType, bottomType, objectClass);
          for (int i = 0; i < variables.length; ++i) {
            variables[i].defaultType = calculatedBounds[i];
          }
        }
      }

      if (legacyMode || haveErroneousBounds) {
        // In Dart 1, put `dynamic` everywhere.
        for (int i = 0; i < variables.length; ++i) {
          variables[i].defaultType = dynamicType;
        }
      }

      return variables.length;
    }

    void reportIssues(List<Object> issues) {
      for (int i = 0; i < issues.length; i += 3) {
        TypeDeclarationBuilder declaration = issues[i];
        Message message = issues[i + 1];
        List<LocatedMessage> context = issues[i + 2];

        addProblem(message, declaration.charOffset, declaration.name.length,
            declaration.fileUri,
            context: context);
      }
    }

    bool legacyMode = loader.target.legacyMode;
    for (var declaration in libraryDeclaration.members.values) {
      if (declaration is ClassBuilder) {
        {
          List<Object> issues = legacyMode
              ? const <Object>[]
              : getNonSimplicityIssuesForDeclaration(declaration,
                  performErrorRecovery: true);
          reportIssues(issues);
          // In case of issues, use legacy mode for error recovery.
          count += computeDefaultTypesForVariables(
              declaration.typeVariables, legacyMode || issues.isNotEmpty);
        }
        declaration.forEach((String name, Builder member) {
          if (member is ProcedureBuilder) {
            List<Object> issues = legacyMode
                ? const <Object>[]
                : getNonSimplicityIssuesForTypeVariables(member.typeVariables);
            reportIssues(issues);
            // In case of issues, use legacy mode for error recovery.
            count += computeDefaultTypesForVariables(
                member.typeVariables, legacyMode || issues.isNotEmpty);
          }
        });
      } else if (declaration is TypeAliasBuilder) {
        List<Object> issues = legacyMode
            ? const <Object>[]
            : getNonSimplicityIssuesForDeclaration(declaration,
                performErrorRecovery: true);
        reportIssues(issues);
        // In case of issues, use legacy mode for error recovery.
        count += computeDefaultTypesForVariables(
            declaration.typeVariables, legacyMode || issues.isNotEmpty);
      } else if (declaration is FunctionBuilder) {
        List<Object> issues = legacyMode
            ? const <Object>[]
            : getNonSimplicityIssuesForTypeVariables(declaration.typeVariables);
        reportIssues(issues);
        // In case of issues, use legacy mode for error recovery.
        count += computeDefaultTypesForVariables(
            declaration.typeVariables, legacyMode || issues.isNotEmpty);
      }
    }

    return count;
  }

  @override
  void applyPatches() {
    if (!isPatch) return;
    NameIterator originDeclarations = origin.nameIterator;
    while (originDeclarations.moveNext()) {
      String name = originDeclarations.name;
      Builder member = originDeclarations.current;
      bool isSetter = member.isSetter;
      Builder patch = isSetter ? scope.setters[name] : scope.local[name];
      if (patch != null) {
        // [patch] has the same name as a [member] in [origin] library, so it
        // must be a patch to [member].
        member.applyPatch(patch);
        // TODO(ahe): Verify that patch has the @patch annotation.
      } else {
        // No member with [name] exists in this library already. So we need to
        // import it into the patch library. This ensures that the origin
        // library is in scope of the patch library.
        if (isSetter) {
          scopeBuilder.addSetter(name, member);
        } else {
          scopeBuilder.addMember(name, member);
        }
      }
    }
    NameIterator patchDeclarations = nameIterator;
    while (patchDeclarations.moveNext()) {
      String name = patchDeclarations.name;
      Builder member = patchDeclarations.current;
      // We need to inject all non-patch members into the origin library. This
      // should only apply to private members.
      if (member.isPatch) {
        // Ignore patches.
      } else if (name.startsWith("_")) {
        origin.injectMemberFromPatch(name, member);
      } else {
        origin.exportMemberFromPatch(name, member);
      }
    }
  }

  int finishPatchMethods() {
    if (!isPatch) return 0;
    int count = 0;
    Iterator<Builder> iterator = this.iterator;
    while (iterator.moveNext()) {
      count += iterator.current.finishPatch();
    }
    return count;
  }

  void injectMemberFromPatch(String name, Builder member) {
    if (member.isSetter) {
      assert(scope.setters[name] == null);
      scopeBuilder.addSetter(name, member);
    } else {
      assert(scope.local[name] == null);
      scopeBuilder.addMember(name, member);
    }
  }

  void exportMemberFromPatch(String name, Builder member) {
    if (uri.scheme != "dart" || !uri.path.startsWith("_")) {
      addProblem(templatePatchInjectionFailed.withArguments(name, uri),
          member.charOffset, noLength, member.fileUri);
    }
    // Platform-private libraries, such as "dart:_internal" have special
    // semantics: public members are injected into the origin library.
    // TODO(ahe): See if we can remove this special case.

    // If this member already exist in the origin library scope, it should
    // have been marked as patch.
    assert((member.isSetter && scope.setters[name] == null) ||
        (!member.isSetter && scope.local[name] == null));
    addToExportScope(name, member);
  }

  void reportTypeArgumentIssues(
      List<TypeArgumentIssue> issues, Uri fileUri, int offset,
      {bool inferred, DartType targetReceiver, String targetName}) {
    for (TypeArgumentIssue issue in issues) {
      DartType argument = issue.argument;
      TypeParameter typeParameter = issue.typeParameter;

      Message message;
      bool issueInferred = inferred ?? inferredTypes.contains(argument);
      if (argument is FunctionType && argument.typeParameters.length > 0) {
        if (issueInferred) {
          message = templateGenericFunctionTypeInferredAsActualTypeArgument
              .withArguments(argument);
        } else {
          message = messageGenericFunctionTypeUsedAsActualTypeArgument;
        }
        typeParameter = null;
      } else if (argument is TypeParameterType &&
          argument.promotedBound != null) {
        addProblem(
            templateIntersectionTypeAsTypeArgument.withArguments(
                typeParameter.name, argument, argument.promotedBound),
            offset,
            noLength,
            fileUri);
        continue;
      } else {
        if (issue.enclosingType == null && targetReceiver != null) {
          if (issueInferred) {
            message =
                templateIncorrectTypeArgumentQualifiedInferred.withArguments(
                    argument,
                    typeParameter.bound,
                    typeParameter.name,
                    targetReceiver,
                    targetName);
          } else {
            message = templateIncorrectTypeArgumentQualified.withArguments(
                argument,
                typeParameter.bound,
                typeParameter.name,
                targetReceiver,
                targetName);
          }
        } else {
          String enclosingName = issue.enclosingType == null
              ? targetName
              : getGenericTypeName(issue.enclosingType);
          assert(enclosingName != null);
          if (issueInferred) {
            message = templateIncorrectTypeArgumentInferred.withArguments(
                argument,
                typeParameter.bound,
                typeParameter.name,
                enclosingName);
          } else {
            message = templateIncorrectTypeArgument.withArguments(argument,
                typeParameter.bound, typeParameter.name, enclosingName);
          }
        }
      }

      reportTypeArgumentIssue(message, fileUri, offset, typeParameter);
    }
  }

  void reportTypeArgumentIssue(Message message, Uri fileUri, int fileOffset,
      TypeParameter typeParameter) {
    List<LocatedMessage> context;
    if (typeParameter != null && typeParameter.fileOffset != -1) {
      // It looks like when parameters come from patch files, they don't
      // have a reportable location.
      context = <LocatedMessage>[
        messageIncorrectTypeArgumentVariable.withLocation(
            typeParameter.location.file, typeParameter.fileOffset, noLength)
      ];
    }
    addProblem(message, fileOffset, noLength, fileUri, context: context);
  }

  void checkBoundsInField(Field field, TypeEnvironment typeEnvironment) {
    if (loader.target.legacyMode) return;
    checkBoundsInType(
        field.type, typeEnvironment, field.fileUri, field.fileOffset,
        allowSuperBounded: true);
  }

  void checkBoundsInFunctionNodeParts(
      TypeEnvironment typeEnvironment, Uri fileUri, int fileOffset,
      {List<TypeParameter> typeParameters,
      List<VariableDeclaration> positionalParameters,
      List<VariableDeclaration> namedParameters,
      DartType returnType}) {
    if (loader.target.legacyMode) return;
    if (typeParameters != null) {
      for (TypeParameter parameter in typeParameters) {
        checkBoundsInType(
            parameter.bound, typeEnvironment, fileUri, parameter.fileOffset,
            allowSuperBounded: true);
      }
    }
    if (positionalParameters != null) {
      for (VariableDeclaration formal in positionalParameters) {
        checkBoundsInType(
            formal.type, typeEnvironment, fileUri, formal.fileOffset,
            allowSuperBounded: true);
      }
    }
    if (namedParameters != null) {
      for (VariableDeclaration named in namedParameters) {
        checkBoundsInType(
            named.type, typeEnvironment, fileUri, named.fileOffset,
            allowSuperBounded: true);
      }
    }
    if (returnType != null) {
      List<TypeArgumentIssue> issues = findTypeArgumentIssues(
          returnType, typeEnvironment,
          allowSuperBounded: true);
      if (issues != null) {
        int offset = fileOffset;
        for (TypeArgumentIssue issue in issues) {
          DartType argument = issue.argument;
          TypeParameter typeParameter = issue.typeParameter;

          // We don't need to check if [argument] was inferred or specified
          // here, because inference in return types boils down to instantiate-
          // -to-bound, and it can't provide a type that violates the bound.
          Message message;
          if (argument is FunctionType && argument.typeParameters.length > 0) {
            message = messageGenericFunctionTypeUsedAsActualTypeArgument;
            typeParameter = null;
          } else {
            message = templateIncorrectTypeArgumentInReturnType.withArguments(
                argument,
                typeParameter.bound,
                typeParameter.name,
                getGenericTypeName(issue.enclosingType));
          }

          reportTypeArgumentIssue(message, fileUri, offset, typeParameter);
        }
      }
    }
  }

  void checkBoundsInFunctionNode(
      FunctionNode function, TypeEnvironment typeEnvironment, Uri fileUri) {
    if (loader.target.legacyMode) return;
    checkBoundsInFunctionNodeParts(
        typeEnvironment, fileUri, function.fileOffset,
        typeParameters: function.typeParameters,
        positionalParameters: function.positionalParameters,
        namedParameters: function.namedParameters,
        returnType: function.returnType);
  }

  void checkBoundsInListLiteral(
      ListLiteral node, TypeEnvironment typeEnvironment, Uri fileUri,
      {bool inferred = false}) {
    if (loader.target.legacyMode) return;
    checkBoundsInType(
        node.typeArgument, typeEnvironment, fileUri, node.fileOffset,
        inferred: inferred, allowSuperBounded: true);
  }

  void checkBoundsInSetLiteral(
      SetLiteral node, TypeEnvironment typeEnvironment, Uri fileUri,
      {bool inferred = false}) {
    if (loader.target.legacyMode) return;
    checkBoundsInType(
        node.typeArgument, typeEnvironment, fileUri, node.fileOffset,
        inferred: inferred, allowSuperBounded: true);
  }

  void checkBoundsInMapLiteral(
      MapLiteral node, TypeEnvironment typeEnvironment, Uri fileUri,
      {bool inferred = false}) {
    if (loader.target.legacyMode) return;
    checkBoundsInType(node.keyType, typeEnvironment, fileUri, node.fileOffset,
        inferred: inferred, allowSuperBounded: true);
    checkBoundsInType(node.valueType, typeEnvironment, fileUri, node.fileOffset,
        inferred: inferred, allowSuperBounded: true);
  }

  void checkBoundsInType(
      DartType type, TypeEnvironment typeEnvironment, Uri fileUri, int offset,
      {bool inferred, bool allowSuperBounded = true}) {
    if (loader.target.legacyMode) return;
    List<TypeArgumentIssue> issues = findTypeArgumentIssues(
        type, typeEnvironment,
        allowSuperBounded: allowSuperBounded);
    if (issues != null) {
      reportTypeArgumentIssues(issues, fileUri, offset, inferred: inferred);
    }
  }

  void checkBoundsInVariableDeclaration(
      VariableDeclaration node, TypeEnvironment typeEnvironment, Uri fileUri,
      {bool inferred = false}) {
    if (loader.target.legacyMode) return;
    if (node.type == null) return;
    checkBoundsInType(node.type, typeEnvironment, fileUri, node.fileOffset,
        inferred: inferred, allowSuperBounded: true);
  }

  void checkBoundsInConstructorInvocation(
      ConstructorInvocation node, TypeEnvironment typeEnvironment, Uri fileUri,
      {bool inferred = false}) {
    if (loader.target.legacyMode) return;
    if (node.arguments.types.isEmpty) return;
    Constructor constructor = node.target;
    Class klass = constructor.enclosingClass;
    DartType constructedType = new InterfaceType(klass, node.arguments.types);
    checkBoundsInType(
        constructedType, typeEnvironment, fileUri, node.fileOffset,
        inferred: inferred, allowSuperBounded: false);
  }

  void checkBoundsInFactoryInvocation(
      StaticInvocation node, TypeEnvironment typeEnvironment, Uri fileUri,
      {bool inferred = false}) {
    if (loader.target.legacyMode) return;
    if (node.arguments.types.isEmpty) return;
    Procedure factory = node.target;
    assert(factory.isFactory);
    Class klass = factory.enclosingClass;
    DartType constructedType = new InterfaceType(klass, node.arguments.types);
    checkBoundsInType(
        constructedType, typeEnvironment, fileUri, node.fileOffset,
        inferred: inferred, allowSuperBounded: false);
  }

  void checkBoundsInStaticInvocation(
      StaticInvocation node, TypeEnvironment typeEnvironment, Uri fileUri,
      {bool inferred = false}) {
    if (loader.target.legacyMode) return;
    if (node.arguments.types.isEmpty) return;
    Class klass = node.target.enclosingClass;
    List<TypeParameter> parameters = node.target.function.typeParameters;
    List<DartType> arguments = node.arguments.types;
    // The following error is to be reported elsewhere.
    if (parameters.length != arguments.length) return;
    List<TypeArgumentIssue> issues = findTypeArgumentIssuesForInvocation(
        parameters, arguments, typeEnvironment);
    if (issues != null) {
      DartType targetReceiver;
      if (klass != null) {
        targetReceiver = new InterfaceType(klass);
      }
      String targetName = node.target.name.name;
      reportTypeArgumentIssues(issues, fileUri, node.fileOffset,
          inferred: inferred,
          targetReceiver: targetReceiver,
          targetName: targetName);
    }
  }

  void checkBoundsInMethodInvocation(
      DartType receiverType,
      TypeEnvironment typeEnvironment,
      ClassHierarchy hierarchy,
      TypeInferrerImpl typeInferrer,
      Name name,
      Member interfaceTarget,
      Arguments arguments,
      Uri fileUri,
      int offset,
      {bool inferred = false}) {
    if (loader.target.legacyMode) return;
    if (arguments.types.isEmpty) return;
    Class klass;
    List<DartType> receiverTypeArguments;
    if (receiverType is InterfaceType) {
      klass = receiverType.classNode;
      receiverTypeArguments = receiverType.typeArguments;
    } else {
      return;
    }
    // TODO(dmitryas): Find a better way than relying on [interfaceTarget].
    Member method = hierarchy.getDispatchTarget(klass, name) ?? interfaceTarget;
    if (method == null || method is! Procedure) {
      return;
    }
    if (klass != method.enclosingClass) {
      Supertype parent =
          hierarchy.getClassAsInstanceOf(klass, method.enclosingClass);
      klass = method.enclosingClass;
      receiverTypeArguments = parent.typeArguments;
    }
    Map<TypeParameter, DartType> substitutionMap = <TypeParameter, DartType>{};
    for (int i = 0; i < receiverTypeArguments.length; ++i) {
      substitutionMap[klass.typeParameters[i]] = receiverTypeArguments[i];
    }
    List<TypeParameter> methodParameters = method.function.typeParameters;
    // The error is to be reported elsewhere.
    if (methodParameters.length != arguments.types.length) return;
    List<TypeParameter> instantiatedMethodParameters =
        new List<TypeParameter>.filled(methodParameters.length, null);
    for (int i = 0; i < instantiatedMethodParameters.length; ++i) {
      instantiatedMethodParameters[i] =
          new TypeParameter(methodParameters[i].name);
      substitutionMap[methodParameters[i]] =
          new TypeParameterType(instantiatedMethodParameters[i]);
    }
    for (int i = 0; i < instantiatedMethodParameters.length; ++i) {
      instantiatedMethodParameters[i].bound =
          substitute(methodParameters[i].bound, substitutionMap);
    }
    List<TypeArgumentIssue> issues = findTypeArgumentIssuesForInvocation(
        instantiatedMethodParameters, arguments.types, typeEnvironment);
    if (issues != null) {
      reportTypeArgumentIssues(issues, fileUri, offset,
          inferred: inferred,
          targetReceiver: receiverType,
          targetName: name.name);
    }
  }

  void checkBoundsInOutline(TypeEnvironment typeEnvironment) {
    if (loader.target.legacyMode) return;
    Iterator<Builder> iterator = this.iterator;
    while (iterator.moveNext()) {
      Builder declaration = iterator.current;
      if (declaration is FieldBuilder) {
        checkBoundsInField(declaration.target, typeEnvironment);
      } else if (declaration is ProcedureBuilder) {
        checkBoundsInFunctionNode(
            declaration.target.function, typeEnvironment, declaration.fileUri);
      } else if (declaration is ClassBuilder) {
        declaration.checkBoundsInOutline(typeEnvironment);
      }
    }
    inferredTypes.clear();
  }

  int finalizeInitializingFormals() {
    if (!legacyMode || untypedInitializingFormals == null) return 0;
    for (int i = 0; i < untypedInitializingFormals.length; i++) {
      untypedInitializingFormals[i].finalizeInitializingFormal();
    }
    int count = untypedInitializingFormals.length;
    untypedInitializingFormals = null;
    return count;
  }

  @override
  List<FieldBuilder> takeImplicitlyTypedFields() {
    List<FieldBuilder> result = implicitlyTypedFields;
    implicitlyTypedFields = null;
    return result;
  }
}

// The kind of type parameter scope built by a [TypeParameterScopeBuilder]
// object.
enum TypeParameterScopeKind {
  library,
  classOrNamedMixinApplication,
  classDeclaration,
  mixinDeclaration,
  unnamedMixinApplication,
  namedMixinApplication,
  extensionDeclaration,
  typedef,
  staticOrInstanceMethodOrConstructor,
  topLevelMethod,
  factoryMethod,
  functionType,
}

/// A builder object preparing for building declarations that can introduce type
/// parameter and/or members.
///
/// Unlike [Scope], this scope is used during construction of builders to
/// ensure types and members are added to and resolved in the correct location.
class TypeParameterScopeBuilder {
  TypeParameterScopeKind _kind;

  final TypeParameterScopeBuilder parent;

  final Map<String, Builder> members;

  final Map<String, Builder> constructors;

  final Map<String, Builder> setters;

  final List<UnresolvedType> types = <UnresolvedType>[];

  // TODO(johnniwinther): Stop using [_name] for determining the declaration
  // kind.
  String _name;

  /// Offset of name token, updated by the outline builder along
  /// with the name as the current declaration changes.
  int _charOffset;

  List<TypeVariableBuilder> _typeVariables;

  /// The type of `this` in instance methods declared in extension declarations.
  ///
  /// Instance methods declared in extension declarations methods are extended
  /// with a synthesized parameter of this type.
  TypeBuilder _extensionThisType;

  bool hasConstConstructor = false;

  TypeParameterScopeBuilder(this._kind, this.members, this.setters,
      this.constructors, this._name, this._charOffset, this.parent) {
    assert(_name != null);
  }

  TypeParameterScopeBuilder.library()
      : this(TypeParameterScopeKind.library, <String, Builder>{},
            <String, Builder>{}, null, "<library>", -1, null);

  TypeParameterScopeBuilder createNested(
      TypeParameterScopeKind kind, String name, bool hasMembers) {
    return new TypeParameterScopeBuilder(
        kind,
        hasMembers ? <String, MemberBuilder>{} : null,
        hasMembers ? <String, MemberBuilder>{} : null,
        hasMembers ? <String, MemberBuilder>{} : null,
        name,
        -1,
        this);
  }

  /// Registers that this builder is preparing for a class declaration with the
  /// given [name] and [typeVariables] located [charOffset].
  void markAsClassDeclaration(
      String name, int charOffset, List<TypeVariableBuilder> typeVariables) {
    assert(_kind == TypeParameterScopeKind.classOrNamedMixinApplication,
        "Unexpected declaration kind: $_kind");
    _kind = TypeParameterScopeKind.classDeclaration;
    _name = name;
    _charOffset = charOffset;
    _typeVariables = typeVariables;
  }

  /// Registers that this builder is preparing for a named mixin application
  /// with the given [name] and [typeVariables] located [charOffset].
  void markAsNamedMixinApplication(
      String name, int charOffset, List<TypeVariableBuilder> typeVariables) {
    assert(_kind == TypeParameterScopeKind.classOrNamedMixinApplication,
        "Unexpected declaration kind: $_kind");
    _kind = TypeParameterScopeKind.namedMixinApplication;
    _name = name;
    _charOffset = charOffset;
    _typeVariables = typeVariables;
  }

  /// Registers that this builder is preparing for a mixin declaration with the
  /// given [name] and [typeVariables] located [charOffset].
  void markAsMixinDeclaration(
      String name, int charOffset, List<TypeVariableBuilder> typeVariables) {
    // TODO(johnniwinther): Avoid using 'classOrNamedMixinApplication' for mixin
    // declaration. These are syntactically distinct so we don't need the
    // transition.
    assert(_kind == TypeParameterScopeKind.classOrNamedMixinApplication,
        "Unexpected declaration kind: $_kind");
    _kind = TypeParameterScopeKind.mixinDeclaration;
    _name = name;
    _charOffset = charOffset;
    _typeVariables = typeVariables;
  }

  /// Registers that this builder is preparing for an extension declaration with
  /// the given [name] and [typeVariables] located [charOffset].
  void markAsExtensionDeclaration(
      String name, int charOffset, List<TypeVariableBuilder> typeVariables) {
    assert(_kind == TypeParameterScopeKind.extensionDeclaration,
        "Unexpected declaration kind: $_kind");
    _name = name;
    _charOffset = charOffset;
    _typeVariables = typeVariables;
  }

  /// Registers the 'extension this type' of the extension declaration prepared
  /// for by this builder.
  ///
  /// See [extensionThisType] for terminology.
  void registerExtensionThisType(TypeBuilder type) {
    assert(_kind == TypeParameterScopeKind.extensionDeclaration,
        "DeclarationBuilder.registerExtensionThisType is not supported $_kind");
    assert(_extensionThisType == null,
        "Extension this type has already been set.");
    _extensionThisType = type;
  }

  /// Returns what kind of declaration this [TypeParameterScopeBuilder] is
  /// preparing for.
  ///
  /// This information is transient for some declarations. In particular
  /// classes and named mixin applications are initially created with the kind
  /// [TypeParameterScopeKind.classOrNamedMixinApplication] before a call to
  /// either [markAsClassDeclaration] or [markAsNamedMixinApplication] sets the
  /// value to its actual kind.
  // TODO(johnniwinther): Avoid the transition currently used on mixin
  // declarations.
  TypeParameterScopeKind get kind => _kind;

  String get name => _name;

  int get charOffset => _charOffset;

  List<TypeVariableBuilder> get typeVariables => _typeVariables;

  /// Returns the 'extension this type' of the extension declaration prepared
  /// for by this builder.
  ///
  /// The 'extension this type' is the type mentioned in the on-clause of the
  /// extension declaration. For instance `B` in this extension declaration:
  ///
  ///     extension A on B {
  ///       B method() => this;
  ///     }
  ///
  /// The 'extension this type' is the type if `this` expression in instance
  /// methods declared in extension declarations.
  TypeBuilder get extensionThisType {
    assert(kind == TypeParameterScopeKind.extensionDeclaration,
        "DeclarationBuilder.extensionThisType not supported on $kind.");
    assert(_extensionThisType != null,
        "DeclarationBuilder.extensionThisType has not been set on $this.");
    return _extensionThisType;
  }

  /// Adds the yet unresolved [type] to this scope builder.
  ///
  /// Unresolved type will be resolved through [resolveTypes] when the scope
  /// is fully built. This allows for resolving self-referencing types, like
  /// type parameter used in their own bound, for instance `<T extends A<T>>`.
  void addType(UnresolvedType type) {
    types.add(type);
  }

  /// Resolves type variables in [types] and propagate other types to [parent].
  void resolveTypes(
      List<TypeVariableBuilder> typeVariables, SourceLibraryBuilder library) {
    Map<String, TypeVariableBuilder> map;
    if (typeVariables != null) {
      map = <String, TypeVariableBuilder>{};
      for (TypeVariableBuilder builder in typeVariables) {
        map[builder.name] = builder;
      }
    }
    Scope scope;
    for (UnresolvedType type in types) {
      Object nameOrQualified = type.builder.name;
      String name = nameOrQualified is QualifiedName
          ? nameOrQualified.qualifier
          : nameOrQualified;
      Builder declaration;
      if (name != null) {
        if (members != null) {
          declaration = members[name];
        }
        if (declaration == null && map != null) {
          declaration = map[name];
        }
      }
      if (declaration == null) {
        // Since name didn't resolve in this scope, propagate it to the
        // parent declaration.
        parent.addType(type);
      } else if (nameOrQualified is QualifiedName) {
        // Attempt to use a member or type variable as a prefix.
        Message message = templateNotAPrefixInTypeAnnotation.withArguments(
            flattenName(
                nameOrQualified.qualifier, type.charOffset, type.fileUri),
            nameOrQualified.name);
        library.addProblem(message, type.charOffset,
            nameOrQualified.endCharOffset - type.charOffset, type.fileUri);
        type.builder.bind(type.builder.buildInvalidType(message.withLocation(
            type.fileUri,
            type.charOffset,
            nameOrQualified.endCharOffset - type.charOffset)));
      } else {
        scope ??= toScope(null).withTypeVariables(typeVariables);
        type.resolveIn(scope, library);
      }
    }
    types.clear();
  }

  Scope toScope(Scope parent) {
    return new Scope(members, setters, parent, name, isModifiable: false);
  }

  @override
  String toString() => 'DeclarationBuilder(${hashCode}:kind=$kind,name=$name)';
}

class FieldInfo {
  final String name;
  final int charOffset;
  final Token initializerToken;
  final Token beforeLast;
  final int charEndOffset;

  const FieldInfo(this.name, this.charOffset, this.initializerToken,
      this.beforeLast, this.charEndOffset);
}

class ImplementationInfo {
  final String name;
  final Builder declaration;
  final int charOffset;

  const ImplementationInfo(this.name, this.declaration, this.charOffset);
}

Uri computeLibraryUri(Builder declaration) {
  Builder current = declaration;
  do {
    if (current is LibraryBuilder) return current.uri;
    current = current.parent;
  } while (current != null);
  return unhandled("no library parent", "${declaration.runtimeType}",
      declaration.charOffset, declaration.fileUri);
}

String extractName(name) => name is QualifiedName ? name.name : name;

class PostponedProblem {
  final Message message;
  final int charOffset;
  final int length;
  final Uri fileUri;

  PostponedProblem(this.message, this.charOffset, this.length, this.fileUri);
}

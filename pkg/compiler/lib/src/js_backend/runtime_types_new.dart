// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library js_backend.runtime_types_new;

import 'package:js_runtime/shared/recipe_syntax.dart';

import '../common_elements.dart'
    show CommonElements, JCommonElements, JElementEnvironment;
import '../elements/entities.dart';
import '../elements/types.dart';
import '../js/js.dart' as jsAst;
import '../js/js.dart' show js;
import '../js_model/type_recipe.dart';
import '../js_emitter/js_emitter.dart' show ModularEmitter;
import '../universe/class_hierarchy.dart';
import '../world.dart';
import 'namer.dart';
import 'native_data.dart';
import 'runtime_types_codegen.dart' show RuntimeTypesSubstitutions;
import 'runtime_types_resolution.dart' show RuntimeTypesNeed;

class RecipeEncoding {
  final jsAst.Literal recipe;
  final Set<TypeVariableType> typeVariables;

  const RecipeEncoding(this.recipe, this.typeVariables);
}

abstract class RecipeEncoder {
  /// Returns a [RecipeEncoding] representing the given [recipe] to be
  /// evaluated against a type environment with shape [structure].
  RecipeEncoding encodeRecipe(ModularEmitter emitter,
      TypeEnvironmentStructure environmentStructure, TypeRecipe recipe);

  jsAst.Literal encodeGroundRecipe(ModularEmitter emitter, TypeRecipe recipe);

  /// Return the recipe with type variables replaced with <any>. This is a hack
  /// until DartType contains <any> and the parameter stub emitter is replaced
  /// with an SSA path.
  // TODO(33422): Remove need for this.
  jsAst.Literal encodeRecipeWithVariablesReplaceByAny(
      ModularEmitter emitter, DartType dartType);

  /// Returns a [jsAst.Literal] representing [supertypeArgument] to be evaluated
  /// against a [FullTypeEnvironmentStructure] representing [declaringType]. Any
  /// [TypeVariableType]s appearing in [supertypeArgument] which are declared by
  /// [declaringType] are always encoded as indices.
  jsAst.Literal encodeDirectSupertypeRecipe(ModularEmitter emitter,
      InterfaceType declaringType, DartType supertypeArgument);

  /// Converts a recipe into a fragment of code that accesses the evaluated
  /// recipe.
  // TODO(33422): Remove need for this by pushing stubs through SSA.
  jsAst.Expression evaluateRecipe(ModularEmitter emitter, jsAst.Literal recipe);

  // TODO(sra): Still need a $signature function when the function type is a
  // function of closed type variables. See if the $signature method can always
  // be generated through SSA in those cases.
  jsAst.Expression encodeSignature(ModularNamer namer, ModularEmitter emitter,
      DartType type, jsAst.Expression this_);
}

class RecipeEncoderImpl implements RecipeEncoder {
  final JClosedWorld _closedWorld;
  final RuntimeTypesSubstitutions _rtiSubstitutions;
  final NativeBasicData _nativeData;
  final JElementEnvironment _elementEnvironment;
  final JCommonElements commonElements;
  final RuntimeTypesNeed _rtiNeed;

  RecipeEncoderImpl(this._closedWorld, this._rtiSubstitutions, this._nativeData,
      this._elementEnvironment, this.commonElements, this._rtiNeed);

  @override
  RecipeEncoding encodeRecipe(ModularEmitter emitter,
      TypeEnvironmentStructure environmentStructure, TypeRecipe recipe) {
    return _RecipeGenerator(this, emitter, environmentStructure, recipe).run();
  }

  @override
  jsAst.Literal encodeGroundRecipe(ModularEmitter emitter, TypeRecipe recipe) {
    return _RecipeGenerator(this, emitter, null, recipe).run().recipe;
  }

  @override
  jsAst.Literal encodeRecipeWithVariablesReplaceByAny(
      ModularEmitter emitter, DartType dartType) {
    return _RecipeGenerator(this, emitter, null, TypeExpressionRecipe(dartType),
            hackTypeVariablesToAny: true)
        .run()
        .recipe;
  }

  @override
  jsAst.Literal encodeDirectSupertypeRecipe(ModularEmitter emitter,
      InterfaceType declaringType, DartType supertypeArgument) {
    return _RecipeGenerator(
            this,
            emitter,
            FullTypeEnvironmentStructure(classType: declaringType),
            TypeExpressionRecipe(supertypeArgument),
            indexTypeVariablesOnDeclaringClass: true)
        .run()
        .recipe;
  }

  @override
  jsAst.Expression evaluateRecipe(
      ModularEmitter emitter, jsAst.Literal recipe) {
    return js('#(#)',
        [emitter.staticFunctionAccess(commonElements.findType), recipe]);
  }

  @override
  jsAst.Expression encodeSignature(ModularNamer namer, ModularEmitter emitter,
      DartType type, jsAst.Expression this_) {
    // TODO(sra): These inputs (referenced to quell lints) are used by the old
    // rti signature generator. Do we need them?
    _rtiNeed;
    commonElements;
    _elementEnvironment;
    throw UnimplementedError('RecipeEncoderImpl.getSignatureEncoding');
  }
}

class _RecipeGenerator implements DartTypeVisitor<void, void> {
  final RecipeEncoderImpl _encoder;
  final ModularEmitter _emitter;
  final TypeEnvironmentStructure _environment;
  final TypeRecipe _recipe;
  final bool indexTypeVariablesOnDeclaringClass;
  final bool hackTypeVariablesToAny;

  final List<FunctionTypeVariable> functionTypeVariables = [];
  final Set<TypeVariableType> typeVariables = {};

  // Accumulated recipe.
  final List<jsAst.Literal> _fragments = [];
  final List<int> _codes = [];

  _RecipeGenerator(
      this._encoder, this._emitter, this._environment, this._recipe,
      {this.indexTypeVariablesOnDeclaringClass = false,
      this.hackTypeVariablesToAny = false});

  JClosedWorld get _closedWorld => _encoder._closedWorld;
  NativeBasicData get _nativeData => _encoder._nativeData;
  RuntimeTypesSubstitutions get _rtiSubstitutions => _encoder._rtiSubstitutions;

  RecipeEncoding _finishEncoding(jsAst.Literal literal) =>
      RecipeEncoding(literal, typeVariables);

  RecipeEncoding run() {
    _start(_recipe);
    assert(functionTypeVariables.isEmpty);
    if (_fragments.isEmpty) {
      return _finishEncoding(js.string(String.fromCharCodes(_codes)));
    }
    _flushCodes();
    jsAst.LiteralString quote = jsAst.LiteralString('"');
    return _finishEncoding(
        jsAst.StringConcatenation([quote, ..._fragments, quote]));
  }

  void _start(TypeRecipe recipe) {
    if (recipe is TypeExpressionRecipe) {
      visit(recipe.type, null);
    } else if (recipe is SingletonTypeEnvironmentRecipe) {
      visit(recipe.type, null);
    } else if (recipe is FullTypeEnvironmentRecipe) {
      _startFullTypeEnvironmentRecipe(recipe, null);
    }
  }

  void _startFullTypeEnvironmentRecipe(FullTypeEnvironmentRecipe recipe, _) {
    if (recipe.classType == null) {
      _emitCode(Recipe.pushDynamic);
      assert(recipe.types.isNotEmpty);
    } else {
      visit(recipe.classType, null);
      // TODO(sra): The separator can be omitted when the parser will have
      // reduced to the top of stack to an Rti value.
      _emitCode(Recipe.toType);
    }

    if (recipe.types.isNotEmpty) {
      _emitCode(Recipe.startTypeArguments);
      bool first = true;
      for (DartType type in recipe.types) {
        if (!first) {
          _emitCode(Recipe.separator);
        }
        visit(type, _);
        first = false;
      }
      _emitCode(Recipe.endTypeArguments);
    }
  }

  void _emitCode(int code) {
    // TODO(sra): We should permit codes with short escapes (like '\n') for
    // infrequent operators.
    assert(code >= 0x20 && code <= 0x7E && code != 0x22);
    _codes.add(code);
  }

  void _flushCodes() {
    if (_codes.isEmpty) return;
    // TODO(sra): codes need some escaping.
    _fragments.add(StringBackedName(String.fromCharCodes(_codes)));
    _codes.clear();
  }

  void _emitInteger(int value) {
    if (_codes.isEmpty ? _fragments.isNotEmpty : Recipe.isDigit(_codes.last)) {
      _emitCode(Recipe.separator);
    }
    _emitStringUnescaped('$value');
  }

  void _emitStringUnescaped(String string) {
    for (int code in string.codeUnits) {
      _emitCode(code);
    }
  }

  void _emitName(jsAst.Name name) {
    if (_fragments.isNotEmpty && _codes.isEmpty) {
      _emitCode(Recipe.separator);
    }
    _flushCodes();
    _fragments.add(name);
  }

  void _emitExtensionOp(int value) {
    _emitInteger(value);
    _emitCode(Recipe.extensionOp);
  }

  @override
  void visit(DartType type, _) => type.accept(this, _);

  @override
  void visitTypeVariableType(TypeVariableType type, _) {
    if (hackTypeVariablesToAny) {
      // Emit 'any' type.
      _emitExtensionOp(Recipe.pushAnyExtension);
      return;
    }

    TypeEnvironmentStructure environment = _environment;
    if (environment is SingletonTypeEnvironmentStructure) {
      if (type == environment.variable) {
        _emitInteger(0);
        return;
      }
    }
    if (environment is FullTypeEnvironmentStructure) {
      int i = environment.bindings.indexOf(type);
      if (i >= 0) {
        // Indexes are 1-based since '0' encodes using the entire type for the
        // singleton structure.
        _emitInteger(i + 1);
        return;
      }

      int index = _indexIntoClassTypeVariables(type);
      if (index != null) {
        // Indexed class type variables come after the bound function type
        // variables.
        _emitInteger(1 + environment.bindings.length + index);
        return;
      }
      jsAst.Name name = _emitter.typeVariableAccessNewRti(type.element);
      _emitName(name);
      typeVariables.add(type);
      return;
    }
    // TODO(sra): Handle missing cases. This just emits some readable junk. The
    // backticks ensure it won't parse at runtime.
    '`$type`'.codeUnits.forEach(_emitCode);
  }

  int /*?*/ _indexIntoClassTypeVariables(TypeVariableType variable) {
    TypeVariableEntity element = variable.element;
    ClassEntity cls = element.typeDeclaration;

    if (indexTypeVariablesOnDeclaringClass) {
      TypeEnvironmentStructure environment = _environment;
      if (environment is FullTypeEnvironmentStructure) {
        if (identical(environment.classType.element, cls)) {
          return element.index;
        }
      }
    }

    // TODO(sra): We might be in a context where the class type variable has an
    // index, even though in the general case it is not at a specific index.

    if (_closedWorld.isUsedAsMixin(cls)) return null;

    ClassHierarchy classHierarchy = _closedWorld.classHierarchy;
    if (classHierarchy.anyStrictSubclassOf(cls, (ClassEntity subclass) {
      return !_rtiSubstitutions.isTrivialSubstitution(subclass, cls);
    })) {
      return null;
    }
    return element.index;
  }

  @override
  void visitFunctionTypeVariable(FunctionTypeVariable type, _) {
    int position = functionTypeVariables.indexOf(type);
    assert(position >= 0);
    // See [visitFunctionType] for explanation.
    _emitInteger(functionTypeVariables.length - position - 1);
    _emitCode(Recipe.genericFunctionTypeParameterIndex);
  }

  @override
  void visitDynamicType(DynamicType type, _) {
    _emitCode(Recipe.pushDynamic);
  }

  @override
  void visitInterfaceType(InterfaceType type, _) {
    jsAst.Name name = _emitter.typeAccessNewRti(type.element);
    if (type.typeArguments.isEmpty) {
      // Push the name, which is later converted by an implicit toType
      // operation.
      _emitName(name);
    } else {
      _emitName(name);
      _emitCode(Recipe.startTypeArguments);
      bool first = true;
      for (DartType argumentType in type.typeArguments) {
        if (!first) {
          _emitCode(Recipe.separator);
        }
        if (_nativeData.isJsInteropClass(type.element)) {
          // Emit 'any' type.
          _emitExtensionOp(Recipe.pushAnyExtension);
        } else {
          visit(argumentType, _);
        }
        first = false;
      }
      _emitCode(Recipe.endTypeArguments);
    }
  }

  @override
  void visitFunctionType(FunctionType type, _) {
    if (type.typeVariables.isNotEmpty) {
      // Enter generic function scope.
      //
      // Function type variables are encoded as a modified de Bruin index. We
      // count variables from the current scope outwards, counting the variables
      // in the same scope left-to-right.
      //
      // If we push the current scope's variables in reverse, then the index is
      // the position measured from the end.
      //
      //    foo<AA,BB>() => ...
      //      //^0 ^1
      //    functionTypeVariables: [BB,AA]
      //
      //    foo<AA,BB>() => <UU,VV,WW>() => ...
      //        ^3 ^4        ^0 ^1 ^2
      //    functionTypeVariables: [BB,AA,WW,VV,UU]
      //
      for (FunctionTypeVariable variable in type.typeVariables.reversed) {
        functionTypeVariables.add(variable);
      }
    }

    visit(type.returnType, _);
    _emitCode(Recipe.startFunctionArguments);

    bool first = true;
    for (DartType parameterType in type.parameterTypes) {
      if (!first) {
        _emitCode(Recipe.separator);
      }
      visit(parameterType, _);
      first = false;
    }

    if (type.optionalParameterTypes.isNotEmpty) {
      first = true;
      _emitCode(Recipe.startOptionalGroup);
      for (DartType parameterType in type.optionalParameterTypes) {
        if (!first) {
          _emitCode(Recipe.separator);
        }
        visit(parameterType, _);
        first = false;
      }
      _emitCode(Recipe.endOptionalGroup);
    }

    void emitNamedGroup(List<String> names, List<DartType> types) {
      assert(names.length == types.length);
      first = true;
      _emitCode(Recipe.startNamedGroup);
      for (int i = 0; i < names.length; i++) {
        if (!first) {
          _emitCode(Recipe.separator);
        }
        _emitStringUnescaped(names[i]);
        _emitCode(Recipe.nameSeparator);
        visit(types[i], _);
        first = false;
      }
      _emitCode(Recipe.endNamedGroup);
    }

    // TODO(sra): These are optional named parameters. Handle required named
    // parameters the same way when they are implemented.
    if (type.namedParameterTypes.isNotEmpty) {
      emitNamedGroup(type.namedParameters, type.namedParameterTypes);
    }

    _emitCode(Recipe.endFunctionArguments);

    // Emit generic type bounds.
    if (type.typeVariables.isNotEmpty) {
      bool first = true;
      _emitCode(Recipe.startTypeArguments);
      for (FunctionTypeVariable typeVariable in type.typeVariables) {
        if (!first) {
          _emitCode(Recipe.separator);
        }
        visit(typeVariable.bound, _);
      }
      _emitCode(Recipe.endTypeArguments);
    }

    if (type.typeVariables.isNotEmpty) {
      // Exit generic function scope. Remove the type variables pushed at entry.
      functionTypeVariables.length -= type.typeVariables.length;
    }
  }

  @override
  void visitVoidType(VoidType type, _) {
    _emitCode(Recipe.pushVoid);
  }

  @override
  void visitTypedefType(TypedefType type, _) {
    visit(type.unaliased, _);
  }

  @override
  void visitFutureOrType(FutureOrType type, _) {
    visit(type.typeArgument, _);
    _emitCode(Recipe.wrapFutureOr);
  }
}

class _RulesetEntry {
  final InterfaceType _targetType;
  List<InterfaceType> _supertypes;
  Map<TypeVariableType, DartType> _typeVariables;

  _RulesetEntry(
      this._targetType, Iterable<InterfaceType> supertypes, this._typeVariables)
      : _supertypes = supertypes.toList();

  bool get isEmpty => _supertypes.isEmpty && _typeVariables.isEmpty;
}

class Ruleset {
  List<_RulesetEntry> _entries;

  Ruleset(this._entries);
  Ruleset.empty() : this([]);

  void add(InterfaceType targetType, Iterable<InterfaceType> supertypes,
          Map<TypeVariableType, DartType> typeVariables) =>
      _entries.add(_RulesetEntry(targetType, supertypes, typeVariables));
}

class RulesetEncoder {
  final DartTypes _dartTypes;
  final ModularEmitter _emitter;
  final RecipeEncoder _recipeEncoder;

  RulesetEncoder(this._dartTypes, this._emitter, this._recipeEncoder);

  CommonElements get _commonElements => _dartTypes.commonElements;
  ClassEntity get _objectClass => _commonElements.objectClass;

  final _leftBrace = js.stringPart('{');
  final _rightBrace = js.stringPart('}');
  final _leftBracket = js.stringPart('[');
  final _rightBracket = js.stringPart(']');
  final _colon = js.stringPart(':');
  final _comma = js.stringPart(',');
  final _quote = js.stringPart("'");

  bool _isObject(InterfaceType type) => identical(type.element, _objectClass);

  void _preprocessEntry(_RulesetEntry entry) {
    entry._supertypes.removeWhere((InterfaceType supertype) =>
        _isObject(supertype) || identical(entry._targetType, supertype));
  }

  void _preprocessRuleset(Ruleset ruleset) {
    ruleset._entries
        .removeWhere((_RulesetEntry entry) => _isObject(entry._targetType));
    ruleset._entries.forEach(_preprocessEntry);
    ruleset._entries.removeWhere((_RulesetEntry entry) => entry.isEmpty);
  }

  // TODO(fishythefish): Common substring elimination.

  /// Produces a string readable by `JSON.parse()`.
  jsAst.StringConcatenation encodeRuleset(Ruleset ruleset) {
    _preprocessRuleset(ruleset);
    return _encodeRuleset(ruleset);
  }

  jsAst.StringConcatenation _encodeRuleset(Ruleset ruleset) =>
      js.concatenateStrings([
        _quote,
        _leftBrace,
        ...js.joinLiterals(ruleset._entries.map(_encodeEntry), _comma),
        _rightBrace,
        _quote,
      ]);

  jsAst.StringConcatenation _encodeEntry(_RulesetEntry entry) =>
      js.concatenateStrings([
        js.quoteName(_emitter.typeAccessNewRti(entry._targetType.element)),
        _colon,
        _leftBrace,
        ...js.joinLiterals([
          ...entry._supertypes.map((InterfaceType supertype) =>
              _encodeSupertype(entry._targetType, supertype)),
          ...entry._typeVariables.entries.map((mapEntry) => _encodeTypeVariable(
              entry._targetType, mapEntry.key, mapEntry.value))
        ], _comma),
        _rightBrace,
      ]);

  jsAst.StringConcatenation _encodeSupertype(
          InterfaceType targetType, InterfaceType supertype) =>
      js.concatenateStrings([
        js.quoteName(_emitter.typeAccessNewRti(supertype.element)),
        _colon,
        _leftBracket,
        ...js.joinLiterals(
            supertype.typeArguments.map((DartType supertypeArgument) =>
                _encodeSupertypeArgument(targetType, supertypeArgument)),
            _comma),
        _rightBracket,
      ]);

  jsAst.StringConcatenation _encodeTypeVariable(InterfaceType targetType,
          TypeVariableType typeVariable, DartType supertypeArgument) =>
      js.concatenateStrings([
        js.quoteName(_emitter.typeVariableAccessNewRti(typeVariable.element)),
        _colon,
        _encodeSupertypeArgument(targetType, supertypeArgument),
      ]);

  jsAst.Literal _encodeSupertypeArgument(
          InterfaceType targetType, DartType supertypeArgument) =>
      _recipeEncoder.encodeDirectSupertypeRecipe(
          _emitter, targetType, supertypeArgument);
}

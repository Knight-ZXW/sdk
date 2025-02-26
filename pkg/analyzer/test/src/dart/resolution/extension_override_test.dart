// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'driver_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ExtensionOverrideTest);
  });
}

@reflectiveTest
class ExtensionOverrideTest extends DriverResolutionTest {
  ExtensionElement extension;
  ExtensionOverride extensionOverride;

  @override
  AnalysisOptionsImpl get analysisOptions => AnalysisOptionsImpl()
    ..contextFeatures = new FeatureSet.forTesting(
        sdkVersion: '2.3.0', additionalFeatures: [Feature.extension_methods]);

  void findDeclarationAndOverride(
      {@required String declarationName,
      @required String overrideSearch,
      String declarationUri}) {
    if (declarationUri == null) {
      ExtensionDeclaration declaration =
          findNode.extensionDeclaration('extension $declarationName');
      extension = declaration?.declaredElement;
    } else {
      extension =
          findElement.importFind(declarationUri).extension_(declarationName);
    }
    extensionOverride = findNode.extensionOverride(overrideSearch);
  }

  test_call_noPrefix_noTypeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E on A {
  int call(String s) => 0;
}
void f(A a) {
  E(a)('');
}
''');
    findDeclarationAndOverride(declarationName: 'E ', overrideSearch: 'E(a)');
    validateOverride();
    validateCall();
  }

  @failingTest
  test_call_noPrefix_typeArguments() async {
    // The test is failing because we're not yet doing type inference.
    await assertNoErrorsInCode('''
class A {}
extension E<T> on A {
  int call(T s) => 0;
}
void f(A a) {
  E<String>(a)('');
}
''');
    findDeclarationAndOverride(declarationName: 'E<T>', overrideSearch: 'E<S');
    validateOverride(typeArguments: [stringType]);
    validateCall();
  }

  test_call_prefix_noTypeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E on A {
  int call(String s) => 0;
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E(a)('');
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E(a)');
    validateOverride();
    validateCall();
  }

  @failingTest
  test_call_prefix_typeArguments() async {
    // The test is failing because we're not yet doing type inference.
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E<T> on A {
  int call(T s) => 0;
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E<String>(a)('');
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E<S');
    validateOverride(typeArguments: [stringType]);
    validateCall();
  }

  test_getter_noPrefix_noTypeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E on A {
  int get g => 0;
}
void f(A a) {
  E(a).g;
}
''');
    findDeclarationAndOverride(declarationName: 'E ', overrideSearch: 'E(a)');
    validateOverride();
    validatePropertyAccess();
  }

  test_getter_noPrefix_noTypeArguments_methodInvocation() async {
    await assertNoErrorsInCode('''
class A {}

extension E on A {
  double Function(int) get g => (b) => 2.0;
}

void f(A a) {
  E(a).g(0);
}
''');
    findDeclarationAndOverride(declarationName: 'E ', overrideSearch: 'E(a)');
    validateOverride();

    var invocation = findNode.methodInvocation('g(0);');
    assertMethodInvocation(
      invocation,
      findElement.getter('g'),
      'double Function(int)',
      expectedMethodNameType: 'double Function(int) Function()',
    );
  }

  test_getter_noPrefix_typeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E<T> on A {
  int get g => 0;
}
void f(A a) {
  E<int>(a).g;
}
''');
    findDeclarationAndOverride(declarationName: 'E', overrideSearch: 'E<int>');
    validateOverride(typeArguments: [intType]);
    validatePropertyAccess();
  }

  test_getter_prefix_noTypeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E on A {
  int get g => 0;
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E(a).g;
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E(a)');
    validateOverride();
    validatePropertyAccess();
  }

  test_getter_prefix_typeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E<T> on A {
  int get g => 0;
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E<int>(a).g;
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E<int>');
    validateOverride(typeArguments: [intType]);
    validatePropertyAccess();
  }

  test_method_noPrefix_noTypeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E on A {
  void m() {}
}
void f(A a) {
  E(a).m();
}
''');
    findDeclarationAndOverride(declarationName: 'E ', overrideSearch: 'E(a)');
    validateOverride();
    validateInvocation();
  }

  test_method_noPrefix_typeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E<T> on A {
  void m() {}
}
void f(A a) {
  E<int>(a).m();
}
''');
    findDeclarationAndOverride(declarationName: 'E', overrideSearch: 'E<int>');
    validateOverride(typeArguments: [intType]);
    validateInvocation();
  }

  test_method_prefix_noTypeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E on A {
  void m() {}
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E(a).m();
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E(a)');
    validateOverride();
    validateInvocation();
  }

  test_method_prefix_typeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E<T> on A {
  void m() {}
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E<int>(a).m();
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E<int>');
    validateOverride(typeArguments: [intType]);
    validateInvocation();
  }

  test_operator_noPrefix_noTypeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E on A {
  void operator +(int offset) {}
}
void f(A a) {
  E(a) + 1;
}
''');
    findDeclarationAndOverride(declarationName: 'E ', overrideSearch: 'E(a)');
    validateOverride();
    validateBinaryExpression();
  }

  test_operator_noPrefix_typeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E<T> on A {
  void operator +(int offset) {}
}
void f(A a) {
  E<int>(a) + 1;
}
''');
    findDeclarationAndOverride(declarationName: 'E', overrideSearch: 'E<int>');
    validateOverride(typeArguments: [intType]);
    validateBinaryExpression();
  }

  test_operator_prefix_noTypeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E on A {
  void operator +(int offset) {}
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E(a) + 1;
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E(a)');
    validateOverride();
    validateBinaryExpression();
  }

  test_operator_prefix_typeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E<T> on A {
  void operator +(int offset) {}
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E<int>(a) + 1;
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E<int>');
    validateOverride(typeArguments: [intType]);
    validateBinaryExpression();
  }

  test_setter_noPrefix_noTypeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E on A {
  set s(int x) {}
}
void f(A a) {
  E(a).s = 0;
}
''');
    findDeclarationAndOverride(declarationName: 'E ', overrideSearch: 'E(a)');
    validateOverride();
    validatePropertyAccess();
  }

  test_setter_noPrefix_typeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E<T> on A {
  set s(int x) {}
}
void f(A a) {
  E<int>(a).s = 0;
}
''');
    findDeclarationAndOverride(declarationName: 'E', overrideSearch: 'E<int>');
    validateOverride(typeArguments: [intType]);
    validatePropertyAccess();
  }

  test_setter_prefix_noTypeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E on A {
  set s(int x) {}
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E(a).s = 0;
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E(a)');
    validateOverride();
    validatePropertyAccess();
  }

  test_setter_prefix_typeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E<T> on A {
  set s(int x) {}
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E<int>(a).s = 0;
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E<int>');
    validateOverride(typeArguments: [intType]);
    validatePropertyAccess();
  }

  test_setterAndGetter_noPrefix_noTypeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E on A {
  int get s => 0;
  set s(int x) {}
}
void f(A a) {
  E(a).s += 0;
}
''');
    findDeclarationAndOverride(declarationName: 'E ', overrideSearch: 'E(a)');
    validateOverride();
    validatePropertyAccess();
  }

  test_setterAndGetter_noPrefix_typeArguments() async {
    await assertNoErrorsInCode('''
class A {}
extension E<T> on A {
  int get s => 0;
  set s(int x) {}
}
void f(A a) {
  E<int>(a).s += 0;
}
''');
    findDeclarationAndOverride(declarationName: 'E', overrideSearch: 'E<int>');
    validateOverride(typeArguments: [intType]);
    validatePropertyAccess();
  }

  test_setterAndGetter_prefix_noTypeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E on A {
  int get s => 0;
  set s(int x) {}
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E(a).s += 0;
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E(a)');
    validateOverride();
    validatePropertyAccess();
  }

  test_setterAndGetter_prefix_typeArguments() async {
    newFile('/test/lib/lib.dart', content: '''
class A {}
extension E<T> on A {
  int get s => 0;
  set s(int x) {}
}
''');
    await assertNoErrorsInCode('''
import 'lib.dart' as p;
void f(p.A a) {
  p.E<int>(a).s += 0;
}
''');
    findDeclarationAndOverride(
        declarationName: 'E',
        declarationUri: 'package:test/lib.dart',
        overrideSearch: 'E<int>');
    validateOverride(typeArguments: [intType]);
    validatePropertyAccess();
  }

  test_tearoff() async {
    await assertNoErrorsInCode('''
class C {}

extension E on C {
  void a(int x) {}
}

f(C c) => E(c).a;
''');
    var identifier = findNode.simple('a;');
    assertElement(identifier, findElement.method('a'));
    assertType(identifier, 'void Function(int)');
  }

  void validateBinaryExpression() {
    BinaryExpression binary = extensionOverride.parent as BinaryExpression;
    Element resolvedElement = binary.staticElement;
    expect(resolvedElement, extension.getMethod('+'));
  }

  void validateCall() {
    FunctionExpressionInvocation invocation =
        extensionOverride.parent as FunctionExpressionInvocation;
    Element resolvedElement = invocation.staticElement;
    expect(resolvedElement, extension.getMethod('call'));

    NodeList<Expression> arguments = invocation.argumentList.arguments;
    for (int i = 0; i < arguments.length; i++) {
      expect(arguments[i].staticParameterElement, isNotNull);
    }
  }

  void validateInvocation() {
    MethodInvocation invocation = extensionOverride.parent as MethodInvocation;

    assertMethodInvocation(
      invocation,
      extension.getMethod('m'),
      'void Function()',
    );

    NodeList<Expression> arguments = invocation.argumentList.arguments;
    for (int i = 0; i < arguments.length; i++) {
      expect(arguments[i].staticParameterElement, isNotNull);
    }
  }

  void validateOverride({List<DartType> typeArguments}) {
    expect(extensionOverride.extensionName.staticElement, extension);
    if (typeArguments == null) {
      expect(extensionOverride.typeArguments, isNull);
    } else {
      expect(
          extensionOverride.typeArguments.arguments
              .map((annotation) => annotation.type),
          unorderedEquals(typeArguments));
    }
    expect(extensionOverride.argumentList.arguments, hasLength(1));
  }

  void validatePropertyAccess() {
    PropertyAccess access = extensionOverride.parent as PropertyAccess;
    Element resolvedElement = access.propertyName.staticElement;
    PropertyAccessorElement expectedElement;
    if (access.propertyName.inSetterContext()) {
      expectedElement = extension.getSetter('s');
      if (access.propertyName.inGetterContext()) {
        PropertyAccessorElement expectedGetter = extension.getGetter('s');
        Element actualGetter =
            access.propertyName.auxiliaryElements.staticElement;
        expect(actualGetter, expectedGetter);
      }
    } else {
      expectedElement = extension.getGetter('g');
    }
    expect(resolvedElement, expectedElement);
  }
}

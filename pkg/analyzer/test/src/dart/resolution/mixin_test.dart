// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/error/syntactic_errors.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'driver_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(MixinDriverResolutionTest);
  });
}

@reflectiveTest
class MixinDriverResolutionTest extends DriverResolutionTest {
  test_accessor_getter() async {
    await assertNoErrorsInCode(r'''
mixin M {
  int get g => 0;
}
''');

    var element = findElement.mixin('M');

    var accessors = element.accessors;
    expect(accessors, hasLength(1));

    var gElement = accessors[0];
    assertElementName(gElement, 'g', offset: 20);

    var gNode = findNode.methodDeclaration('g =>');
    assertElement(gNode.name, gElement);

    var fields = element.fields;
    expect(fields, hasLength(1));
    assertElementName(fields[0], 'g', isSynthetic: true);
  }

  test_accessor_method() async {
    await assertNoErrorsInCode(r'''
mixin M {
  void foo() {}
}
''');

    var element = findElement.mixin('M');

    var methods = element.methods;
    expect(methods, hasLength(1));

    var fooElement = methods[0];
    assertElementName(fooElement, 'foo', offset: 17);

    var fooNode = findNode.methodDeclaration('foo()');
    assertElement(fooNode.name, fooElement);
  }

  test_accessor_setter() async {
    await assertNoErrorsInCode(r'''
mixin M {
  void set s(int _) {}
}
''');

    var element = findElement.mixin('M');

    var accessors = element.accessors;
    expect(accessors, hasLength(1));

    var sElement = accessors[0];
    assertElementName(sElement, 's=', offset: 21);

    var gNode = findNode.methodDeclaration('s(int _)');
    assertElement(gNode.name, sElement);

    var fields = element.fields;
    expect(fields, hasLength(1));
    assertElementName(fields[0], 's', isSynthetic: true);
  }

  test_classDeclaration_with() async {
    await assertNoErrorsInCode(r'''
mixin M {}
class A extends Object with M {} // A
''');

    var mElement = findElement.mixin('M');

    var aElement = findElement.class_('A');
    assertElementTypes(aElement.mixins, [mElement.type]);

    var mRef = findNode.typeName('M {} // A');
    assertTypeName(mRef, mElement, 'M');
  }

  test_classTypeAlias_with() async {
    await assertNoErrorsInCode(r'''
mixin M {}
class A = Object with M;
''');

    var mElement = findElement.mixin('M');

    var aElement = findElement.class_('A');
    assertElementTypes(aElement.mixins, [mElement.type]);

    var mRef = findNode.typeName('M;');
    assertTypeName(mRef, mElement, 'M');
  }

  test_commentReference() async {
    await assertNoErrorsInCode(r'''
const a = 0;

/// Reference [a] in documentation.
mixin M {}
''');

    var aRef = findNode.commentReference('a]').identifier;
    assertElement(aRef, findElement.topGet('a'));
    assertTypeNull(aRef);
  }

  test_conflictingGenericInterfaces() async {
    await assertErrorsInCode('''
class I<T> {}
class A implements I<int> {}
class B implements I<String> {}
mixin M on A implements B {}
''', [
      error(CompileTimeErrorCode.CONFLICTING_GENERIC_INTERFACES, 75, 28),
    ]);
  }

  test_element() async {
    await assertNoErrorsInCode(r'''
mixin M {}
''');

    var mixin = findNode.mixin('mixin M');
    var element = findElement.mixin('M');
    assertElement(mixin, element);

    expect(element.typeParameters, isEmpty);

    expect(element.supertype, isNull);
    expect(element.isAbstract, isTrue);
    expect(element.isEnum, isFalse);
    expect(element.isMixin, isTrue);
    expect(element.isMixinApplication, isFalse);
    expect(element.type.isObject, isFalse);

    assertElementTypes(element.superclassConstraints, [objectType]);
    assertElementTypes(element.interfaces, []);
  }

  test_element_allSupertypes() async {
    await assertNoErrorsInCode(r'''
class A {}
class B {}
class C {}

mixin M1 on A, B {}
mixin M2 on A implements B, C {}
''');

    var a = findElement.class_('A');
    var b = findElement.class_('B');
    var c = findElement.class_('C');
    assertElementTypes(
      findElement.mixin('M1').allSupertypes,
      [a.type, b.type, objectType],
    );
    assertElementTypes(
      findElement.mixin('M2').allSupertypes,
      [a.type, objectType, b.type, c.type],
    );
  }

  test_element_allSupertypes_generic() async {
    await assertNoErrorsInCode(r'''
class A<T, U> {}
class B<T> extends A<int, T> {}

mixin M1 on A<int, double> {}
mixin M2 on B<String> {}
''');

    var a = findElement.class_('A');
    var b = findElement.class_('B');
    assertElementTypes(
      findElement.mixin('M1').allSupertypes,
      [
        a.type.instantiate([intType, doubleType]),
        objectType
      ],
    );
    assertElementTypes(
      findElement.mixin('M2').allSupertypes,
      [
        b.type.instantiate([stringType]),
        a.type.instantiate([intType, stringType]),
        objectType
      ],
    );
  }

  test_error_builtInIdentifierAsTypeName() async {
    await assertErrorsInCode(r'''
mixin as {}
''', [
      error(CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPE_NAME, 6, 2),
    ]);
  }

  test_error_builtInIdentifierAsTypeName_OK_on() async {
    await assertNoErrorsInCode(r'''
class A {}

mixin on on A {}

mixin M on on {}

mixin M2 implements on {}

class B = A with on;
class C = B with M;
class D = Object with M2;
''');
  }

  test_error_conflictingStaticAndInstance_inClass_getter_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  static int get foo => 0;
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 27, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inClass_getter_method() async {
    await assertErrorsInCode(r'''
mixin M {
  static int get foo => 0;
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 27, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inClass_getter_setter() async {
    await assertErrorsInCode(r'''
mixin M {
  static int get foo => 0;
  set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 27, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inClass_method_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  static void foo() {}
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 24, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inClass_method_method() async {
    await assertErrorsInCode(r'''
mixin M {
  static void foo() {}
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 24, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inClass_method_setter() async {
    await assertErrorsInCode(r'''
mixin M {
  static void foo() {}
  set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 24, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inClass_setter_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  static set foo(_) {}
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 23, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inClass_setter_method() async {
    await assertErrorsInCode(r'''
mixin M {
  static set foo(_) {}
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 23, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inClass_setter_setter() async {
    await assertErrorsInCode(r'''
mixin M {
  static set foo(_) {}
  set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 23, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inConstraint_getter_getter() async {
    await assertErrorsInCode(r'''
class A {
  int get foo => 0;
}
mixin M on A {
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 64, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inConstraint_getter_method() async {
    await assertErrorsInCode(r'''
class A {
  int get foo => 0;
}
mixin M on A {
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 61, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inConstraint_getter_setter() async {
    await assertErrorsInCode(r'''
class A {
  set foo(_) {}
}
mixin M on A {
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 60, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inConstraint_method_getter() async {
    await assertErrorsInCode(r'''
class A {
  int get foo => 0;
}
mixin M on A {
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 61, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inConstraint_method_method() async {
    await assertErrorsInCode(r'''
class A {
  void foo() {}
}
mixin M on A {
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 57, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inConstraint_method_setter() async {
    await assertErrorsInCode(r'''
class A {
  set foo(_) {}
}
mixin M on A {
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 57, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inConstraint_setter_method() async {
    await assertErrorsInCode(r'''
class A {
  void foo() {}
}
mixin M on A {
  static set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 56, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inConstraint_setter_setter() async {
    await assertErrorsInCode(r'''
class A {
  set foo(_) {}
}
mixin M on A {
  static set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 56, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inInterface_getter_getter() async {
    await assertErrorsInCode(r'''
class A {
  int get foo => 0;
}
mixin M implements A {
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 72, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inInterface_getter_method() async {
    await assertErrorsInCode(r'''
class A {
  int get foo => 0;
}
mixin M implements A {
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 69, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inInterface_getter_setter() async {
    await assertErrorsInCode(r'''
class A {
  set foo(_) {}
}
mixin M implements A {
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 68, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inInterface_method_getter() async {
    await assertErrorsInCode(r'''
class A {
  int get foo => 0;
}
mixin M implements A {
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 69, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inInterface_method_method() async {
    await assertErrorsInCode(r'''
class A {
  void foo() {}
}
mixin M implements A {
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 65, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inInterface_method_setter() async {
    await assertErrorsInCode(r'''
class A {
  set foo(_) {}
}
mixin M implements A {
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 65, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inInterface_setter_method() async {
    await assertErrorsInCode(r'''
class A {
  void foo() {}
}
mixin M implements A {
  static set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 64, 3),
    ]);
  }

  test_error_conflictingStaticAndInstance_inInterface_setter_setter() async {
    await assertErrorsInCode(r'''
class A {
  set foo(_) {}
}
mixin M implements A {
  static set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, 64, 3),
    ]);
  }

  test_error_conflictingTypeVariableAndClass() async {
    await assertErrorsInCode(r'''
mixin M<M> {}
''', [
      error(CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_CLASS, 8, 1),
    ]);
  }

  test_error_conflictingTypeVariableAndMember_field() async {
    await assertErrorsInCode(r'''
mixin M<T> {
  var T;
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_MEMBER, 8, 1),
    ]);
  }

  test_error_conflictingTypeVariableAndMember_getter() async {
    await assertErrorsInCode(r'''
mixin M<T> {
  get T => null;
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_MEMBER, 8, 1),
    ]);
  }

  test_error_conflictingTypeVariableAndMember_method() async {
    await assertErrorsInCode(r'''
mixin M<T> {
  T() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_MEMBER, 8, 1),
    ]);
  }

  test_error_conflictingTypeVariableAndMember_method_static() async {
    await assertErrorsInCode(r'''
mixin M<T> {
  static T() {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_MEMBER, 8, 1),
    ]);
  }

  test_error_conflictingTypeVariableAndMember_setter() async {
    await assertErrorsInCode(r'''
mixin M<T> {
  void set T(_) {}
}
''', [
      error(CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_MEMBER, 8, 1),
    ]);
  }

  test_error_finalNotInitialized() async {
    await assertErrorsInCode(r'''
mixin M {
  final int f;
}
''', [
      error(StaticWarningCode.FINAL_NOT_INITIALIZED, 22, 1),
    ]);
  }

  test_error_finalNotInitialized_OK() async {
    await assertNoErrorsInCode(r'''
mixin M {
  final int f = 0;
}
''');
  }

  test_error_finalNotInitializedConstructor() async {
    await assertErrorsInCode(r'''
mixin M {
  final int f;
  M();
}
''', [
      error(CompileTimeErrorCode.MIXIN_DECLARES_CONSTRUCTOR, 27, 1),
      error(StaticWarningCode.FINAL_NOT_INITIALIZED_CONSTRUCTOR_1, 27, 1),
    ]);
  }

  test_error_finalNotInitializedConstructor_OK() async {
    await assertErrorsInCode(r'''
mixin M {
  final int f;
  M(this.f);
}
''', [
      error(CompileTimeErrorCode.MIXIN_DECLARES_CONSTRUCTOR, 27, 1),
    ]);

    var element = findElement.mixin('M');
    var constructorElement = element.constructors.single;

    var fpNode = findNode.fieldFormalParameter('f);');
    assertElement(fpNode.identifier, constructorElement.parameters[0]);

    FieldFormalParameterElement fpElement = fpNode.declaredElement;
    expect(fpElement.field, same(findElement.field('f')));
  }

  test_error_implementsClause_deferredClass() async {
    await assertErrorsInCode(r'''
import 'dart:math' deferred as math;
mixin M implements math.Random {}
''', [
      error(CompileTimeErrorCode.IMPLEMENTS_DEFERRED_CLASS, 56, 11),
    ]);
    var mathImport = findElement.import('dart:math');
    var randomElement = mathImport.importedLibrary.getType('Random');

    var element = findElement.mixin('M');
    assertElementTypes(element.interfaces, [randomElement.type]);

    var typeRef = findNode.typeName('Random {}');
    assertTypeName(typeRef, randomElement, 'Random',
        expectedPrefix: mathImport.prefix);
  }

  test_error_implementsClause_disallowedClass_int() async {
    await assertErrorsInCode(r'''
mixin M implements int {}
''', [
      error(CompileTimeErrorCode.IMPLEMENTS_DISALLOWED_CLASS, 19, 3),
    ]);

    var element = findElement.mixin('M');
    assertElementTypes(element.interfaces, [intType]);

    var typeRef = findNode.typeName('int {}');
    assertTypeName(typeRef, intElement, 'int');
  }

  test_error_implementsClause_nonClass_void() async {
    await assertErrorsInCode(r'''
mixin M implements void {}
''', [
      error(CompileTimeErrorCode.IMPLEMENTS_NON_CLASS, 19, 4),
      error(ParserErrorCode.EXPECTED_TYPE_NAME, 19, 4),
    ]);

    var element = findElement.mixin('M');
    assertElementTypes(element.interfaces, []);

    var typeRef = findNode.typeName('void {}');
    assertTypeName(typeRef, null, 'void');
  }

  test_error_implementsRepeated() async {
    await assertErrorsInCode(r'''
class A {}
mixin M implements A, A {}
''', [
      error(CompileTimeErrorCode.IMPLEMENTS_REPEATED, 33, 1),
    ]);
  }

  test_error_memberWithClassName_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  int get M => 0;
}
''', [
      error(CompileTimeErrorCode.MEMBER_WITH_CLASS_NAME, 20, 1),
    ]);
  }

  test_error_memberWithClassName_getter_static() async {
    await assertErrorsInCode(r'''
mixin M {
  static int get M => 0;
}
''', [
      error(CompileTimeErrorCode.MEMBER_WITH_CLASS_NAME, 27, 1),
    ]);
  }

  test_error_memberWithClassName_setter() async {
    await assertErrorsInCode(r'''
mixin M {
  void set M(_) {}
}
''', [
      error(CompileTimeErrorCode.MEMBER_WITH_CLASS_NAME, 21, 1),
    ]);
  }

  test_error_memberWithClassName_setter_static() async {
    await assertErrorsInCode(r'''
mixin M {
  static void set M(_) {}
}
''', [
      error(CompileTimeErrorCode.MEMBER_WITH_CLASS_NAME, 28, 1),
    ]);
  }

  test_error_mixinApplicationConcreteSuperInvokedMemberType_method() async {
    await assertErrorsInCode(r'''
class I {
  void foo([int p]) {}
}

class A {
  void foo(int p) {}
}

abstract class B extends A implements I {
  void foo([int p]);
}

mixin M on I {
  void bar() {
    super.foo(42);
  }
}

abstract class X extends B with M {}
''', [
      error(
          CompileTimeErrorCode
              .MIXIN_APPLICATION_CONCRETE_SUPER_INVOKED_MEMBER_TYPE,
          224,
          1),
    ]);
  }

  test_error_mixinApplicationConcreteSuperInvokedMemberType_OK_method_overriddenInMixin() async {
    await assertNoErrorsInCode(r'''
class A<T> {
  void remove(T x) {}
}

mixin M<U> on A<U> {
  void remove(Object x) {
    super.remove(x as U);
  }
}

class X<T> = A<T> with M<T>;
''');
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_getter() async {
    await assertErrorsInCode(r'''
abstract class A {
  int get foo;
}

mixin M on A {
  void bar() {
    super.foo;
  }
}

abstract class X extends A with M {}
''', [
      error(
          CompileTimeErrorCode
              .MIXIN_APPLICATION_NO_CONCRETE_SUPER_INVOKED_MEMBER,
          121,
          1),
    ]);
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_inNextMixin() async {
    await assertErrorsInCode('''
abstract class A {
  void foo();
}

mixin M1 on A {
  void foo() {
    super.foo();
  }
}

mixin M2 on A {
  void foo() {}
}

class X extends A with M1, M2 {}
''', [
      error(
          CompileTimeErrorCode
              .MIXIN_APPLICATION_NO_CONCRETE_SUPER_INVOKED_MEMBER,
          149,
          2),
    ]);
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_inSameMixin() async {
    await assertErrorsInCode('''
abstract class A {
  void foo();
}

mixin M on A {
  void foo() {
    super.foo();
  }
}

class X extends A with M {}
''', [
      error(
          CompileTimeErrorCode
              .MIXIN_APPLICATION_NO_CONCRETE_SUPER_INVOKED_MEMBER,
          113,
          1),
    ]);
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_method() async {
    await assertErrorsInCode(r'''
abstract class A {
  void foo();
}

mixin M on A {
  void bar() {
    super.foo();
  }
}

abstract class X extends A with M {}
''', [
      error(
          CompileTimeErrorCode
              .MIXIN_APPLICATION_NO_CONCRETE_SUPER_INVOKED_MEMBER,
          122,
          1),
    ]);
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_OK_hasNSM() async {
    await assertNoErrorsInCode(r'''
abstract class A {
  void foo();
}

mixin M on A {
  void bar() {
    super.foo();
  }
}

class C implements A {
  noSuchMethod(_) {}
}

class X extends C with M {}
''');
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_OK_hasNSM2() async {
    await assertNoErrorsInCode(r'''
abstract class A {
  void foo();
}

mixin M on A {
  void bar() {
    super.foo();
  }
}

/// Class `B` has noSuchMethod forwarder for `foo`.
class B implements A {
  noSuchMethod(_) {}
}

/// Class `C` is abstract, but it inherits noSuchMethod forwarders from `B`.
abstract class C extends B {}

class X extends C with M {}
''');
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_OK_inPreviousMixin() async {
    await assertNoErrorsInCode(r'''
abstract class A {
  void foo();
}

mixin M1 {
  void foo() {}
}

mixin M2 on A {
  void bar() {
    super.foo();
  }
}

class X extends A with M1, M2 {}
''');
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_OK_inSuper_fromMixin() async {
    await assertNoErrorsInCode(r'''
abstract class A {
  void foo();
}

mixin M1 {
  void foo() {}
}

class B extends A with M1 {}

mixin M2 on A {
  void bar() {
    super.foo();
  }
}

class X extends B with M2 {}
''');
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_OK_notInvoked() async {
    await assertNoErrorsInCode(r'''
abstract class A {
  void foo();
}

mixin M on A {}

abstract class X extends A with M {}
''');
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_OK_super_covariant() async {
    await assertNoErrorsInCode(r'''
class A {
  bar(num n) {}
}

mixin M on A {
  test() {
    super.bar(3.14);
  }
}

class B implements A {
  bar(covariant int i) {}
}

class C extends B with M {}
''');
  }

  test_error_mixinApplicationNoConcreteSuperInvokedMember_setter() async {
    await assertErrorsInCode(r'''
abstract class A {
  void set foo(_);
}

mixin M on A {
  void bar() {
    super.foo = 0;
  }
}

abstract class X extends A with M {}
''', [
      error(
          CompileTimeErrorCode
              .MIXIN_APPLICATION_NO_CONCRETE_SUPER_INVOKED_MEMBER,
          129,
          1),
    ]);
  }

  test_error_mixinApplicationNotImplementedInterface() async {
    await assertErrorsInCode(r'''
class A {}

mixin M on A {}

class X = Object with M;
''', [
      error(CompileTimeErrorCode.MIXIN_APPLICATION_NOT_IMPLEMENTED_INTERFACE,
          51, 1),
    ]);
  }

  test_error_mixinApplicationNotImplementedInterface_generic() async {
    await assertErrorsInCode(r'''
class A<T> {}

mixin M on A<int> {}

class X = A<double> with M;
''', [
      error(CompileTimeErrorCode.MIXIN_APPLICATION_NOT_IMPLEMENTED_INTERFACE,
          62, 1),
    ]);
  }

  test_error_mixinApplicationNotImplementedInterface_noMemberErrors() async {
    await assertErrorsInCode(r'''
class A {
  void foo() {}
}

mixin M on A {
  void bar() {
    super.foo();
  }
}

class C {
  noSuchMethod(_) {}
}

class X = C with M;
''', [
      error(CompileTimeErrorCode.MIXIN_APPLICATION_NOT_IMPLEMENTED_INTERFACE,
          134, 1),
    ]);
  }

  test_error_mixinApplicationNotImplementedInterface_OK_0() async {
    await assertNoErrorsInCode(r'''
mixin M {}

class X = Object with M;
''');
  }

  test_error_mixinApplicationNotImplementedInterface_OK_1() async {
    await assertNoErrorsInCode(r'''
class A {}

mixin M on A {}

class X = A with M;
''');
  }

  test_error_mixinApplicationNotImplementedInterface_OK_generic() async {
    await assertNoErrorsInCode(r'''
class A<T> {}

mixin M<T> on A<T> {}

class B<T> implements A<T> {}

class C<T> = B<T> with M<T>;
''');
  }

  test_error_mixinApplicationNotImplementedInterface_OK_previousMixin() async {
    await assertNoErrorsInCode(r'''
class A {}

mixin M1 implements A {}

mixin M2 on A {}

class X = Object with M1, M2;
''');
  }

  test_error_mixinApplicationNotImplementedInterface_oneOfTwo() async {
    await assertErrorsInCode(r'''
class A {}
class B {}
class C {}

mixin M on A, B {}

class X = C with M;
''', [
      error(CompileTimeErrorCode.MIXIN_APPLICATION_NOT_IMPLEMENTED_INTERFACE,
          71, 1),
    ]);
  }

  test_error_mixinDeclaresConstructor() async {
    await assertErrorsInCode(r'''
mixin M {
  M(int a) {
    a; // read
  }
}
''', [
      error(CompileTimeErrorCode.MIXIN_DECLARES_CONSTRUCTOR, 12, 1),
    ]);

    // Even though it is an error for a mixin to declare a constructor,
    // we still build elements for constructors, and resolve them.

    var element = findElement.mixin('M');
    var constructors = element.constructors;
    expect(constructors, hasLength(1));
    var constructorElement = constructors[0];

    var constructorNode = findNode.constructor('M(int a)');
    assertElement(constructorNode, constructorElement);

    var aElement = constructorElement.parameters[0];
    var aNode = constructorNode.parameters.parameters[0];
    assertElement(aNode, aElement);

    var aRef = findNode.simple('a; // read');
    assertElement(aRef, aElement);
    assertType(aRef, 'int');
  }

  test_error_mixinInstantiate_default() async {
    addTestFile(r'''
mixin M {}

main() {
  new M();
}
''');
    await resolveTestFile();
    assertTestErrorsWithCodes([CompileTimeErrorCode.MIXIN_INSTANTIATE]);

    var creation = findNode.instanceCreation('M();');
    var m = findElement.mixin('M');
    assertInstanceCreation(creation, m, 'M');
  }

  test_error_mixinInstantiate_named() async {
    await assertErrorsInCode(r'''
mixin M {
  M.named() {}
}

main() {
  new M.named();
}
''', [
      error(CompileTimeErrorCode.MIXIN_DECLARES_CONSTRUCTOR, 12, 1),
      error(CompileTimeErrorCode.MIXIN_INSTANTIATE, 43, 1),
    ]);

    var creation = findNode.instanceCreation('M.named();');
    var m = findElement.mixin('M');
    assertInstanceCreation(creation, m, 'M', constructorName: 'named');
  }

  test_error_mixinInstantiate_undefined() async {
    await assertErrorsInCode(r'''
mixin M {}

main() {
  new M.named();
}
''', [
      error(CompileTimeErrorCode.MIXIN_INSTANTIATE, 27, 1),
    ]);

    var creation = findNode.instanceCreation('M.named();');
    var m = findElement.mixin('M');
    assertElement(creation.constructorName.type.name, m);
  }

  test_error_onClause_deferredClass() async {
    await assertErrorsInCode(r'''
import 'dart:math' deferred as math;
mixin M on math.Random {}
''', [
      error(CompileTimeErrorCode.MIXIN_SUPER_CLASS_CONSTRAINT_DEFERRED_CLASS,
          48, 11),
    ]);
    var mathImport = findElement.import('dart:math');
    var randomElement = mathImport.importedLibrary.getType('Random');

    var element = findElement.mixin('M');
    assertElementTypes(element.superclassConstraints, [randomElement.type]);

    var typeRef = findNode.typeName('Random {}');
    assertTypeName(typeRef, randomElement, 'Random',
        expectedPrefix: mathImport.prefix);
  }

  test_error_onClause_disallowedClass_int() async {
    await assertErrorsInCode(r'''
mixin M on int {}
''', [
      error(CompileTimeErrorCode.MIXIN_SUPER_CLASS_CONSTRAINT_DISALLOWED_CLASS,
          11, 3),
    ]);

    var element = findElement.mixin('M');
    assertElementTypes(element.superclassConstraints, [intType]);

    var typeRef = findNode.typeName('int {}');
    assertTypeName(typeRef, intElement, 'int');
  }

  test_error_onClause_nonInterface_dynamic() async {
    await assertErrorsInCode(r'''
mixin M on dynamic {}
''', [
      error(CompileTimeErrorCode.MIXIN_SUPER_CLASS_CONSTRAINT_NON_INTERFACE, 11,
          7),
    ]);

    var element = findElement.mixin('M');
    assertElementTypes(element.superclassConstraints, [objectType]);

    var typeRef = findNode.typeName('dynamic {}');
    assertTypeName(typeRef, dynamicElement, 'dynamic');
  }

  test_error_onClause_nonInterface_enum() async {
    await assertErrorsInCode(r'''
enum E {E1, E2, E3}
mixin M on E {}
''', [
      error(CompileTimeErrorCode.MIXIN_SUPER_CLASS_CONSTRAINT_NON_INTERFACE, 31,
          1),
    ]);

    var element = findElement.mixin('M');
    assertElementTypes(element.superclassConstraints, [objectType]);

    var typeRef = findNode.typeName('E {}');
    assertTypeName(typeRef, findElement.enum_('E'), 'E');
  }

  test_error_onClause_nonInterface_void() async {
    await assertErrorsInCode(r'''
mixin M on void {}
''', [
      error(ParserErrorCode.EXPECTED_TYPE_NAME, 11, 4),
      error(CompileTimeErrorCode.MIXIN_SUPER_CLASS_CONSTRAINT_NON_INTERFACE, 11,
          4),
    ]);

    var element = findElement.mixin('M');
    assertElementTypes(element.superclassConstraints, [objectType]);

    var typeRef = findNode.typeName('void {}');
    assertTypeName(typeRef, null, 'void');
  }

  test_error_onClause_OK_mixin() async {
    await assertNoErrorsInCode(r'''
mixin A {}
mixin B on A {} // ref
''');

    var a = findElement.mixin('A');
    var b = findElement.mixin('B');
    assertElementTypes(b.superclassConstraints, [a.type]);
  }

  test_error_onRepeated() async {
    await assertErrorsInCode(r'''
class A {}
mixin M on A, A {}
''', [
      error(CompileTimeErrorCode.ON_REPEATED, 25, 1),
    ]);
  }

  test_error_undefinedSuperMethod() async {
    await assertErrorsInCode(r'''
class A {}

mixin M on A {
  void bar() {
    super.foo(42);
  }
}
''', [
      error(StaticTypeWarningCode.UNDEFINED_SUPER_METHOD, 52, 3),
    ]);

    var invocation = findNode.methodInvocation('foo(42)');
    assertElementNull(invocation.methodName);
    assertInvokeTypeDynamic(invocation);
    assertTypeDynamic(invocation);
  }

  test_field() async {
    await assertNoErrorsInCode(r'''
mixin M<T> {
  T f;
}
''');

    var element = findElement.mixin('M');

    var typeParameters = element.typeParameters;
    expect(typeParameters, hasLength(1));

    var tElement = typeParameters.single;
    assertElementName(tElement, 'T', offset: 8);
    assertEnclosingElement(tElement, element);

    var tNode = findNode.typeParameter('T> {');
    assertElement(tNode.name, tElement);

    var fields = element.fields;
    expect(fields, hasLength(1));

    var fElement = fields[0];
    assertElementName(fElement, 'f', offset: 17);
    assertEnclosingElement(fElement, element);

    var fNode = findNode.variableDeclaration('f;');
    assertElement(fNode.name, fElement);

    assertTypeName(findNode.typeName('T f'), tElement, 'T');

    var accessors = element.accessors;
    expect(accessors, hasLength(2));
    assertElementName(accessors[0], 'f', isSynthetic: true);
    assertElementName(accessors[1], 'f=', isSynthetic: true);
  }

  test_implementsClause() async {
    await assertNoErrorsInCode(r'''
class A {}
class B {}

mixin M implements A, B {} // M
''');

    var element = findElement.mixin('M');
    assertElementTypes(element.interfaces, [
      findElement.interfaceType('A'),
      findElement.interfaceType('B'),
    ]);

    var aRef = findNode.typeName('A, ');
    assertTypeName(aRef, findElement.class_('A'), 'A');

    var bRef = findNode.typeName('B {} // M');
    assertTypeName(bRef, findElement.class_('B'), 'B');
  }

  test_inconsistentInheritance_implements_parameterType() async {
    await assertErrorsInCode(r'''
abstract class A {
  x(int i);
}
abstract class B {
  x(String s);
}
mixin M implements A, B {}
''', [
      error(CompileTimeErrorCode.INCONSISTENT_INHERITANCE, 75, 1),
    ]);
  }

  test_inconsistentInheritance_implements_requiredParameters() async {
    await assertErrorsInCode(r'''
abstract class A {
  x();
}
abstract class B {
  x(int y);
}
mixin M implements A, B {}
''', [
      error(CompileTimeErrorCode.INCONSISTENT_INHERITANCE, 67, 1),
    ]);
  }

  test_inconsistentInheritance_implements_returnType() async {
    await assertErrorsInCode(r'''
abstract class A {
  int x();
}
abstract class B {
  String x();
}
mixin M implements A, B {}
''', [
      error(CompileTimeErrorCode.INCONSISTENT_INHERITANCE, 73, 1),
    ]);
  }

  test_inconsistentInheritance_on_parameterType() async {
    await assertErrorsInCode(r'''
abstract class A {
  x(int i);
}
abstract class B {
  x(String s);
}
mixin M on A, B {}
''', [
      error(CompileTimeErrorCode.INCONSISTENT_INHERITANCE, 75, 1),
    ]);
  }

  test_inconsistentInheritance_on_requiredParameters() async {
    await assertErrorsInCode(r'''
abstract class A {
  x();
}
abstract class B {
  x(int y);
}
mixin M on A, B {}
''', [
      error(CompileTimeErrorCode.INCONSISTENT_INHERITANCE, 67, 1),
    ]);
  }

  test_inconsistentInheritance_on_returnType() async {
    await assertErrorsInCode(r'''
abstract class A {
  int x();
}
abstract class B {
  String x();
}
mixin M on A, B {}
''', [
      error(CompileTimeErrorCode.INCONSISTENT_INHERITANCE, 73, 1),
    ]);
  }

  test_inconsistentInheritanceGetterAndMethod_implements_getter_method() async {
    await assertErrorsInCode(r'''
abstract class A {
  int get x;
}
abstract class B {
  int x();
}
mixin M implements A, B {}
''', [
      error(CompileTimeErrorCode.INCONSISTENT_INHERITANCE_GETTER_AND_METHOD, 72,
          1),
    ]);
  }

  test_inconsistentInheritanceGetterAndMethod_implements_method_getter() async {
    await assertErrorsInCode(r'''
abstract class A {
  int x();
}
abstract class B {
  int get x;
}
mixin M implements A, B {}
''', [
      error(CompileTimeErrorCode.INCONSISTENT_INHERITANCE_GETTER_AND_METHOD, 72,
          1),
    ]);
  }

  test_inconsistentInheritanceGetterAndMethod_on_getter_method() async {
    await assertErrorsInCode(r'''
abstract class A {
  int get x;
}
abstract class B {
  int x();
}
mixin M implements A, B {}
''', [
      error(CompileTimeErrorCode.INCONSISTENT_INHERITANCE_GETTER_AND_METHOD, 72,
          1),
    ]);
  }

  test_inconsistentInheritanceGetterAndMethod_on_method_getter() async {
    await assertErrorsInCode(r'''
abstract class A {
  int x();
}
abstract class B {
  int get x;
}
mixin M implements A, B {}
''', [
      error(CompileTimeErrorCode.INCONSISTENT_INHERITANCE_GETTER_AND_METHOD, 72,
          1),
    ]);
  }

  test_invalid_unresolved_before_mixin() async {
    await assertErrorsInCode(r'''
abstract class A {
  int foo();
}

mixin M on A {
  void bar() {
    super.foo();
  }
}

abstract class X extends A with U1, U2, M {}
''', [
      error(StaticWarningCode.UNDEFINED_CLASS, 121, 2),
      error(CompileTimeErrorCode.MIXIN_OF_NON_CLASS, 121, 2),
      error(CompileTimeErrorCode.MIXIN_OF_NON_CLASS, 125, 2),
      error(StaticWarningCode.UNDEFINED_CLASS, 125, 2),
      error(
          CompileTimeErrorCode
              .MIXIN_APPLICATION_NO_CONCRETE_SUPER_INVOKED_MEMBER,
          129,
          1),
    ]);
  }

  test_isMoreSpecificThan() async {
    await assertNoErrorsInCode(r'''
mixin M {}
''');

    var element = findElement.mixin('M');
    var type = element.type;
    // ignore: deprecated_member_use_from_same_package
    expect(type.isMoreSpecificThan(intType), isFalse);
  }

  test_lookUpMemberInInterfaces_Object() async {
    await assertNoErrorsInCode(r'''
class Foo {}

mixin UnhappyMixin on Foo {
  String toString() => '$runtimeType';
}
''');
  }

  test_metadata() async {
    await assertNoErrorsInCode(r'''
const a = 0;

@a
mixin M {}
''');

    var a = findElement.topGet('a');
    var element = findElement.mixin('M');

    var metadata = element.metadata;
    expect(metadata, hasLength(1));
    expect(metadata[0].element, same(a));

    var annotation = findNode.annotation('@a');
    assertElement(annotation, a);
    expect(annotation.elementAnnotation, same(metadata[0]));
  }

  test_methodCallTypeInference_mixinType() async {
    await assertNoErrorsInCode('''
main() {
  C<int> c = f();
}

class C<T> {}

mixin M<T> on C<T> {}

M<T> f<T>() => null;
''');
    var fInvocation = findNode.methodInvocation('f()');
    expect(fInvocation.staticInvokeType.toString(), 'M<int> Function()');
  }

  test_onClause() async {
    await assertNoErrorsInCode(r'''
class A {}
class B {}

mixin M on A, B {} // M
''');

    var element = findElement.mixin('M');
    assertElementTypes(element.superclassConstraints, [
      findElement.interfaceType('A'),
      findElement.interfaceType('B'),
    ]);

    var aRef = findNode.typeName('A, ');
    assertTypeName(aRef, findElement.class_('A'), 'A');

    var bRef = findNode.typeName('B {} // M');
    assertTypeName(bRef, findElement.class_('B'), 'B');
  }

  test_recursiveInterfaceInheritance_implements() async {
    await assertErrorsInCode(r'''
mixin A implements B {}
mixin B implements A {}''', [
      error(CompileTimeErrorCode.RECURSIVE_INTERFACE_INHERITANCE, 6, 1),
      error(CompileTimeErrorCode.RECURSIVE_INTERFACE_INHERITANCE, 30, 1),
    ]);
  }

  test_recursiveInterfaceInheritance_on() async {
    await assertErrorsInCode(r'''
mixin A on B {}
mixin B on A {}''', [
      error(CompileTimeErrorCode.RECURSIVE_INTERFACE_INHERITANCE, 6, 1),
      error(CompileTimeErrorCode.RECURSIVE_INTERFACE_INHERITANCE, 22, 1),
    ]);
  }

  test_recursiveInterfaceInheritanceOn() async {
    await assertErrorsInCode(r'''
mixin A on A {}
''', [
      error(CompileTimeErrorCode.RECURSIVE_INTERFACE_INHERITANCE_ON, 6, 1),
    ]);
  }

  test_superInvocation_getter() async {
    await assertNoErrorsInCode(r'''
class A {
  int get foo => 0;
}

mixin M on A {
  void bar() {
    super.foo;
  }
}

class X extends A with M {}
''');

    var access = findNode.propertyAccess('super.foo;');
    assertElement(access, findElement.getter('foo'));
    assertType(access, 'int');
  }

  test_superInvocation_method() async {
    await assertNoErrorsInCode(r'''
class A {
  void foo(int x) {}
}

mixin M on A {
  void bar() {
    super.foo(42);
  }
}

class X extends A with M {}
''');

    var invocation = findNode.methodInvocation('foo(42)');
    assertElement(invocation, findElement.method('foo'));
    assertInvokeType(invocation, 'void Function(int)');
    assertType(invocation, 'void');
  }

  test_superInvocation_setter() async {
    await assertNoErrorsInCode(r'''
class A {
  void set foo(_) {}
}

mixin M on A {
  void bar() {
    super.foo = 0;
  }
}

class X extends A with M {}
''');

    var access = findNode.propertyAccess('super.foo = 0');
    assertElement(access, findElement.setter('foo'));
    // Hm... Does it need any type?
    assertTypeDynamic(access);
  }
}

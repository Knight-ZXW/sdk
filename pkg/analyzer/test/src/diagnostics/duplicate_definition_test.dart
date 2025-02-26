// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../generated/test_support.dart';
import '../dart/resolution/driver_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(DuplicateDefinitionTest);
    defineReflectiveTests(DuplicateDefinitionClassTest);
    defineReflectiveTests(DuplicateDefinitionExtensionTest);
    defineReflectiveTests(DuplicateDefinitionMixinTest);
  });
}

@reflectiveTest
class DuplicateDefinitionClassTest extends DriverResolutionTest {
  test_instance_field_field() async {
    await assertErrorsInCode(r'''
class C {
  int foo;
  int foo;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 27, 3),
    ]);
  }

  test_instance_field_getter() async {
    await assertErrorsInCode(r'''
class C {
  int foo;
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 31, 3),
    ]);
  }

  test_instance_field_method() async {
    await assertErrorsInCode(r'''
class C {
  int foo;
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 28, 3),
    ]);
  }

  test_instance_fieldFinal_getter() async {
    await assertErrorsInCode(r'''
class C {
  final int foo = 0;
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 41, 3),
    ]);
  }

  test_instance_fieldFinal_setter() async {
    await assertNoErrorsInCode(r'''
class C {
  final int foo = 0;
  set foo(int x) {}
}
''');
  }

  test_instance_getter_getter() async {
    await assertErrorsInCode(r'''
class C {
  int get foo => 0;
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 40, 3),
    ]);
  }

  test_instance_getter_method() async {
    await assertErrorsInCode(r'''
class C {
  int get foo => 0;
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 37, 3),
    ]);
  }

  test_instance_getter_setter() async {
    await assertNoErrorsInCode(r'''
class C {
  int get foo => 0;
  set foo(_) {}
}
''');
  }

  test_instance_method_getter() async {
    await assertErrorsInCode(r'''
class C {
  void foo() {}
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 36, 3),
    ]);
  }

  test_instance_method_method() async {
    await assertErrorsInCode(r'''
class C {
  void foo() {}
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 33, 3),
    ]);
  }

  test_instance_method_setter() async {
    await assertErrorsInCode(r'''
class C {
  void foo() {}
  set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 32, 3),
    ]);
  }

  test_instance_setter_getter() async {
    await assertNoErrorsInCode(r'''
class C {
  set foo(_) {}
  int get foo => 0;
}
''');
  }

  test_instance_setter_method() async {
    await assertErrorsInCode(r'''
class C {
  set foo(_) {}
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 33, 3),
    ]);
  }

  test_instance_setter_setter() async {
    await assertErrorsInCode(r'''
class C {
  void set foo(_) {}
  void set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 42, 3),
    ]);
  }

  test_static_field_field() async {
    await assertErrorsInCode(r'''
class C {
  static int foo;
  static int foo;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 41, 3),
    ]);
  }

  test_static_field_getter() async {
    await assertErrorsInCode(r'''
class C {
  static int foo;
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 45, 3),
    ]);
  }

  test_static_field_method() async {
    await assertErrorsInCode(r'''
class C {
  static int foo;
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 42, 3),
    ]);
  }

  test_static_fieldFinal_getter() async {
    await assertErrorsInCode(r'''
class C {
  static final int foo = 0;
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 55, 3),
    ]);
  }

  test_static_fieldFinal_setter() async {
    await assertNoErrorsInCode(r'''
class C {
  static final int foo = 0;
  static set foo(int x) {}
}
''');
  }

  test_static_getter_getter() async {
    await assertErrorsInCode(r'''
class C {
  static int get foo => 0;
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 54, 3),
    ]);
  }

  test_static_getter_method() async {
    await assertErrorsInCode(r'''
class C {
  static int get foo => 0;
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 51, 3),
    ]);
  }

  test_static_getter_setter() async {
    await assertNoErrorsInCode(r'''
class C {
  static int get foo => 0;
  static set foo(_) {}
}
''');
  }

  test_static_method_getter() async {
    await assertErrorsInCode(r'''
class C {
  static void foo() {}
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 50, 3),
    ]);
  }

  test_static_method_method() async {
    await assertErrorsInCode(r'''
class C {
  static void foo() {}
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 47, 3),
    ]);
  }

  test_static_method_setter() async {
    await assertErrorsInCode(r'''
class C {
  static void foo() {}
  static set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 46, 3),
    ]);
  }

  test_static_setter_getter() async {
    await assertNoErrorsInCode(r'''
class C {
  static set foo(_) {}
  static int get foo => 0;
}
''');
  }

  test_static_setter_method() async {
    await assertErrorsInCode(r'''
class C {
  static set foo(_) {}
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 47, 3),
    ]);
  }

  test_static_setter_setter() async {
    await assertErrorsInCode(r'''
class C {
  static void set foo(_) {}
  static void set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 56, 3),
    ]);
  }
}

@reflectiveTest
class DuplicateDefinitionExtensionTest extends DriverResolutionTest {
  @override
  AnalysisOptionsImpl get analysisOptions => AnalysisOptionsImpl()
    ..contextFeatures = new FeatureSet.forTesting(
        sdkVersion: '2.3.0', additionalFeatures: [Feature.extension_methods]);

  CompileTimeErrorCode get _errorCode =>
      CompileTimeErrorCode.DUPLICATE_DEFINITION;

  test_extendedType_instance() async {
    await assertNoErrorsInCode('''
class A {
  int get foo => 0;
  set foo(_) {}
  void bar() {}
}

extension E on A {
  int get foo => 0;
  set foo(_) {}
  void bar() {}
}
''');
  }

  test_extendedType_static() async {
    await assertNoErrorsInCode('''
class A {
  static int get foo => 0;
  static set foo(_) {}
  static void bar() {}
}

extension E on A {
  static int get foo => 0;
  static set foo(_) {}
  static void bar() {}
}
''');
  }

  test_instance_getter_getter() async {
    await assertErrorsInCode('''
extension E on String {
  int get foo => 0;
  int get foo => 0;
}
''', [
      error(_errorCode, 54, 3),
    ]);
  }

  test_instance_getter_setter() async {
    await assertNoErrorsInCode('''
extension E on String {
  int get foo => 0;
  set foo(_) {}
}
''');
  }

  test_instance_method_method() async {
    await assertErrorsInCode('''
extension E on String {
  void foo() {}
  void foo() {}
}
''', [
      error(_errorCode, 47, 3),
    ]);
  }

  test_instance_setter_setter() async {
    await assertErrorsInCode('''
extension E on String {
  set foo(_) {}
  set foo(_) {}
}
''', [
      error(_errorCode, 46, 3),
    ]);
  }

  test_static_getter_getter() async {
    await assertErrorsInCode('''
extension E on String {
  static int get foo => 0;
  static int get foo => 0;
}
''', [
      error(_errorCode, 68, 3),
    ]);
  }

  test_static_getter_setter() async {
    await assertNoErrorsInCode('''
extension E on String {
  static int get foo => 0;
  static set foo(_) {}
}
''');
  }

  test_static_method_method() async {
    await assertErrorsInCode('''
extension E on String {
  static void foo() {}
  static void foo() {}
}
''', [
      error(_errorCode, 61, 3),
    ]);
  }

  test_static_setter_setter() async {
    await assertErrorsInCode('''
extension E on String {
  static set foo(_) {}
  static set foo(_) {}
}
''', [
      error(_errorCode, 60, 3),
    ]);
  }
}

@reflectiveTest
class DuplicateDefinitionMixinTest extends DriverResolutionTest {
  test_instance_field_field() async {
    await assertErrorsInCode(r'''
mixin M {
  int foo;
  int foo;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 27, 3),
    ]);
  }

  test_instance_field_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  int foo;
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 31, 3),
    ]);
  }

  test_instance_field_method() async {
    await assertErrorsInCode(r'''
mixin M {
  int foo;
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 28, 3),
    ]);
  }

  test_instance_fieldFinal_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  final int foo = 0;
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 41, 3),
    ]);
  }

  test_instance_fieldFinal_setter() async {
    await assertNoErrorsInCode(r'''
mixin M {
  final int foo = 0;
  set foo(int x) {}
}
''');
  }

  test_instance_getter_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  int get foo => 0;
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 40, 3),
    ]);
  }

  test_instance_getter_method() async {
    await assertErrorsInCode(r'''
mixin M {
  int get foo => 0;
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 37, 3),
    ]);
  }

  test_instance_getter_setter() async {
    await assertNoErrorsInCode(r'''
mixin M {
  int get foo => 0;
  set foo(_) {}
}
''');
  }

  test_instance_method_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  void foo() {}
  int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 36, 3),
    ]);
  }

  test_instance_method_method() async {
    await assertErrorsInCode(r'''
mixin M {
  void foo() {}
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 33, 3),
    ]);
  }

  test_instance_method_setter() async {
    await assertErrorsInCode(r'''
mixin M {
  void foo() {}
  set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 32, 3),
    ]);
  }

  test_instance_setter_getter() async {
    await assertNoErrorsInCode(r'''
mixin M {
  set foo(_) {}
  int get foo => 0;
}
''');
  }

  test_instance_setter_method() async {
    await assertErrorsInCode(r'''
mixin M {
  set foo(_) {}
  void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 33, 3),
    ]);
  }

  test_instance_setter_setter() async {
    await assertErrorsInCode(r'''
mixin M {
  void set foo(_) {}
  void set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 42, 3),
    ]);
  }

  test_static_field_field() async {
    await assertErrorsInCode(r'''
mixin M {
  static int foo;
  static int foo;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 41, 3),
    ]);
  }

  test_static_field_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  static int foo;
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 45, 3),
    ]);
  }

  test_static_field_method() async {
    await assertErrorsInCode(r'''
mixin M {
  static int foo;
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 42, 3),
    ]);
  }

  test_static_fieldFinal_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  static final int foo = 0;
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 55, 3),
    ]);
  }

  test_static_fieldFinal_setter() async {
    await assertNoErrorsInCode(r'''
mixin M {
  static final int foo = 0;
  static set foo(int x) {}
}
''');
  }

  test_static_getter_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  static int get foo => 0;
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 54, 3),
    ]);
  }

  test_static_getter_method() async {
    await assertErrorsInCode(r'''
mixin M {
  static int get foo => 0;
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 51, 3),
    ]);
  }

  test_static_getter_setter() async {
    await assertNoErrorsInCode(r'''
mixin M {
  static int get foo => 0;
  static set foo(_) {}
}
''');
  }

  test_static_method_getter() async {
    await assertErrorsInCode(r'''
mixin M {
  static void foo() {}
  static int get foo => 0;
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 50, 3),
    ]);
  }

  test_static_method_method() async {
    await assertErrorsInCode(r'''
mixin M {
  static void foo() {}
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 47, 3),
    ]);
  }

  test_static_method_setter() async {
    await assertErrorsInCode(r'''
mixin M {
  static void foo() {}
  static set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 46, 3),
    ]);
  }

  test_static_setter_getter() async {
    await assertNoErrorsInCode(r'''
mixin M {
  static set foo(_) {}
  static int get foo => 0;
}
''');
  }

  test_static_setter_method() async {
    await assertErrorsInCode(r'''
mixin M {
  static set foo(_) {}
  static void foo() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 47, 3),
    ]);
  }

  test_static_setter_setter() async {
    await assertErrorsInCode(r'''
mixin M {
  static void set foo(_) {}
  static void set foo(_) {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 56, 3),
    ]);
  }
}

@reflectiveTest
class DuplicateDefinitionTest extends DriverResolutionTest {
  test_catch() async {
    await assertErrorsInCode(r'''
main() {
  try {} catch (e, e) {}
}''', [
      error(HintCode.UNUSED_CATCH_STACK, 28, 1),
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 28, 1),
    ]);
  }

  test_for_initializers() async {
    await assertErrorsInCode(r'''
f() {
  for (int i = 0, i = 0; i < 5;) {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 24, 1),
      error(HintCode.UNUSED_LOCAL_VARIABLE, 24, 1),
    ]);
  }

  test_locals_block_if() async {
    await assertErrorsInCode(r'''
main(int p) {
  if (p != 0) {
    var a;
    var a;
  }
}
''', [
      error(HintCode.UNUSED_LOCAL_VARIABLE, 38, 1),
      error(HintCode.UNUSED_LOCAL_VARIABLE, 49, 1),
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 49, 1),
    ]);
  }

  test_locals_block_method() async {
    await assertErrorsInCode(r'''
class A {
  m() {
    int a;
    int a;
  }
}
''', [
      error(HintCode.UNUSED_LOCAL_VARIABLE, 26, 1),
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 37, 1),
      error(HintCode.UNUSED_LOCAL_VARIABLE, 37, 1),
    ]);
  }

  test_locals_block_switchCase() async {
    await assertErrorsInCode(r'''
main() {
  switch(1) {
    case 1:
      var a;
      var a;
  }
}
''', [
      error(HintCode.UNUSED_LOCAL_VARIABLE, 45, 1),
      error(HintCode.UNUSED_LOCAL_VARIABLE, 58, 1),
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 58, 1),
    ]);
  }

  test_locals_block_topLevelFunction() async {
    await assertErrorsInCode(r'''
main() {
  int m = 0;
  m(a) {}
}
''', [
      error(HintCode.UNUSED_LOCAL_VARIABLE, 15, 1),
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 24, 1),
      error(HintCode.UNUSED_ELEMENT, 24, 1),
    ]);
  }

  test_parameters_constructor() async {
    await assertErrorsInCode(r'''
class A {
  int a;
  A(int a, this.a);
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 35, 1),
    ]);
  }

  test_parameters_functionTypeAlias() async {
    await assertErrorsInCode(r'''
typedef void F(int a, double a);
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 29, 1),
    ]);
  }

  test_parameters_genericFunction() async {
    await assertErrorsInCode(r'''
typedef F = void Function(int a, double a);
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 40, 1),
    ]);
  }

  test_parameters_localFunction() async {
    await assertErrorsInCode(r'''
main() {
  f(int a, double a) {
  };
}
''', [
      error(HintCode.UNUSED_ELEMENT, 11, 1),
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 27, 1),
    ]);
  }

  test_parameters_method() async {
    await assertErrorsInCode(r'''
class A {
  m(int a, double a) {
  }
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 28, 1),
    ]);
  }

  test_parameters_topLevelFunction() async {
    await assertErrorsInCode(r'''
f(int a, double a) {}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 16, 1),
    ]);
  }

  test_typeParameters_class() async {
    await assertErrorsInCode(r'''
class A<T, T> {}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 11, 1),
    ]);
  }

  test_typeParameters_functionTypeAlias() async {
    await assertErrorsInCode(r'''
typedef void F<T, T>();
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 18, 1),
    ]);
  }

  test_typeParameters_genericFunction() async {
    await assertErrorsInCode(r'''
typedef F = void Function<T, T>();
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 29, 1),
    ]);
  }

  test_typeParameters_method() async {
    await assertErrorsInCode(r'''
class A {
  void m<T, T>() {}
}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 22, 1),
    ]);
  }

  test_typeParameters_topLevelFunction() async {
    await assertErrorsInCode(r'''
void f<T, T>() {}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 10, 1),
    ]);
  }

  test_unitMembers_class() async {
    await assertErrorsInCode('''
class A {}
class B {}
class A {}
''', [
      error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 28, 1),
    ]);
  }

  test_unitMembers_part_library() async {
    var libPath = convertPath('/test/lib/lib.dart');
    var aPath = convertPath('/test/lib/a.dart');
    newFile(libPath, content: '''
part 'a.dart';

class A {}
''');
    newFile(aPath, content: '''
part of 'lib.dart';

class A {}
''');

    await resolveFile(libPath);

    var aResult = await resolveFile(aPath);
    GatheringErrorListener()
      ..addAll(aResult.errors)
      ..assertErrors([
        error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 27, 1),
      ]);
  }

  test_unitMembers_part_part() async {
    var libPath = convertPath('/test/lib/lib.dart');
    var aPath = convertPath('/test/lib/a.dart');
    var bPath = convertPath('/test/lib/b.dart');
    newFile(libPath, content: '''
part 'a.dart';
part 'b.dart';
''');
    newFile(aPath, content: '''
part of 'lib.dart';

class A {}
''');
    newFile(bPath, content: '''
part of 'lib.dart';

class A {}
''');

    await resolveFile(libPath);

    var aResult = await resolveFile(aPath);
    GatheringErrorListener()
      ..addAll(aResult.errors)
      ..assertNoErrors();

    var bResult = await resolveFile(bPath);
    GatheringErrorListener()
      ..addAll(bResult.errors)
      ..assertErrors([
        error(CompileTimeErrorCode.DUPLICATE_DEFINITION, 27, 1),
      ]);
  }
}

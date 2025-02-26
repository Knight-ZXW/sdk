// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../dart/resolution/driver_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(AmbiguousExtensionMethodAccessTest);
  });
}

@reflectiveTest
class AmbiguousExtensionMethodAccessTest extends DriverResolutionTest {
  @override
  AnalysisOptionsImpl get analysisOptions => AnalysisOptionsImpl()
    ..contextFeatures = new FeatureSet.forTesting(
        sdkVersion: '2.3.0', additionalFeatures: [Feature.extension_methods]);

  test_getter() async {
    // TODO(brianwilkerson) Ensure that only one diagnostic is produced.
    await assertErrorsInCode('''
class A {}

extension A1_Ext on A {
  void get a => 1;
}

extension A2_Ext on A {
  void get a => 2;
}

f(A a) {
  a.a;
}
''', [
      error(StaticTypeWarningCode.UNDEFINED_GETTER, 117, 1),
      error(CompileTimeErrorCode.AMBIGUOUS_EXTENSION_METHOD_ACCESS, 117, 1),
    ]);
  }

  test_method() async {
    await assertErrorsInCode('''
class A {}

extension A1_Ext on A {
  void a() {}
}

extension A2_Ext on A {
  void a() {}
}

f(A a) {
  a.a();
}
''', [
      error(CompileTimeErrorCode.AMBIGUOUS_EXTENSION_METHOD_ACCESS, 107, 1),
    ]);
  }

  test_setter() async {
    // TODO(brianwilkerson) Ensure that only one diagnostic is produced.
    await assertErrorsInCode('''
class A {}

extension A1_Ext on A {
  set a(x) {}
}

extension A2_Ext on A {
  set a(x) {}
}

f(A a) {
  a.a = 3;
}
''', [
      error(StaticTypeWarningCode.UNDEFINED_SETTER, 107, 1),
      error(CompileTimeErrorCode.AMBIGUOUS_EXTENSION_METHOD_ACCESS, 107, 1),
    ]);
  }
}

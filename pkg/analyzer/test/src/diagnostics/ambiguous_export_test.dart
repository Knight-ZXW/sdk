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
    defineReflectiveTests(AmbiguousExportTest);
    defineReflectiveTests(AmbiguousExportWithExtensionMethodsTest);
  });
}

@reflectiveTest
class AmbiguousExportTest extends DriverResolutionTest {
  test_class() async {
    newFile('/test/lib/lib1.dart', content: r'''
class N {}
''');
    newFile('/test/lib/lib2.dart', content: r'''
class N {}
''');
    await assertErrorsInCode(r'''
export 'lib1.dart';
export 'lib2.dart';
''', [
      error(CompileTimeErrorCode.AMBIGUOUS_EXPORT, 20, 19),
    ]);
  }
}

@reflectiveTest
class AmbiguousExportWithExtensionMethodsTest extends DriverResolutionTest {
  @override
  AnalysisOptionsImpl get analysisOptions => AnalysisOptionsImpl()
    ..contextFeatures = new FeatureSet.forTesting(
        sdkVersion: '2.3.0', additionalFeatures: [Feature.extension_methods]);

  test_extension() async {
    newFile('/test/lib/lib1.dart', content: r'''
extension E on String {}
''');
    newFile('/test/lib/lib2.dart', content: r'''
extension E on String {}
''');
    await assertErrorsInCode(r'''
export 'lib1.dart';
export 'lib2.dart';
''', [
      error(CompileTimeErrorCode.AMBIGUOUS_EXPORT, 20, 19),
    ]);
  }
}

// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// SharedOptions=--enable-experiment=extension-methods

// Tests resolution of identifiers inside of extension methods

// Test the error cases for an extension MyExt with member names
// overlapping the global and instance scopes against:
//   - a class A with only its own members
//   - an extension ExtraExt which has members overlapping the global names,
//     the instance names from A, and the extension names from MyExt, as well as
//     its own names.

import "package:expect/expect.dart";

/////////////////////////////////////////////////////////////////////////
// Note: These imports may be deliberately unused.  They bring certain
// names into scope, in order to test that certain resolution choices are
// made even in the presence of other symbols.
/////////////////////////////////////////////////////////////////////////

// Do Not Delete.
// Bring global members into scope.
import "helpers/global_scope.dart";

// Do Not Delete.
// Bring a class A with instance members into scope.
import "helpers/class_no_shadow.dart";

// Do Not Delete.
// Bring an extension ExtraExt with symbols that overlap the global, instance,
// and extension names into scope.
import "helpers/extension_all.dart";

const bool extensionValue = true;

void checkExtensionValue(bool x) {
  Expect.equals(x, extensionValue);
}

// An extension which defines its own members
extension MyExt on A {
  bool get fieldInGlobalScope => extensionValue;
  bool get getterInGlobalScope => extensionValue;
  set setterInGlobalScope(bool x) {
    checkExtensionValue(x);
  }
  bool methodInGlobalScope() => extensionValue;

  bool get fieldInInstanceScope => extensionValue;
  bool get getterInInstanceScope => extensionValue;
  set setterInInstanceScope(bool x) {
    checkExtensionValue(x);
  }
  bool methodInInstanceScope() => extensionValue;

  bool get fieldInExtensionScope => extensionValue;
  bool get getterInExtensionScope => extensionValue;
  set setterInExtensionScope(bool x) {
    checkExtensionValue(x);
  }
  bool methodInExtensionScope() => extensionValue;

  void testNakedIdentifiers() {
    // Globals should resolve to local extension versions
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }

    // Un-prefixed instance members resolve to the local extension versions
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }

    // Extension members resolve to the extension methods in this extension
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }

    // Extension members not on this extension resolve to the extension methods
    // in the other extension (unresolved identifier "id" gets turned into
    // "this.id", which is then subject to extension method lookup).
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }

  }

  void testIdentifiersOnThis() {
    // Prefixed globals are ambiguous
    {
      bool t0 = this.fieldInGlobalScope;
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //             ^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
      checkExtensionValue(t0);
      bool t1 = this.getterInGlobalScope;
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //             ^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
      checkExtensionValue(t1);
      this.setterInGlobalScope = extensionValue;
      //   ^^^
      // [cfe] unspecified
      //   ^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //   ^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_SETTER
      bool t2 = this.methodInGlobalScope();
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      checkExtensionValue(t2);
    }

    // Instance members resolve to the instance methods and not the members
    // of either extension
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }

    // Extension members are ambigious.
    {
      bool t0 = this.fieldInExtensionScope;
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //             ^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
      checkExtensionValue(t0);
      bool t1 = this.getterInExtensionScope;
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //             ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
      checkExtensionValue(t1);
      this.setterInExtensionScope = extensionValue;
      //   ^^^
      // [cfe] unspecified
      //   ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //   ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_SETTER
      bool t2 = this.methodInExtensionScope();
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      checkExtensionValue(t2);
    }

    // Extension members not on this extension resolve to the extension methods
    // in the other extension.
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }
  }

  void testIdentifiersOnInstance() {
    A self = this;

    // Prefixed globals are ambiguous
    {
      bool t0 = self.fieldInGlobalScope;
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //             ^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
      checkExtensionValue(t0);
      bool t1 = self.getterInGlobalScope;
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //             ^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
      checkExtensionValue(t1);
      self.setterInGlobalScope = extensionValue;
      //   ^^^
      // [cfe] unspecified
      //   ^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //   ^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_SETTER
      bool t2 = self.methodInGlobalScope();
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      checkExtensionValue(t2);
    }

    // Instance members resolve to the instance methods and not the members
    // of the extension
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }

    // Extension members are ambigious.
    {
      bool t0 = self.fieldInExtensionScope;
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //             ^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
      checkExtensionValue(t0);
      bool t1 = self.getterInExtensionScope;
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //             ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
      checkExtensionValue(t1);
      self.setterInExtensionScope = extensionValue;
      //   ^^^
      // [cfe] unspecified
      //   ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //   ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_SETTER
      bool t2 = self.methodInExtensionScope();
      //             ^^^
      // [cfe] unspecified
      //             ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      checkExtensionValue(t2);
    }

    // Extension members not on this extension resolve to the extension methods
    // in the other extension.
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }
  }

  void instanceTest() {
    MyExt(this).testNakedIdentifiers();
    MyExt(this).testIdentifiersOnThis();
    MyExt(this).testIdentifiersOnInstance();
  }
}


class B extends A {
  void testNakedIdentifiers() {
    // Globals should resolve to the global name space, and not to the members
    // of either extension
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }

    // Instance members resolve to the instance methods and not the members
    // of the other extension (when present)
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }

    // Extension members are ambiguous
    {
      bool t0 = fieldInExtensionScope;
      //        ^^^
      // [cfe] unspecified
      //        ^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //        ^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_WARNING.UNDEFINED_IDENTIFIER
      checkExtensionValue(t0);
      bool t1 = getterInExtensionScope;
      //        ^^^
      // [cfe] unspecified
      //        ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //        ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_WARNING.UNDEFINED_IDENTIFIER
      checkExtensionValue(t1);
      setterInExtensionScope = extensionValue;
//    ^^^^^^^^^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
//    ^^^^^^^^^^^^^^^^^^^^^^
// [analyzer] STATIC_WARNING.UNDEFINED_IDENTIFIER
//              ^^^
// [cfe] unspecified
      bool t2 = methodInExtensionScope();
      //        ^^^
      // [cfe] unspecified
      //        ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
      //        ^^^^^^^^^^^^^^^^^^^^^^
      // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_METHOD
      checkExtensionValue(t2);
    }

   // Extension members resolve to the extension methods in the other
    // extension (unresolved identifier "id" gets turned into "this.id",
    // which is then subject to extension method lookup).
    {
      // No errors: see static_extension_internal_resolution_4_test.dart
    }
  }
}

void main() {
  var a = new A();
  a.instanceTest();
  new B().testNakedIdentifiers();

  // Check external resolution as well while we're here

  // Global names come from both extensions and hence are ambiguous.
  {
    bool t0 = a.fieldInGlobalScope;
    //          ^^^
    // [cfe] unspecified
    //          ^^^^^^^^^^^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
    //          ^^^^^^^^^^^^^^^^^^
    // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
    checkExtensionValue(t0);
    bool t1 = a.getterInGlobalScope;
    //          ^^^
    // [cfe] unspecified
    //          ^^^^^^^^^^^^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
    //          ^^^^^^^^^^^^^^^^^^^
    // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
    checkExtensionValue(t1);
    a.setterInGlobalScope = extensionValue;
    //^^^^^^^^^^^^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
    //^^^^^^^^^^^^^^^^^^^
    // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_SETTER
    // ^^^
    // [cfe] unspecified
    bool t2 = a.methodInGlobalScope();
    //          ^^^
    // [cfe] unspecified
    //          ^^^^^^^^^^^^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
    checkExtensionValue(t2);
  }

  // Instance members resolve to the instance methods and not the members
  // of the other extension (when present)
  {
    // No errors: see static_extension_internal_resolution_4_test.dart
  }

  // Extension members are ambiguous
  {
    bool t0 = a.fieldInExtensionScope;
    //          ^^^
    // [cfe] unspecified
    //          ^^^^^^^^^^^^^^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
    //          ^^^^^^^^^^^^^^^^^^^^^
    // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
    checkExtensionValue(t0);
    bool t1 = a.getterInExtensionScope;
    //          ^^^
    // [cfe] unspecified
    //          ^^^^^^^^^^^^^^^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
    //          ^^^^^^^^^^^^^^^^^^^^^^
    // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_GETTER
    checkExtensionValue(t1);
    a.setterInExtensionScope = extensionValue;
    //^^^^^^^^^^^^^^^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
    //^^^^^^^^^^^^^^^^^^^^^^
    // [analyzer] STATIC_TYPE_WARNING.UNDEFINED_SETTER
    // ^^^
    // [cfe] unspecified
    bool t2 = a.methodInExtensionScope();
    //          ^^^
    // [cfe] unspecified
    //          ^^^^^^^^^^^^^^^^^^^^^^
    // [analyzer] COMPILE_TIME_ERROR.AMBIGUOUS_EXTENSION_METHOD_ACCESS
    checkExtensionValue(t2);
  }

  // Extension members resolve to the extension methods in the other
  // extension.
  {
    // No errors: see static_extension_internal_resolution_4_test.dart
  }

}
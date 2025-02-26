// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// ignore: IMPORT_INTERNAL_LIBRARY
import 'dart:_foreign_helper';

/// ignore: IMPORT_INTERNAL_LIBRARY
import 'dart:_js_embedded_names';

/// ignore: IMPORT_INTERNAL_LIBRARY, UNUSED_IMPORT
import 'dart:_interceptors';

/*member: jsCallEmpty:SideEffects(reads nothing; writes nothing)*/
jsCallEmpty() => JS('', '#', 0);

/*member: jsCallInt:SideEffects(reads nothing; writes nothing)*/
jsCallInt() => JS('int', '#', 0);

/*member: jsCallEffectsAllDependsNoIndex:SideEffects(reads field, static; writes anything)*/
jsCallEffectsAllDependsNoIndex() => JS('effects:all;depends:no-index', '#', 0);

/*member: jsCallEffectsNoInstanceDependsNoStatic:SideEffects(reads index, field; writes index, static)*/
jsCallEffectsNoInstanceDependsNoStatic() =>
    JS('effects:no-instance;depends:no-static', '#', 0);

/*member: jsBuiltin_rawRtiToJsConstructorName:SideEffects(reads anything; writes anything)*/
jsBuiltin_rawRtiToJsConstructorName() {
  return JS_BUILTIN('String', JsBuiltin.rawRtiToJsConstructorName, null);
}

/*strong.member: jsEmbeddedGlobal_getTypeFromName:SideEffects(reads static; writes nothing)*/
/*omit.member: jsEmbeddedGlobal_getTypeFromName:SideEffects(reads static; writes nothing)*/
// With CFE constant we no longer get the noise from the static get if GET_TYPE_FROM_NAME.
/*strongConst.member: jsEmbeddedGlobal_getTypeFromName:SideEffects(reads nothing; writes nothing)*/
/*omitConst.member: jsEmbeddedGlobal_getTypeFromName:SideEffects(reads nothing; writes nothing)*/
jsEmbeddedGlobal_getTypeFromName() {
  return JS_EMBEDDED_GLOBAL('', GET_TYPE_FROM_NAME);
}

/*strong.member: jsEmbeddedGlobal_libraries:SideEffects(reads static; writes nothing)*/
/*omit.member: jsEmbeddedGlobal_libraries:SideEffects(reads static; writes nothing)*/
// With CFE constant we no longer get the noise from the static get if LIBRARIES.
/*strongConst.member: jsEmbeddedGlobal_libraries:SideEffects(reads nothing; writes nothing)*/
/*omitConst.member: jsEmbeddedGlobal_libraries:SideEffects(reads nothing; writes nothing)*/
jsEmbeddedGlobal_libraries() {
  return JS_EMBEDDED_GLOBAL('JSExtendableArray|Null', LIBRARIES);
}

/*member: jsStringConcat:SideEffects(reads nothing; writes nothing)*/
jsStringConcat() => JS_STRING_CONCAT('a', 'b');

/*member: jsGetStaticState:SideEffects(reads nothing; writes anything)*/
jsGetStaticState() => JS_GET_STATIC_STATE();

/*member: main:SideEffects(reads anything; writes anything)*/
main() {
  jsCallInt();
  jsCallEmpty();
  jsCallEffectsAllDependsNoIndex();
  jsCallEffectsNoInstanceDependsNoStatic();

  jsBuiltin_rawRtiToJsConstructorName();

  jsEmbeddedGlobal_getTypeFromName();
  jsEmbeddedGlobal_libraries();

  jsStringConcat();

  jsGetStaticState();
}

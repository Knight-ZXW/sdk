// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// This file has been automatically generated. Please do not edit it manually.
// To regenerate the file, use the script
// "pkg/analysis_server/tool/spec/generate_files".

/**
 * Matchers for data types defined in the analysis server API
 */
import 'package:test/test.dart';

import 'integration_tests.dart';

/**
 * AddContentOverlay
 *
 * {
 *   "type": "add"
 *   "content": String
 * }
 */
final Matcher isAddContentOverlay = new LazyMatcher(() => new MatchesJsonObject(
    "AddContentOverlay", {"type": equals("add"), "content": isString}));

/**
 * AnalysisError
 *
 * {
 *   "severity": AnalysisErrorSeverity
 *   "type": AnalysisErrorType
 *   "location": Location
 *   "message": String
 *   "correction": optional String
 *   "code": String
 *   "url": optional String
 *   "contextMessages": optional List<DiagnosticMessage>
 *   "hasFix": optional bool
 * }
 */
final Matcher isAnalysisError =
    new LazyMatcher(() => new MatchesJsonObject("AnalysisError", {
          "severity": isAnalysisErrorSeverity,
          "type": isAnalysisErrorType,
          "location": isLocation,
          "message": isString,
          "code": isString
        }, optionalFields: {
          "correction": isString,
          "url": isString,
          "contextMessages": isListOf(isDiagnosticMessage),
          "hasFix": isBool
        }));

/**
 * AnalysisErrorFixes
 *
 * {
 *   "error": AnalysisError
 *   "fixes": List<SourceChange>
 * }
 */
final Matcher isAnalysisErrorFixes = new LazyMatcher(() =>
    new MatchesJsonObject("AnalysisErrorFixes",
        {"error": isAnalysisError, "fixes": isListOf(isSourceChange)}));

/**
 * AnalysisErrorSeverity
 *
 * enum {
 *   INFO
 *   WARNING
 *   ERROR
 * }
 */
final Matcher isAnalysisErrorSeverity =
    new MatchesEnum("AnalysisErrorSeverity", ["INFO", "WARNING", "ERROR"]);

/**
 * AnalysisErrorType
 *
 * enum {
 *   CHECKED_MODE_COMPILE_TIME_ERROR
 *   COMPILE_TIME_ERROR
 *   HINT
 *   LINT
 *   STATIC_TYPE_WARNING
 *   STATIC_WARNING
 *   SYNTACTIC_ERROR
 *   TODO
 * }
 */
final Matcher isAnalysisErrorType = new MatchesEnum("AnalysisErrorType", [
  "CHECKED_MODE_COMPILE_TIME_ERROR",
  "COMPILE_TIME_ERROR",
  "HINT",
  "LINT",
  "STATIC_TYPE_WARNING",
  "STATIC_WARNING",
  "SYNTACTIC_ERROR",
  "TODO"
]);

/**
 * AnalysisOptions
 *
 * {
 *   "enableAsync": optional bool
 *   "enableDeferredLoading": optional bool
 *   "enableEnums": optional bool
 *   "enableNullAwareOperators": optional bool
 *   "enableSuperMixins": optional bool
 *   "generateDart2jsHints": optional bool
 *   "generateHints": optional bool
 *   "generateLints": optional bool
 * }
 */
final Matcher isAnalysisOptions = new LazyMatcher(
    () => new MatchesJsonObject("AnalysisOptions", null, optionalFields: {
          "enableAsync": isBool,
          "enableDeferredLoading": isBool,
          "enableEnums": isBool,
          "enableNullAwareOperators": isBool,
          "enableSuperMixins": isBool,
          "generateDart2jsHints": isBool,
          "generateHints": isBool,
          "generateLints": isBool
        }));

/**
 * AnalysisService
 *
 * enum {
 *   CLOSING_LABELS
 *   FOLDING
 *   HIGHLIGHTS
 *   IMPLEMENTED
 *   INVALIDATE
 *   NAVIGATION
 *   OCCURRENCES
 *   OUTLINE
 *   OVERRIDES
 * }
 */
final Matcher isAnalysisService = new MatchesEnum("AnalysisService", [
  "CLOSING_LABELS",
  "FOLDING",
  "HIGHLIGHTS",
  "IMPLEMENTED",
  "INVALIDATE",
  "NAVIGATION",
  "OCCURRENCES",
  "OUTLINE",
  "OVERRIDES"
]);

/**
 * AnalysisStatus
 *
 * {
 *   "isAnalyzing": bool
 *   "analysisTarget": optional String
 * }
 */
final Matcher isAnalysisStatus = new LazyMatcher(() => new MatchesJsonObject(
    "AnalysisStatus", {"isAnalyzing": isBool},
    optionalFields: {"analysisTarget": isString}));

/**
 * AvailableSuggestion
 *
 * {
 *   "label": String
 *   "declaringLibraryUri": String
 *   "element": Element
 *   "defaultArgumentListString": optional String
 *   "defaultArgumentListTextRanges": optional List<int>
 *   "docComplete": optional String
 *   "docSummary": optional String
 *   "parameterNames": optional List<String>
 *   "parameterTypes": optional List<String>
 *   "relevanceTags": optional List<AvailableSuggestionRelevanceTag>
 *   "requiredParameterCount": optional int
 * }
 */
final Matcher isAvailableSuggestion =
    new LazyMatcher(() => new MatchesJsonObject("AvailableSuggestion", {
          "label": isString,
          "declaringLibraryUri": isString,
          "element": isElement
        }, optionalFields: {
          "defaultArgumentListString": isString,
          "defaultArgumentListTextRanges": isListOf(isInt),
          "docComplete": isString,
          "docSummary": isString,
          "parameterNames": isListOf(isString),
          "parameterTypes": isListOf(isString),
          "relevanceTags": isListOf(isAvailableSuggestionRelevanceTag),
          "requiredParameterCount": isInt
        }));

/**
 * AvailableSuggestionRelevanceTag
 *
 * String
 */
final Matcher isAvailableSuggestionRelevanceTag = isString;

/**
 * AvailableSuggestionSet
 *
 * {
 *   "id": int
 *   "uri": String
 *   "items": List<AvailableSuggestion>
 * }
 */
final Matcher isAvailableSuggestionSet = new LazyMatcher(() =>
    new MatchesJsonObject("AvailableSuggestionSet", {
      "id": isInt,
      "uri": isString,
      "items": isListOf(isAvailableSuggestion)
    }));

/**
 * ChangeContentOverlay
 *
 * {
 *   "type": "change"
 *   "edits": List<SourceEdit>
 * }
 */
final Matcher isChangeContentOverlay = new LazyMatcher(() =>
    new MatchesJsonObject("ChangeContentOverlay",
        {"type": equals("change"), "edits": isListOf(isSourceEdit)}));

/**
 * ClosingLabel
 *
 * {
 *   "offset": int
 *   "length": int
 *   "label": String
 * }
 */
final Matcher isClosingLabel = new LazyMatcher(() => new MatchesJsonObject(
    "ClosingLabel", {"offset": isInt, "length": isInt, "label": isString}));

/**
 * CompletionId
 *
 * String
 */
final Matcher isCompletionId = isString;

/**
 * CompletionService
 *
 * enum {
 *   AVAILABLE_SUGGESTION_SETS
 * }
 */
final Matcher isCompletionService =
    new MatchesEnum("CompletionService", ["AVAILABLE_SUGGESTION_SETS"]);

/**
 * CompletionSuggestion
 *
 * {
 *   "kind": CompletionSuggestionKind
 *   "relevance": int
 *   "completion": String
 *   "displayText": optional String
 *   "selectionOffset": int
 *   "selectionLength": int
 *   "isDeprecated": bool
 *   "isPotential": bool
 *   "docSummary": optional String
 *   "docComplete": optional String
 *   "declaringType": optional String
 *   "defaultArgumentListString": optional String
 *   "defaultArgumentListTextRanges": optional List<int>
 *   "element": optional Element
 *   "returnType": optional String
 *   "parameterNames": optional List<String>
 *   "parameterTypes": optional List<String>
 *   "requiredParameterCount": optional int
 *   "hasNamedParameters": optional bool
 *   "parameterName": optional String
 *   "parameterType": optional String
 * }
 */
final Matcher isCompletionSuggestion =
    new LazyMatcher(() => new MatchesJsonObject("CompletionSuggestion", {
          "kind": isCompletionSuggestionKind,
          "relevance": isInt,
          "completion": isString,
          "selectionOffset": isInt,
          "selectionLength": isInt,
          "isDeprecated": isBool,
          "isPotential": isBool
        }, optionalFields: {
          "displayText": isString,
          "docSummary": isString,
          "docComplete": isString,
          "declaringType": isString,
          "defaultArgumentListString": isString,
          "defaultArgumentListTextRanges": isListOf(isInt),
          "element": isElement,
          "returnType": isString,
          "parameterNames": isListOf(isString),
          "parameterTypes": isListOf(isString),
          "requiredParameterCount": isInt,
          "hasNamedParameters": isBool,
          "parameterName": isString,
          "parameterType": isString
        }));

/**
 * CompletionSuggestionKind
 *
 * enum {
 *   ARGUMENT_LIST
 *   IMPORT
 *   IDENTIFIER
 *   INVOCATION
 *   KEYWORD
 *   NAMED_ARGUMENT
 *   OPTIONAL_ARGUMENT
 *   OVERRIDE
 *   PARAMETER
 * }
 */
final Matcher isCompletionSuggestionKind =
    new MatchesEnum("CompletionSuggestionKind", [
  "ARGUMENT_LIST",
  "IMPORT",
  "IDENTIFIER",
  "INVOCATION",
  "KEYWORD",
  "NAMED_ARGUMENT",
  "OPTIONAL_ARGUMENT",
  "OVERRIDE",
  "PARAMETER"
]);

/**
 * ContextData
 *
 * {
 *   "name": String
 *   "explicitFileCount": int
 *   "implicitFileCount": int
 *   "workItemQueueLength": int
 *   "cacheEntryExceptions": List<String>
 * }
 */
final Matcher isContextData =
    new LazyMatcher(() => new MatchesJsonObject("ContextData", {
          "name": isString,
          "explicitFileCount": isInt,
          "implicitFileCount": isInt,
          "workItemQueueLength": isInt,
          "cacheEntryExceptions": isListOf(isString)
        }));

/**
 * DartFix
 *
 * {
 *   "name": String
 *   "description": optional String
 *   "isRequired": optional bool
 * }
 */
final Matcher isDartFix = new LazyMatcher(() => new MatchesJsonObject(
    "DartFix", {"name": isString},
    optionalFields: {"description": isString, "isRequired": isBool}));

/**
 * DartFixSuggestion
 *
 * {
 *   "description": String
 *   "location": optional Location
 * }
 */
final Matcher isDartFixSuggestion = new LazyMatcher(() => new MatchesJsonObject(
    "DartFixSuggestion", {"description": isString},
    optionalFields: {"location": isLocation}));

/**
 * DiagnosticMessage
 *
 * {
 *   "message": String
 *   "location": Location
 * }
 */
final Matcher isDiagnosticMessage = new LazyMatcher(() => new MatchesJsonObject(
    "DiagnosticMessage", {"message": isString, "location": isLocation}));

/**
 * Element
 *
 * {
 *   "kind": ElementKind
 *   "name": String
 *   "location": optional Location
 *   "flags": int
 *   "parameters": optional String
 *   "returnType": optional String
 *   "typeParameters": optional String
 * }
 */
final Matcher isElement =
    new LazyMatcher(() => new MatchesJsonObject("Element", {
          "kind": isElementKind,
          "name": isString,
          "flags": isInt
        }, optionalFields: {
          "location": isLocation,
          "parameters": isString,
          "returnType": isString,
          "typeParameters": isString
        }));

/**
 * ElementDeclaration
 *
 * {
 *   "name": String
 *   "kind": ElementKind
 *   "fileIndex": int
 *   "offset": int
 *   "line": int
 *   "column": int
 *   "codeOffset": int
 *   "codeLength": int
 *   "className": optional String
 *   "mixinName": optional String
 *   "parameters": optional String
 * }
 */
final Matcher isElementDeclaration =
    new LazyMatcher(() => new MatchesJsonObject("ElementDeclaration", {
          "name": isString,
          "kind": isElementKind,
          "fileIndex": isInt,
          "offset": isInt,
          "line": isInt,
          "column": isInt,
          "codeOffset": isInt,
          "codeLength": isInt
        }, optionalFields: {
          "className": isString,
          "mixinName": isString,
          "parameters": isString
        }));

/**
 * ElementKind
 *
 * enum {
 *   CLASS
 *   CLASS_TYPE_ALIAS
 *   COMPILATION_UNIT
 *   CONSTRUCTOR
 *   CONSTRUCTOR_INVOCATION
 *   ENUM
 *   ENUM_CONSTANT
 *   EXTENSION
 *   FIELD
 *   FILE
 *   FUNCTION
 *   FUNCTION_INVOCATION
 *   FUNCTION_TYPE_ALIAS
 *   GETTER
 *   LABEL
 *   LIBRARY
 *   LOCAL_VARIABLE
 *   METHOD
 *   MIXIN
 *   PARAMETER
 *   PREFIX
 *   SETTER
 *   TOP_LEVEL_VARIABLE
 *   TYPE_PARAMETER
 *   UNIT_TEST_GROUP
 *   UNIT_TEST_TEST
 *   UNKNOWN
 * }
 */
final Matcher isElementKind = new MatchesEnum("ElementKind", [
  "CLASS",
  "CLASS_TYPE_ALIAS",
  "COMPILATION_UNIT",
  "CONSTRUCTOR",
  "CONSTRUCTOR_INVOCATION",
  "ENUM",
  "ENUM_CONSTANT",
  "EXTENSION",
  "FIELD",
  "FILE",
  "FUNCTION",
  "FUNCTION_INVOCATION",
  "FUNCTION_TYPE_ALIAS",
  "GETTER",
  "LABEL",
  "LIBRARY",
  "LOCAL_VARIABLE",
  "METHOD",
  "MIXIN",
  "PARAMETER",
  "PREFIX",
  "SETTER",
  "TOP_LEVEL_VARIABLE",
  "TYPE_PARAMETER",
  "UNIT_TEST_GROUP",
  "UNIT_TEST_TEST",
  "UNKNOWN"
]);

/**
 * ExecutableFile
 *
 * {
 *   "file": FilePath
 *   "kind": ExecutableKind
 * }
 */
final Matcher isExecutableFile = new LazyMatcher(() => new MatchesJsonObject(
    "ExecutableFile", {"file": isFilePath, "kind": isExecutableKind}));

/**
 * ExecutableKind
 *
 * enum {
 *   CLIENT
 *   EITHER
 *   NOT_EXECUTABLE
 *   SERVER
 * }
 */
final Matcher isExecutableKind = new MatchesEnum(
    "ExecutableKind", ["CLIENT", "EITHER", "NOT_EXECUTABLE", "SERVER"]);

/**
 * ExecutionContextId
 *
 * String
 */
final Matcher isExecutionContextId = isString;

/**
 * ExecutionService
 *
 * enum {
 *   LAUNCH_DATA
 * }
 */
final Matcher isExecutionService =
    new MatchesEnum("ExecutionService", ["LAUNCH_DATA"]);

/**
 * ExistingImport
 *
 * {
 *   "uri": int
 *   "elements": List<int>
 * }
 */
final Matcher isExistingImport = new LazyMatcher(() => new MatchesJsonObject(
    "ExistingImport", {"uri": isInt, "elements": isListOf(isInt)}));

/**
 * ExistingImports
 *
 * {
 *   "elements": ImportedElementSet
 *   "imports": List<ExistingImport>
 * }
 */
final Matcher isExistingImports = new LazyMatcher(() => new MatchesJsonObject(
    "ExistingImports",
    {"elements": isImportedElementSet, "imports": isListOf(isExistingImport)}));

/**
 * FileKind
 *
 * enum {
 *   LIBRARY
 *   PART
 * }
 */
final Matcher isFileKind = new MatchesEnum("FileKind", ["LIBRARY", "PART"]);

/**
 * FilePath
 *
 * String
 */
final Matcher isFilePath = isString;

/**
 * FlutterOutline
 *
 * {
 *   "kind": FlutterOutlineKind
 *   "offset": int
 *   "length": int
 *   "codeOffset": int
 *   "codeLength": int
 *   "label": optional String
 *   "dartElement": optional Element
 *   "attributes": optional List<FlutterOutlineAttribute>
 *   "className": optional String
 *   "parentAssociationLabel": optional String
 *   "variableName": optional String
 *   "children": optional List<FlutterOutline>
 * }
 */
final Matcher isFlutterOutline =
    new LazyMatcher(() => new MatchesJsonObject("FlutterOutline", {
          "kind": isFlutterOutlineKind,
          "offset": isInt,
          "length": isInt,
          "codeOffset": isInt,
          "codeLength": isInt
        }, optionalFields: {
          "label": isString,
          "dartElement": isElement,
          "attributes": isListOf(isFlutterOutlineAttribute),
          "className": isString,
          "parentAssociationLabel": isString,
          "variableName": isString,
          "children": isListOf(isFlutterOutline)
        }));

/**
 * FlutterOutlineAttribute
 *
 * {
 *   "name": String
 *   "label": String
 *   "literalValueBoolean": optional bool
 *   "literalValueInteger": optional int
 *   "literalValueString": optional String
 *   "nameLocation": optional Location
 *   "valueLocation": optional Location
 * }
 */
final Matcher isFlutterOutlineAttribute =
    new LazyMatcher(() => new MatchesJsonObject("FlutterOutlineAttribute", {
          "name": isString,
          "label": isString
        }, optionalFields: {
          "literalValueBoolean": isBool,
          "literalValueInteger": isInt,
          "literalValueString": isString,
          "nameLocation": isLocation,
          "valueLocation": isLocation
        }));

/**
 * FlutterOutlineKind
 *
 * enum {
 *   DART_ELEMENT
 *   GENERIC
 *   NEW_INSTANCE
 *   INVOCATION
 *   VARIABLE
 *   PLACEHOLDER
 * }
 */
final Matcher isFlutterOutlineKind = new MatchesEnum("FlutterOutlineKind", [
  "DART_ELEMENT",
  "GENERIC",
  "NEW_INSTANCE",
  "INVOCATION",
  "VARIABLE",
  "PLACEHOLDER"
]);

/**
 * FlutterService
 *
 * enum {
 *   OUTLINE
 * }
 */
final Matcher isFlutterService = new MatchesEnum("FlutterService", ["OUTLINE"]);

/**
 * FlutterWidgetProperty
 *
 * {
 *   "documentation": optional String
 *   "expression": optional String
 *   "id": int
 *   "isRequired": bool
 *   "isSafeToUpdate": bool
 *   "name": String
 *   "children": optional List<FlutterWidgetProperty>
 *   "editor": optional FlutterWidgetPropertyEditor
 *   "value": optional FlutterWidgetPropertyValue
 * }
 */
final Matcher isFlutterWidgetProperty =
    new LazyMatcher(() => new MatchesJsonObject("FlutterWidgetProperty", {
          "id": isInt,
          "isRequired": isBool,
          "isSafeToUpdate": isBool,
          "name": isString
        }, optionalFields: {
          "documentation": isString,
          "expression": isString,
          "children": isListOf(isFlutterWidgetProperty),
          "editor": isFlutterWidgetPropertyEditor,
          "value": isFlutterWidgetPropertyValue
        }));

/**
 * FlutterWidgetPropertyEditor
 *
 * {
 *   "kind": FlutterWidgetPropertyEditorKind
 *   "enumItems": optional List<FlutterWidgetPropertyValueEnumItem>
 * }
 */
final Matcher isFlutterWidgetPropertyEditor = new LazyMatcher(() =>
    new MatchesJsonObject("FlutterWidgetPropertyEditor", {
      "kind": isFlutterWidgetPropertyEditorKind
    }, optionalFields: {
      "enumItems": isListOf(isFlutterWidgetPropertyValueEnumItem)
    }));

/**
 * FlutterWidgetPropertyEditorKind
 *
 * enum {
 *   BOOL
 *   DOUBLE
 *   ENUM
 *   ENUM_LIKE
 *   INT
 *   STRING
 * }
 */
final Matcher isFlutterWidgetPropertyEditorKind = new MatchesEnum(
    "FlutterWidgetPropertyEditorKind",
    ["BOOL", "DOUBLE", "ENUM", "ENUM_LIKE", "INT", "STRING"]);

/**
 * FlutterWidgetPropertyValue
 *
 * {
 *   "boolValue": optional bool
 *   "doubleValue": optional double
 *   "intValue": optional int
 *   "stringValue": optional String
 *   "enumValue": optional FlutterWidgetPropertyValueEnumItem
 *   "expression": optional String
 * }
 */
final Matcher isFlutterWidgetPropertyValue = new LazyMatcher(() =>
    new MatchesJsonObject("FlutterWidgetPropertyValue", null, optionalFields: {
      "boolValue": isBool,
      "doubleValue": isDouble,
      "intValue": isInt,
      "stringValue": isString,
      "enumValue": isFlutterWidgetPropertyValueEnumItem,
      "expression": isString
    }));

/**
 * FlutterWidgetPropertyValueEnumItem
 *
 * {
 *   "libraryUri": String
 *   "className": String
 *   "name": String
 *   "documentation": optional String
 * }
 */
final Matcher isFlutterWidgetPropertyValueEnumItem = new LazyMatcher(() =>
    new MatchesJsonObject("FlutterWidgetPropertyValueEnumItem",
        {"libraryUri": isString, "className": isString, "name": isString},
        optionalFields: {"documentation": isString}));

/**
 * FoldingKind
 *
 * enum {
 *   ANNOTATIONS
 *   CLASS_BODY
 *   DIRECTIVES
 *   DOCUMENTATION_COMMENT
 *   FILE_HEADER
 *   FUNCTION_BODY
 *   INVOCATION
 *   LITERAL
 * }
 */
final Matcher isFoldingKind = new MatchesEnum("FoldingKind", [
  "ANNOTATIONS",
  "CLASS_BODY",
  "DIRECTIVES",
  "DOCUMENTATION_COMMENT",
  "FILE_HEADER",
  "FUNCTION_BODY",
  "INVOCATION",
  "LITERAL"
]);

/**
 * FoldingRegion
 *
 * {
 *   "kind": FoldingKind
 *   "offset": int
 *   "length": int
 * }
 */
final Matcher isFoldingRegion = new LazyMatcher(() => new MatchesJsonObject(
    "FoldingRegion",
    {"kind": isFoldingKind, "offset": isInt, "length": isInt}));

/**
 * GeneralAnalysisService
 *
 * enum {
 *   ANALYZED_FILES
 * }
 */
final Matcher isGeneralAnalysisService =
    new MatchesEnum("GeneralAnalysisService", ["ANALYZED_FILES"]);

/**
 * HighlightRegion
 *
 * {
 *   "type": HighlightRegionType
 *   "offset": int
 *   "length": int
 * }
 */
final Matcher isHighlightRegion = new LazyMatcher(() => new MatchesJsonObject(
    "HighlightRegion",
    {"type": isHighlightRegionType, "offset": isInt, "length": isInt}));

/**
 * HighlightRegionType
 *
 * enum {
 *   ANNOTATION
 *   BUILT_IN
 *   CLASS
 *   COMMENT_BLOCK
 *   COMMENT_DOCUMENTATION
 *   COMMENT_END_OF_LINE
 *   CONSTRUCTOR
 *   DIRECTIVE
 *   DYNAMIC_TYPE
 *   DYNAMIC_LOCAL_VARIABLE_DECLARATION
 *   DYNAMIC_LOCAL_VARIABLE_REFERENCE
 *   DYNAMIC_PARAMETER_DECLARATION
 *   DYNAMIC_PARAMETER_REFERENCE
 *   ENUM
 *   ENUM_CONSTANT
 *   FIELD
 *   FIELD_STATIC
 *   FUNCTION
 *   FUNCTION_DECLARATION
 *   FUNCTION_TYPE_ALIAS
 *   GETTER_DECLARATION
 *   IDENTIFIER_DEFAULT
 *   IMPORT_PREFIX
 *   INSTANCE_FIELD_DECLARATION
 *   INSTANCE_FIELD_REFERENCE
 *   INSTANCE_GETTER_DECLARATION
 *   INSTANCE_GETTER_REFERENCE
 *   INSTANCE_METHOD_DECLARATION
 *   INSTANCE_METHOD_REFERENCE
 *   INSTANCE_SETTER_DECLARATION
 *   INSTANCE_SETTER_REFERENCE
 *   INVALID_STRING_ESCAPE
 *   KEYWORD
 *   LABEL
 *   LIBRARY_NAME
 *   LITERAL_BOOLEAN
 *   LITERAL_DOUBLE
 *   LITERAL_INTEGER
 *   LITERAL_LIST
 *   LITERAL_MAP
 *   LITERAL_STRING
 *   LOCAL_FUNCTION_DECLARATION
 *   LOCAL_FUNCTION_REFERENCE
 *   LOCAL_VARIABLE
 *   LOCAL_VARIABLE_DECLARATION
 *   LOCAL_VARIABLE_REFERENCE
 *   METHOD
 *   METHOD_DECLARATION
 *   METHOD_DECLARATION_STATIC
 *   METHOD_STATIC
 *   PARAMETER
 *   SETTER_DECLARATION
 *   TOP_LEVEL_VARIABLE
 *   PARAMETER_DECLARATION
 *   PARAMETER_REFERENCE
 *   STATIC_FIELD_DECLARATION
 *   STATIC_GETTER_DECLARATION
 *   STATIC_GETTER_REFERENCE
 *   STATIC_METHOD_DECLARATION
 *   STATIC_METHOD_REFERENCE
 *   STATIC_SETTER_DECLARATION
 *   STATIC_SETTER_REFERENCE
 *   TOP_LEVEL_FUNCTION_DECLARATION
 *   TOP_LEVEL_FUNCTION_REFERENCE
 *   TOP_LEVEL_GETTER_DECLARATION
 *   TOP_LEVEL_GETTER_REFERENCE
 *   TOP_LEVEL_SETTER_DECLARATION
 *   TOP_LEVEL_SETTER_REFERENCE
 *   TOP_LEVEL_VARIABLE_DECLARATION
 *   TYPE_NAME_DYNAMIC
 *   TYPE_PARAMETER
 *   UNRESOLVED_INSTANCE_MEMBER_REFERENCE
 *   VALID_STRING_ESCAPE
 * }
 */
final Matcher isHighlightRegionType = new MatchesEnum("HighlightRegionType", [
  "ANNOTATION",
  "BUILT_IN",
  "CLASS",
  "COMMENT_BLOCK",
  "COMMENT_DOCUMENTATION",
  "COMMENT_END_OF_LINE",
  "CONSTRUCTOR",
  "DIRECTIVE",
  "DYNAMIC_TYPE",
  "DYNAMIC_LOCAL_VARIABLE_DECLARATION",
  "DYNAMIC_LOCAL_VARIABLE_REFERENCE",
  "DYNAMIC_PARAMETER_DECLARATION",
  "DYNAMIC_PARAMETER_REFERENCE",
  "ENUM",
  "ENUM_CONSTANT",
  "FIELD",
  "FIELD_STATIC",
  "FUNCTION",
  "FUNCTION_DECLARATION",
  "FUNCTION_TYPE_ALIAS",
  "GETTER_DECLARATION",
  "IDENTIFIER_DEFAULT",
  "IMPORT_PREFIX",
  "INSTANCE_FIELD_DECLARATION",
  "INSTANCE_FIELD_REFERENCE",
  "INSTANCE_GETTER_DECLARATION",
  "INSTANCE_GETTER_REFERENCE",
  "INSTANCE_METHOD_DECLARATION",
  "INSTANCE_METHOD_REFERENCE",
  "INSTANCE_SETTER_DECLARATION",
  "INSTANCE_SETTER_REFERENCE",
  "INVALID_STRING_ESCAPE",
  "KEYWORD",
  "LABEL",
  "LIBRARY_NAME",
  "LITERAL_BOOLEAN",
  "LITERAL_DOUBLE",
  "LITERAL_INTEGER",
  "LITERAL_LIST",
  "LITERAL_MAP",
  "LITERAL_STRING",
  "LOCAL_FUNCTION_DECLARATION",
  "LOCAL_FUNCTION_REFERENCE",
  "LOCAL_VARIABLE",
  "LOCAL_VARIABLE_DECLARATION",
  "LOCAL_VARIABLE_REFERENCE",
  "METHOD",
  "METHOD_DECLARATION",
  "METHOD_DECLARATION_STATIC",
  "METHOD_STATIC",
  "PARAMETER",
  "SETTER_DECLARATION",
  "TOP_LEVEL_VARIABLE",
  "PARAMETER_DECLARATION",
  "PARAMETER_REFERENCE",
  "STATIC_FIELD_DECLARATION",
  "STATIC_GETTER_DECLARATION",
  "STATIC_GETTER_REFERENCE",
  "STATIC_METHOD_DECLARATION",
  "STATIC_METHOD_REFERENCE",
  "STATIC_SETTER_DECLARATION",
  "STATIC_SETTER_REFERENCE",
  "TOP_LEVEL_FUNCTION_DECLARATION",
  "TOP_LEVEL_FUNCTION_REFERENCE",
  "TOP_LEVEL_GETTER_DECLARATION",
  "TOP_LEVEL_GETTER_REFERENCE",
  "TOP_LEVEL_SETTER_DECLARATION",
  "TOP_LEVEL_SETTER_REFERENCE",
  "TOP_LEVEL_VARIABLE_DECLARATION",
  "TYPE_NAME_DYNAMIC",
  "TYPE_PARAMETER",
  "UNRESOLVED_INSTANCE_MEMBER_REFERENCE",
  "VALID_STRING_ESCAPE"
]);

/**
 * HoverInformation
 *
 * {
 *   "offset": int
 *   "length": int
 *   "containingLibraryPath": optional String
 *   "containingLibraryName": optional String
 *   "containingClassDescription": optional String
 *   "dartdoc": optional String
 *   "elementDescription": optional String
 *   "elementKind": optional String
 *   "isDeprecated": optional bool
 *   "parameter": optional String
 *   "propagatedType": optional String
 *   "staticType": optional String
 * }
 */
final Matcher isHoverInformation =
    new LazyMatcher(() => new MatchesJsonObject("HoverInformation", {
          "offset": isInt,
          "length": isInt
        }, optionalFields: {
          "containingLibraryPath": isString,
          "containingLibraryName": isString,
          "containingClassDescription": isString,
          "dartdoc": isString,
          "elementDescription": isString,
          "elementKind": isString,
          "isDeprecated": isBool,
          "parameter": isString,
          "propagatedType": isString,
          "staticType": isString
        }));

/**
 * ImplementedClass
 *
 * {
 *   "offset": int
 *   "length": int
 * }
 */
final Matcher isImplementedClass = new LazyMatcher(() => new MatchesJsonObject(
    "ImplementedClass", {"offset": isInt, "length": isInt}));

/**
 * ImplementedMember
 *
 * {
 *   "offset": int
 *   "length": int
 * }
 */
final Matcher isImplementedMember = new LazyMatcher(() => new MatchesJsonObject(
    "ImplementedMember", {"offset": isInt, "length": isInt}));

/**
 * ImportedElementSet
 *
 * {
 *   "strings": List<String>
 *   "uris": List<int>
 *   "names": List<int>
 * }
 */
final Matcher isImportedElementSet = new LazyMatcher(() =>
    new MatchesJsonObject("ImportedElementSet", {
      "strings": isListOf(isString),
      "uris": isListOf(isInt),
      "names": isListOf(isInt)
    }));

/**
 * ImportedElements
 *
 * {
 *   "path": FilePath
 *   "prefix": String
 *   "elements": List<String>
 * }
 */
final Matcher isImportedElements = new LazyMatcher(() => new MatchesJsonObject(
    "ImportedElements",
    {"path": isFilePath, "prefix": isString, "elements": isListOf(isString)}));

/**
 * IncludedSuggestionRelevanceTag
 *
 * {
 *   "tag": AvailableSuggestionRelevanceTag
 *   "relevanceBoost": int
 * }
 */
final Matcher isIncludedSuggestionRelevanceTag = new LazyMatcher(() =>
    new MatchesJsonObject("IncludedSuggestionRelevanceTag",
        {"tag": isAvailableSuggestionRelevanceTag, "relevanceBoost": isInt}));

/**
 * IncludedSuggestionSet
 *
 * {
 *   "id": int
 *   "relevance": int
 *   "displayUri": optional String
 * }
 */
final Matcher isIncludedSuggestionSet = new LazyMatcher(() =>
    new MatchesJsonObject(
        "IncludedSuggestionSet", {"id": isInt, "relevance": isInt},
        optionalFields: {"displayUri": isString}));

/**
 * KytheEntry
 *
 * {
 *   "source": KytheVName
 *   "kind": optional String
 *   "target": optional KytheVName
 *   "fact": String
 *   "value": optional List<int>
 * }
 */
final Matcher isKytheEntry = new LazyMatcher(() => new MatchesJsonObject(
        "KytheEntry", {
      "source": isKytheVName,
      "fact": isString
    }, optionalFields: {
      "kind": isString,
      "target": isKytheVName,
      "value": isListOf(isInt)
    }));

/**
 * KytheVName
 *
 * {
 *   "signature": String
 *   "corpus": String
 *   "root": String
 *   "path": String
 *   "language": String
 * }
 */
final Matcher isKytheVName =
    new LazyMatcher(() => new MatchesJsonObject("KytheVName", {
          "signature": isString,
          "corpus": isString,
          "root": isString,
          "path": isString,
          "language": isString
        }));

/**
 * LibraryPathSet
 *
 * {
 *   "scope": FilePath
 *   "libraryPaths": List<FilePath>
 * }
 */
final Matcher isLibraryPathSet = new LazyMatcher(() => new MatchesJsonObject(
    "LibraryPathSet",
    {"scope": isFilePath, "libraryPaths": isListOf(isFilePath)}));

/**
 * LinkedEditGroup
 *
 * {
 *   "positions": List<Position>
 *   "length": int
 *   "suggestions": List<LinkedEditSuggestion>
 * }
 */
final Matcher isLinkedEditGroup =
    new LazyMatcher(() => new MatchesJsonObject("LinkedEditGroup", {
          "positions": isListOf(isPosition),
          "length": isInt,
          "suggestions": isListOf(isLinkedEditSuggestion)
        }));

/**
 * LinkedEditSuggestion
 *
 * {
 *   "value": String
 *   "kind": LinkedEditSuggestionKind
 * }
 */
final Matcher isLinkedEditSuggestion = new LazyMatcher(() =>
    new MatchesJsonObject("LinkedEditSuggestion",
        {"value": isString, "kind": isLinkedEditSuggestionKind}));

/**
 * LinkedEditSuggestionKind
 *
 * enum {
 *   METHOD
 *   PARAMETER
 *   TYPE
 *   VARIABLE
 * }
 */
final Matcher isLinkedEditSuggestionKind = new MatchesEnum(
    "LinkedEditSuggestionKind", ["METHOD", "PARAMETER", "TYPE", "VARIABLE"]);

/**
 * Location
 *
 * {
 *   "file": FilePath
 *   "offset": int
 *   "length": int
 *   "startLine": int
 *   "startColumn": int
 * }
 */
final Matcher isLocation =
    new LazyMatcher(() => new MatchesJsonObject("Location", {
          "file": isFilePath,
          "offset": isInt,
          "length": isInt,
          "startLine": isInt,
          "startColumn": isInt
        }));

/**
 * NavigationRegion
 *
 * {
 *   "offset": int
 *   "length": int
 *   "targets": List<int>
 * }
 */
final Matcher isNavigationRegion = new LazyMatcher(() => new MatchesJsonObject(
    "NavigationRegion",
    {"offset": isInt, "length": isInt, "targets": isListOf(isInt)}));

/**
 * NavigationTarget
 *
 * {
 *   "kind": ElementKind
 *   "fileIndex": int
 *   "offset": int
 *   "length": int
 *   "startLine": int
 *   "startColumn": int
 * }
 */
final Matcher isNavigationTarget =
    new LazyMatcher(() => new MatchesJsonObject("NavigationTarget", {
          "kind": isElementKind,
          "fileIndex": isInt,
          "offset": isInt,
          "length": isInt,
          "startLine": isInt,
          "startColumn": isInt
        }));

/**
 * Occurrences
 *
 * {
 *   "element": Element
 *   "offsets": List<int>
 *   "length": int
 * }
 */
final Matcher isOccurrences = new LazyMatcher(() => new MatchesJsonObject(
    "Occurrences",
    {"element": isElement, "offsets": isListOf(isInt), "length": isInt}));

/**
 * Outline
 *
 * {
 *   "element": Element
 *   "offset": int
 *   "length": int
 *   "codeOffset": int
 *   "codeLength": int
 *   "children": optional List<Outline>
 * }
 */
final Matcher isOutline =
    new LazyMatcher(() => new MatchesJsonObject("Outline", {
          "element": isElement,
          "offset": isInt,
          "length": isInt,
          "codeOffset": isInt,
          "codeLength": isInt
        }, optionalFields: {
          "children": isListOf(isOutline)
        }));

/**
 * OverriddenMember
 *
 * {
 *   "element": Element
 *   "className": String
 * }
 */
final Matcher isOverriddenMember = new LazyMatcher(() => new MatchesJsonObject(
    "OverriddenMember", {"element": isElement, "className": isString}));

/**
 * Override
 *
 * {
 *   "offset": int
 *   "length": int
 *   "superclassMember": optional OverriddenMember
 *   "interfaceMembers": optional List<OverriddenMember>
 * }
 */
final Matcher isOverride =
    new LazyMatcher(() => new MatchesJsonObject("Override", {
          "offset": isInt,
          "length": isInt
        }, optionalFields: {
          "superclassMember": isOverriddenMember,
          "interfaceMembers": isListOf(isOverriddenMember)
        }));

/**
 * ParameterInfo
 *
 * {
 *   "kind": ParameterKind
 *   "name": String
 *   "type": String
 *   "defaultValue": optional String
 * }
 */
final Matcher isParameterInfo = new LazyMatcher(() => new MatchesJsonObject(
    "ParameterInfo",
    {"kind": isParameterKind, "name": isString, "type": isString},
    optionalFields: {"defaultValue": isString}));

/**
 * ParameterKind
 *
 * enum {
 *   NAMED
 *   OPTIONAL
 *   REQUIRED
 * }
 */
final Matcher isParameterKind =
    new MatchesEnum("ParameterKind", ["NAMED", "OPTIONAL", "REQUIRED"]);

/**
 * Position
 *
 * {
 *   "file": FilePath
 *   "offset": int
 * }
 */
final Matcher isPosition = new LazyMatcher(() =>
    new MatchesJsonObject("Position", {"file": isFilePath, "offset": isInt}));

/**
 * PostfixTemplateDescriptor
 *
 * {
 *   "name": String
 *   "key": String
 *   "example": String
 * }
 */
final Matcher isPostfixTemplateDescriptor = new LazyMatcher(() =>
    new MatchesJsonObject("PostfixTemplateDescriptor",
        {"name": isString, "key": isString, "example": isString}));

/**
 * PubStatus
 *
 * {
 *   "isListingPackageDirs": bool
 * }
 */
final Matcher isPubStatus = new LazyMatcher(
    () => new MatchesJsonObject("PubStatus", {"isListingPackageDirs": isBool}));

/**
 * RefactoringFeedback
 *
 * {
 * }
 */
final Matcher isRefactoringFeedback =
    new LazyMatcher(() => new MatchesJsonObject("RefactoringFeedback", null));

/**
 * RefactoringKind
 *
 * enum {
 *   CONVERT_GETTER_TO_METHOD
 *   CONVERT_METHOD_TO_GETTER
 *   EXTRACT_LOCAL_VARIABLE
 *   EXTRACT_METHOD
 *   EXTRACT_WIDGET
 *   INLINE_LOCAL_VARIABLE
 *   INLINE_METHOD
 *   MOVE_FILE
 *   RENAME
 * }
 */
final Matcher isRefactoringKind = new MatchesEnum("RefactoringKind", [
  "CONVERT_GETTER_TO_METHOD",
  "CONVERT_METHOD_TO_GETTER",
  "EXTRACT_LOCAL_VARIABLE",
  "EXTRACT_METHOD",
  "EXTRACT_WIDGET",
  "INLINE_LOCAL_VARIABLE",
  "INLINE_METHOD",
  "MOVE_FILE",
  "RENAME"
]);

/**
 * RefactoringMethodParameter
 *
 * {
 *   "id": optional String
 *   "kind": RefactoringMethodParameterKind
 *   "type": String
 *   "name": String
 *   "parameters": optional String
 * }
 */
final Matcher isRefactoringMethodParameter = new LazyMatcher(() =>
    new MatchesJsonObject("RefactoringMethodParameter", {
      "kind": isRefactoringMethodParameterKind,
      "type": isString,
      "name": isString
    }, optionalFields: {
      "id": isString,
      "parameters": isString
    }));

/**
 * RefactoringMethodParameterKind
 *
 * enum {
 *   REQUIRED
 *   POSITIONAL
 *   NAMED
 * }
 */
final Matcher isRefactoringMethodParameterKind = new MatchesEnum(
    "RefactoringMethodParameterKind", ["REQUIRED", "POSITIONAL", "NAMED"]);

/**
 * RefactoringOptions
 *
 * {
 * }
 */
final Matcher isRefactoringOptions =
    new LazyMatcher(() => new MatchesJsonObject("RefactoringOptions", null));

/**
 * RefactoringProblem
 *
 * {
 *   "severity": RefactoringProblemSeverity
 *   "message": String
 *   "location": optional Location
 * }
 */
final Matcher isRefactoringProblem = new LazyMatcher(() =>
    new MatchesJsonObject("RefactoringProblem",
        {"severity": isRefactoringProblemSeverity, "message": isString},
        optionalFields: {"location": isLocation}));

/**
 * RefactoringProblemSeverity
 *
 * enum {
 *   INFO
 *   WARNING
 *   ERROR
 *   FATAL
 * }
 */
final Matcher isRefactoringProblemSeverity = new MatchesEnum(
    "RefactoringProblemSeverity", ["INFO", "WARNING", "ERROR", "FATAL"]);

/**
 * RemoveContentOverlay
 *
 * {
 *   "type": "remove"
 * }
 */
final Matcher isRemoveContentOverlay = new LazyMatcher(() =>
    new MatchesJsonObject("RemoveContentOverlay", {"type": equals("remove")}));

/**
 * RequestError
 *
 * {
 *   "code": RequestErrorCode
 *   "message": String
 *   "stackTrace": optional String
 * }
 */
final Matcher isRequestError = new LazyMatcher(() => new MatchesJsonObject(
    "RequestError", {"code": isRequestErrorCode, "message": isString},
    optionalFields: {"stackTrace": isString}));

/**
 * RequestErrorCode
 *
 * enum {
 *   CONTENT_MODIFIED
 *   DEBUG_PORT_COULD_NOT_BE_OPENED
 *   FILE_NOT_ANALYZED
 *   FLUTTER_GET_WIDGET_DESCRIPTION_NO_WIDGET
 *   FLUTTER_SET_WIDGET_PROPERTY_VALUE_INVALID_ID
 *   FLUTTER_SET_WIDGET_PROPERTY_VALUE_IS_REQUIRED
 *   FORMAT_INVALID_FILE
 *   FORMAT_WITH_ERRORS
 *   GET_ERRORS_INVALID_FILE
 *   GET_IMPORTED_ELEMENTS_INVALID_FILE
 *   GET_KYTHE_ENTRIES_INVALID_FILE
 *   GET_NAVIGATION_INVALID_FILE
 *   GET_REACHABLE_SOURCES_INVALID_FILE
 *   GET_SIGNATURE_INVALID_FILE
 *   GET_SIGNATURE_INVALID_OFFSET
 *   GET_SIGNATURE_UNKNOWN_FUNCTION
 *   IMPORT_ELEMENTS_INVALID_FILE
 *   INVALID_ANALYSIS_ROOT
 *   INVALID_EXECUTION_CONTEXT
 *   INVALID_FILE_PATH_FORMAT
 *   INVALID_OVERLAY_CHANGE
 *   INVALID_PARAMETER
 *   INVALID_REQUEST
 *   ORGANIZE_DIRECTIVES_ERROR
 *   REFACTORING_REQUEST_CANCELLED
 *   SERVER_ALREADY_STARTED
 *   SERVER_ERROR
 *   SORT_MEMBERS_INVALID_FILE
 *   SORT_MEMBERS_PARSE_ERRORS
 *   UNKNOWN_FIX
 *   UNKNOWN_REQUEST
 *   UNSUPPORTED_FEATURE
 * }
 */
final Matcher isRequestErrorCode = new MatchesEnum("RequestErrorCode", [
  "CONTENT_MODIFIED",
  "DEBUG_PORT_COULD_NOT_BE_OPENED",
  "FILE_NOT_ANALYZED",
  "FLUTTER_GET_WIDGET_DESCRIPTION_NO_WIDGET",
  "FLUTTER_SET_WIDGET_PROPERTY_VALUE_INVALID_ID",
  "FLUTTER_SET_WIDGET_PROPERTY_VALUE_IS_REQUIRED",
  "FORMAT_INVALID_FILE",
  "FORMAT_WITH_ERRORS",
  "GET_ERRORS_INVALID_FILE",
  "GET_IMPORTED_ELEMENTS_INVALID_FILE",
  "GET_KYTHE_ENTRIES_INVALID_FILE",
  "GET_NAVIGATION_INVALID_FILE",
  "GET_REACHABLE_SOURCES_INVALID_FILE",
  "GET_SIGNATURE_INVALID_FILE",
  "GET_SIGNATURE_INVALID_OFFSET",
  "GET_SIGNATURE_UNKNOWN_FUNCTION",
  "IMPORT_ELEMENTS_INVALID_FILE",
  "INVALID_ANALYSIS_ROOT",
  "INVALID_EXECUTION_CONTEXT",
  "INVALID_FILE_PATH_FORMAT",
  "INVALID_OVERLAY_CHANGE",
  "INVALID_PARAMETER",
  "INVALID_REQUEST",
  "ORGANIZE_DIRECTIVES_ERROR",
  "REFACTORING_REQUEST_CANCELLED",
  "SERVER_ALREADY_STARTED",
  "SERVER_ERROR",
  "SORT_MEMBERS_INVALID_FILE",
  "SORT_MEMBERS_PARSE_ERRORS",
  "UNKNOWN_FIX",
  "UNKNOWN_REQUEST",
  "UNSUPPORTED_FEATURE"
]);

/**
 * RuntimeCompletionExpression
 *
 * {
 *   "offset": int
 *   "length": int
 *   "type": optional RuntimeCompletionExpressionType
 * }
 */
final Matcher isRuntimeCompletionExpression = new LazyMatcher(() =>
    new MatchesJsonObject(
        "RuntimeCompletionExpression", {"offset": isInt, "length": isInt},
        optionalFields: {"type": isRuntimeCompletionExpressionType}));

/**
 * RuntimeCompletionExpressionType
 *
 * {
 *   "libraryPath": optional FilePath
 *   "kind": RuntimeCompletionExpressionTypeKind
 *   "name": optional String
 *   "typeArguments": optional List<RuntimeCompletionExpressionType>
 *   "returnType": optional RuntimeCompletionExpressionType
 *   "parameterTypes": optional List<RuntimeCompletionExpressionType>
 *   "parameterNames": optional List<String>
 * }
 */
final Matcher isRuntimeCompletionExpressionType = new LazyMatcher(
    () => new MatchesJsonObject("RuntimeCompletionExpressionType", {
          "kind": isRuntimeCompletionExpressionTypeKind
        }, optionalFields: {
          "libraryPath": isFilePath,
          "name": isString,
          "typeArguments": isListOf(isRuntimeCompletionExpressionType),
          "returnType": isRuntimeCompletionExpressionType,
          "parameterTypes": isListOf(isRuntimeCompletionExpressionType),
          "parameterNames": isListOf(isString)
        }));

/**
 * RuntimeCompletionExpressionTypeKind
 *
 * enum {
 *   DYNAMIC
 *   FUNCTION
 *   INTERFACE
 * }
 */
final Matcher isRuntimeCompletionExpressionTypeKind = new MatchesEnum(
    "RuntimeCompletionExpressionTypeKind",
    ["DYNAMIC", "FUNCTION", "INTERFACE"]);

/**
 * RuntimeCompletionVariable
 *
 * {
 *   "name": String
 *   "type": RuntimeCompletionExpressionType
 * }
 */
final Matcher isRuntimeCompletionVariable = new LazyMatcher(() =>
    new MatchesJsonObject("RuntimeCompletionVariable",
        {"name": isString, "type": isRuntimeCompletionExpressionType}));

/**
 * SearchId
 *
 * String
 */
final Matcher isSearchId = isString;

/**
 * SearchResult
 *
 * {
 *   "location": Location
 *   "kind": SearchResultKind
 *   "isPotential": bool
 *   "path": List<Element>
 * }
 */
final Matcher isSearchResult =
    new LazyMatcher(() => new MatchesJsonObject("SearchResult", {
          "location": isLocation,
          "kind": isSearchResultKind,
          "isPotential": isBool,
          "path": isListOf(isElement)
        }));

/**
 * SearchResultKind
 *
 * enum {
 *   DECLARATION
 *   INVOCATION
 *   READ
 *   READ_WRITE
 *   REFERENCE
 *   UNKNOWN
 *   WRITE
 * }
 */
final Matcher isSearchResultKind = new MatchesEnum("SearchResultKind", [
  "DECLARATION",
  "INVOCATION",
  "READ",
  "READ_WRITE",
  "REFERENCE",
  "UNKNOWN",
  "WRITE"
]);

/**
 * ServerService
 *
 * enum {
 *   STATUS
 * }
 */
final Matcher isServerService = new MatchesEnum("ServerService", ["STATUS"]);

/**
 * SourceChange
 *
 * {
 *   "message": String
 *   "edits": List<SourceFileEdit>
 *   "linkedEditGroups": List<LinkedEditGroup>
 *   "selection": optional Position
 *   "id": optional String
 * }
 */
final Matcher isSourceChange =
    new LazyMatcher(() => new MatchesJsonObject("SourceChange", {
          "message": isString,
          "edits": isListOf(isSourceFileEdit),
          "linkedEditGroups": isListOf(isLinkedEditGroup)
        }, optionalFields: {
          "selection": isPosition,
          "id": isString
        }));

/**
 * SourceEdit
 *
 * {
 *   "offset": int
 *   "length": int
 *   "replacement": String
 *   "id": optional String
 * }
 */
final Matcher isSourceEdit = new LazyMatcher(() => new MatchesJsonObject(
    "SourceEdit", {"offset": isInt, "length": isInt, "replacement": isString},
    optionalFields: {"id": isString}));

/**
 * SourceFileEdit
 *
 * {
 *   "file": FilePath
 *   "fileStamp": long
 *   "edits": List<SourceEdit>
 * }
 */
final Matcher isSourceFileEdit = new LazyMatcher(() => new MatchesJsonObject(
    "SourceFileEdit",
    {"file": isFilePath, "fileStamp": isInt, "edits": isListOf(isSourceEdit)}));

/**
 * TokenDetails
 *
 * {
 *   "lexeme": String
 *   "type": optional String
 *   "validElementKinds": optional List<String>
 * }
 */
final Matcher isTokenDetails = new LazyMatcher(() => new MatchesJsonObject(
        "TokenDetails", {
      "lexeme": isString
    }, optionalFields: {
      "type": isString,
      "validElementKinds": isListOf(isString)
    }));

/**
 * TypeHierarchyItem
 *
 * {
 *   "classElement": Element
 *   "displayName": optional String
 *   "memberElement": optional Element
 *   "superclass": optional int
 *   "interfaces": List<int>
 *   "mixins": List<int>
 *   "subclasses": List<int>
 * }
 */
final Matcher isTypeHierarchyItem =
    new LazyMatcher(() => new MatchesJsonObject("TypeHierarchyItem", {
          "classElement": isElement,
          "interfaces": isListOf(isInt),
          "mixins": isListOf(isInt),
          "subclasses": isListOf(isInt)
        }, optionalFields: {
          "displayName": isString,
          "memberElement": isElement,
          "superclass": isInt
        }));

/**
 * analysis.analyzedFiles params
 *
 * {
 *   "directories": List<FilePath>
 * }
 */
final Matcher isAnalysisAnalyzedFilesParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.analyzedFiles params",
        {"directories": isListOf(isFilePath)}));

/**
 * analysis.closingLabels params
 *
 * {
 *   "file": FilePath
 *   "labels": List<ClosingLabel>
 * }
 */
final Matcher isAnalysisClosingLabelsParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.closingLabels params",
        {"file": isFilePath, "labels": isListOf(isClosingLabel)}));

/**
 * analysis.errors params
 *
 * {
 *   "file": FilePath
 *   "errors": List<AnalysisError>
 * }
 */
final Matcher isAnalysisErrorsParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.errors params",
        {"file": isFilePath, "errors": isListOf(isAnalysisError)}));

/**
 * analysis.flushResults params
 *
 * {
 *   "files": List<FilePath>
 * }
 */
final Matcher isAnalysisFlushResultsParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "analysis.flushResults params", {"files": isListOf(isFilePath)}));

/**
 * analysis.folding params
 *
 * {
 *   "file": FilePath
 *   "regions": List<FoldingRegion>
 * }
 */
final Matcher isAnalysisFoldingParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.folding params",
        {"file": isFilePath, "regions": isListOf(isFoldingRegion)}));

/**
 * analysis.getErrors params
 *
 * {
 *   "file": FilePath
 * }
 */
final Matcher isAnalysisGetErrorsParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.getErrors params", {"file": isFilePath}));

/**
 * analysis.getErrors result
 *
 * {
 *   "errors": List<AnalysisError>
 * }
 */
final Matcher isAnalysisGetErrorsResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "analysis.getErrors result", {"errors": isListOf(isAnalysisError)}));

/**
 * analysis.getHover params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 * }
 */
final Matcher isAnalysisGetHoverParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "analysis.getHover params", {"file": isFilePath, "offset": isInt}));

/**
 * analysis.getHover result
 *
 * {
 *   "hovers": List<HoverInformation>
 * }
 */
final Matcher isAnalysisGetHoverResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "analysis.getHover result", {"hovers": isListOf(isHoverInformation)}));

/**
 * analysis.getImportedElements params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 *   "length": int
 * }
 */
final Matcher isAnalysisGetImportedElementsParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.getImportedElements params",
        {"file": isFilePath, "offset": isInt, "length": isInt}));

/**
 * analysis.getImportedElements result
 *
 * {
 *   "elements": List<ImportedElements>
 * }
 */
final Matcher isAnalysisGetImportedElementsResult = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.getImportedElements result",
        {"elements": isListOf(isImportedElements)}));

/**
 * analysis.getLibraryDependencies params
 */
final Matcher isAnalysisGetLibraryDependenciesParams = isNull;

/**
 * analysis.getLibraryDependencies result
 *
 * {
 *   "libraries": List<FilePath>
 *   "packageMap": Map<String, Map<String, List<FilePath>>>
 * }
 */
final Matcher isAnalysisGetLibraryDependenciesResult = new LazyMatcher(
    () => new MatchesJsonObject("analysis.getLibraryDependencies result", {
          "libraries": isListOf(isFilePath),
          "packageMap":
              isMapOf(isString, isMapOf(isString, isListOf(isFilePath)))
        }));

/**
 * analysis.getNavigation params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 *   "length": int
 * }
 */
final Matcher isAnalysisGetNavigationParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.getNavigation params",
        {"file": isFilePath, "offset": isInt, "length": isInt}));

/**
 * analysis.getNavigation result
 *
 * {
 *   "files": List<FilePath>
 *   "targets": List<NavigationTarget>
 *   "regions": List<NavigationRegion>
 * }
 */
final Matcher isAnalysisGetNavigationResult = new LazyMatcher(
    () => new MatchesJsonObject("analysis.getNavigation result", {
          "files": isListOf(isFilePath),
          "targets": isListOf(isNavigationTarget),
          "regions": isListOf(isNavigationRegion)
        }));

/**
 * analysis.getReachableSources params
 *
 * {
 *   "file": FilePath
 * }
 */
final Matcher isAnalysisGetReachableSourcesParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "analysis.getReachableSources params", {"file": isFilePath}));

/**
 * analysis.getReachableSources result
 *
 * {
 *   "sources": Map<String, List<String>>
 * }
 */
final Matcher isAnalysisGetReachableSourcesResult = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.getReachableSources result",
        {"sources": isMapOf(isString, isListOf(isString))}));

/**
 * analysis.getSignature params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 * }
 */
final Matcher isAnalysisGetSignatureParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "analysis.getSignature params", {"file": isFilePath, "offset": isInt}));

/**
 * analysis.getSignature result
 *
 * {
 *   "name": String
 *   "parameters": List<ParameterInfo>
 *   "dartdoc": optional String
 * }
 */
final Matcher isAnalysisGetSignatureResult = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.getSignature result",
        {"name": isString, "parameters": isListOf(isParameterInfo)},
        optionalFields: {"dartdoc": isString}));

/**
 * analysis.highlights params
 *
 * {
 *   "file": FilePath
 *   "regions": List<HighlightRegion>
 * }
 */
final Matcher isAnalysisHighlightsParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.highlights params",
        {"file": isFilePath, "regions": isListOf(isHighlightRegion)}));

/**
 * analysis.implemented params
 *
 * {
 *   "file": FilePath
 *   "classes": List<ImplementedClass>
 *   "members": List<ImplementedMember>
 * }
 */
final Matcher isAnalysisImplementedParams =
    new LazyMatcher(() => new MatchesJsonObject("analysis.implemented params", {
          "file": isFilePath,
          "classes": isListOf(isImplementedClass),
          "members": isListOf(isImplementedMember)
        }));

/**
 * analysis.invalidate params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 *   "length": int
 *   "delta": int
 * }
 */
final Matcher isAnalysisInvalidateParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.invalidate params", {
      "file": isFilePath,
      "offset": isInt,
      "length": isInt,
      "delta": isInt
    }));

/**
 * analysis.navigation params
 *
 * {
 *   "file": FilePath
 *   "regions": List<NavigationRegion>
 *   "targets": List<NavigationTarget>
 *   "files": List<FilePath>
 * }
 */
final Matcher isAnalysisNavigationParams =
    new LazyMatcher(() => new MatchesJsonObject("analysis.navigation params", {
          "file": isFilePath,
          "regions": isListOf(isNavigationRegion),
          "targets": isListOf(isNavigationTarget),
          "files": isListOf(isFilePath)
        }));

/**
 * analysis.occurrences params
 *
 * {
 *   "file": FilePath
 *   "occurrences": List<Occurrences>
 * }
 */
final Matcher isAnalysisOccurrencesParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.occurrences params",
        {"file": isFilePath, "occurrences": isListOf(isOccurrences)}));

/**
 * analysis.outline params
 *
 * {
 *   "file": FilePath
 *   "kind": FileKind
 *   "libraryName": optional String
 *   "outline": Outline
 * }
 */
final Matcher isAnalysisOutlineParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.outline params",
        {"file": isFilePath, "kind": isFileKind, "outline": isOutline},
        optionalFields: {"libraryName": isString}));

/**
 * analysis.overrides params
 *
 * {
 *   "file": FilePath
 *   "overrides": List<Override>
 * }
 */
final Matcher isAnalysisOverridesParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.overrides params",
        {"file": isFilePath, "overrides": isListOf(isOverride)}));

/**
 * analysis.reanalyze params
 */
final Matcher isAnalysisReanalyzeParams = isNull;

/**
 * analysis.reanalyze result
 */
final Matcher isAnalysisReanalyzeResult = isNull;

/**
 * analysis.setAnalysisRoots params
 *
 * {
 *   "included": List<FilePath>
 *   "excluded": List<FilePath>
 *   "packageRoots": optional Map<FilePath, FilePath>
 * }
 */
final Matcher isAnalysisSetAnalysisRootsParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.setAnalysisRoots params",
        {"included": isListOf(isFilePath), "excluded": isListOf(isFilePath)},
        optionalFields: {"packageRoots": isMapOf(isFilePath, isFilePath)}));

/**
 * analysis.setAnalysisRoots result
 */
final Matcher isAnalysisSetAnalysisRootsResult = isNull;

/**
 * analysis.setGeneralSubscriptions params
 *
 * {
 *   "subscriptions": List<GeneralAnalysisService>
 * }
 */
final Matcher isAnalysisSetGeneralSubscriptionsParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.setGeneralSubscriptions params",
        {"subscriptions": isListOf(isGeneralAnalysisService)}));

/**
 * analysis.setGeneralSubscriptions result
 */
final Matcher isAnalysisSetGeneralSubscriptionsResult = isNull;

/**
 * analysis.setPriorityFiles params
 *
 * {
 *   "files": List<FilePath>
 * }
 */
final Matcher isAnalysisSetPriorityFilesParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "analysis.setPriorityFiles params", {"files": isListOf(isFilePath)}));

/**
 * analysis.setPriorityFiles result
 */
final Matcher isAnalysisSetPriorityFilesResult = isNull;

/**
 * analysis.setSubscriptions params
 *
 * {
 *   "subscriptions": Map<AnalysisService, List<FilePath>>
 * }
 */
final Matcher isAnalysisSetSubscriptionsParams = new LazyMatcher(() =>
    new MatchesJsonObject("analysis.setSubscriptions params",
        {"subscriptions": isMapOf(isAnalysisService, isListOf(isFilePath))}));

/**
 * analysis.setSubscriptions result
 */
final Matcher isAnalysisSetSubscriptionsResult = isNull;

/**
 * analysis.updateContent params
 *
 * {
 *   "files": Map<FilePath, AddContentOverlay | ChangeContentOverlay | RemoveContentOverlay>
 * }
 */
final Matcher isAnalysisUpdateContentParams = new LazyMatcher(
    () => new MatchesJsonObject("analysis.updateContent params", {
          "files": isMapOf(
              isFilePath,
              isOneOf([
                isAddContentOverlay,
                isChangeContentOverlay,
                isRemoveContentOverlay
              ]))
        }));

/**
 * analysis.updateContent result
 *
 * {
 * }
 */
final Matcher isAnalysisUpdateContentResult = new LazyMatcher(
    () => new MatchesJsonObject("analysis.updateContent result", null));

/**
 * analysis.updateOptions params
 *
 * {
 *   "options": AnalysisOptions
 * }
 */
final Matcher isAnalysisUpdateOptionsParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "analysis.updateOptions params", {"options": isAnalysisOptions}));

/**
 * analysis.updateOptions result
 */
final Matcher isAnalysisUpdateOptionsResult = isNull;

/**
 * analytics.enable params
 *
 * {
 *   "value": bool
 * }
 */
final Matcher isAnalyticsEnableParams = new LazyMatcher(
    () => new MatchesJsonObject("analytics.enable params", {"value": isBool}));

/**
 * analytics.enable result
 */
final Matcher isAnalyticsEnableResult = isNull;

/**
 * analytics.isEnabled params
 */
final Matcher isAnalyticsIsEnabledParams = isNull;

/**
 * analytics.isEnabled result
 *
 * {
 *   "enabled": bool
 * }
 */
final Matcher isAnalyticsIsEnabledResult = new LazyMatcher(() =>
    new MatchesJsonObject("analytics.isEnabled result", {"enabled": isBool}));

/**
 * analytics.sendEvent params
 *
 * {
 *   "action": String
 * }
 */
final Matcher isAnalyticsSendEventParams = new LazyMatcher(() =>
    new MatchesJsonObject("analytics.sendEvent params", {"action": isString}));

/**
 * analytics.sendEvent result
 */
final Matcher isAnalyticsSendEventResult = isNull;

/**
 * analytics.sendTiming params
 *
 * {
 *   "event": String
 *   "millis": int
 * }
 */
final Matcher isAnalyticsSendTimingParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "analytics.sendTiming params", {"event": isString, "millis": isInt}));

/**
 * analytics.sendTiming result
 */
final Matcher isAnalyticsSendTimingResult = isNull;

/**
 * completion.availableSuggestions params
 *
 * {
 *   "changedLibraries": optional List<AvailableSuggestionSet>
 *   "removedLibraries": optional List<int>
 * }
 */
final Matcher isCompletionAvailableSuggestionsParams = new LazyMatcher(() =>
    new MatchesJsonObject("completion.availableSuggestions params", null,
        optionalFields: {
          "changedLibraries": isListOf(isAvailableSuggestionSet),
          "removedLibraries": isListOf(isInt)
        }));

/**
 * completion.existingImports params
 *
 * {
 *   "file": FilePath
 *   "imports": ExistingImports
 * }
 */
final Matcher isCompletionExistingImportsParams = new LazyMatcher(() =>
    new MatchesJsonObject("completion.existingImports params",
        {"file": isFilePath, "imports": isExistingImports}));

/**
 * completion.getSuggestionDetails params
 *
 * {
 *   "file": FilePath
 *   "id": int
 *   "label": String
 *   "offset": int
 * }
 */
final Matcher isCompletionGetSuggestionDetailsParams = new LazyMatcher(() =>
    new MatchesJsonObject("completion.getSuggestionDetails params",
        {"file": isFilePath, "id": isInt, "label": isString, "offset": isInt}));

/**
 * completion.getSuggestionDetails result
 *
 * {
 *   "completion": String
 *   "change": optional SourceChange
 * }
 */
final Matcher isCompletionGetSuggestionDetailsResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "completion.getSuggestionDetails result", {"completion": isString},
        optionalFields: {"change": isSourceChange}));

/**
 * completion.getSuggestions params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 * }
 */
final Matcher isCompletionGetSuggestionsParams = new LazyMatcher(() =>
    new MatchesJsonObject("completion.getSuggestions params",
        {"file": isFilePath, "offset": isInt}));

/**
 * completion.getSuggestions result
 *
 * {
 *   "id": CompletionId
 * }
 */
final Matcher isCompletionGetSuggestionsResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "completion.getSuggestions result", {"id": isCompletionId}));

/**
 * completion.listTokenDetails params
 *
 * {
 *   "file": FilePath
 * }
 */
final Matcher isCompletionListTokenDetailsParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "completion.listTokenDetails params", {"file": isFilePath}));

/**
 * completion.listTokenDetails result
 *
 * {
 *   "tokens": List<TokenDetails>
 * }
 */
final Matcher isCompletionListTokenDetailsResult = new LazyMatcher(() =>
    new MatchesJsonObject("completion.listTokenDetails result",
        {"tokens": isListOf(isTokenDetails)}));

/**
 * completion.registerLibraryPaths params
 *
 * {
 *   "paths": List<LibraryPathSet>
 * }
 */
final Matcher isCompletionRegisterLibraryPathsParams = new LazyMatcher(() =>
    new MatchesJsonObject("completion.registerLibraryPaths params",
        {"paths": isListOf(isLibraryPathSet)}));

/**
 * completion.registerLibraryPaths result
 */
final Matcher isCompletionRegisterLibraryPathsResult = isNull;

/**
 * completion.results params
 *
 * {
 *   "id": CompletionId
 *   "replacementOffset": int
 *   "replacementLength": int
 *   "results": List<CompletionSuggestion>
 *   "isLast": bool
 *   "libraryFile": optional FilePath
 *   "includedSuggestionSets": optional List<IncludedSuggestionSet>
 *   "includedElementKinds": optional List<ElementKind>
 *   "includedSuggestionRelevanceTags": optional List<IncludedSuggestionRelevanceTag>
 * }
 */
final Matcher isCompletionResultsParams =
    new LazyMatcher(() => new MatchesJsonObject("completion.results params", {
          "id": isCompletionId,
          "replacementOffset": isInt,
          "replacementLength": isInt,
          "results": isListOf(isCompletionSuggestion),
          "isLast": isBool
        }, optionalFields: {
          "libraryFile": isFilePath,
          "includedSuggestionSets": isListOf(isIncludedSuggestionSet),
          "includedElementKinds": isListOf(isElementKind),
          "includedSuggestionRelevanceTags":
              isListOf(isIncludedSuggestionRelevanceTag)
        }));

/**
 * completion.setSubscriptions params
 *
 * {
 *   "subscriptions": List<CompletionService>
 * }
 */
final Matcher isCompletionSetSubscriptionsParams = new LazyMatcher(() =>
    new MatchesJsonObject("completion.setSubscriptions params",
        {"subscriptions": isListOf(isCompletionService)}));

/**
 * completion.setSubscriptions result
 */
final Matcher isCompletionSetSubscriptionsResult = isNull;

/**
 * convertGetterToMethod feedback
 */
final Matcher isConvertGetterToMethodFeedback = isNull;

/**
 * convertGetterToMethod options
 */
final Matcher isConvertGetterToMethodOptions = isNull;

/**
 * convertMethodToGetter feedback
 */
final Matcher isConvertMethodToGetterFeedback = isNull;

/**
 * convertMethodToGetter options
 */
final Matcher isConvertMethodToGetterOptions = isNull;

/**
 * diagnostic.getDiagnostics params
 */
final Matcher isDiagnosticGetDiagnosticsParams = isNull;

/**
 * diagnostic.getDiagnostics result
 *
 * {
 *   "contexts": List<ContextData>
 * }
 */
final Matcher isDiagnosticGetDiagnosticsResult = new LazyMatcher(() =>
    new MatchesJsonObject("diagnostic.getDiagnostics result",
        {"contexts": isListOf(isContextData)}));

/**
 * diagnostic.getServerPort params
 */
final Matcher isDiagnosticGetServerPortParams = isNull;

/**
 * diagnostic.getServerPort result
 *
 * {
 *   "port": int
 * }
 */
final Matcher isDiagnosticGetServerPortResult = new LazyMatcher(() =>
    new MatchesJsonObject("diagnostic.getServerPort result", {"port": isInt}));

/**
 * edit.dartfix params
 *
 * {
 *   "included": List<FilePath>
 *   "includedFixes": optional List<String>
 *   "includePedanticFixes": optional bool
 *   "includeRequiredFixes": optional bool
 *   "excludedFixes": optional List<String>
 * }
 */
final Matcher isEditDartfixParams =
    new LazyMatcher(() => new MatchesJsonObject("edit.dartfix params", {
          "included": isListOf(isFilePath)
        }, optionalFields: {
          "includedFixes": isListOf(isString),
          "includePedanticFixes": isBool,
          "includeRequiredFixes": isBool,
          "excludedFixes": isListOf(isString)
        }));

/**
 * edit.dartfix result
 *
 * {
 *   "suggestions": List<DartFixSuggestion>
 *   "otherSuggestions": List<DartFixSuggestion>
 *   "hasErrors": bool
 *   "edits": List<SourceFileEdit>
 *   "details": optional List<String>
 * }
 */
final Matcher isEditDartfixResult =
    new LazyMatcher(() => new MatchesJsonObject("edit.dartfix result", {
          "suggestions": isListOf(isDartFixSuggestion),
          "otherSuggestions": isListOf(isDartFixSuggestion),
          "hasErrors": isBool,
          "edits": isListOf(isSourceFileEdit)
        }, optionalFields: {
          "details": isListOf(isString)
        }));

/**
 * edit.format params
 *
 * {
 *   "file": FilePath
 *   "selectionOffset": int
 *   "selectionLength": int
 *   "lineLength": optional int
 * }
 */
final Matcher isEditFormatParams = new LazyMatcher(() => new MatchesJsonObject(
    "edit.format params",
    {"file": isFilePath, "selectionOffset": isInt, "selectionLength": isInt},
    optionalFields: {"lineLength": isInt}));

/**
 * edit.format result
 *
 * {
 *   "edits": List<SourceEdit>
 *   "selectionOffset": int
 *   "selectionLength": int
 * }
 */
final Matcher isEditFormatResult =
    new LazyMatcher(() => new MatchesJsonObject("edit.format result", {
          "edits": isListOf(isSourceEdit),
          "selectionOffset": isInt,
          "selectionLength": isInt
        }));

/**
 * edit.getAssists params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 *   "length": int
 * }
 */
final Matcher isEditGetAssistsParams = new LazyMatcher(() =>
    new MatchesJsonObject("edit.getAssists params",
        {"file": isFilePath, "offset": isInt, "length": isInt}));

/**
 * edit.getAssists result
 *
 * {
 *   "assists": List<SourceChange>
 * }
 */
final Matcher isEditGetAssistsResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "edit.getAssists result", {"assists": isListOf(isSourceChange)}));

/**
 * edit.getAvailableRefactorings params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 *   "length": int
 * }
 */
final Matcher isEditGetAvailableRefactoringsParams = new LazyMatcher(() =>
    new MatchesJsonObject("edit.getAvailableRefactorings params",
        {"file": isFilePath, "offset": isInt, "length": isInt}));

/**
 * edit.getAvailableRefactorings result
 *
 * {
 *   "kinds": List<RefactoringKind>
 * }
 */
final Matcher isEditGetAvailableRefactoringsResult = new LazyMatcher(() =>
    new MatchesJsonObject("edit.getAvailableRefactorings result",
        {"kinds": isListOf(isRefactoringKind)}));

/**
 * edit.getDartfixInfo params
 *
 * {
 * }
 */
final Matcher isEditGetDartfixInfoParams = new LazyMatcher(
    () => new MatchesJsonObject("edit.getDartfixInfo params", null));

/**
 * edit.getDartfixInfo result
 *
 * {
 *   "fixes": List<DartFix>
 * }
 */
final Matcher isEditGetDartfixInfoResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "edit.getDartfixInfo result", {"fixes": isListOf(isDartFix)}));

/**
 * edit.getFixes params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 * }
 */
final Matcher isEditGetFixesParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "edit.getFixes params", {"file": isFilePath, "offset": isInt}));

/**
 * edit.getFixes result
 *
 * {
 *   "fixes": List<AnalysisErrorFixes>
 * }
 */
final Matcher isEditGetFixesResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "edit.getFixes result", {"fixes": isListOf(isAnalysisErrorFixes)}));

/**
 * edit.getPostfixCompletion params
 *
 * {
 *   "file": FilePath
 *   "key": String
 *   "offset": int
 * }
 */
final Matcher isEditGetPostfixCompletionParams = new LazyMatcher(() =>
    new MatchesJsonObject("edit.getPostfixCompletion params",
        {"file": isFilePath, "key": isString, "offset": isInt}));

/**
 * edit.getPostfixCompletion result
 *
 * {
 *   "change": SourceChange
 * }
 */
final Matcher isEditGetPostfixCompletionResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "edit.getPostfixCompletion result", {"change": isSourceChange}));

/**
 * edit.getRefactoring params
 *
 * {
 *   "kind": RefactoringKind
 *   "file": FilePath
 *   "offset": int
 *   "length": int
 *   "validateOnly": bool
 *   "options": optional RefactoringOptions
 * }
 */
final Matcher isEditGetRefactoringParams =
    new LazyMatcher(() => new MatchesJsonObject("edit.getRefactoring params", {
          "kind": isRefactoringKind,
          "file": isFilePath,
          "offset": isInt,
          "length": isInt,
          "validateOnly": isBool
        }, optionalFields: {
          "options": isRefactoringOptions
        }));

/**
 * edit.getRefactoring result
 *
 * {
 *   "initialProblems": List<RefactoringProblem>
 *   "optionsProblems": List<RefactoringProblem>
 *   "finalProblems": List<RefactoringProblem>
 *   "feedback": optional RefactoringFeedback
 *   "change": optional SourceChange
 *   "potentialEdits": optional List<String>
 * }
 */
final Matcher isEditGetRefactoringResult =
    new LazyMatcher(() => new MatchesJsonObject("edit.getRefactoring result", {
          "initialProblems": isListOf(isRefactoringProblem),
          "optionsProblems": isListOf(isRefactoringProblem),
          "finalProblems": isListOf(isRefactoringProblem)
        }, optionalFields: {
          "feedback": isRefactoringFeedback,
          "change": isSourceChange,
          "potentialEdits": isListOf(isString)
        }));

/**
 * edit.getStatementCompletion params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 * }
 */
final Matcher isEditGetStatementCompletionParams = new LazyMatcher(() =>
    new MatchesJsonObject("edit.getStatementCompletion params",
        {"file": isFilePath, "offset": isInt}));

/**
 * edit.getStatementCompletion result
 *
 * {
 *   "change": SourceChange
 *   "whitespaceOnly": bool
 * }
 */
final Matcher isEditGetStatementCompletionResult = new LazyMatcher(() =>
    new MatchesJsonObject("edit.getStatementCompletion result",
        {"change": isSourceChange, "whitespaceOnly": isBool}));

/**
 * edit.importElements params
 *
 * {
 *   "file": FilePath
 *   "elements": List<ImportedElements>
 *   "offset": optional int
 * }
 */
final Matcher isEditImportElementsParams = new LazyMatcher(() =>
    new MatchesJsonObject("edit.importElements params",
        {"file": isFilePath, "elements": isListOf(isImportedElements)},
        optionalFields: {"offset": isInt}));

/**
 * edit.importElements result
 *
 * {
 *   "edit": optional SourceFileEdit
 * }
 */
final Matcher isEditImportElementsResult = new LazyMatcher(() =>
    new MatchesJsonObject("edit.importElements result", null,
        optionalFields: {"edit": isSourceFileEdit}));

/**
 * edit.isPostfixCompletionApplicable params
 *
 * {
 *   "file": FilePath
 *   "key": String
 *   "offset": int
 * }
 */
final Matcher isEditIsPostfixCompletionApplicableParams = new LazyMatcher(() =>
    new MatchesJsonObject("edit.isPostfixCompletionApplicable params",
        {"file": isFilePath, "key": isString, "offset": isInt}));

/**
 * edit.isPostfixCompletionApplicable result
 *
 * {
 *   "value": bool
 * }
 */
final Matcher isEditIsPostfixCompletionApplicableResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "edit.isPostfixCompletionApplicable result", {"value": isBool}));

/**
 * edit.listPostfixCompletionTemplates params
 */
final Matcher isEditListPostfixCompletionTemplatesParams = isNull;

/**
 * edit.listPostfixCompletionTemplates result
 *
 * {
 *   "templates": List<PostfixTemplateDescriptor>
 * }
 */
final Matcher isEditListPostfixCompletionTemplatesResult = new LazyMatcher(() =>
    new MatchesJsonObject("edit.listPostfixCompletionTemplates result",
        {"templates": isListOf(isPostfixTemplateDescriptor)}));

/**
 * edit.organizeDirectives params
 *
 * {
 *   "file": FilePath
 * }
 */
final Matcher isEditOrganizeDirectivesParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "edit.organizeDirectives params", {"file": isFilePath}));

/**
 * edit.organizeDirectives result
 *
 * {
 *   "edit": SourceFileEdit
 * }
 */
final Matcher isEditOrganizeDirectivesResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "edit.organizeDirectives result", {"edit": isSourceFileEdit}));

/**
 * edit.sortMembers params
 *
 * {
 *   "file": FilePath
 * }
 */
final Matcher isEditSortMembersParams = new LazyMatcher(() =>
    new MatchesJsonObject("edit.sortMembers params", {"file": isFilePath}));

/**
 * edit.sortMembers result
 *
 * {
 *   "edit": SourceFileEdit
 * }
 */
final Matcher isEditSortMembersResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "edit.sortMembers result", {"edit": isSourceFileEdit}));

/**
 * execution.createContext params
 *
 * {
 *   "contextRoot": FilePath
 * }
 */
final Matcher isExecutionCreateContextParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "execution.createContext params", {"contextRoot": isFilePath}));

/**
 * execution.createContext result
 *
 * {
 *   "id": ExecutionContextId
 * }
 */
final Matcher isExecutionCreateContextResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "execution.createContext result", {"id": isExecutionContextId}));

/**
 * execution.deleteContext params
 *
 * {
 *   "id": ExecutionContextId
 * }
 */
final Matcher isExecutionDeleteContextParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "execution.deleteContext params", {"id": isExecutionContextId}));

/**
 * execution.deleteContext result
 */
final Matcher isExecutionDeleteContextResult = isNull;

/**
 * execution.getSuggestions params
 *
 * {
 *   "code": String
 *   "offset": int
 *   "contextFile": FilePath
 *   "contextOffset": int
 *   "variables": List<RuntimeCompletionVariable>
 *   "expressions": optional List<RuntimeCompletionExpression>
 * }
 */
final Matcher isExecutionGetSuggestionsParams = new LazyMatcher(
    () => new MatchesJsonObject("execution.getSuggestions params", {
          "code": isString,
          "offset": isInt,
          "contextFile": isFilePath,
          "contextOffset": isInt,
          "variables": isListOf(isRuntimeCompletionVariable)
        }, optionalFields: {
          "expressions": isListOf(isRuntimeCompletionExpression)
        }));

/**
 * execution.getSuggestions result
 *
 * {
 *   "suggestions": optional List<CompletionSuggestion>
 *   "expressions": optional List<RuntimeCompletionExpression>
 * }
 */
final Matcher isExecutionGetSuggestionsResult = new LazyMatcher(() =>
    new MatchesJsonObject("execution.getSuggestions result", null,
        optionalFields: {
          "suggestions": isListOf(isCompletionSuggestion),
          "expressions": isListOf(isRuntimeCompletionExpression)
        }));

/**
 * execution.launchData params
 *
 * {
 *   "file": FilePath
 *   "kind": optional ExecutableKind
 *   "referencedFiles": optional List<FilePath>
 * }
 */
final Matcher isExecutionLaunchDataParams = new LazyMatcher(() =>
    new MatchesJsonObject("execution.launchData params", {
      "file": isFilePath
    }, optionalFields: {
      "kind": isExecutableKind,
      "referencedFiles": isListOf(isFilePath)
    }));

/**
 * execution.mapUri params
 *
 * {
 *   "id": ExecutionContextId
 *   "file": optional FilePath
 *   "uri": optional String
 * }
 */
final Matcher isExecutionMapUriParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "execution.mapUri params", {"id": isExecutionContextId},
        optionalFields: {"file": isFilePath, "uri": isString}));

/**
 * execution.mapUri result
 *
 * {
 *   "file": optional FilePath
 *   "uri": optional String
 * }
 */
final Matcher isExecutionMapUriResult = new LazyMatcher(() =>
    new MatchesJsonObject("execution.mapUri result", null,
        optionalFields: {"file": isFilePath, "uri": isString}));

/**
 * execution.setSubscriptions params
 *
 * {
 *   "subscriptions": List<ExecutionService>
 * }
 */
final Matcher isExecutionSetSubscriptionsParams = new LazyMatcher(() =>
    new MatchesJsonObject("execution.setSubscriptions params",
        {"subscriptions": isListOf(isExecutionService)}));

/**
 * execution.setSubscriptions result
 */
final Matcher isExecutionSetSubscriptionsResult = isNull;

/**
 * extractLocalVariable feedback
 *
 * {
 *   "coveringExpressionOffsets": optional List<int>
 *   "coveringExpressionLengths": optional List<int>
 *   "names": List<String>
 *   "offsets": List<int>
 *   "lengths": List<int>
 * }
 */
final Matcher isExtractLocalVariableFeedback = new LazyMatcher(
    () => new MatchesJsonObject("extractLocalVariable feedback", {
          "names": isListOf(isString),
          "offsets": isListOf(isInt),
          "lengths": isListOf(isInt)
        }, optionalFields: {
          "coveringExpressionOffsets": isListOf(isInt),
          "coveringExpressionLengths": isListOf(isInt)
        }));

/**
 * extractLocalVariable options
 *
 * {
 *   "name": String
 *   "extractAll": bool
 * }
 */
final Matcher isExtractLocalVariableOptions = new LazyMatcher(() =>
    new MatchesJsonObject("extractLocalVariable options",
        {"name": isString, "extractAll": isBool}));

/**
 * extractMethod feedback
 *
 * {
 *   "offset": int
 *   "length": int
 *   "returnType": String
 *   "names": List<String>
 *   "canCreateGetter": bool
 *   "parameters": List<RefactoringMethodParameter>
 *   "offsets": List<int>
 *   "lengths": List<int>
 * }
 */
final Matcher isExtractMethodFeedback =
    new LazyMatcher(() => new MatchesJsonObject("extractMethod feedback", {
          "offset": isInt,
          "length": isInt,
          "returnType": isString,
          "names": isListOf(isString),
          "canCreateGetter": isBool,
          "parameters": isListOf(isRefactoringMethodParameter),
          "offsets": isListOf(isInt),
          "lengths": isListOf(isInt)
        }));

/**
 * extractMethod options
 *
 * {
 *   "returnType": String
 *   "createGetter": bool
 *   "name": String
 *   "parameters": List<RefactoringMethodParameter>
 *   "extractAll": bool
 * }
 */
final Matcher isExtractMethodOptions =
    new LazyMatcher(() => new MatchesJsonObject("extractMethod options", {
          "returnType": isString,
          "createGetter": isBool,
          "name": isString,
          "parameters": isListOf(isRefactoringMethodParameter),
          "extractAll": isBool
        }));

/**
 * extractWidget feedback
 *
 * {
 * }
 */
final Matcher isExtractWidgetFeedback = new LazyMatcher(
    () => new MatchesJsonObject("extractWidget feedback", null));

/**
 * extractWidget options
 *
 * {
 *   "name": String
 * }
 */
final Matcher isExtractWidgetOptions = new LazyMatcher(
    () => new MatchesJsonObject("extractWidget options", {"name": isString}));

/**
 * flutter.getWidgetDescription params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 * }
 */
final Matcher isFlutterGetWidgetDescriptionParams = new LazyMatcher(() =>
    new MatchesJsonObject("flutter.getWidgetDescription params",
        {"file": isFilePath, "offset": isInt}));

/**
 * flutter.getWidgetDescription result
 *
 * {
 *   "properties": List<FlutterWidgetProperty>
 * }
 */
final Matcher isFlutterGetWidgetDescriptionResult = new LazyMatcher(() =>
    new MatchesJsonObject("flutter.getWidgetDescription result",
        {"properties": isListOf(isFlutterWidgetProperty)}));

/**
 * flutter.outline params
 *
 * {
 *   "file": FilePath
 *   "outline": FlutterOutline
 * }
 */
final Matcher isFlutterOutlineParams = new LazyMatcher(() =>
    new MatchesJsonObject("flutter.outline params",
        {"file": isFilePath, "outline": isFlutterOutline}));

/**
 * flutter.setSubscriptions params
 *
 * {
 *   "subscriptions": Map<FlutterService, List<FilePath>>
 * }
 */
final Matcher isFlutterSetSubscriptionsParams = new LazyMatcher(() =>
    new MatchesJsonObject("flutter.setSubscriptions params",
        {"subscriptions": isMapOf(isFlutterService, isListOf(isFilePath))}));

/**
 * flutter.setSubscriptions result
 */
final Matcher isFlutterSetSubscriptionsResult = isNull;

/**
 * flutter.setWidgetPropertyValue params
 *
 * {
 *   "id": int
 *   "value": optional FlutterWidgetPropertyValue
 * }
 */
final Matcher isFlutterSetWidgetPropertyValueParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "flutter.setWidgetPropertyValue params", {"id": isInt},
        optionalFields: {"value": isFlutterWidgetPropertyValue}));

/**
 * flutter.setWidgetPropertyValue result
 *
 * {
 *   "change": SourceChange
 * }
 */
final Matcher isFlutterSetWidgetPropertyValueResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "flutter.setWidgetPropertyValue result", {"change": isSourceChange}));

/**
 * inlineLocalVariable feedback
 *
 * {
 *   "name": String
 *   "occurrences": int
 * }
 */
final Matcher isInlineLocalVariableFeedback = new LazyMatcher(() =>
    new MatchesJsonObject("inlineLocalVariable feedback",
        {"name": isString, "occurrences": isInt}));

/**
 * inlineLocalVariable options
 */
final Matcher isInlineLocalVariableOptions = isNull;

/**
 * inlineMethod feedback
 *
 * {
 *   "className": optional String
 *   "methodName": String
 *   "isDeclaration": bool
 * }
 */
final Matcher isInlineMethodFeedback = new LazyMatcher(() =>
    new MatchesJsonObject("inlineMethod feedback",
        {"methodName": isString, "isDeclaration": isBool},
        optionalFields: {"className": isString}));

/**
 * inlineMethod options
 *
 * {
 *   "deleteSource": bool
 *   "inlineAll": bool
 * }
 */
final Matcher isInlineMethodOptions = new LazyMatcher(() =>
    new MatchesJsonObject(
        "inlineMethod options", {"deleteSource": isBool, "inlineAll": isBool}));

/**
 * kythe.getKytheEntries params
 *
 * {
 *   "file": FilePath
 * }
 */
final Matcher isKytheGetKytheEntriesParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "kythe.getKytheEntries params", {"file": isFilePath}));

/**
 * kythe.getKytheEntries result
 *
 * {
 *   "entries": List<KytheEntry>
 *   "files": List<FilePath>
 * }
 */
final Matcher isKytheGetKytheEntriesResult = new LazyMatcher(() =>
    new MatchesJsonObject("kythe.getKytheEntries result",
        {"entries": isListOf(isKytheEntry), "files": isListOf(isFilePath)}));

/**
 * moveFile feedback
 */
final Matcher isMoveFileFeedback = isNull;

/**
 * moveFile options
 *
 * {
 *   "newFile": FilePath
 * }
 */
final Matcher isMoveFileOptions = new LazyMatcher(
    () => new MatchesJsonObject("moveFile options", {"newFile": isFilePath}));

/**
 * rename feedback
 *
 * {
 *   "offset": int
 *   "length": int
 *   "elementKindName": String
 *   "oldName": String
 * }
 */
final Matcher isRenameFeedback =
    new LazyMatcher(() => new MatchesJsonObject("rename feedback", {
          "offset": isInt,
          "length": isInt,
          "elementKindName": isString,
          "oldName": isString
        }));

/**
 * rename options
 *
 * {
 *   "newName": String
 * }
 */
final Matcher isRenameOptions = new LazyMatcher(
    () => new MatchesJsonObject("rename options", {"newName": isString}));

/**
 * search.findElementReferences params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 *   "includePotential": bool
 * }
 */
final Matcher isSearchFindElementReferencesParams = new LazyMatcher(() =>
    new MatchesJsonObject("search.findElementReferences params",
        {"file": isFilePath, "offset": isInt, "includePotential": isBool}));

/**
 * search.findElementReferences result
 *
 * {
 *   "id": optional SearchId
 *   "element": optional Element
 * }
 */
final Matcher isSearchFindElementReferencesResult = new LazyMatcher(() =>
    new MatchesJsonObject("search.findElementReferences result", null,
        optionalFields: {"id": isSearchId, "element": isElement}));

/**
 * search.findMemberDeclarations params
 *
 * {
 *   "name": String
 * }
 */
final Matcher isSearchFindMemberDeclarationsParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "search.findMemberDeclarations params", {"name": isString}));

/**
 * search.findMemberDeclarations result
 *
 * {
 *   "id": SearchId
 * }
 */
final Matcher isSearchFindMemberDeclarationsResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "search.findMemberDeclarations result", {"id": isSearchId}));

/**
 * search.findMemberReferences params
 *
 * {
 *   "name": String
 * }
 */
final Matcher isSearchFindMemberReferencesParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "search.findMemberReferences params", {"name": isString}));

/**
 * search.findMemberReferences result
 *
 * {
 *   "id": SearchId
 * }
 */
final Matcher isSearchFindMemberReferencesResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "search.findMemberReferences result", {"id": isSearchId}));

/**
 * search.findTopLevelDeclarations params
 *
 * {
 *   "pattern": String
 * }
 */
final Matcher isSearchFindTopLevelDeclarationsParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "search.findTopLevelDeclarations params", {"pattern": isString}));

/**
 * search.findTopLevelDeclarations result
 *
 * {
 *   "id": SearchId
 * }
 */
final Matcher isSearchFindTopLevelDeclarationsResult = new LazyMatcher(() =>
    new MatchesJsonObject(
        "search.findTopLevelDeclarations result", {"id": isSearchId}));

/**
 * search.getElementDeclarations params
 *
 * {
 *   "file": optional FilePath
 *   "pattern": optional String
 *   "maxResults": optional int
 * }
 */
final Matcher isSearchGetElementDeclarationsParams = new LazyMatcher(() =>
    new MatchesJsonObject("search.getElementDeclarations params", null,
        optionalFields: {
          "file": isFilePath,
          "pattern": isString,
          "maxResults": isInt
        }));

/**
 * search.getElementDeclarations result
 *
 * {
 *   "declarations": List<ElementDeclaration>
 *   "files": List<FilePath>
 * }
 */
final Matcher isSearchGetElementDeclarationsResult = new LazyMatcher(() =>
    new MatchesJsonObject("search.getElementDeclarations result", {
      "declarations": isListOf(isElementDeclaration),
      "files": isListOf(isFilePath)
    }));

/**
 * search.getTypeHierarchy params
 *
 * {
 *   "file": FilePath
 *   "offset": int
 *   "superOnly": optional bool
 * }
 */
final Matcher isSearchGetTypeHierarchyParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "search.getTypeHierarchy params", {"file": isFilePath, "offset": isInt},
        optionalFields: {"superOnly": isBool}));

/**
 * search.getTypeHierarchy result
 *
 * {
 *   "hierarchyItems": optional List<TypeHierarchyItem>
 * }
 */
final Matcher isSearchGetTypeHierarchyResult = new LazyMatcher(() =>
    new MatchesJsonObject("search.getTypeHierarchy result", null,
        optionalFields: {"hierarchyItems": isListOf(isTypeHierarchyItem)}));

/**
 * search.results params
 *
 * {
 *   "id": SearchId
 *   "results": List<SearchResult>
 *   "isLast": bool
 * }
 */
final Matcher isSearchResultsParams = new LazyMatcher(() =>
    new MatchesJsonObject("search.results params", {
      "id": isSearchId,
      "results": isListOf(isSearchResult),
      "isLast": isBool
    }));

/**
 * server.connected params
 *
 * {
 *   "version": String
 *   "pid": int
 *   "sessionId": optional String
 * }
 */
final Matcher isServerConnectedParams = new LazyMatcher(() =>
    new MatchesJsonObject(
        "server.connected params", {"version": isString, "pid": isInt},
        optionalFields: {"sessionId": isString}));

/**
 * server.error params
 *
 * {
 *   "isFatal": bool
 *   "message": String
 *   "stackTrace": String
 * }
 */
final Matcher isServerErrorParams = new LazyMatcher(() => new MatchesJsonObject(
    "server.error params",
    {"isFatal": isBool, "message": isString, "stackTrace": isString}));

/**
 * server.getVersion params
 */
final Matcher isServerGetVersionParams = isNull;

/**
 * server.getVersion result
 *
 * {
 *   "version": String
 * }
 */
final Matcher isServerGetVersionResult = new LazyMatcher(() =>
    new MatchesJsonObject("server.getVersion result", {"version": isString}));

/**
 * server.setSubscriptions params
 *
 * {
 *   "subscriptions": List<ServerService>
 * }
 */
final Matcher isServerSetSubscriptionsParams = new LazyMatcher(() =>
    new MatchesJsonObject("server.setSubscriptions params",
        {"subscriptions": isListOf(isServerService)}));

/**
 * server.setSubscriptions result
 */
final Matcher isServerSetSubscriptionsResult = isNull;

/**
 * server.shutdown params
 */
final Matcher isServerShutdownParams = isNull;

/**
 * server.shutdown result
 */
final Matcher isServerShutdownResult = isNull;

/**
 * server.status params
 *
 * {
 *   "analysis": optional AnalysisStatus
 *   "pub": optional PubStatus
 * }
 */
final Matcher isServerStatusParams = new LazyMatcher(() =>
    new MatchesJsonObject("server.status params", null,
        optionalFields: {"analysis": isAnalysisStatus, "pub": isPubStatus}));

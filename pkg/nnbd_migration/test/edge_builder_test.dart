// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/member.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/testing/test_type_provider.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:nnbd_migration/src/decorated_class_hierarchy.dart';
import 'package:nnbd_migration/src/decorated_type.dart';
import 'package:nnbd_migration/src/edge_builder.dart';
import 'package:nnbd_migration/src/edge_origin.dart';
import 'package:nnbd_migration/src/expression_checks.dart';
import 'package:nnbd_migration/src/nullability_node.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'migration_visitor_test_base.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(AssignmentCheckerTest);
    defineReflectiveTests(EdgeBuilderTest);
  });
}

@reflectiveTest
class AssignmentCheckerTest extends Object with EdgeTester {
  static const EdgeOrigin origin = const _TestEdgeOrigin();

  ClassElement _myListOfListClass;

  DecoratedType _myListOfListSupertype;

  final TypeProvider typeProvider;

  final NullabilityGraphForTesting graph;

  final AssignmentCheckerForTesting checker;

  int offset = 0;

  factory AssignmentCheckerTest() {
    var typeProvider = TestTypeProvider();
    var graph = NullabilityGraphForTesting();
    var decoratedClassHierarchy = _DecoratedClassHierarchyForTesting();
    var checker = AssignmentCheckerForTesting(
        Dart2TypeSystem(typeProvider), graph, decoratedClassHierarchy);
    var assignmentCheckerTest =
        AssignmentCheckerTest._(typeProvider, graph, checker);
    decoratedClassHierarchy.assignmentCheckerTest = assignmentCheckerTest;
    return assignmentCheckerTest;
  }

  AssignmentCheckerTest._(this.typeProvider, this.graph, this.checker);

  NullabilityNode get always => graph.always;

  DecoratedType get bottom => DecoratedType(typeProvider.bottomType, never);

  DecoratedType get dynamic_ => DecoratedType(typeProvider.dynamicType, always);

  NullabilityNode get never => graph.never;

  DecoratedType get null_ => DecoratedType(typeProvider.nullType, always);

  DecoratedType get void_ => DecoratedType(typeProvider.voidType, always);

  void assign(DecoratedType source, DecoratedType destination,
      {bool hard = false}) {
    checker.checkAssignment(origin,
        source: source, destination: destination, hard: hard);
  }

  DecoratedType function(DecoratedType returnType,
      {List<DecoratedType> required = const [],
      List<DecoratedType> positional = const [],
      Map<String, DecoratedType> named = const {}}) {
    int i = 0;
    var parameters = required
        .map((t) => ParameterElementImpl.synthetic(
            'p${i++}', t.type, ParameterKind.REQUIRED))
        .toList();
    parameters.addAll(positional.map((t) => ParameterElementImpl.synthetic(
        'p${i++}', t.type, ParameterKind.POSITIONAL)));
    parameters.addAll(named.entries.map((e) => ParameterElementImpl.synthetic(
        e.key, e.value.type, ParameterKind.NAMED)));
    return DecoratedType(
        FunctionTypeImpl.synthetic(returnType.type, const [], parameters),
        NullabilityNode.forTypeAnnotation(offset++),
        returnType: returnType,
        positionalParameters: required.toList()..addAll(positional),
        namedParameters: named);
  }

  DecoratedType list(DecoratedType elementType) => DecoratedType(
      typeProvider.listType.instantiate([elementType.type]),
      NullabilityNode.forTypeAnnotation(offset++),
      typeArguments: [elementType]);

  DecoratedType myListOfList(DecoratedType elementType) {
    if (_myListOfListClass == null) {
      var t = TypeParameterElementImpl.synthetic('T')..bound = object().type;
      _myListOfListSupertype = list(list(typeParameterType(t)));
      _myListOfListClass = ClassElementImpl('MyListOfList', 0)
        ..typeParameters = [t]
        ..supertype = _myListOfListSupertype.type as InterfaceType;
    }
    return DecoratedType(
        InterfaceTypeImpl(_myListOfListClass)
          ..typeArguments = [elementType.type],
        NullabilityNode.forTypeAnnotation(offset++),
        typeArguments: [elementType]);
  }

  DecoratedType object() => DecoratedType(
      typeProvider.objectType, NullabilityNode.forTypeAnnotation(offset++));

  void test_bottom_to_generic() {
    var t = list(object());
    assign(bottom, t);
    assertEdge(never, t.node, hard: false);
    expect(graph.getUpstreamEdges(t.typeArguments[0].node), isEmpty);
  }

  void test_bottom_to_simple() {
    var t = object();
    assign(bottom, t);
    assertEdge(never, t.node, hard: false);
  }

  void test_complex_to_typeParam() {
    var bound = list(object());
    var t = TypeParameterElementImpl.synthetic('T')..bound = bound.type;
    checker.bounds[t] = bound;
    var t1 = list(object());
    var t2 = typeParameterType(t);
    assign(t1, t2, hard: true);
    assertEdge(t1.node, t2.node, hard: true);
    assertNoEdge(t1.node, bound.node);
    assertEdge(t1.typeArguments[0].node, bound.typeArguments[0].node,
        hard: false);
  }

  void test_dynamic_to_dynamic() {
    assign(dynamic_, dynamic_);
    // Note: no assertions to do; just need to make sure there wasn't a crash.
  }

  void test_function_type_named_parameter() {
    var t1 = function(dynamic_, named: {'x': object()});
    var t2 = function(dynamic_, named: {'x': object()});
    assign(t1, t2, hard: true);
    // Note: t1 and t2 are swapped due to contravariance.
    assertEdge(t2.namedParameters['x'].node, t1.namedParameters['x'].node,
        hard: false);
  }

  void test_function_type_named_to_no_parameter() {
    var t1 = function(dynamic_, named: {'x': object()});
    var t2 = function(dynamic_);
    assign(t1, t2);
    // Note: no assertions to do; just need to make sure there wasn't a crash.
  }

  void test_function_type_positional_parameter() {
    var t1 = function(dynamic_, positional: [object()]);
    var t2 = function(dynamic_, positional: [object()]);
    assign(t1, t2, hard: true);
    // Note: t1 and t2 are swapped due to contravariance.
    assertEdge(t2.positionalParameters[0].node, t1.positionalParameters[0].node,
        hard: false);
  }

  void test_function_type_positional_to_no_parameter() {
    var t1 = function(dynamic_, positional: [object()]);
    var t2 = function(dynamic_);
    assign(t1, t2);
    // Note: no assertions to do; just need to make sure there wasn't a crash.
  }

  void test_function_type_positional_to_required_parameter() {
    var t1 = function(dynamic_, positional: [object()]);
    var t2 = function(dynamic_, required: [object()]);
    assign(t1, t2, hard: true);
    // Note: t1 and t2 are swapped due to contravariance.
    assertEdge(t2.positionalParameters[0].node, t1.positionalParameters[0].node,
        hard: false);
  }

  void test_function_type_required_parameter() {
    var t1 = function(dynamic_, required: [object()]);
    var t2 = function(dynamic_, required: [object()]);
    assign(t1, t2);
    // Note: t1 and t2 are swapped due to contravariance.
    assertEdge(t2.positionalParameters[0].node, t1.positionalParameters[0].node,
        hard: false);
  }

  void test_function_type_return_type() {
    var t1 = function(object());
    var t2 = function(object());
    assign(t1, t2, hard: true);
    assertEdge(t1.returnType.node, t2.returnType.node, hard: false);
  }

  test_generic_to_dynamic() {
    var t = list(object());
    assign(t, dynamic_);
    assertEdge(t.node, always, hard: false);
    expect(graph.getDownstreamEdges(t.typeArguments[0].node), isEmpty);
  }

  test_generic_to_generic_downcast() {
    var t1 = list(list(object()));
    var t2 = myListOfList(object());
    assign(t1, t2, hard: true);
    assertEdge(t1.node, t2.node, hard: true);
    // Let A, B, and C be nullability nodes such that:
    // - t2 is MyListOfList<Object?A>
    var a = t2.typeArguments[0].node;
    // - t1 is List<List<Object?B>>
    var b = t1.typeArguments[0].typeArguments[0].node;
    // - the supertype of MyListOfList<T> is List<List<T?C>>
    var c = _myListOfListSupertype.typeArguments[0].typeArguments[0].node;
    // Then there should be an edge from b to substitute(a, c)
    var substitutionNode = graph.getDownstreamEdges(b).single.destinationNode
        as NullabilityNodeForSubstitution;
    expect(substitutionNode.innerNode, same(a));
    expect(substitutionNode.outerNode, same(c));
  }

  test_generic_to_generic_same_element() {
    var t1 = list(object());
    var t2 = list(object());
    assign(t1, t2, hard: true);
    assertEdge(t1.node, t2.node, hard: true);
    assertEdge(t1.typeArguments[0].node, t2.typeArguments[0].node, hard: false);
  }

  test_generic_to_generic_upcast() {
    var t1 = myListOfList(object());
    var t2 = list(list(object()));
    assign(t1, t2);
    assertEdge(t1.node, t2.node, hard: false);
    // Let A, B, and C be nullability nodes such that:
    // - t1 is MyListOfList<Object?A>
    var a = t1.typeArguments[0].node;
    // - t2 is List<List<Object?B>>
    var b = t2.typeArguments[0].typeArguments[0].node;
    // - the supertype of MyListOfList<T> is List<List<T?C>>
    var c = _myListOfListSupertype.typeArguments[0].typeArguments[0].node;
    // Then there should be an edge from substitute(a, c) to b.
    var substitutionNode = graph.getUpstreamEdges(b).single.primarySource
        as NullabilityNodeForSubstitution;
    expect(substitutionNode.innerNode, same(a));
    expect(substitutionNode.outerNode, same(c));
  }

  test_generic_to_object() {
    var t1 = list(object());
    var t2 = object();
    assign(t1, t2);
    assertEdge(t1.node, t2.node, hard: false);
    expect(graph.getDownstreamEdges(t1.typeArguments[0].node), isEmpty);
  }

  test_generic_to_void() {
    var t = list(object());
    assign(t, void_);
    assertEdge(t.node, always, hard: false);
    expect(graph.getDownstreamEdges(t.typeArguments[0].node), isEmpty);
  }

  void test_null_to_generic() {
    var t = list(object());
    assign(null_, t);
    assertEdge(always, t.node, hard: false);
    expect(graph.getUpstreamEdges(t.typeArguments[0].node), isEmpty);
  }

  void test_null_to_simple() {
    var t = object();
    assign(null_, t);
    assertEdge(always, t.node, hard: false);
  }

  test_simple_to_dynamic() {
    var t = object();
    assign(t, dynamic_);
    assertEdge(t.node, always, hard: false);
  }

  test_simple_to_simple() {
    var t1 = object();
    var t2 = object();
    assign(t1, t2);
    assertEdge(t1.node, t2.node, hard: false);
  }

  test_simple_to_simple_hard() {
    var t1 = object();
    var t2 = object();
    assign(t1, t2, hard: true);
    assertEdge(t1.node, t2.node, hard: true);
  }

  test_simple_to_void() {
    var t = object();
    assign(t, void_);
    assertEdge(t.node, always, hard: false);
  }

  void test_typeParam_to_complex() {
    var bound = list(object());
    var t = TypeParameterElementImpl.synthetic('T')..bound = bound.type;
    checker.bounds[t] = bound;
    var t1 = typeParameterType(t);
    var t2 = list(object());
    assign(t1, t2, hard: true);
    assertEdge(t1.node, t2.node, hard: true);
    assertEdge(bound.node, t2.node, hard: false);
    assertEdge(bound.typeArguments[0].node, t2.typeArguments[0].node,
        hard: false);
  }

  void test_typeParam_to_object() {
    var bound = object();
    var t = TypeParameterElementImpl.synthetic('T')..bound = bound.type;
    checker.bounds[t] = bound;
    var t1 = typeParameterType(t);
    var t2 = object();
    assign(t1, t2);
    assertEdge(t1.node, t2.node, hard: false);
  }

  void test_typeParam_to_typeParam() {
    var t = TypeParameterElementImpl.synthetic('T')..bound = object().type;
    var t1 = typeParameterType(t);
    var t2 = typeParameterType(t);
    assign(t1, t2);
    assertEdge(t1.node, t2.node, hard: false);
  }

  DecoratedType typeParameterType(TypeParameterElement typeParameter) =>
      DecoratedType(
          typeParameter.type, NullabilityNode.forTypeAnnotation(offset++));
}

@reflectiveTest
class EdgeBuilderTest extends MigrationVisitorTestBase {
  /// Analyzes the given source code, producing constraint variables and
  /// constraints for it.
  @override
  Future<CompilationUnit> analyze(String code) async {
    var unit = await super.analyze(code);
    unit.accept(EdgeBuilder(
        typeProvider, typeSystem, variables, graph, testSource, null));
    return unit;
  }

  void assertGLB(
      NullabilityNode node, NullabilityNode left, NullabilityNode right) {
    expect(node, isNot(TypeMatcher<NullabilityNodeForLUB>()));
    assertEdge(left, node, hard: false, guards: [right]);
    assertEdge(node, left, hard: false);
    assertEdge(node, right, hard: false);
  }

  void assertLUB(
      NullabilityNode node, NullabilityNode left, NullabilityNode right) {
    var conditionalNode = node as NullabilityNodeForLUB;
    expect(conditionalNode.left, same(left));
    expect(conditionalNode.right, same(right));
  }

  /// Checks that there are no nullability nodes upstream from [node] that could
  /// cause it to become nullable.
  void assertNoUpstreamNullability(NullabilityNode node) {
    // never can never become nullable, even if it has nodes
    // upstream from it.
    if (node == never) return;

    for (var edge in graph.getUpstreamEdges(node)) {
      expect(edge.primarySource, never);
    }
  }

  /// Verifies that a null check will occur when the given edge is unsatisfied.
  ///
  /// [expressionChecks] is the object tracking whether or not a null check is
  /// needed.
  void assertNullCheck(
      ExpressionChecks expressionChecks, NullabilityEdge expectedEdge) {
    expect(expressionChecks.edges, contains(expectedEdge));
  }

  /// Gets the [ExpressionChecks] associated with the expression whose text
  /// representation is [text], or `null` if the expression has no
  /// [ExpressionChecks] associated with it.
  ExpressionChecks checkExpression(String text) {
    return variables.checkExpression(findNode.expression(text));
  }

  /// Gets the [DecoratedType] associated with the expression whose text
  /// representation is [text], or `null` if the expression has no
  /// [DecoratedType] associated with it.
  DecoratedType decoratedExpressionType(String text) {
    return variables.decoratedExpressionType(findNode.expression(text));
  }

  test_assert_demonstrates_non_null_intent() async {
    await analyze('''
void f(int i) {
  assert(i != null);
}
''');

    assertEdge(decoratedTypeAnnotation('int i').node, never, hard: true);
  }

  test_assign_bound_to_type_parameter() async {
    await analyze('''
class C<T extends List<int>> {
  T f(List<int> x) => x;
}
''');
    var boundType = decoratedTypeAnnotation('List<int>>');
    var parameterType = decoratedTypeAnnotation('List<int> x');
    var tType = decoratedTypeAnnotation('T f');
    assertEdge(parameterType.node, tType.node, hard: true);
    assertNoEdge(parameterType.node, boundType.node);
    assertEdge(
        parameterType.typeArguments[0].node, boundType.typeArguments[0].node,
        hard: false);
  }

  test_assign_null_to_generic_type() async {
    await analyze('''
main() {
  List<int> x = null;
}
''');
    // TODO(paulberry): edge should be hard.
    assertEdge(always, decoratedTypeAnnotation('List').node, hard: false);
  }

  test_assign_type_parameter_to_bound() async {
    await analyze('''
class C<T extends List<int>> {
  List<int> f(T x) => x;
}
''');
    var boundType = decoratedTypeAnnotation('List<int>>');
    var returnType = decoratedTypeAnnotation('List<int> f');
    var tType = decoratedTypeAnnotation('T x');
    assertEdge(tType.node, returnType.node, hard: true);
    assertEdge(boundType.node, returnType.node, hard: false);
    assertEdge(
        boundType.typeArguments[0].node, returnType.typeArguments[0].node,
        hard: false);
  }

  test_assignmentExpression_field() async {
    await analyze('''
class C {
  int x = 0;
}
void f(C c, int i) {
  c.x = i;
}
''');
    assertEdge(decoratedTypeAnnotation('int i').node,
        decoratedTypeAnnotation('int x').node,
        hard: true);
  }

  test_assignmentExpression_field_cascaded() async {
    await analyze('''
class C {
  int x = 0;
}
void f(C c, int i) {
  c..x = i;
}
''');
    assertEdge(decoratedTypeAnnotation('int i').node,
        decoratedTypeAnnotation('int x').node,
        hard: true);
  }

  test_assignmentExpression_field_target_check() async {
    await analyze('''
class C {
  int x = 0;
}
void f(C c, int i) {
  c.x = i;
}
''');
    assertNullCheck(checkExpression('c.x'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_assignmentExpression_field_target_check_cascaded() async {
    await analyze('''
class C {
  int x = 0;
}
void f(C c, int i) {
  c..x = i;
}
''');
    assertNullCheck(checkExpression('c..x'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_assignmentExpression_indexExpression_index() async {
    await analyze('''
class C {
  void operator[]=(int a, int b) {}
}
void f(C c, int i, int j) {
  c[i] = j;
}
''');
    assertEdge(decoratedTypeAnnotation('int i').node,
        decoratedTypeAnnotation('int a').node,
        hard: true);
  }

  test_assignmentExpression_indexExpression_return_value() async {
    await analyze('''
class C {
  void operator[]=(int a, int b) {}
}
int f(C c, int i, int j) => c[i] = j;
''');
    assertEdge(decoratedTypeAnnotation('int j').node,
        decoratedTypeAnnotation('int f').node,
        hard: false);
  }

  test_assignmentExpression_indexExpression_target_check() async {
    await analyze('''
class C {
  void operator[]=(int a, int b) {}
}
void f(C c, int i, int j) {
  c[i] = j;
}
''');
    assertNullCheck(checkExpression('c['),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_assignmentExpression_indexExpression_value() async {
    await analyze('''
class C {
  void operator[]=(int a, int b) {}
}
void f(C c, int i, int j) {
  c[i] = j;
}
''');
    assertEdge(decoratedTypeAnnotation('int j').node,
        decoratedTypeAnnotation('int b').node,
        hard: true);
  }

  test_assignmentExpression_operands() async {
    await analyze('''
void f(int i, int j) {
  i = j;
}
''');
    assertEdge(decoratedTypeAnnotation('int j').node,
        decoratedTypeAnnotation('int i').node,
        hard: true);
  }

  test_assignmentExpression_return_value() async {
    await analyze('''
void f(int i, int j) {
  g(i = j);
}
void g(int k) {}
''');
    assertEdge(decoratedTypeAnnotation('int j').node,
        decoratedTypeAnnotation('int k').node,
        hard: false);
  }

  test_assignmentExpression_setter() async {
    await analyze('''
class C {
  void set s(int value) {}
}
void f(C c, int i) {
  c.s = i;
}
''');
    assertEdge(decoratedTypeAnnotation('int i').node,
        decoratedTypeAnnotation('int value').node,
        hard: true);
  }

  test_assignmentExpression_setter_null_aware() async {
    await analyze('''
class C {
  void set s(int value) {}
}
int f(C c, int i) => (c?.s = i);
''');
    var lubNode =
        decoratedExpressionType('(c?.s = i)').node as NullabilityNodeForLUB;
    expect(lubNode.left, same(decoratedTypeAnnotation('C c').node));
    expect(lubNode.right, same(decoratedTypeAnnotation('int i').node));
    assertEdge(lubNode, decoratedTypeAnnotation('int f').node, hard: false);
  }

  test_assignmentExpression_setter_target_check() async {
    await analyze('''
class C {
  void set s(int value) {}
}
void f(C c, int i) {
  c.s = i;
}
''');
    assertNullCheck(checkExpression('c.s'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  @failingTest
  test_awaitExpression_future_nonNullable() async {
    await analyze('''
Future<void> f() async {
  int x = await g();
}
Future<int> g() async => 3;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int').node);
  }

  @failingTest
  test_awaitExpression_future_nullable() async {
    await analyze('''
Future<void> f() async {
  int x = await g();
}
Future<int> g() async => null;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int').node);
  }

  test_awaitExpression_nonFuture() async {
    await analyze('''
Future<void> f() async {
  int x = await 3;
}
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int').node);
  }

  test_binaryExpression_ampersand_result_not_null() async {
    await analyze('''
int f(int i, int j) => i & j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int f').node);
  }

  test_binaryExpression_ampersandAmpersand() async {
    await analyze('''
bool f(bool i, bool j) => i && j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('bool i').node);
  }

  test_binaryExpression_bar_result_not_null() async {
    await analyze('''
int f(int i, int j) => i | j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int f').node);
  }

  test_binaryExpression_barBar() async {
    await analyze('''
bool f(bool i, bool j) => i || j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('bool i').node);
  }

  test_binaryExpression_caret_result_not_null() async {
    await analyze('''
int f(int i, int j) => i ^ j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int f').node);
  }

  test_binaryExpression_equal() async {
    await analyze('''
bool f(int i, int j) => i == j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('bool f').node);
  }

  test_binaryExpression_gt_result_not_null() async {
    await analyze('''
bool f(int i, int j) => i > j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('bool f').node);
  }

  test_binaryExpression_gtEq_result_not_null() async {
    await analyze('''
bool f(int i, int j) => i >= j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('bool f').node);
  }

  test_binaryExpression_gtGt_result_not_null() async {
    await analyze('''
int f(int i, int j) => i >> j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int f').node);
  }

  test_binaryExpression_lt_result_not_null() async {
    await analyze('''
bool f(int i, int j) => i < j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('bool f').node);
  }

  test_binaryExpression_ltEq_result_not_null() async {
    await analyze('''
bool f(int i, int j) => i <= j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('bool f').node);
  }

  test_binaryExpression_ltLt_result_not_null() async {
    await analyze('''
int f(int i, int j) => i << j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int f').node);
  }

  test_binaryExpression_minus_result_not_null() async {
    await analyze('''
int f(int i, int j) => i - j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int f').node);
  }

  test_binaryExpression_notEqual() async {
    await analyze('''
bool f(int i, int j) => i != j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('bool f').node);
  }

  test_binaryExpression_percent_result_not_null() async {
    await analyze('''
int f(int i, int j) => i % j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int f').node);
  }

  test_binaryExpression_plus_left_check() async {
    await analyze('''
int f(int i, int j) => i + j;
''');

    assertNullCheck(checkExpression('i +'),
        assertEdge(decoratedTypeAnnotation('int i').node, never, hard: true));
  }

  test_binaryExpression_plus_left_check_custom() async {
    await analyze('''
class Int {
  Int operator+(Int other) => this;
}
Int f(Int i, Int j) => i + j;
''');

    assertNullCheck(checkExpression('i +'),
        assertEdge(decoratedTypeAnnotation('Int i').node, never, hard: true));
  }

  test_binaryExpression_plus_result_custom() async {
    await analyze('''
class Int {
  Int operator+(Int other) => this;
}
Int f(Int i, Int j) => (i + j);
''');

    assertNullCheck(
        checkExpression('(i + j)'),
        assertEdge(decoratedTypeAnnotation('Int operator+').node,
            decoratedTypeAnnotation('Int f').node,
            hard: false));
  }

  test_binaryExpression_plus_result_not_null() async {
    await analyze('''
int f(int i, int j) => i + j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int f').node);
  }

  test_binaryExpression_plus_right_check() async {
    await analyze('''
int f(int i, int j) => i + j;
''');

    assertNullCheck(checkExpression('j;'),
        assertEdge(decoratedTypeAnnotation('int j').node, never, hard: true));
  }

  test_binaryExpression_plus_right_check_custom() async {
    await analyze('''
class Int {
  Int operator+(Int other) => this;
}
Int f(Int i, Int j) => i + j/*check*/;
''');

    assertNullCheck(
        checkExpression('j/*check*/'),
        assertEdge(decoratedTypeAnnotation('Int j').node,
            decoratedTypeAnnotation('Int other').node,
            hard: true));
  }

  test_binaryExpression_questionQuestion() async {
    await analyze('''
int f(int i, int j) => i ?? j;
''');

    var left = decoratedTypeAnnotation('int i').node;
    var right = decoratedTypeAnnotation('int j').node;
    var expression = decoratedExpressionType('??').node;
    assertEdge(right, expression, guards: [left], hard: false);
  }

  test_binaryExpression_slash_result_not_null() async {
    await analyze('''
double f(int i, int j) => i / j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('double f').node);
  }

  test_binaryExpression_star_result_not_null() async {
    await analyze('''
int f(int i, int j) => i * j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int f').node);
  }

  test_binaryExpression_tildeSlash_result_not_null() async {
    await analyze('''
int f(int i, int j) => i ~/ j;
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int f').node);
  }

  test_boolLiteral() async {
    await analyze('''
bool f() {
  return true;
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('bool').node);
  }

  test_cascadeExpression() async {
    await analyze('''
class C {
  int x = 0;
}
C f(C c, int i) => c..x = i;
''');
    assertEdge(decoratedTypeAnnotation('C c').node,
        decoratedTypeAnnotation('C f').node,
        hard: false);
  }

  test_catch_clause() async {
    await analyze('''
foo() => 1;
main() {
  try { foo(); } on Exception catch (e) { print(e); }
}
''');
    // No assertions; just checking that it doesn't crash.
  }

  test_catch_clause_no_type() async {
    await analyze('''
foo() => 1;
main() {
  try { foo(); } catch (e) { print(e); }
}
''');
    // No assertions; just checking that it doesn't crash.
  }

  test_class_alias_synthetic_constructor_with_parameters_complex() async {
    await analyze('''
class MyList<T> {}
class C {
  C(MyList<int>/*1*/ x);
}
mixin M {}
class D = C with M;
D f(MyList<int>/*2*/ x) => D(x);
''');
    var syntheticConstructor = findElement.unnamedConstructor('D');
    var constructorType = variables.decoratedElementType(syntheticConstructor);
    var constructorParameterType = constructorType.positionalParameters[0];
    assertEdge(decoratedTypeAnnotation('MyList<int>/*2*/').node,
        constructorParameterType.node,
        hard: true);
    assertEdge(decoratedTypeAnnotation('int>/*2*/').node,
        constructorParameterType.typeArguments[0].node,
        hard: false);
    assertUnion(constructorParameterType.node,
        decoratedTypeAnnotation('MyList<int>/*1*/').node);
    assertUnion(constructorParameterType.typeArguments[0].node,
        decoratedTypeAnnotation('int>/*1*/').node);
  }

  test_class_alias_synthetic_constructor_with_parameters_generic() async {
    await analyze('''
class C<T> {
  C(T t);
}
mixin M {}
class D<U> = C<U> with M;
''');
    var syntheticConstructor = findElement.unnamedConstructor('D');
    var constructorType = variables.decoratedElementType(syntheticConstructor);
    var constructorParameterType = constructorType.positionalParameters[0];
    assertUnion(
        constructorParameterType.node, decoratedTypeAnnotation('T t').node);
  }

  test_class_alias_synthetic_constructor_with_parameters_named() async {
    await analyze('''
class C {
  C({int/*1*/ i});
}
mixin M {}
class D = C with M;
D f(int/*2*/ i) => D(i: i);
''');
    var syntheticConstructor = findElement.unnamedConstructor('D');
    var constructorType = variables.decoratedElementType(syntheticConstructor);
    var constructorParameterType = constructorType.namedParameters['i'];
    assertEdge(
        decoratedTypeAnnotation('int/*2*/').node, constructorParameterType.node,
        hard: true);
    assertUnion(constructorParameterType.node,
        decoratedTypeAnnotation('int/*1*/').node);
  }

  test_class_alias_synthetic_constructor_with_parameters_optional() async {
    await analyze('''
class C {
  C([int/*1*/ i]);
}
mixin M {}
class D = C with M;
D f(int/*2*/ i) => D(i);
''');
    var syntheticConstructor = findElement.unnamedConstructor('D');
    var constructorType = variables.decoratedElementType(syntheticConstructor);
    var constructorParameterType = constructorType.positionalParameters[0];
    assertEdge(
        decoratedTypeAnnotation('int/*2*/').node, constructorParameterType.node,
        hard: true);
    assertUnion(constructorParameterType.node,
        decoratedTypeAnnotation('int/*1*/').node);
  }

  test_class_alias_synthetic_constructor_with_parameters_required() async {
    await analyze('''
class C {
  C(int/*1*/ i);
}
mixin M {}
class D = C with M;
D f(int/*2*/ i) => D(i);
''');
    var syntheticConstructor = findElement.unnamedConstructor('D');
    var constructorType = variables.decoratedElementType(syntheticConstructor);
    var constructorParameterType = constructorType.positionalParameters[0];
    assertEdge(
        decoratedTypeAnnotation('int/*2*/').node, constructorParameterType.node,
        hard: true);
    assertUnion(constructorParameterType.node,
        decoratedTypeAnnotation('int/*1*/').node);
  }

  test_conditionalExpression_condition_check() async {
    await analyze('''
int f(bool b, int i, int j) {
  return (b ? i : j);
}
''');

    var nullable_b = decoratedTypeAnnotation('bool b').node;
    var check_b = checkExpression('b ?');
    assertNullCheck(check_b, assertEdge(nullable_b, never, hard: true));
  }

  test_conditionalExpression_functionTyped_namedParameter() async {
    await analyze('''
void f(bool b, void Function({int p}) x, void Function({int p}) y) {
  (b ? x : y);
}
''');
    var xType =
        decoratedGenericFunctionTypeAnnotation('void Function({int p}) x');
    var yType =
        decoratedGenericFunctionTypeAnnotation('void Function({int p}) y');
    var resultType = decoratedExpressionType('(b ?');
    assertLUB(resultType.node, xType.node, yType.node);
    assertGLB(resultType.namedParameters['p'].node,
        xType.namedParameters['p'].node, yType.namedParameters['p'].node);
  }

  test_conditionalExpression_functionTyped_normalParameter() async {
    await analyze('''
void f(bool b, void Function(int) x, void Function(int) y) {
  (b ? x : y);
}
''');
    var xType = decoratedGenericFunctionTypeAnnotation('void Function(int) x');
    var yType = decoratedGenericFunctionTypeAnnotation('void Function(int) y');
    var resultType = decoratedExpressionType('(b ?');
    assertLUB(resultType.node, xType.node, yType.node);
    assertGLB(resultType.positionalParameters[0].node,
        xType.positionalParameters[0].node, yType.positionalParameters[0].node);
  }

  test_conditionalExpression_functionTyped_normalParameters() async {
    await analyze('''
void f(bool b, void Function(int, int) x, void Function(int, int) y) {
  (b ? x : y);
}
''');
    var xType =
        decoratedGenericFunctionTypeAnnotation('void Function(int, int) x');
    var yType =
        decoratedGenericFunctionTypeAnnotation('void Function(int, int) y');
    var resultType = decoratedExpressionType('(b ?');
    assertLUB(resultType.node, xType.node, yType.node);
    assertGLB(resultType.positionalParameters[0].node,
        xType.positionalParameters[0].node, yType.positionalParameters[0].node);
    assertGLB(resultType.positionalParameters[1].node,
        xType.positionalParameters[1].node, yType.positionalParameters[1].node);
  }

  test_conditionalExpression_functionTyped_optionalParameter() async {
    await analyze('''
void f(bool b, void Function([int]) x, void Function([int]) y) {
  (b ? x : y);
}
''');
    var xType =
        decoratedGenericFunctionTypeAnnotation('void Function([int]) x');
    var yType =
        decoratedGenericFunctionTypeAnnotation('void Function([int]) y');
    var resultType = decoratedExpressionType('(b ?');
    assertLUB(resultType.node, xType.node, yType.node);
    assertGLB(resultType.positionalParameters[0].node,
        xType.positionalParameters[0].node, yType.positionalParameters[0].node);
  }

  test_conditionalExpression_functionTyped_returnType() async {
    await analyze('''
void f(bool b, int Function() x, int Function() y) {
  (b ? x : y);
}
''');
    var xType = decoratedGenericFunctionTypeAnnotation('int Function() x');
    var yType = decoratedGenericFunctionTypeAnnotation('int Function() y');
    var resultType = decoratedExpressionType('(b ?');
    assertLUB(resultType.node, xType.node, yType.node);
    assertLUB(resultType.returnType.node, xType.returnType.node,
        yType.returnType.node);
  }

  test_conditionalExpression_functionTyped_returnType_void() async {
    await analyze('''
void f(bool b, void Function() x, void Function() y) {
  (b ? x : y);
}
''');
    var xType = decoratedGenericFunctionTypeAnnotation('void Function() x');
    var yType = decoratedGenericFunctionTypeAnnotation('void Function() y');
    var resultType = decoratedExpressionType('(b ?');
    assertLUB(resultType.node, xType.node, yType.node);
    expect(resultType.returnType.node, same(always));
  }

  test_conditionalExpression_general() async {
    await analyze('''
int f(bool b, int i, int j) {
  return (b ? i : j);
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_j = decoratedTypeAnnotation('int j').node;
    var nullable_conditional = decoratedExpressionType('(b ?').node;
    assertLUB(nullable_conditional, nullable_i, nullable_j);
    var nullable_return = decoratedTypeAnnotation('int f').node;
    assertNullCheck(checkExpression('(b ? i : j)'),
        assertEdge(nullable_conditional, nullable_return, hard: false));
  }

  test_conditionalExpression_generic() async {
    await analyze('''
void f(bool b, Map<int, String> x, Map<int, String> y) {
  (b ? x : y);
}
''');
    var xType = decoratedTypeAnnotation('Map<int, String> x');
    var yType = decoratedTypeAnnotation('Map<int, String> y');
    var resultType = decoratedExpressionType('(b ?');
    assertLUB(resultType.node, xType.node, yType.node);
    assertLUB(resultType.typeArguments[0].node, xType.typeArguments[0].node,
        yType.typeArguments[0].node);
    assertLUB(resultType.typeArguments[1].node, xType.typeArguments[1].node,
        yType.typeArguments[1].node);
  }

  test_conditionalExpression_left_non_null() async {
    await analyze('''
int f(bool b, int i) {
  return (b ? (throw i) : i);
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_conditional =
        decoratedExpressionType('(b ?').node as NullabilityNodeForLUB;
    var nullable_throw = nullable_conditional.left;
    assertNoUpstreamNullability(nullable_throw);
    assertLUB(nullable_conditional, nullable_throw, nullable_i);
  }

  test_conditionalExpression_left_null() async {
    await analyze('''
int f(bool b, int i) {
  return (b ? null : i);
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_conditional = decoratedExpressionType('(b ?').node;
    assertLUB(nullable_conditional, always, nullable_i);
  }

  test_conditionalExpression_right_non_null() async {
    await analyze('''
int f(bool b, int i) {
  return (b ? i : (throw i));
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_conditional =
        decoratedExpressionType('(b ?').node as NullabilityNodeForLUB;
    var nullable_throw = nullable_conditional.right;
    assertNoUpstreamNullability(nullable_throw);
    assertLUB(nullable_conditional, nullable_i, nullable_throw);
  }

  test_conditionalExpression_right_null() async {
    await analyze('''
int f(bool b, int i) {
  return (b ? i : null);
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_conditional = decoratedExpressionType('(b ?').node;
    assertLUB(nullable_conditional, nullable_i, always);
  }

  test_constructor_named() async {
    await analyze('''
class C {
  C.named();
}
''');
    // No assertions; just need to make sure that the test doesn't cause an
    // exception to be thrown.
  }

  test_constructorDeclaration_returnType_generic() async {
    await analyze('''
class C<T, U> {
  C();
}
''');
    var constructor = findElement.unnamedConstructor('C');
    var constructorDecoratedType = variables.decoratedElementType(constructor);
    expect(constructorDecoratedType.type.toString(), 'C<T, U> Function()');
    expect(constructorDecoratedType.node, same(never));
    expect(constructorDecoratedType.typeFormals, isEmpty);
    expect(constructorDecoratedType.returnType.node, same(never));
    expect(constructorDecoratedType.returnType.type.toString(), 'C<T, U>');
    var typeArguments = constructorDecoratedType.returnType.typeArguments;
    expect(typeArguments, hasLength(2));
    expect(typeArguments[0].type.toString(), 'T');
    expect(typeArguments[0].node, same(never));
    expect(typeArguments[1].type.toString(), 'U');
    expect(typeArguments[1].node, same(never));
  }

  test_constructorDeclaration_returnType_generic_implicit() async {
    await analyze('''
class C<T, U> {}
''');
    var constructor = findElement.unnamedConstructor('C');
    var constructorDecoratedType = variables.decoratedElementType(constructor);
    expect(constructorDecoratedType.type.toString(), 'C<T, U> Function()');
    expect(constructorDecoratedType.node, same(never));
    expect(constructorDecoratedType.typeFormals, isEmpty);
    expect(constructorDecoratedType.returnType.node, same(never));
    expect(constructorDecoratedType.returnType.type.toString(), 'C<T, U>');
    var typeArguments = constructorDecoratedType.returnType.typeArguments;
    expect(typeArguments, hasLength(2));
    expect(typeArguments[0].type.toString(), 'T');
    expect(typeArguments[0].node, same(never));
    expect(typeArguments[1].type.toString(), 'U');
    expect(typeArguments[1].node, same(never));
  }

  test_constructorDeclaration_returnType_simple() async {
    await analyze('''
class C {
  C();
}
''');
    var constructorDecoratedType =
        variables.decoratedElementType(findElement.unnamedConstructor('C'));
    expect(constructorDecoratedType.type.toString(), 'C Function()');
    expect(constructorDecoratedType.node, same(never));
    expect(constructorDecoratedType.typeFormals, isEmpty);
    expect(constructorDecoratedType.returnType.node, same(never));
    expect(constructorDecoratedType.returnType.typeArguments, isEmpty);
  }

  test_constructorDeclaration_returnType_simple_implicit() async {
    await analyze('''
class C {}
''');
    var constructorDecoratedType =
        variables.decoratedElementType(findElement.unnamedConstructor('C'));
    expect(constructorDecoratedType.type.toString(), 'C Function()');
    expect(constructorDecoratedType.node, same(never));
    expect(constructorDecoratedType.typeFormals, isEmpty);
    expect(constructorDecoratedType.returnType.node, same(never));
    expect(constructorDecoratedType.returnType.typeArguments, isEmpty);
  }

  test_constructorFieldInitializer_generic() async {
    await analyze('''
class C<T> {
  C(T/*1*/ x) : f = x;
  T/*2*/ f;
}
''');
    assertEdge(decoratedTypeAnnotation('T/*1*/').node,
        decoratedTypeAnnotation('T/*2*/').node,
        hard: true);
  }

  test_constructorFieldInitializer_simple() async {
    await analyze('''
class C {
  C(int/*1*/ i) : f = i;
  int/*2*/ f;
}
''');
    assertEdge(decoratedTypeAnnotation('int/*1*/').node,
        decoratedTypeAnnotation('int/*2*/').node,
        hard: true);
  }

  test_constructorFieldInitializer_via_this() async {
    await analyze('''
class C {
  C(int/*1*/ i) : this.f = i;
  int/*2*/ f;
}
''');
    assertEdge(decoratedTypeAnnotation('int/*1*/').node,
        decoratedTypeAnnotation('int/*2*/').node,
        hard: true);
  }

  test_do_while_condition() async {
    await analyze('''
void f(bool b) {
  do {} while (b);
}
''');

    assertNullCheck(checkExpression('b);'),
        assertEdge(decoratedTypeAnnotation('bool b').node, never, hard: true));
  }

  test_doubleLiteral() async {
    await analyze('''
double f() {
  return 1.0;
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('double').node);
  }

  test_field_type_inferred() async {
    await analyze('''
int f() => 1;
class C {
  var x = f();
}
''');
    var xType =
        variables.decoratedElementType(findNode.simple('x').staticElement);
    assertUnion(xType.node, decoratedTypeAnnotation('int').node);
  }

  test_fieldFormalParameter_function_typed() async {
    await analyze('''
class C {
  int Function(int, {int j}) f;
  C(int this.f(int i, {int j}));
}
''');
    var ctorParamType = variables
        .decoratedElementType(findElement.unnamedConstructor('C'))
        .positionalParameters[0];
    var fieldType = variables.decoratedElementType(findElement.field('f'));
    assertEdge(ctorParamType.node, fieldType.node, hard: true);
    assertEdge(ctorParamType.returnType.node, fieldType.returnType.node,
        hard: false);
    assertEdge(fieldType.positionalParameters[0].node,
        ctorParamType.positionalParameters[0].node,
        hard: false);
    assertEdge(fieldType.namedParameters['j'].node,
        ctorParamType.namedParameters['j'].node,
        hard: false);
  }

  test_fieldFormalParameter_typed() async {
    await analyze('''
class C {
  int i;
  C(int this.i);
}
''');
    assertEdge(decoratedTypeAnnotation('int this').node,
        decoratedTypeAnnotation('int i').node,
        hard: true);
  }

  test_fieldFormalParameter_untyped() async {
    await analyze('''
class C {
  int i;
  C.named(this.i);
}
''');
    var decoratedConstructorParamType =
        decoratedConstructorDeclaration('named').positionalParameters[0];
    assertUnion(decoratedConstructorParamType.node,
        decoratedTypeAnnotation('int i').node);
  }

  test_for_with_declaration() async {
    await analyze('''
main() {
  for (int i in <int>[1, 2, 3]) { print(i); }
}
''');
    // No assertions; just checking that it doesn't crash.
  }

  test_for_with_var() async {
    await analyze('''
main() {
  for (var i in <int>[1, 2, 3]) { print(i); }
}
''');
    // No assertions; just checking that it doesn't crash.
  }

  test_function_assignment() async {
    await analyze('''
class C {
  void f1(String message) {}
  void f2(String message) {}
}
foo(C c, bool flag) {
  Function(String message) out = flag ? c.f1 : c.f2;
  out('hello');
}
bar() {
  foo(C(), true);
  foo(C(), false);
}
''');
    var type = decoratedTypeAnnotation('Function(String message)');
    expect(type.returnType, isNotNull);
  }

  test_functionDeclaration_expression_body() async {
    await analyze('''
int/*1*/ f(int/*2*/ i) => i/*3*/;
''');

    assertNullCheck(
        checkExpression('i/*3*/'),
        assertEdge(decoratedTypeAnnotation('int/*2*/').node,
            decoratedTypeAnnotation('int/*1*/').node,
            hard: true));
  }

  test_functionDeclaration_parameter_named_default_listConst() async {
    await analyze('''
void f({List<int/*1*/> i = const <int/*2*/>[]}) {}
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('List<int/*1*/>').node);
    assertEdge(decoratedTypeAnnotation('int/*2*/').node,
        decoratedTypeAnnotation('int/*1*/').node,
        hard: false);
  }

  test_functionDeclaration_parameter_named_default_notNull() async {
    await analyze('''
void f({int i = 1}) {}
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int').node);
  }

  test_functionDeclaration_parameter_named_default_null() async {
    await analyze('''
void f({int i = null}) {}
''');

    assertEdge(always, decoratedTypeAnnotation('int').node, hard: false);
  }

  test_functionDeclaration_parameter_named_no_default() async {
    await analyze('''
void f({int i}) {}
''');

    assertEdge(always, decoratedTypeAnnotation('int').node, hard: false);
  }

  test_functionDeclaration_parameter_named_no_default_required() async {
    addMetaPackage();
    await analyze('''
import 'package:meta/meta.dart';
void f({@required int i}) {}
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int').node);
  }

  test_functionDeclaration_parameter_positionalOptional_default_notNull() async {
    await analyze('''
void f([int i = 1]) {}
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('int').node);
  }

  test_functionDeclaration_parameter_positionalOptional_default_null() async {
    await analyze('''
void f([int i = null]) {}
''');

    assertEdge(always, decoratedTypeAnnotation('int').node, hard: false);
  }

  test_functionDeclaration_parameter_positionalOptional_no_default() async {
    await analyze('''
void f([int i]) {}
''');

    assertEdge(always, decoratedTypeAnnotation('int').node, hard: false);
  }

  test_functionDeclaration_resets_unconditional_control_flow() async {
    await analyze('''
void f(bool b, int i, int j) {
  assert(i != null);
  if (b) return;
  assert(j != null);
}
void g(int k) {
  assert(k != null);
}
''');
    assertEdge(decoratedTypeAnnotation('int i').node, never, hard: true);
    assertNoEdge(always, decoratedTypeAnnotation('int j').node);
    assertEdge(decoratedTypeAnnotation('int k').node, never, hard: true);
  }

  test_functionExpressionInvocation_parameterType() async {
    await analyze('''
abstract class C {
  void Function(int) f();
}
void g(C c, int i) {
  c.f()(i);
}
''');
    assertEdge(decoratedTypeAnnotation('int i').node,
        decoratedTypeAnnotation('int)').node,
        hard: true);
  }

  test_functionExpressionInvocation_returnType() async {
    await analyze('''
abstract class C {
  int Function() f();
}
int g(C c) => c.f()();
''');
    assertEdge(decoratedTypeAnnotation('int Function').node,
        decoratedTypeAnnotation('int g').node,
        hard: false);
  }

  test_functionInvocation_parameter_fromLocalParameter() async {
    await analyze('''
void f(int/*1*/ i) {}
void test(int/*2*/ i) {
  f(i/*3*/);
}
''');

    var int_1 = decoratedTypeAnnotation('int/*1*/');
    var int_2 = decoratedTypeAnnotation('int/*2*/');
    var i_3 = checkExpression('i/*3*/');
    assertNullCheck(i_3, assertEdge(int_2.node, int_1.node, hard: true));
    assertEdge(int_2.node, int_1.node, hard: true);
  }

  test_functionInvocation_parameter_named() async {
    await analyze('''
void f({int i: 0}) {}
void g(int j) {
  f(i: j/*check*/);
}
''');
    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_j = decoratedTypeAnnotation('int j').node;
    assertNullCheck(checkExpression('j/*check*/'),
        assertEdge(nullable_j, nullable_i, hard: true));
  }

  test_functionInvocation_parameter_named_missing() async {
    await analyze('''
void f({int i}) {}
void g() {
  f();
}
''');
    var optional_i = possiblyOptionalParameter('int i');
    expect(getEdges(always, optional_i), isNotEmpty);
  }

  test_functionInvocation_parameter_named_missing_required() async {
    addMetaPackage();
    verifyNoTestUnitErrors = false;
    await analyze('''
import 'package:meta/meta.dart';
void f({@required int i}) {}
void g() {
  f();
}
''');
    // The call at `f()` is presumed to be in error; no constraint is recorded.
    var optional_i = possiblyOptionalParameter('int i');
    expect(optional_i, isNull);
    var nullable_i = decoratedTypeAnnotation('int i').node;
    assertNoUpstreamNullability(nullable_i);
  }

  test_functionInvocation_parameter_null() async {
    await analyze('''
void f(int i) {}
void test() {
  f(null);
}
''');

    assertNullCheck(checkExpression('null'),
        assertEdge(always, decoratedTypeAnnotation('int').node, hard: false));
  }

  test_functionInvocation_return() async {
    await analyze('''
int/*1*/ f() => 0;
int/*2*/ g() {
  return (f());
}
''');

    assertNullCheck(
        checkExpression('(f())'),
        assertEdge(decoratedTypeAnnotation('int/*1*/').node,
            decoratedTypeAnnotation('int/*2*/').node,
            hard: false));
  }

  test_if_condition() async {
    await analyze('''
void f(bool b) {
  if (b) {}
}
''');

    assertNullCheck(checkExpression('b) {}'),
        assertEdge(decoratedTypeAnnotation('bool b').node, never, hard: true));
  }

  test_if_conditional_control_flow_after() async {
    // Asserts after ifs don't demonstrate non-null intent.
    // TODO(paulberry): if both branches complete normally, they should.
    await analyze('''
void f(bool b, int i) {
  if (b) return;
  assert(i != null);
}
''');

    assertNoEdge(always, decoratedTypeAnnotation('int i').node);
  }

  test_if_conditional_control_flow_within() async {
    // Asserts inside ifs don't demonstrate non-null intent.
    await analyze('''
void f(bool b, int i) {
  if (b) {
    assert(i != null);
  } else {
    assert(i != null);
  }
}
''');

    assertNoEdge(always, decoratedTypeAnnotation('int i').node);
  }

  test_if_guard_equals_null() async {
    await analyze('''
int f(int i, int j, int k) {
  if (i == null) {
    return j/*check*/;
  } else {
    return k/*check*/;
  }
}
''');
    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_j = decoratedTypeAnnotation('int j').node;
    var nullable_k = decoratedTypeAnnotation('int k').node;
    var nullable_return = decoratedTypeAnnotation('int f').node;
    assertNullCheck(
        checkExpression('j/*check*/'),
        assertEdge(nullable_j, nullable_return,
            guards: [nullable_i], hard: false));
    assertNullCheck(checkExpression('k/*check*/'),
        assertEdge(nullable_k, nullable_return, hard: false));
    var discard = statementDiscard('if (i == null)');
    expect(discard.trueGuard, same(nullable_i));
    expect(discard.falseGuard, null);
    expect(discard.pureCondition, true);
  }

  test_if_simple() async {
    await analyze('''
int f(bool b, int i, int j) {
  if (b) {
    return i/*check*/;
  } else {
    return j/*check*/;
  }
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_j = decoratedTypeAnnotation('int j').node;
    var nullable_return = decoratedTypeAnnotation('int f').node;
    assertNullCheck(checkExpression('i/*check*/'),
        assertEdge(nullable_i, nullable_return, hard: false));
    assertNullCheck(checkExpression('j/*check*/'),
        assertEdge(nullable_j, nullable_return, hard: false));
  }

  test_if_without_else() async {
    await analyze('''
int f(bool b, int i) {
  if (b) {
    return i/*check*/;
  }
  return 0;
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_return = decoratedTypeAnnotation('int f').node;
    assertNullCheck(checkExpression('i/*check*/'),
        assertEdge(nullable_i, nullable_return, hard: false));
  }

  test_indexExpression_index() async {
    await analyze('''
class C {
  int operator[](int i) => 1;
}
int f(C c, int j) => c[j];
''');
    assertEdge(decoratedTypeAnnotation('int j').node,
        decoratedTypeAnnotation('int i').node,
        hard: true);
  }

  test_indexExpression_index_cascaded() async {
    await analyze('''
class C {
  int operator[](int i) => 1;
}
C f(C c, int j) => c..[j];
''');
    assertEdge(decoratedTypeAnnotation('int j').node,
        decoratedTypeAnnotation('int i').node,
        hard: true);
  }

  test_indexExpression_return_type() async {
    await analyze('''
class C {
  int operator[](int i) => 1;
}
int f(C c) => c[0];
''');
    assertEdge(decoratedTypeAnnotation('int operator').node,
        decoratedTypeAnnotation('int f').node,
        hard: false);
  }

  test_indexExpression_target_check() async {
    await analyze('''
class C {
  int operator[](int i) => 1;
}
int f(C c) => c[0];
''');
    assertNullCheck(checkExpression('c['),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_indexExpression_target_check_cascaded() async {
    await analyze('''
class C {
  int operator[](int i) => 1;
}
C f(C c) => c..[0];
''');
    assertNullCheck(checkExpression('c..['),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_indexExpression_target_demonstrates_non_null_intent() async {
    await analyze('''
class C {
  int operator[](int i) => 1;
}
int f(C c) => c[0];
''');
    assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true);
  }

  test_indexExpression_target_demonstrates_non_null_intent_cascaded() async {
    await analyze('''
class C {
  int operator[](int i) => 1;
}
C f(C c) => c..[0];
''');
    assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true);
  }

  test_instanceCreation_generic() async {
    await analyze('''
class C<T> {}
C<int> f() => C<int>();
''');
    assertEdge(decoratedTypeAnnotation('int>(').node,
        decoratedTypeAnnotation('int> f').node,
        hard: false);
  }

  test_instanceCreation_generic_parameter() async {
    await analyze('''
class C<T> {
  C(T t);
}
f(int i) => C<int>(i/*check*/);
''');
    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_c_t = decoratedTypeAnnotation('C<int>').typeArguments[0].node;
    var nullable_t = decoratedTypeAnnotation('T t').node;
    var check_i = checkExpression('i/*check*/');
    var nullable_c_t_or_nullable_t =
        check_i.edges.single.destinationNode as NullabilityNodeForSubstitution;
    expect(nullable_c_t_or_nullable_t.innerNode, same(nullable_c_t));
    expect(nullable_c_t_or_nullable_t.outerNode, same(nullable_t));
    assertNullCheck(check_i,
        assertEdge(nullable_i, nullable_c_t_or_nullable_t, hard: true));
  }

  test_instanceCreation_parameter_named_optional() async {
    await analyze('''
class C {
  C({int x = 0});
}
void f(int y) {
  C(x: y);
}
''');

    assertEdge(decoratedTypeAnnotation('int y').node,
        decoratedTypeAnnotation('int x').node,
        hard: true);
  }

  test_instanceCreation_parameter_positional_optional() async {
    await analyze('''
class C {
  C([int x]);
}
void f(int y) {
  C(y);
}
''');

    assertEdge(decoratedTypeAnnotation('int y').node,
        decoratedTypeAnnotation('int x').node,
        hard: true);
  }

  test_instanceCreation_parameter_positional_required() async {
    await analyze('''
class C {
  C(int x);
}
void f(int y) {
  C(y);
}
''');

    assertEdge(decoratedTypeAnnotation('int y').node,
        decoratedTypeAnnotation('int x').node,
        hard: true);
  }

  test_integerLiteral() async {
    await analyze('''
int f() {
  return 0;
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('int').node);
  }

  @failingTest
  test_isExpression_genericFunctionType() async {
    await analyze('''
bool f(a) => a is int Function(String);
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('bool').node);
  }

  test_isExpression_typeName_noTypeArguments() async {
    await analyze('''
bool f(a) => a is String;
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('bool').node);
  }

  @failingTest
  test_isExpression_typeName_typeArguments() async {
    await analyze('''
bool f(a) => a is List<int>;
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('bool').node);
  }

  test_libraryDirective() async {
    await analyze('''
library foo;
''');
    // Passes if no exceptions are thrown.
  }

  @failingTest
  test_listLiteral_noTypeArgument_noNullableElements() async {
    // Failing because we're not yet handling collection literals without a
    // type argument.
    await analyze('''
List<String> f() {
  return ['a', 'b'];
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('List').node);
    // TODO(brianwilkerson) Add an assertion that there is an edge from the list
    //  literal's fake type argument to the return type's type argument.
  }

  @failingTest
  test_listLiteral_noTypeArgument_nullableElement() async {
    // Failing because we're not yet handling collection literals without a
    // type argument.
    await analyze('''
List<String> f() {
  return ['a', null, 'c'];
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('List').node);
    assertEdge(always, decoratedTypeAnnotation('String').node, hard: false);
  }

  test_listLiteral_typeArgument_noNullableElements() async {
    await analyze('''
List<String> f() {
  return <String>['a', 'b'];
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('List').node);
    var typeArgForLiteral = decoratedTypeAnnotation('String>[').node;
    var typeArgForReturnType = decoratedTypeAnnotation('String> ').node;
    assertNoUpstreamNullability(typeArgForLiteral);
    assertEdge(typeArgForLiteral, typeArgForReturnType, hard: false);
  }

  test_listLiteral_typeArgument_nullableElement() async {
    await analyze('''
List<String> f() {
  return <String>['a', null, 'c'];
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('List').node);
    assertEdge(always, decoratedTypeAnnotation('String>[').node, hard: false);
  }

  test_localVariable_type_inferred() async {
    await analyze('''
int f() => 1;
main() {
  var x = f();
}
''');
    var xType =
        variables.decoratedElementType(findNode.simple('x').staticElement);
    assertUnion(xType.node, decoratedTypeAnnotation('int').node);
  }

  test_method_parameterType_inferred() async {
    await analyze('''
class B {
  void f/*B*/(int x) {}
}
class C extends B {
  void f/*C*/(x) {}
}
''');
    var bReturnType = decoratedMethodType('f/*B*/').positionalParameters[0];
    var cReturnType = decoratedMethodType('f/*C*/').positionalParameters[0];
    assertUnion(bReturnType.node, cReturnType.node);
  }

  test_method_parameterType_inferred_named() async {
    await analyze('''
class B {
  void f/*B*/({int x = 0}) {}
}
class C extends B {
  void f/*C*/({x = 0}) {}
}
''');
    var bReturnType = decoratedMethodType('f/*B*/').namedParameters['x'];
    var cReturnType = decoratedMethodType('f/*C*/').namedParameters['x'];
    assertUnion(bReturnType.node, cReturnType.node);
  }

  test_method_returnType_inferred() async {
    await analyze('''
class B {
  int f/*B*/() => 1;
}
class C extends B {
  f/*C*/() => 1;
}
''');
    var bReturnType = decoratedMethodType('f/*B*/').returnType;
    var cReturnType = decoratedMethodType('f/*C*/').returnType;
    assertUnion(bReturnType.node, cReturnType.node);
  }

  test_methodDeclaration_doesntAffect_unconditional_control_flow() async {
    await analyze('''
class C {
  void f(bool b, int i, int j) {
    assert(i != null);
    if (b) {}
    assert(j != null);
  }
  void g(int k) {
    assert(k != null);
  }
}
''');
    assertEdge(decoratedTypeAnnotation('int i').node, never, hard: true);
    assertNoEdge(always, decoratedTypeAnnotation('int j').node);
    assertEdge(decoratedTypeAnnotation('int k').node, never, hard: true);
  }

  test_methodDeclaration_resets_unconditional_control_flow() async {
    await analyze('''
class C {
  void f(bool b, int i, int j) {
    assert(i != null);
    if (b) return;
    assert(j != null);
  }
  void g(int k) {
    assert(k != null);
  }
}
''');
    assertEdge(decoratedTypeAnnotation('int i').node, never, hard: true);
    assertNoEdge(always, decoratedTypeAnnotation('int j').node);
    assertEdge(decoratedTypeAnnotation('int k').node, never, hard: true);
  }

  test_methodInvocation_parameter_contravariant() async {
    await analyze('''
class C<T> {
  void f(T t) {}
}
void g(C<int> c, int i) {
  c.f(i/*check*/);
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_c_t = decoratedTypeAnnotation('C<int>').typeArguments[0].node;
    var nullable_t = decoratedTypeAnnotation('T t').node;
    var check_i = checkExpression('i/*check*/');
    var nullable_c_t_or_nullable_t =
        check_i.edges.single.destinationNode as NullabilityNodeForSubstitution;
    expect(nullable_c_t_or_nullable_t.innerNode, same(nullable_c_t));
    expect(nullable_c_t_or_nullable_t.outerNode, same(nullable_t));
    assertNullCheck(check_i,
        assertEdge(nullable_i, nullable_c_t_or_nullable_t, hard: true));
  }

  test_methodInvocation_parameter_contravariant_from_migrated_class() async {
    await analyze('''
void f(List<int> x, int i) {
  x.add(i/*check*/);
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_list_t =
        decoratedTypeAnnotation('List<int>').typeArguments[0].node;
    var addMethod = findNode.methodInvocation('x.add').methodName.staticElement
        as MethodMember;
    var nullable_t = variables
        .decoratedElementType(addMethod.baseElement)
        .positionalParameters[0]
        .node;
    expect(nullable_t, same(never));
    var check_i = checkExpression('i/*check*/');
    var nullable_list_t_or_nullable_t =
        check_i.edges.single.destinationNode as NullabilityNodeForSubstitution;
    expect(nullable_list_t_or_nullable_t.innerNode, same(nullable_list_t));
    expect(nullable_list_t_or_nullable_t.outerNode, same(nullable_t));
    assertNullCheck(check_i,
        assertEdge(nullable_i, nullable_list_t_or_nullable_t, hard: true));
  }

  test_methodInvocation_parameter_contravariant_function() async {
    await analyze('''
void f<T>(T t) {}
void g(int i) {
  f<int>(i/*check*/);
}
''');
    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_f_t = decoratedTypeAnnotation('int>').node;
    var nullable_t = decoratedTypeAnnotation('T t').node;
    var check_i = checkExpression('i/*check*/');
    var nullable_f_t_or_nullable_t =
        check_i.edges.single.destinationNode as NullabilityNodeForSubstitution;
    expect(nullable_f_t_or_nullable_t.innerNode, same(nullable_f_t));
    expect(nullable_f_t_or_nullable_t.outerNode, same(nullable_t));
    assertNullCheck(check_i,
        assertEdge(nullable_i, nullable_f_t_or_nullable_t, hard: true));
  }

  test_methodInvocation_parameter_generic() async {
    await analyze('''
class C<T> {}
void f(C<int/*1*/>/*2*/ c) {}
void g(C<int/*3*/>/*4*/ c) {
  f(c/*check*/);
}
''');

    assertEdge(decoratedTypeAnnotation('int/*3*/').node,
        decoratedTypeAnnotation('int/*1*/').node,
        hard: false);
    assertNullCheck(
        checkExpression('c/*check*/'),
        assertEdge(decoratedTypeAnnotation('C<int/*3*/>/*4*/').node,
            decoratedTypeAnnotation('C<int/*1*/>/*2*/').node,
            hard: true));
  }

  test_methodInvocation_parameter_named() async {
    await analyze('''
class C {
  void f({int i: 0}) {}
}
void g(C c, int j) {
  c.f(i: j/*check*/);
}
''');
    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_j = decoratedTypeAnnotation('int j').node;
    assertNullCheck(checkExpression('j/*check*/'),
        assertEdge(nullable_j, nullable_i, hard: true));
  }

  test_methodInvocation_parameter_named_differentPackage() async {
    addPackageFile('pkgC', 'c.dart', '''
class C {
  void f({int i}) {}
}
''');
    await analyze('''
import "package:pkgC/c.dart";
void g(C c, int j) {
  c.f(i: j/*check*/);
}
''');
    var nullable_j = decoratedTypeAnnotation('int j');
    assertNullCheck(checkExpression('j/*check*/'),
        assertEdge(nullable_j.node, never, hard: true));
  }

  test_methodInvocation_resolves_to_getter() async {
    await analyze('''
abstract class C {
  int/*1*/ Function(int/*2*/ i) get f;
}
int/*3*/ g(C c, int/*4*/ i) => c.f(i);
''');
    assertEdge(decoratedTypeAnnotation('int/*4*/').node,
        decoratedTypeAnnotation('int/*2*/').node,
        hard: true);
    assertEdge(decoratedTypeAnnotation('int/*1*/').node,
        decoratedTypeAnnotation('int/*3*/').node,
        hard: false);
  }

  test_methodInvocation_return_type() async {
    await analyze('''
class C {
  bool m() => true;
}
bool f(C c) => c.m();
''');
    assertEdge(decoratedTypeAnnotation('bool m').node,
        decoratedTypeAnnotation('bool f').node,
        hard: false);
  }

  test_methodInvocation_return_type_generic_function() async {
    await analyze('''
T f<T>(T t) => t;
int g() => (f<int>(1));
''');
    var check_i = checkExpression('(f<int>(1))');
    var nullable_f_t = decoratedTypeAnnotation('int>').node;
    var nullable_f_t_or_nullable_t =
        check_i.edges.single.primarySource as NullabilityNodeForSubstitution;
    var nullable_t = decoratedTypeAnnotation('T f').node;
    expect(nullable_f_t_or_nullable_t.innerNode, same(nullable_f_t));
    expect(nullable_f_t_or_nullable_t.outerNode, same(nullable_t));
    var nullable_return = decoratedTypeAnnotation('int g').node;
    assertNullCheck(check_i,
        assertEdge(nullable_f_t_or_nullable_t, nullable_return, hard: false));
  }

  test_methodInvocation_return_type_null_aware() async {
    await analyze('''
class C {
  bool m() => true;
}
bool f(C c) => (c?.m());
''');
    var lubNode =
        decoratedExpressionType('(c?.m())').node as NullabilityNodeForLUB;
    expect(lubNode.left, same(decoratedTypeAnnotation('C c').node));
    expect(lubNode.right, same(decoratedTypeAnnotation('bool m').node));
    assertEdge(lubNode, decoratedTypeAnnotation('bool f').node, hard: false);
  }

  test_methodInvocation_target_check() async {
    await analyze('''
class C {
  void m() {}
}
void test(C c) {
  c.m();
}
''');

    assertNullCheck(checkExpression('c.m'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_methodInvocation_target_check_cascaded() async {
    await analyze('''
class C {
  void m() {}
}
void test(C c) {
  c..m();
}
''');

    assertNullCheck(checkExpression('c..m'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_methodInvocation_target_demonstrates_non_null_intent() async {
    await analyze('''
class C {
  void m() {}
}
void test(C c) {
  c.m();
}
''');

    assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true);
  }

  test_methodInvocation_target_demonstrates_non_null_intent_cascaded() async {
    await analyze('''
class C {
  void m() {}
}
void test(C c) {
  c..m();
}
''');

    assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true);
  }

  test_never() async {
    await analyze('');

    expect(never.isNullable, isFalse);
  }

  test_override_parameter_type_named() async {
    await analyze('''
abstract class Base {
  void f({int/*1*/ i});
}
class Derived extends Base {
  void f({int/*2*/ i}) {}
}
''');
    var int1 = decoratedTypeAnnotation('int/*1*/');
    var int2 = decoratedTypeAnnotation('int/*2*/');
    assertEdge(int1.node, int2.node, hard: true);
  }

  test_override_parameter_type_named_over_none() async {
    await analyze('''
abstract class Base {
  void f();
}
class Derived extends Base {
  void f({int i}) {}
}
''');
    // No assertions; just checking that it doesn't crash.
  }

  test_override_parameter_type_operator() async {
    await analyze('''
abstract class Base {
  Base operator+(Base/*1*/ b);
}
class Derived extends Base {
  Base operator+(Base/*2*/ b) => this;
}
''');
    var base1 = decoratedTypeAnnotation('Base/*1*/');
    var base2 = decoratedTypeAnnotation('Base/*2*/');
    assertEdge(base1.node, base2.node, hard: true);
  }

  test_override_parameter_type_optional() async {
    await analyze('''
abstract class Base {
  void f([int/*1*/ i]);
}
class Derived extends Base {
  void f([int/*2*/ i]) {}
}
''');
    var int1 = decoratedTypeAnnotation('int/*1*/');
    var int2 = decoratedTypeAnnotation('int/*2*/');
    assertEdge(int1.node, int2.node, hard: true);
  }

  test_override_parameter_type_optional_over_none() async {
    await analyze('''
abstract class Base {
  void f();
}
class Derived extends Base {
  void f([int i]) {}
}
''');
    // No assertions; just checking that it doesn't crash.
  }

  test_override_parameter_type_optional_over_required() async {
    await analyze('''
abstract class Base {
  void f(int/*1*/ i);
}
class Derived extends Base {
  void f([int/*2*/ i]) {}
}
''');
    var int1 = decoratedTypeAnnotation('int/*1*/');
    var int2 = decoratedTypeAnnotation('int/*2*/');
    assertEdge(int1.node, int2.node, hard: true);
  }

  test_override_parameter_type_required() async {
    await analyze('''
abstract class Base {
  void f(int/*1*/ i);
}
class Derived extends Base {
  void f(int/*2*/ i) {}
}
''');
    var int1 = decoratedTypeAnnotation('int/*1*/');
    var int2 = decoratedTypeAnnotation('int/*2*/');
    assertEdge(int1.node, int2.node, hard: true);
  }

  test_override_parameter_type_setter() async {
    await analyze('''
abstract class Base {
  void set x(int/*1*/ value);
}
class Derived extends Base {
  void set x(int/*2*/ value) {}
}
''');
    var int1 = decoratedTypeAnnotation('int/*1*/');
    var int2 = decoratedTypeAnnotation('int/*2*/');
    assertEdge(int1.node, int2.node, hard: true);
  }

  test_override_return_type_getter() async {
    await analyze('''
abstract class Base {
  int/*1*/ get x;
}
class Derived extends Base {
  int/*2*/ get x => null;
}
''');
    var int1 = decoratedTypeAnnotation('int/*1*/');
    var int2 = decoratedTypeAnnotation('int/*2*/');
    assertEdge(int2.node, int1.node, hard: true);
  }

  test_override_return_type_method() async {
    await analyze('''
abstract class Base {
  int/*1*/ f();
}
class Derived extends Base {
  int/*2*/ f() => null;
}
''');
    var int1 = decoratedTypeAnnotation('int/*1*/');
    var int2 = decoratedTypeAnnotation('int/*2*/');
    assertEdge(int2.node, int1.node, hard: true);
  }

  test_override_return_type_operator() async {
    await analyze('''
abstract class Base {
  Base/*1*/ operator-();
}
class Derived extends Base {
  Derived/*2*/ operator-() => null;
}
''');
    var base1 = decoratedTypeAnnotation('Base/*1*/');
    var derived2 = decoratedTypeAnnotation('Derived/*2*/');
    assertEdge(derived2.node, base1.node, hard: true);
  }

  test_parenthesizedExpression() async {
    await analyze('''
int f() {
  return (null);
}
''');

    assertNullCheck(checkExpression('(null)'),
        assertEdge(always, decoratedTypeAnnotation('int').node, hard: false));
  }

  test_postDominators_assert() async {
    await analyze('''
void test(bool b1, bool b2, bool b3, bool _b) {
  assert(b1 != null);
  if (_b) {
    assert(b2 != null);
  }
  assert(b3 != null);
}
''');

    assertEdge(decoratedTypeAnnotation('bool b1').node, never, hard: true);
    assertNoEdge(decoratedTypeAnnotation('bool b2').node, never);
    assertEdge(decoratedTypeAnnotation('bool b3').node, never, hard: true);
  }

  test_postDominators_break() async {
    await analyze('''
class C {
  void m() {}
}
void test(bool b1, C _c) {
  while (b1/*check*/) {
    bool b2 = b1;
    C c = _c;
    if (b2/*check*/) {
      break;
    }
    c.m();
  }
}
''');

    // TODO(mfairhurst): enable this check
    //assertNullCheck(checkExpression('b1/*check*/'),
    //    assertEdge(decoratedTypeAnnotation('bool b1').node, never, hard: true));
    assertNullCheck(checkExpression('b2/*check*/'),
        assertEdge(decoratedTypeAnnotation('bool b2').node, never, hard: true));
    assertNullCheck(checkExpression('c.m'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: false));
  }

  test_postDominators_continue() async {
    await analyze('''
class C {
  void m() {}
}
void test(bool b1, C _c) {
  while (b1/*check*/) {
    bool b2 = b1;
    C c = _c;
    if (b2/*check*/) {
      continue;
    }
    c.m();
  }
}
''');

    // TODO(mfairhurst): enable this check
    //assertNullCheck(checkExpression('b1/*check*/'),
    //    assertEdge(decoratedTypeAnnotation('bool b1').node, never, hard: true));
    assertNullCheck(checkExpression('b2/*check*/'),
        assertEdge(decoratedTypeAnnotation('bool b2').node, never, hard: true));
    assertNullCheck(checkExpression('c.m'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: false));
  }

  test_postDominators_doWhileStatement_conditional() async {
    await analyze('''
class C {
  void m() {}
}
void test(bool b, C c) {
  do {
    return;
  } while(b/*check*/);

  c.m();
}
''');

    // TODO(mfairhurst): enable this check
    //assertNullCheck(checkExpression('b/*check*/'),
    //    assertEdge(decoratedTypeAnnotation('bool b').node, never, hard: false));
    assertNullCheck(checkExpression('c.m'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: false));
  }

  test_postDominators_doWhileStatement_unconditional() async {
    await analyze('''
class C {
  void m() {}
}
void test(bool b, C c1, C c2) {
  do {
    C c3 = C();
    c1.m();
    c3.m();
  } while(b/*check*/);

  c2.m();
}
''');

    // TODO(mfairhurst): enable this check
    //assertNullCheck(checkExpression('b/*check*/'),
    //    assertEdge(decoratedTypeAnnotation('bool b').node, never, hard: true));
    assertNullCheck(checkExpression('c1.m'),
        assertEdge(decoratedTypeAnnotation('C c1').node, never, hard: true));
    assertNullCheck(checkExpression('c2.m'),
        assertEdge(decoratedTypeAnnotation('C c2').node, never, hard: true));
    assertNullCheck(checkExpression('c3.m'),
        assertEdge(decoratedTypeAnnotation('C c3').node, never, hard: true));
  }

  test_postDominators_forInStatement_unconditional() async {
    await analyze('''
class C {
  void m() {}
}
void test(List<C> l, C c1, C c2) {
  for (C c3 in l) {
    c1.m();
    c3.m();
  }

  c2.m();
}
''');

    //TODO(mfairhurst): enable this check
    //assertNullCheck(checkExpression('l/*check*/'),
    //    assertEdge(decoratedTypeAnnotation('List<C> l').node, never, hard: true));
    assertNullCheck(checkExpression('c1.m'),
        assertEdge(decoratedTypeAnnotation('C c1').node, never, hard: false));
    assertNullCheck(checkExpression('c2.m'),
        assertEdge(decoratedTypeAnnotation('C c2').node, never, hard: true));
    assertNullCheck(checkExpression('c3.m'),
        assertEdge(decoratedTypeAnnotation('C c3').node, never, hard: false));
  }

  test_postDominators_forStatement_unconditional() async {
    await analyze('''

class C {
  void m() {}
}
void test(bool b1, C c1, C c2, C c3) {
  for (bool b2 = b1, b3 = b1; b1/*check*/ & b2/*check*/; c3.m()) {
    c1.m();
    assert(b3 != null);
  }

  c2.m();
}
''');

    //TODO(mfairhurst): enable this check
    assertNullCheck(checkExpression('b1/*check*/'),
        assertEdge(decoratedTypeAnnotation('bool b1').node, never, hard: true));
    //assertNullCheck(checkExpression('b2/*check*/'),
    //    assertEdge(decoratedTypeAnnotation('bool b2').node, never, hard: true));
    //assertEdge(decoratedTypeAnnotation('b3 =').node, never, hard: false);
    assertNullCheck(checkExpression('c1.m'),
        assertEdge(decoratedTypeAnnotation('C c1').node, never, hard: false));
    assertNullCheck(checkExpression('c2.m'),
        assertEdge(decoratedTypeAnnotation('C c2').node, never, hard: true));
    assertNullCheck(checkExpression('c3.m'),
        assertEdge(decoratedTypeAnnotation('C c3').node, never, hard: false));
  }

  test_postDominators_ifStatement_conditional() async {
    await analyze('''
class C {
  void m() {}
}
void test(bool b, C c1, C c2) {
  if (b/*check*/) {
    C c3 = C();
    C c4 = C();
    c1.m();
    c3.m();

    // Divergence breaks post-dominance.
    return;
    c4.m();

  }
  c2.m();
}
''');

    assertNullCheck(checkExpression('b/*check*/'),
        assertEdge(decoratedTypeAnnotation('bool b').node, never, hard: true));
    assertNullCheck(checkExpression('c1.m'),
        assertEdge(decoratedTypeAnnotation('C c1').node, never, hard: false));
    assertNullCheck(checkExpression('c2.m'),
        assertEdge(decoratedTypeAnnotation('C c2').node, never, hard: false));
    assertNullCheck(checkExpression('c3.m'),
        assertEdge(decoratedTypeAnnotation('C c3').node, never, hard: true));
    assertNullCheck(checkExpression('c4.m'),
        assertEdge(decoratedTypeAnnotation('C c4').node, never, hard: false));
  }

  test_postDominators_ifStatement_unconditional() async {
    await analyze('''
class C {
  void m() {}
}
void test(bool b, C c1, C c2) {
  if (b/*check*/) {
    C c3 = C();
    C c4 = C();
    c1.m();
    c3.m();

    // We ignore exceptions for post-dominance.
    throw '';
    c4.m();

  }
  c2.m();
}
''');

    assertNullCheck(checkExpression('b/*check*/'),
        assertEdge(decoratedTypeAnnotation('bool b').node, never, hard: true));
    assertNullCheck(checkExpression('c1.m'),
        assertEdge(decoratedTypeAnnotation('C c1').node, never, hard: false));
    assertNullCheck(checkExpression('c2.m'),
        assertEdge(decoratedTypeAnnotation('C c2').node, never, hard: true));
    assertNullCheck(checkExpression('c3.m'),
        assertEdge(decoratedTypeAnnotation('C c3').node, never, hard: true));
    assertNullCheck(checkExpression('c4.m'),
        assertEdge(decoratedTypeAnnotation('C c4').node, never, hard: true));
  }

  test_postDominators_inReturn_local() async {
    await analyze('''
class C {
  int m() => 0;
}
int test(C c) {
  return c.m();
}
''');

    assertNullCheck(checkExpression('c.m'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_postDominators_loopReturn() async {
    await analyze('''
class C {
  void m() {}
}
void test(bool b1, C _c) {
  C c1 = _c;
  while (b1/*check*/) {
    bool b2 = b1;
    C c2 = _c;
    if (b2/*check*/) {
      return;
    }
    c2.m();
  }
  c1.m();
}
''');

    // TODO(mfairhurst): enable this check
    //assertNullCheck(checkExpression('b1/*check*/'),
    //    assertEdge(decoratedTypeAnnotation('bool b1').node, never, hard: true));
    assertNullCheck(checkExpression('b2/*check*/'),
        assertEdge(decoratedTypeAnnotation('bool b2').node, never, hard: true));
    assertNullCheck(checkExpression('c1.m'),
        assertEdge(decoratedTypeAnnotation('C c1').node, never, hard: false));
    assertNullCheck(checkExpression('c2.m'),
        assertEdge(decoratedTypeAnnotation('C c2').node, never, hard: false));
  }

  test_postDominators_reassign() async {
    await analyze('''
void test(bool b, int i1, int i2) {
  i1 = null;
  i1.toDouble();
  if (b) {
    i2 = null;
  }
  i2.toDouble();
}
''');

    assertNullCheck(checkExpression('i1.toDouble'),
        assertEdge(decoratedTypeAnnotation('int i1').node, never, hard: false));

    assertNullCheck(checkExpression('i2.toDouble'),
        assertEdge(decoratedTypeAnnotation('int i2').node, never, hard: false));
  }

  test_postDominators_shortCircuitOperators() async {
    await analyze('''
class C {
  bool m() => true;
}
void test(C c1, C c2, C c3, C c4) {
  c1.m() && c2.m();
  c3.m() || c4.m();
}
''');

    assertNullCheck(checkExpression('c1.m'),
        assertEdge(decoratedTypeAnnotation('C c1').node, never, hard: true));

    assertNullCheck(checkExpression('c3.m'),
        assertEdge(decoratedTypeAnnotation('C c3').node, never, hard: true));

    assertNullCheck(checkExpression('c2.m'),
        assertEdge(decoratedTypeAnnotation('C c2').node, never, hard: false));

    assertNullCheck(checkExpression('c4.m'),
        assertEdge(decoratedTypeAnnotation('C c4').node, never, hard: false));
  }

  @failingTest
  test_postDominators_subFunction() async {
    await analyze('''
class C {
  void m() {}
}
void test() {
  (C c) {
    c.m();
  };
}
''');

    assertNullCheck(checkExpression('c.m'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  @failingTest
  test_postDominators_subFunction_ifStatement_conditional() async {
    // Failing because function expressions aren't implemented
    await analyze('''
class C {
  void m() {}
}
void test() {
  (bool b, C c) {
    if (b/*check*/) {
      return;
    }
    c.m();
  };
}
''');

    assertNullCheck(checkExpression('b/*check*/'),
        assertEdge(decoratedTypeAnnotation('bool b').node, never, hard: false));
    assertNullCheck(checkExpression('c.m'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: false));
  }

  @failingTest
  test_postDominators_subFunction_ifStatement_unconditional() async {
    // Failing because function expressions aren't implemented
    await analyze('''
class C {
  void m() {}
}
void test() {
  (bool b, C c) {
    if (b/*check*/) {
    }
    c.m();
  };
}
''');

    assertNullCheck(checkExpression('b/*check*/'),
        assertEdge(decoratedTypeAnnotation('bool b').node, never, hard: true));
    assertNullCheck(checkExpression('c.m'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_postDominators_ternaryOperator() async {
    await analyze('''
class C {
  bool m() => true;
}
void test(C c1, C c2, C c3, C c4) {
  c1.m() ? c2.m() : c3.m();

  c4.m();
}
''');

    assertNullCheck(checkExpression('c1.m'),
        assertEdge(decoratedTypeAnnotation('C c1').node, never, hard: true));

    assertNullCheck(checkExpression('c4.m'),
        assertEdge(decoratedTypeAnnotation('C c4').node, never, hard: true));

    assertNullCheck(checkExpression('c2.m'),
        assertEdge(decoratedTypeAnnotation('C c2').node, never, hard: false));

    assertNullCheck(checkExpression('c3.m'),
        assertEdge(decoratedTypeAnnotation('C c3').node, never, hard: false));
  }

  test_postDominators_whileStatement_unconditional() async {
    await analyze('''
class C {
  void m() {}
}
void test(bool b, C c1, C c2) {
  while (b/*check*/) {
    C c3 = C();
    c1.m();
    c3.m();
  }

  c2.m();
}
''');

    //TODO(mfairhurst): enable this check
    //assertNullCheck(checkExpression('b/*check*/'),
    //    assertEdge(decoratedTypeAnnotation('bool b').node, never, hard: true));
    assertNullCheck(checkExpression('c1.m'),
        assertEdge(decoratedTypeAnnotation('C c1').node, never, hard: false));
    assertNullCheck(checkExpression('c2.m'),
        assertEdge(decoratedTypeAnnotation('C c2').node, never, hard: true));
    assertNullCheck(checkExpression('c3.m'),
        assertEdge(decoratedTypeAnnotation('C c3').node, never, hard: true));
  }

  test_postfixExpression_minusMinus() async {
    await analyze('''
int f(int i) {
  return i--;
}
''');

    var declaration = decoratedTypeAnnotation('int i').node;
    var use = checkExpression('i--');
    assertNullCheck(use, assertEdge(declaration, never, hard: true));

    var returnType = decoratedTypeAnnotation('int f').node;
    assertEdge(never, returnType, hard: false);
  }

  test_postfixExpression_plusPlus() async {
    await analyze('''
int f(int i) {
  return i++;
}
''');

    var declaration = decoratedTypeAnnotation('int i').node;
    var use = checkExpression('i++');
    assertNullCheck(use, assertEdge(declaration, never, hard: true));

    var returnType = decoratedTypeAnnotation('int f').node;
    assertEdge(never, returnType, hard: false);
  }

  test_prefixedIdentifier_field_type() async {
    await analyze('''
class C {
  bool b = true;
}
bool f(C c) => c.b;
''');
    assertEdge(decoratedTypeAnnotation('bool b').node,
        decoratedTypeAnnotation('bool f').node,
        hard: false);
  }

  test_prefixedIdentifier_getter_type() async {
    await analyze('''
class C {
  bool get b => true;
}
bool f(C c) => c.b;
''');
    assertEdge(decoratedTypeAnnotation('bool get').node,
        decoratedTypeAnnotation('bool f').node,
        hard: false);
  }

  test_prefixedIdentifier_target_check() async {
    await analyze('''
class C {
  int get x => 1;
}
void test(C c) {
  c.x;
}
''');

    assertNullCheck(checkExpression('c.x'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_prefixedIdentifier_target_demonstrates_non_null_intent() async {
    await analyze('''
class C {
  int get x => 1;
}
void test(C c) {
  c.x;
}
''');

    assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true);
  }

  test_prefixedIdentifier_tearoff() async {
    await analyze('''
abstract class C {
  int f(int i);
}
int Function(int) g(C c) => c.f;
''');
    var fType = variables.decoratedElementType(findElement.method('f'));
    var gReturnType =
        variables.decoratedElementType(findElement.function('g')).returnType;
    assertEdge(fType.returnType.node, gReturnType.returnType.node, hard: false);
    assertEdge(gReturnType.positionalParameters[0].node,
        fType.positionalParameters[0].node,
        hard: false);
  }

  test_prefixExpression_bang() async {
    await analyze('''
bool f(bool b) {
  return !b;
}
''');

    var nullable_b = decoratedTypeAnnotation('bool b').node;
    var check_b = checkExpression('b;');
    assertNullCheck(check_b, assertEdge(nullable_b, never, hard: true));

    var return_f = decoratedTypeAnnotation('bool f').node;
    assertEdge(never, return_f, hard: false);
  }

  test_prefixExpression_minus() async {
    await analyze('''
abstract class C {
  C operator-();
}
C test(C c) => -c/*check*/;
''');
    assertEdge(decoratedTypeAnnotation('C operator').node,
        decoratedTypeAnnotation('C test').node,
        hard: false);
    assertNullCheck(checkExpression('c/*check*/'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_prefixExpression_minusMinus() async {
    await analyze('''
int f(int i) {
  return --i;
}
''');

    var declaration = decoratedTypeAnnotation('int i').node;
    var use = checkExpression('i;');
    assertNullCheck(use, assertEdge(declaration, never, hard: true));

    var returnType = decoratedTypeAnnotation('int f').node;
    assertEdge(never, returnType, hard: false);
  }

  test_prefixExpression_plusPlus() async {
    await analyze('''
int f(int i) {
  return ++i;
}
''');

    var declaration = decoratedTypeAnnotation('int i').node;
    var use = checkExpression('i;');
    assertNullCheck(use, assertEdge(declaration, never, hard: true));

    var returnType = decoratedTypeAnnotation('int f').node;
    assertEdge(never, returnType, hard: false);
  }

  test_propertyAccess_return_type() async {
    await analyze('''
class C {
  bool get b => true;
}
bool f(C c) => (c).b;
''');
    assertEdge(decoratedTypeAnnotation('bool get').node,
        decoratedTypeAnnotation('bool f').node,
        hard: false);
  }

  test_propertyAccess_return_type_null_aware() async {
    await analyze('''
class C {
  bool get b => true;
}
bool f(C c) => (c?.b);
''');
    var lubNode =
        decoratedExpressionType('(c?.b)').node as NullabilityNodeForLUB;
    expect(lubNode.left, same(decoratedTypeAnnotation('C c').node));
    expect(lubNode.right, same(decoratedTypeAnnotation('bool get b').node));
    assertEdge(lubNode, decoratedTypeAnnotation('bool f').node, hard: false);
  }

  test_propertyAccess_target_check() async {
    await analyze('''
class C {
  int get x => 1;
}
void test(C c) {
  (c).x;
}
''');

    assertNullCheck(checkExpression('c).x'),
        assertEdge(decoratedTypeAnnotation('C c').node, never, hard: true));
  }

  test_redirecting_constructor_factory() async {
    await analyze('''
class C {
  factory C(int/*1*/ i, {int/*2*/ j}) = D;
}
class D implements C {
  D(int/*3*/ i, {int/*4*/ j});
}
''');
    assertEdge(decoratedTypeAnnotation('int/*1*/').node,
        decoratedTypeAnnotation('int/*3*/').node,
        hard: true);
    assertEdge(decoratedTypeAnnotation('int/*2*/').node,
        decoratedTypeAnnotation('int/*4*/').node,
        hard: true);
  }

  test_redirecting_constructor_factory_from_generic_to_generic() async {
    await analyze('''
class C<T> {
  factory C(T/*1*/ t) = D<T/*2*/>;
}
class D<U> implements C<U> {
  D(U/*3*/ u);
}
''');
    var nullable_t1 = decoratedTypeAnnotation('T/*1*/').node;
    var nullable_t2 = decoratedTypeAnnotation('T/*2*/').node;
    var nullable_u3 = decoratedTypeAnnotation('U/*3*/').node;
    var nullable_t2_or_nullable_u3 = graph
        .getDownstreamEdges(nullable_t1)
        .single
        .destinationNode as NullabilityNodeForSubstitution;
    expect(nullable_t2_or_nullable_u3.innerNode, same(nullable_t2));
    expect(nullable_t2_or_nullable_u3.outerNode, same(nullable_u3));
    assertEdge(nullable_t1, nullable_t2_or_nullable_u3, hard: true);
  }

  test_redirecting_constructor_factory_to_generic() async {
    await analyze('''
class C {
  factory C(int/*1*/ i) = D<int/*2*/>;
}
class D<T> implements C {
  D(T/*3*/ i);
}
''');
    var nullable_i1 = decoratedTypeAnnotation('int/*1*/').node;
    var nullable_i2 = decoratedTypeAnnotation('int/*2*/').node;
    var nullable_t3 = decoratedTypeAnnotation('T/*3*/').node;
    var nullable_i2_or_nullable_t3 = graph
        .getDownstreamEdges(nullable_i1)
        .single
        .destinationNode as NullabilityNodeForSubstitution;
    expect(nullable_i2_or_nullable_t3.innerNode, same(nullable_i2));
    expect(nullable_i2_or_nullable_t3.outerNode, same(nullable_t3));
    assertEdge(nullable_i1, nullable_i2_or_nullable_t3, hard: true);
  }

  test_redirecting_constructor_ordinary() async {
    await analyze('''
class C {
  C(int/*1*/ i, int/*2*/ j) : this.named(j, i);
  C.named(int/*3*/ j, int/*4*/ i);
}
''');
    assertEdge(decoratedTypeAnnotation('int/*1*/').node,
        decoratedTypeAnnotation('int/*4*/').node,
        hard: true);
    assertEdge(decoratedTypeAnnotation('int/*2*/').node,
        decoratedTypeAnnotation('int/*3*/').node,
        hard: true);
  }

  test_redirecting_constructor_ordinary_to_unnamed() async {
    await analyze('''
class C {
  C.named(int/*1*/ i, int/*2*/ j) : this(j, i);
  C(int/*3*/ j, int/*4*/ i);
}
''');
    assertEdge(decoratedTypeAnnotation('int/*1*/').node,
        decoratedTypeAnnotation('int/*4*/').node,
        hard: true);
    assertEdge(decoratedTypeAnnotation('int/*2*/').node,
        decoratedTypeAnnotation('int/*3*/').node,
        hard: true);
  }

  test_return_from_async_future() async {
    await analyze('''
Future<int> f() async {
  return g();
}
int g() => 1;
''');
    // No assertions; just checking that it doesn't crash.
  }

  test_return_from_async_futureOr() async {
    await analyze('''
import 'dart:async';
FutureOr<int> f() async {
  return g();
}
int g() => 1;
''');
    // No assertions; just checking that it doesn't crash.
  }

  test_return_function_type_simple() async {
    await analyze('''
int/*1*/ Function() f(int/*2*/ Function() x) => x;
''');
    var int1 = decoratedTypeAnnotation('int/*1*/');
    var int2 = decoratedTypeAnnotation('int/*2*/');
    assertEdge(int2.node, int1.node, hard: false);
  }

  test_return_implicit_null() async {
    verifyNoTestUnitErrors = false;
    await analyze('''
int f() {
  return;
}
''');

    assertEdge(always, decoratedTypeAnnotation('int').node, hard: false);
  }

  test_return_null() async {
    await analyze('''
int f() {
  return null;
}
''');

    assertNullCheck(checkExpression('null'),
        assertEdge(always, decoratedTypeAnnotation('int').node, hard: false));
  }

  test_return_null_generic() async {
    await analyze('''
class C<T> {
  T f() {
    return null;
  }
}
''');
    var tNode = decoratedTypeAnnotation('T f').node;
    assertEdge(always, tNode, hard: false);
    assertNullCheck(
        checkExpression('null'), assertEdge(always, tNode, hard: false));
  }

  @failingTest
  test_setOrMapLiteral_map_noTypeArgument_noNullableKeysAndValues() async {
    // Failing because we're not yet handling collection literals without a
    // type argument.
    await analyze('''
Map<String, int> f() {
  return {'a' : 1, 'b' : 2};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Map').node);
    // TODO(brianwilkerson) Add an assertion that there is an edge from the set
    //  literal's fake type argument to the return type's type argument.
  }

  @failingTest
  test_setOrMapLiteral_map_noTypeArgument_nullableKey() async {
    // Failing because we're not yet handling collection literals without a
    // type argument.
    await analyze('''
Map<String, int> f() {
  return {'a' : 1, null : 2, 'c' : 3};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Map').node);
    assertEdge(always, decoratedTypeAnnotation('String').node, hard: false);
    assertNoUpstreamNullability(decoratedTypeAnnotation('int').node);
  }

  @failingTest
  test_setOrMapLiteral_map_noTypeArgument_nullableKeyAndValue() async {
    // Failing because we're not yet handling collection literals without a
    // type argument.
    await analyze('''
Map<String, int> f() {
  return {'a' : 1, null : null, 'c' : 3};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Map').node);
    assertEdge(always, decoratedTypeAnnotation('String').node, hard: false);
    assertEdge(always, decoratedTypeAnnotation('int').node, hard: false);
  }

  @failingTest
  test_setOrMapLiteral_map_noTypeArgument_nullableValue() async {
    // Failing because we're not yet handling collection literals without a
    // type argument.
    await analyze('''
Map<String, int> f() {
  return {'a' : 1, 'b' : null, 'c' : 3};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Map').node);
    assertNoUpstreamNullability(decoratedTypeAnnotation('String').node);
    assertEdge(always, decoratedTypeAnnotation('int').node, hard: false);
  }

  test_setOrMapLiteral_map_typeArguments_noNullableKeysAndValues() async {
    await analyze('''
Map<String, int> f() {
  return <String, int>{'a' : 1, 'b' : 2};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Map').node);

    var keyForLiteral = decoratedTypeAnnotation('String, int>{').node;
    var keyForReturnType = decoratedTypeAnnotation('String, int> ').node;
    assertNoUpstreamNullability(keyForLiteral);
    assertEdge(keyForLiteral, keyForReturnType, hard: false);

    var valueForLiteral = decoratedTypeAnnotation('int>{').node;
    var valueForReturnType = decoratedTypeAnnotation('int> ').node;
    assertNoUpstreamNullability(valueForLiteral);
    assertEdge(valueForLiteral, valueForReturnType, hard: false);
  }

  test_setOrMapLiteral_map_typeArguments_nullableKey() async {
    await analyze('''
Map<String, int> f() {
  return <String, int>{'a' : 1, null : 2, 'c' : 3};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Map').node);
    assertEdge(always, decoratedTypeAnnotation('String, int>{').node,
        hard: false);
    assertNoUpstreamNullability(decoratedTypeAnnotation('int>{').node);
  }

  test_setOrMapLiteral_map_typeArguments_nullableKeyAndValue() async {
    await analyze('''
Map<String, int> f() {
  return <String, int>{'a' : 1, null : null, 'c' : 3};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Map').node);
    assertEdge(always, decoratedTypeAnnotation('String, int>{').node,
        hard: false);
    assertEdge(always, decoratedTypeAnnotation('int>{').node, hard: false);
  }

  test_setOrMapLiteral_map_typeArguments_nullableValue() async {
    await analyze('''
Map<String, int> f() {
  return <String, int>{'a' : 1, 'b' : null, 'c' : 3};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Map').node);
    assertNoUpstreamNullability(decoratedTypeAnnotation('String, int>{').node);
    assertEdge(always, decoratedTypeAnnotation('int>{').node, hard: false);
  }

  @failingTest
  test_setOrMapLiteral_set_noTypeArgument_noNullableElements() async {
    // Failing because we're not yet handling collection literals without a
    // type argument.
    await analyze('''
Set<String> f() {
  return {'a', 'b'};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Set').node);
    // TODO(brianwilkerson) Add an assertion that there is an edge from the set
    //  literal's fake type argument to the return type's type argument.
  }

  @failingTest
  test_setOrMapLiteral_set_noTypeArgument_nullableElement() async {
    // Failing because we're not yet handling collection literals without a
    // type argument.
    await analyze('''
Set<String> f() {
  return {'a', null, 'c'};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Set').node);
    assertEdge(always, decoratedTypeAnnotation('String').node, hard: false);
  }

  test_setOrMapLiteral_set_typeArgument_noNullableElements() async {
    await analyze('''
Set<String> f() {
  return <String>{'a', 'b'};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Set').node);
    var typeArgForLiteral = decoratedTypeAnnotation('String>{').node;
    var typeArgForReturnType = decoratedTypeAnnotation('String> ').node;
    assertNoUpstreamNullability(typeArgForLiteral);
    assertEdge(typeArgForLiteral, typeArgForReturnType, hard: false);
  }

  test_setOrMapLiteral_set_typeArgument_nullableElement() async {
    await analyze('''
Set<String> f() {
  return <String>{'a', null, 'c'};
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Set').node);
    assertEdge(always, decoratedTypeAnnotation('String>{').node, hard: false);
  }

  test_simpleIdentifier_function() async {
    await analyze('''
int f() => null;
main() {
  int Function() g = f;
}
''');

    assertEdge(decoratedTypeAnnotation('int f').node,
        decoratedTypeAnnotation('int Function').node,
        hard: false);
  }

  test_simpleIdentifier_local() async {
    await analyze('''
main() {
  int i = 0;
  int j = i;
}
''');

    assertEdge(decoratedTypeAnnotation('int i').node,
        decoratedTypeAnnotation('int j').node,
        hard: true);
  }

  test_simpleIdentifier_tearoff_function() async {
    await analyze('''
int f(int i) => 0;
int Function(int) g() => f;
''');
    var fType = variables.decoratedElementType(findElement.function('f'));
    var gReturnType =
        variables.decoratedElementType(findElement.function('g')).returnType;
    assertEdge(fType.returnType.node, gReturnType.returnType.node, hard: false);
    assertEdge(gReturnType.positionalParameters[0].node,
        fType.positionalParameters[0].node,
        hard: false);
  }

  test_simpleIdentifier_tearoff_method() async {
    await analyze('''
abstract class C {
  int f(int i);
  int Function(int) g() => f;
}
''');
    var fType = variables.decoratedElementType(findElement.method('f'));
    var gReturnType =
        variables.decoratedElementType(findElement.method('g')).returnType;
    assertEdge(fType.returnType.node, gReturnType.returnType.node, hard: false);
    assertEdge(gReturnType.positionalParameters[0].node,
        fType.positionalParameters[0].node,
        hard: false);
  }

  test_skipDirectives() async {
    await analyze('''
import "dart:core" as one;
main() {}
''');
    // No test expectations.
    // Just verifying that the test passes
  }

  test_soft_edge_for_non_variable_reference() async {
    // Edges originating in things other than variable references should be
    // soft.
    await analyze('''
int f() => null;
''');
    assertEdge(always, decoratedTypeAnnotation('int').node, hard: false);
  }

  test_stringLiteral() async {
    // TODO(paulberry): also test string interpolations
    await analyze('''
String f() {
  return 'x';
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('String').node);
  }

  test_superExpression() async {
    await analyze('''
class C {
  C f() => super;
}
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('C f').node);
  }

  test_symbolLiteral() async {
    await analyze('''
Symbol f() {
  return #symbol;
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Symbol').node);
  }

  test_thisExpression() async {
    await analyze('''
class C {
  C f() => this;
}
''');

    assertNoUpstreamNullability(decoratedTypeAnnotation('C f').node);
  }

  test_throwExpression() async {
    await analyze('''
int f() {
  return throw null;
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('int').node);
  }

  test_topLevelSetter() async {
    await analyze('''
void set x(int value) {}
main() { x = 1; }
''');
    var setXType = decoratedTypeAnnotation('int value');
    assertEdge(never, setXType.node, hard: false);
  }

  test_topLevelSetter_nullable() async {
    await analyze('''
void set x(int value) {}
main() { x = null; }
''');
    var setXType = decoratedTypeAnnotation('int value');
    assertEdge(always, setXType.node, hard: false);
  }

  test_topLevelVar_reference() async {
    await analyze('''
double pi = 3.1415;
double get myPi => pi;
''');
    var piType = decoratedTypeAnnotation('double pi');
    var myPiType = decoratedTypeAnnotation('double get');
    assertEdge(piType.node, myPiType.node, hard: false);
  }

  test_topLevelVar_reference_differentPackage() async {
    addPackageFile('pkgPi', 'piConst.dart', '''
double pi = 3.1415;
''');
    await analyze('''
import "package:pkgPi/piConst.dart";
double get myPi => pi;
''');
    var myPiType = decoratedTypeAnnotation('double get');
    assertEdge(never, myPiType.node, hard: false);
  }

  test_topLevelVariable_type_inferred() async {
    await analyze('''
int f() => 1;
var x = f();
''');
    var xType =
        variables.decoratedElementType(findNode.simple('x').staticElement);
    assertUnion(xType.node, decoratedTypeAnnotation('int').node);
  }

  test_type_argument_explicit_bound() async {
    await analyze('''
class C<T extends Object> {}
void f(C<int> c) {}
''');
    assertEdge(decoratedTypeAnnotation('int>').node,
        decoratedTypeAnnotation('Object>').node,
        hard: true);
  }

  test_type_parameterized_migrated_bound_class() async {
    await analyze('''
import 'dart:math';
void f(Point<int> x) {}
''');
    var pointClass =
        findNode.typeName('Point').name.staticElement as ClassElement;
    var pointBound =
        variables.decoratedElementType(pointClass.typeParameters[0]);
    expect(pointBound.type.toString(), 'num');
    assertEdge(decoratedTypeAnnotation('int>').node, pointBound.node,
        hard: true);
  }

  test_type_parameterized_migrated_bound_dynamic() async {
    await analyze('''
void f(List<int> x) {}
''');
    var listClass = typeProvider.listType.element;
    var listBound = variables.decoratedElementType(listClass.typeParameters[0]);
    expect(listBound.type.toString(), 'dynamic');
    assertEdge(decoratedTypeAnnotation('int>').node, listBound.node,
        hard: true);
  }

  test_typeName() async {
    await analyze('''
Type f() {
  return int;
}
''');
    assertNoUpstreamNullability(decoratedTypeAnnotation('Type').node);
  }

  test_typeName_union_with_bound() async {
    await analyze('''
class C<T extends Object> {}
void f(C c) {}
''');
    var cType = decoratedTypeAnnotation('C c');
    var cBound = decoratedTypeAnnotation('Object');
    assertUnion(cType.typeArguments[0].node, cBound.node);
  }

  test_typeName_union_with_bound_function_type() async {
    await analyze('''
class C<T extends int Function()> {}
void f(C c) {}
''');
    var cType = decoratedTypeAnnotation('C c');
    var cBound = decoratedGenericFunctionTypeAnnotation('int Function()');
    assertUnion(cType.typeArguments[0].node, cBound.node);
    assertUnion(cType.typeArguments[0].returnType.node, cBound.returnType.node);
  }

  test_typeName_union_with_bounds() async {
    await analyze('''
class C<T extends Object, U extends Object> {}
void f(C c) {}
''');
    var cType = decoratedTypeAnnotation('C c');
    var tBound = decoratedTypeAnnotation('Object,');
    var uBound = decoratedTypeAnnotation('Object>');
    assertUnion(cType.typeArguments[0].node, tBound.node);
    assertUnion(cType.typeArguments[1].node, uBound.node);
  }

  test_variableDeclaration() async {
    await analyze('''
void f(int i) {
  int j = i;
}
''');
    assertEdge(decoratedTypeAnnotation('int i').node,
        decoratedTypeAnnotation('int j').node,
        hard: true);
  }
}

class _DecoratedClassHierarchyForTesting implements DecoratedClassHierarchy {
  AssignmentCheckerTest assignmentCheckerTest;

  @override
  DecoratedType asInstanceOf(DecoratedType type, ClassElement superclass) {
    var class_ = (type.type as InterfaceType).element;
    if (class_ == superclass) return type;
    if (superclass.name == 'Object') {
      return DecoratedType(superclass.type, type.node);
    }
    if (class_.name == 'MyListOfList' && superclass.name == 'List') {
      return assignmentCheckerTest._myListOfListSupertype
          .substitute({class_.typeParameters[0]: type.typeArguments[0]});
    }
    throw UnimplementedError(
        'TODO(paulberry): asInstanceOf($type, $superclass)');
  }

  @override
  DecoratedType getDecoratedSupertype(
      ClassElement class_, ClassElement superclass) {
    throw UnimplementedError('TODO(paulberry)');
  }
}

class _TestEdgeOrigin extends EdgeOrigin {
  const _TestEdgeOrigin();
}

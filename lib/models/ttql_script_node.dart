import 'package:ttql/models/ttql_ast_node.dart';
import 'package:ttql/models/ttql_expression.dart';
import 'package:ttql/models/ttql_join_node.dart';
import 'package:ttql/models/ttql_order_by_node.dart';
import 'package:ttql/models/ttql_projection_item.dart';
import 'package:ttql/models/ttql_query_invocation_node.dart';

/// Root AST node representing a compiled TTQL analytical script.
class TtqlScriptNode extends TtqlAstNode {
  final Map<String, dynamic> declaredConstants;
  final Map<String, String> connectionAliases;
  final List<TtqlQueryInvocationNode> rootInvocations;
  final List<TtqlJoinNode> joins;
  final List<TtqlOrderByNode> orderBys;
  final int? limit;
  final int? offset;
  final List<String> groupByColumns;
  final TtqlExpression? havingPredicate;
  final List<TtqlProjectionItem> projections;

  factory TtqlScriptNode({
    required Map<String, dynamic> declaredConstants,
    Map<String, String> connectionAliases = const {},
    required List<TtqlQueryInvocationNode> rootInvocations,
    required List<TtqlJoinNode> joins,
    List<TtqlOrderByNode> orderBys = const [],
    TtqlOrderByNode? orderBy,
    int? limit,
    int? offset,
    List<String> groupByColumns = const [],
    TtqlExpression? havingPredicate,
    List<TtqlProjectionItem> projections = const [],
  }) {
    final effectiveOrderBys = orderBys.isNotEmpty
        ? orderBys
        : (orderBy != null ? [orderBy] : const <TtqlOrderByNode>[]);
    return TtqlScriptNode._(
      declaredConstants: declaredConstants,
      connectionAliases: connectionAliases,
      rootInvocations: rootInvocations,
      joins: joins,
      orderBys: effectiveOrderBys,
      limit: limit,
      offset: offset,
      groupByColumns: groupByColumns,
      havingPredicate: havingPredicate,
      projections: projections,
    );
  }

  const TtqlScriptNode._({
    required this.declaredConstants,
    this.connectionAliases = const {},
    required this.rootInvocations,
    required this.joins,
    this.orderBys = const [],
    this.limit,
    this.offset,
    this.groupByColumns = const [],
    this.havingPredicate,
    this.projections = const [],
  });

  TtqlOrderByNode? get orderBy => orderBys.isNotEmpty ? orderBys.first : null;
  List<TtqlQueryInvocationNode> get directQueries => rootInvocations;
  Map<String, dynamic> get constantValues => declaredConstants;

  @override
  Map<String, dynamic> toJson() {
    return {
      'declaredConstants': declaredConstants,
      'connectionAliases': connectionAliases,
      'rootInvocations': rootInvocations.map((i) => i.toJson()).toList(),
      'joins': joins.map((j) => j.toJson()).toList(),
      if (orderBys.isNotEmpty) 'orderBys': orderBys.map((o) => o.toJson()).toList(),
      if (orderBy != null) 'orderBy': orderBy!.toJson(),
      if (limit != null) 'limit': limit,
      if (offset != null) 'offset': offset,
      if (groupByColumns.isNotEmpty) 'groupByColumns': groupByColumns,
      if (havingPredicate != null) 'havingPredicate': havingPredicate!.toJson(),
      if (projections.isNotEmpty) 'projections': projections.map((p) => p.toJson()).toList(),
    };
  }
}

import 'package:ttql/models/ttql_ast_node.dart';
import 'package:ttql/models/ttql_async_run_node.dart';
import 'package:ttql/models/ttql_join_node.dart';
import 'package:ttql/models/ttql_order_by_node.dart';
import 'package:ttql/models/ttql_query_invocation_node.dart';

/// Root AST node representing a compiled TTQL analytical script.
class TtqlScriptNode extends TtqlAstNode {
  final Map<String, dynamic> declaredConstants;
  final Map<String, String> connectionAliases;
  final List<TtqlQueryInvocationNode> rootInvocations;
  final List<TtqlJoinNode> joins;
  final TtqlOrderByNode? orderBy;
  final int? limit;

  const TtqlScriptNode({
    required this.declaredConstants,
    this.connectionAliases = const {},
    required this.rootInvocations,
    required this.joins,
    this.orderBy,
    this.limit,
  });

  List<TtqlQueryInvocationNode> get directQueries => rootInvocations;
  TtqlScriptNode get selectNode => this;

  Map<String, dynamic> get constantValues => declaredConstants;
  TtqlAsyncRunNode? get asyncRun => rootInvocations.isNotEmpty
      ? TtqlAsyncRunNode(invocations: rootInvocations)
      : null;

  @override
  Map<String, dynamic> toJson() {
    return {
      'declaredConstants': declaredConstants,
      'connectionAliases': connectionAliases,
      'rootInvocations': rootInvocations.map((i) => i.toJson()).toList(),
      'joins': joins.map((j) => j.toJson()).toList(),
      if (orderBy != null) 'orderBy': orderBy!.toJson(),
      if (limit != null) 'limit': limit,
    };
  }
}

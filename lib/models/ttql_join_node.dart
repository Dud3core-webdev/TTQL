import 'package:ttql/models/ttql_ast_node.dart';
import 'package:ttql/models/ttql_query_invocation_node.dart';

/// AST Node representing relational join closure `.innerJoin((alias) => { ... })`.
class TtqlJoinNode extends TtqlAstNode {
  final String joinType; // 'INNER' | 'LEFT' | 'RIGHT' | 'FULL_OUTER'
  final String parentEntityAlias;
  final TtqlQueryInvocationNode queryInvocation;

  const TtqlJoinNode({
    required this.joinType,
    required this.parentEntityAlias,
    required this.queryInvocation,
  });

  TtqlQueryInvocationNode get targetInvocation => queryInvocation;

  @override
  Map<String, dynamic> toJson() {
    return {
      'joinType': joinType,
      'parentEntityAlias': parentEntityAlias,
      'queryInvocation': queryInvocation.toJson(),
    };
  }
}

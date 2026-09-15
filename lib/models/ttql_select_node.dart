import 'package:ttql/models/ttql_ast_node.dart';
import 'package:ttql/models/ttql_async_run_node.dart';
import 'package:ttql/models/ttql_query_invocation_node.dart';

/// AST Node representing outer `select(() => { ... })` wrapper.
class TtqlSelectNode extends TtqlAstNode {
  final List<TtqlQueryInvocationNode> queryInvocations;

  const TtqlSelectNode({
    required this.queryInvocations,
  });

  TtqlAsyncRunNode? get asyncRun => queryInvocations.isNotEmpty
      ? TtqlAsyncRunNode(invocations: queryInvocations)
      : null;

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'select',
      'queryInvocations': queryInvocations.map((q) => q.toJson()).toList(),
    };
  }
}

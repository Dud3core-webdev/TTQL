import 'package:ttql/models/ttql_ast_node.dart';

/// Base abstract node for expressions inside `where((...) => ...)` filters.
abstract class TtqlExpression extends TtqlAstNode {
  const TtqlExpression();
}

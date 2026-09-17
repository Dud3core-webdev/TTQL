import 'package:ttql/models/ttql_ast_node.dart';

/// Base class for projected items in a TTQL query.
abstract class TtqlProjectionItem extends TtqlAstNode {
  final String? alias;
  const TtqlProjectionItem({this.alias});

  /// The output name of the column in the final result set.
  String get outputName;

  /// The underlying physical column names referenced by this projection
  /// (used for remote pushdown query projections).
  List<String> get referencedColumns;
}

/// Represents a simple or qualified column projection (`col`, `c.col`, `c.col as alias`).
class TtqlColumnProjection extends TtqlProjectionItem {
  final String columnName;
  final String? entityAlias;

  const TtqlColumnProjection({
    required this.columnName,
    this.entityAlias,
    super.alias,
  });

  @override
  String get outputName => alias ?? columnName;

  @override
  List<String> get referencedColumns => [columnName];

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'column',
      'columnName': columnName,
      if (entityAlias != null) 'entityAlias': entityAlias,
      if (alias != null) 'alias': alias,
    };
  }
}

/// Represents an aggregate function projection (`count()`, `sum(amount)`, `avg(price)`, etc.).
class TtqlAggregateProjection extends TtqlProjectionItem {
  final String functionName; // 'COUNT', 'SUM', 'AVG', 'MIN', 'MAX'
  final String? argumentColumn; // null for COUNT(*) or count()
  final String? entityAlias;

  const TtqlAggregateProjection({
    required this.functionName,
    this.argumentColumn,
    this.entityAlias,
    super.alias,
  });

  @override
  String get outputName =>
      alias ?? '${functionName.toLowerCase()}_${argumentColumn ?? "all"}';

  @override
  List<String> get referencedColumns =>
      (argumentColumn != null && argumentColumn != '*')
          ? [argumentColumn!]
          : const [];

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'aggregate',
      'functionName': functionName,
      if (argumentColumn != null) 'argumentColumn': argumentColumn,
      if (entityAlias != null) 'entityAlias': entityAlias,
      if (alias != null) 'alias': alias,
    };
  }
}

import 'package:ttql/models/ttql_ast_node.dart';

/// AST Node for sorting results `.orderBy((row) => row.col, 'DESC')`.
class TtqlOrderByNode extends TtqlAstNode {
  final String fieldName;
  final String direction; // 'ASC' | 'DESC'
  final String? entityAlias;

  const TtqlOrderByNode({
    required this.fieldName,
    String? direction,
    this.entityAlias,
    bool? isAscending,
    int line = 1,
    int column = 1,
  })  : direction = direction ?? ((isAscending == false) ? 'DESC' : 'ASC'),
        super();

  bool get isAscending => direction.toUpperCase() == 'ASC';

  @override
  Map<String, dynamic> toJson() {
    return {
      'fieldName': fieldName,
      'direction': direction,
      if (entityAlias != null) 'entityAlias': entityAlias,
    };
  }
}

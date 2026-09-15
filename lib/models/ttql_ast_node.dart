/// Base abstract representation of a node in the TTQL Abstract Syntax Tree (AST).
abstract class TtqlAstNode {
  const TtqlAstNode();
  Map<String, dynamic> toJson();
}

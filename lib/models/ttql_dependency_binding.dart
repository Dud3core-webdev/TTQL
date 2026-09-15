/// Represents a foreign key dependency injected from an upstream stage into a downstream stage query.
class TtqlDependencyBinding {
  final String sourceStagingTable;
  final String sourceColumn;
  final String targetFilterField;

  const TtqlDependencyBinding({
    required this.sourceStagingTable,
    required this.sourceColumn,
    required this.targetFilterField,
  });

  Map<String, dynamic> toJson() {
    return {
      'sourceStagingTable': sourceStagingTable,
      'sourceColumn': sourceColumn,
      'targetFilterField': targetFilterField,
    };
  }
}

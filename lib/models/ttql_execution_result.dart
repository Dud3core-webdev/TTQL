/// Normalized analytical result returned by the TTQL engine.
class TtqlExecutionResult {
  final List<String> columns;
  final List<Map<String, dynamic>> rows;
  final int totalRowCount;
  final int executionDurationMs;
  final int stagesExecuted;
  final Map<String, int> stagingTableCounts;

  const TtqlExecutionResult({
    required this.columns,
    required this.rows,
    required this.totalRowCount,
    required this.executionDurationMs,
    required this.stagesExecuted,
    required this.stagingTableCounts,
  });

  Map<String, dynamic> toJson() {
    return {
      'columns': columns,
      'rows': rows,
      'totalRowCount': totalRowCount,
      'executionDurationMs': executionDurationMs,
      'stagesExecuted': stagesExecuted,
      'stagingTableCounts': stagingTableCounts,
    };
  }
}

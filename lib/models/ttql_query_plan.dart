import 'package:ttql/models/ttql_planned_step.dart';

/// Directed Acyclic Graph (DAG) query plan organizing steps into concurrent execution stages.
class TtqlQueryPlan {
  final Map<int, List<TtqlPlannedStep>> stages;

  const TtqlQueryPlan({
    required this.stages,
  });

  List<int> get sortedStageIndices {
    final indices = stages.keys.toList()..sort();
    return indices;
  }

  int get totalSteps {
    return stages.values.fold(0, (sum, list) => sum + list.length);
  }

  Map<String, dynamic> toJson() {
    return {
      'totalStages': stages.length,
      'totalSteps': totalSteps,
      'stages': stages.map((k, v) => MapEntry(k.toString(), v.map((s) => s.toJson()).toList())),
    };
  }
}

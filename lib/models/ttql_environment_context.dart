import 'package:ttql/models/ttql_connection_descriptor.dart';

/// Environment context holding available database connection references for a TTQL script.
class TtqlEnvironmentContext {
  final Map<String, TtqlConnectionDescriptor> connections;

  const TtqlEnvironmentContext({
    required this.connections,
  });

  TtqlConnectionDescriptor? resolveAlias(String alias) {
    if (connections.containsKey(alias)) {
      return connections[alias];
    }
    final normalized = alias.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    for (final entry in connections.entries) {
      final keyNormalized = entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      if (keyNormalized == normalized) {
        return entry.value;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'connections': connections.map((k, v) => MapEntry(k, v.toJson())),
    };
  }
}

import 'package:ttql/models/ttql_suggestion_kind.dart';

/// Code completion suggestion item for TTQL editor Intellisense.
class TtqlSuggestion {
  final String label;
  final String insertText;
  final TtqlSuggestionKind kind;
  final String? detail;

  const TtqlSuggestion({
    required this.label,
    required this.insertText,
    required this.kind,
    this.detail,
  });

  Map<String, dynamic> toJson() {
    return {
      'label': label,
      'insertText': insertText,
      'kind': kind.name,
      if (detail != null) 'detail': detail,
    };
  }
}

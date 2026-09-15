/// Code completion suggestion item for TTQL editor Intellisense.
class TtqlSuggestion {
  final String label;
  final String insertText;
  final String kind; // 'keyword' | 'connection' | 'table' | 'column' | 'operator'
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
      'kind': kind,
      if (detail != null) 'detail': detail,
    };
  }
}

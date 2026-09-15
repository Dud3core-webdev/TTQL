/// Represents line & column span of an identifier binding in a TTQL script.
class TtqlScopeRange {
  final String? name;
  final int startOffset;
  final int endOffset;

  const TtqlScopeRange({
    this.name,
    int? start,
    int? end,
    int? startOffset,
    int? endOffset,
  })  : startOffset = startOffset ?? start ?? 0,
        endOffset = endOffset ?? end ?? 0;

  int get start => startOffset;
  int get end => endOffset;

  bool containsOffset(int offset) {
    return offset >= startOffset && offset <= endOffset;
  }

  bool contains(int offset) => containsOffset(offset);

  Map<String, dynamic> toJson() {
    return {
      if (name != null) 'name': name,
      'startOffset': startOffset,
      'endOffset': endOffset,
    };
  }
}

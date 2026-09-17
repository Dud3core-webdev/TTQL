/// In-memory synchronized text buffer of active open documents in the editor.
class LspDocumentStore {
  final Map<String, String> _documents = {};

  /// Records an opened document with its full content text.
  void open(String uri, String text) {
    _documents[uri] = text;
  }

  /// Updates the content text of a document.
  void update(String uri, String text) {
    _documents[uri] = text;
  }

  /// Retrieves the current text content for [uri], or null if not open.
  String? get(String uri) => _documents[uri];

  /// Removes a closed document from active tracking.
  void close(String uri) {
    _documents.remove(uri);
  }

  /// Checks if [uri] is currently open.
  bool isOpen(String uri) => _documents.containsKey(uri);

  /// All currently open document URIs.
  Iterable<String> get openUris => _documents.keys;

  /// Clears all tracked document buffers.
  void clear() {
    _documents.clear();
  }
}

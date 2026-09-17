import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ttql/models/ttql_diagnostic.dart';
import 'package:ttql/models/ttql_environment_context.dart';
import 'package:ttql/services/cli_connection_provider.dart';
import 'package:ttql/services/lsp/json_rpc_transport.dart';
import 'package:ttql/services/lsp/lsp_document_store.dart';
import 'package:ttql/services/ttql_environment_builder.dart';
import 'package:ttql/services/ttql_linter.dart';

/// Language Server Protocol (LSP) service for TTQL.
/// Provides real-time IDE diagnostics, hover documentation, and document synchronization.
/// Delegates byte-stream framing to [JsonRpcTransport] and buffer tracking to [LspDocumentStore].
class TtqlLspServer {
  final JsonRpcTransport transport;
  final LspDocumentStore documentStore;
  final String? configPath;

  TtqlEnvironmentContext? _environmentContext;
  bool _isShutdown = false;

  TtqlLspServer({
    Stream<List<int>>? inputStream,
    IOSink? outputSink,
    this.configPath,
    LspDocumentStore? documentStore,
  })  : documentStore = documentStore ?? LspDocumentStore(),
        transport = JsonRpcTransport(
          inputStream: inputStream ?? stdin,
          outputSink: outputSink ?? stdout,
          onMessage: (_) {}, // Assigned in constructor body
        ) {
    _initTransport();
    _initEnvironment();
  }

  void _initTransport() {
    // Re-bind message callback to handle method dispatch
    transport.onMessage = _handleJsonRpcMessage;
  }

  void _initEnvironment() {
    try {
      final provider = CliConnectionProvider();
      if (configPath != null && File(configPath!).existsSync()) {
        provider.loadFromConfigFile(File(configPath!));
      } else if (File('connections.json').existsSync()) {
        provider.loadFromConfigFile(File('connections.json'));
      }
      _environmentContext = TtqlEnvironmentBuilder(connectionProvider: provider).buildContext();
    } catch (_) {
      _environmentContext = null;
    }
  }

  /// Starts the LSP server loop reading JSON-RPC frames from the transport.
  Future<void> start() => transport.listen();

  void _handleJsonRpcMessage(String rawJson) {
    try {
      final message = jsonDecode(rawJson);
      if (message is! Map<String, dynamic>) return;

      final method = message['method'] as String?;
      final id = message['id'];
      final params = message['params'] as Map<String, dynamic>? ?? {};

      if (method != null) {
        _handleMethod(method, id, params);
      }
    } catch (_) {}
  }

  void _handleMethod(String method, dynamic id, Map<String, dynamic> params) {
    if (_isShutdown && method != 'exit') return;

    switch (method) {
      case 'initialize':
        transport.sendResponse(id, {
          'capabilities': {
            'textDocumentSync': 1, // Full document synchronization
            'hoverProvider': true,
            'completionProvider': {
              'resolveProvider': false,
              'triggerCharacters': ['.', '(', ' '],
            },
          }
        });
        break;

      case 'initialized':
        break;

      case 'textDocument/didOpen':
        final textDocument = params['textDocument'] as Map<String, dynamic>? ?? {};
        final uri = textDocument['uri'] as String? ?? '';
        final text = textDocument['text'] as String? ?? '';
        documentStore.open(uri, text);
        _lintAndPublishDiagnostics(uri, text);
        break;

      case 'textDocument/didChange':
        final textDocument = params['textDocument'] as Map<String, dynamic>? ?? {};
        final uri = textDocument['uri'] as String? ?? '';
        final contentChanges = params['contentChanges'] as List<dynamic>? ?? [];
        if (contentChanges.isNotEmpty) {
          final lastChange = contentChanges.last as Map<String, dynamic>;
          final text = lastChange['text'] as String? ?? '';
          documentStore.update(uri, text);
          _lintAndPublishDiagnostics(uri, text);
        }
        break;

      case 'textDocument/didSave':
        final textDocument = params['textDocument'] as Map<String, dynamic>? ?? {};
        final uri = textDocument['uri'] as String? ?? '';
        final text = documentStore.get(uri) ?? (params['text'] as String? ?? '');
        _lintAndPublishDiagnostics(uri, text);
        break;

      case 'textDocument/didClose':
        final textDocument = params['textDocument'] as Map<String, dynamic>? ?? {};
        final uri = textDocument['uri'] as String? ?? '';
        documentStore.close(uri);
        _clearDiagnostics(uri);
        break;

      case 'textDocument/hover':
        _handleHover(id, params);
        break;

      case 'textDocument/completion':
        _handleCompletion(id, params);
        break;

      case 'shutdown':
        _isShutdown = true;
        transport.sendResponse(id, null);
        break;

      case 'exit':
        exit(0);

      default:
        if (id != null) {
          transport.sendError(id, -32601, 'Method not found: $method');
        }
        break;
    }
  }

  void _lintAndPublishDiagnostics(String uri, String source) {
    final linter = TtqlLinter(environmentContext: _environmentContext);
    final diagnostics = linter.lint(source);

    final lspDiagnostics = diagnostics.map((d) => _mapToLspDiagnostic(d)).toList();

    transport.sendNotification('textDocument/publishDiagnostics', {
      'uri': uri,
      'diagnostics': lspDiagnostics,
    });
  }

  void _clearDiagnostics(String uri) {
    transport.sendNotification('textDocument/publishDiagnostics', {
      'uri': uri,
      'diagnostics': [],
    });
  }

  Map<String, dynamic> _mapToLspDiagnostic(TtqlDiagnostic d) {
    final startLine = (d.line > 0) ? d.line - 1 : 0;
    final startCol = (d.column > 0) ? d.column - 1 : 0;

    return {
      'range': {
        'start': {'line': startLine, 'character': startCol},
        'end': {'line': startLine, 'character': startCol + 10},
      },
      'severity': d.severity == 'error' ? 1 : 2,
      'code': 'ttql_lint',
      'source': 'ttql',
      'message': d.message,
    };
  }

  void _handleHover(dynamic id, Map<String, dynamic> params) {
    transport.sendResponse(id, {
      'contents': {
        'kind': 'markdown',
        'value': '**TTQL Federated Query**\n\nRuns multi-database analytical queries across PostgreSQL, MongoDB, MySQL, SQLite, and Redis.',
      }
    });
  }

  void _handleCompletion(dynamic id, Map<String, dynamic> params) {
    final textDocument = params['textDocument'] as Map<String, dynamic>? ?? {};
    final uri = textDocument['uri'] as String? ?? '';
    final position = params['position'] as Map<String, dynamic>? ?? {};
    final lineNum = position['line'] as int? ?? 0;
    final charNum = position['character'] as int? ?? 0;

    final fullText = documentStore.get(uri) ?? '';
    final lines = fullText.split('\n');
    final currentLine = (lineNum >= 0 && lineNum < lines.length) ? lines[lineNum] : '';
    final linePrefix = charNum <= currentLine.length ? currentLine.substring(0, charNum) : currentLine;
    final trimmed = linePrefix.trim();

    final List<Map<String, dynamic>> items = [];

    // 1. Connection-scoped table completion (e.g. "pg." or "connections.pg.")
    if (trimmed.endsWith('.')) {
      final beforeDot = trimmed.substring(0, trimmed.length - 1).trim();
      final lastWord = beforeDot.split(RegExp(r'[^a-zA-Z0-9_]')).lastWhere((s) => s.isNotEmpty, orElse: () => '');

      if (_environmentContext != null) {
        final desc = _environmentContext!.resolveAlias(lastWord);
        if (desc != null) {
          for (final table in desc.tableNames) {
            items.add({
              'label': table,
              'kind': 7, // Class / Table
              'detail': 'Table in ${desc.engineType.name} (${desc.alias})',
              'insertText': table,
            });
          }
          transport.sendResponse(id, {'isIncomplete': false, 'items': items});
          return;
        }

        if (lastWord == 'connections') {
          for (final connKey in _environmentContext!.connections.keys) {
            final conn = _environmentContext!.connections[connKey]!;
            items.add({
              'label': connKey,
              'kind': 9, // Module
              'detail': '${conn.engineType.name} connection',
              'insertText': connKey,
            });
          }
          transport.sendResponse(id, {'isIncomplete': false, 'items': items});
          return;
        }
      }

      // Method chaining completion after a pipeline call
      items.addAll(_getPipelineMethodCompletions());
      transport.sendResponse(id, {'isIncomplete': false, 'items': items});
      return;
    }

    // 2. Inside from(...) or join(...) - suggest connection aliases and table refs
    if (trimmed.contains('from(') || trimmed.contains('Join(') || trimmed.contains('join(')) {
      if (_environmentContext != null) {
        for (final entry in _environmentContext!.connections.entries) {
          items.add({
            'label': entry.key,
            'kind': 9, // Module
            'detail': '${entry.value.engineType.name} connection',
            'insertText': entry.key,
          });
          for (final table in entry.value.tableNames) {
            items.add({
              'label': '${entry.key}.$table',
              'kind': 7, // Table
              'detail': '${entry.value.engineType.name} table',
              'insertText': '${entry.key}.$table',
            });
          }
        }
      }
    }

    // 3. Inside select(...), groupBy(...), where(...), having(...)
    items.addAll(_getAggregateFunctionCompletions());

    if (_environmentContext != null) {
      final seenColumns = <String>{};
      for (final desc in _environmentContext!.connections.values) {
        for (final entry in desc.tableColumns.entries) {
          final table = entry.key;
          for (final col in entry.value) {
            if (seenColumns.add(col)) {
              items.add({
                'label': col,
                'kind': 5, // Field
                'detail': 'Column ($table)',
                'insertText': col,
              });
            }
          }
        }
      }
    }

    // 4. Keywords and pipeline methods
    items.addAll(_getPipelineMethodCompletions());
    items.addAll(_getKeywordCompletions());

    transport.sendResponse(id, {'isIncomplete': false, 'items': items});
  }

  List<Map<String, dynamic>> _getPipelineMethodCompletions() {
    return [
      {'label': 'select', 'kind': 2, 'detail': 'Project columns or expressions', 'insertText': r'select($1)'},
      {'label': 'where', 'kind': 2, 'detail': 'Filter rows with predicate', 'insertText': r'where($1)'},
      {'label': 'innerJoin', 'kind': 2, 'detail': 'Inner join with another table', 'insertText': r'innerJoin($1, on: $2)'},
      {'label': 'leftJoin', 'kind': 2, 'detail': 'Left outer join with another table', 'insertText': r'leftJoin($1, on: $2)'},
      {'label': 'rightJoin', 'kind': 2, 'detail': 'Right outer join with another table', 'insertText': r'rightJoin($1, on: $2)'},
      {'label': 'fullOuterJoin', 'kind': 2, 'detail': 'Full outer join with another table', 'insertText': r'fullOuterJoin($1, on: $2)'},
      {'label': 'groupBy', 'kind': 2, 'detail': 'Group results by one or more columns', 'insertText': r'groupBy($1)'},
      {'label': 'having', 'kind': 2, 'detail': 'Filter grouped aggregate results', 'insertText': r'having($1)'},
      {'label': 'orderBy', 'kind': 2, 'detail': 'Sort result set (ASC/DESC)', 'insertText': r"orderBy($1, 'ASC')"},
      {'label': 'limit', 'kind': 2, 'detail': 'Limit number of returned rows', 'insertText': r'limit($1)'},
      {'label': 'offset', 'kind': 2, 'detail': 'Skip number of rows for pagination', 'insertText': r'offset($1)'},
      {'label': 'skip', 'kind': 2, 'detail': 'Alias for offset', 'insertText': r'skip($1)'},
      {'label': 'as', 'kind': 2, 'detail': 'Assign alias to table or column', 'insertText': r"as('$1')"},
    ];
  }

  List<Map<String, dynamic>> _getAggregateFunctionCompletions() {
    return [
      {'label': 'count()', 'kind': 3, 'detail': 'Count total rows', 'insertText': 'count()'},
      {'label': 'sum(col)', 'kind': 3, 'detail': 'Compute sum of column', 'insertText': r'sum($1)'},
      {'label': 'avg(col)', 'kind': 3, 'detail': 'Compute average of column', 'insertText': r'avg($1)'},
      {'label': 'min(col)', 'kind': 3, 'detail': 'Compute minimum of column', 'insertText': r'min($1)'},
      {'label': 'max(col)', 'kind': 3, 'detail': 'Compute maximum of column', 'insertText': r'max($1)'},
    ];
  }

  List<Map<String, dynamic>> _getKeywordCompletions() {
    return [
      {'label': 'from', 'kind': 14, 'detail': 'TTQL root query source', 'insertText': r'from($1)'},
      {'label': 'const', 'kind': 14, 'detail': 'Declare constant or connection alias', 'insertText': 'const '},
      {'label': 'environment', 'kind': 14, 'detail': 'Global environment context', 'insertText': 'environment'},
      {'label': 'ASC', 'kind': 14, 'detail': 'Ascending sort direction', 'insertText': 'ASC'},
      {'label': 'DESC', 'kind': 14, 'detail': 'Descending sort direction', 'insertText': 'DESC'},
      {'label': 'AND', 'kind': 14, 'detail': 'Logical conjunction operator', 'insertText': 'AND '},
      {'label': 'OR', 'kind': 14, 'detail': 'Logical disjunction operator', 'insertText': 'OR '},
      {'label': 'NOT', 'kind': 14, 'detail': 'Logical negation operator', 'insertText': 'NOT '},
    ];
  }
}

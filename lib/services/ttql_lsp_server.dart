import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ttql/models/ttql_diagnostic.dart';
import 'package:ttql/models/ttql_environment_context.dart';
import 'package:ttql/services/cli_connection_provider.dart';
import 'package:ttql/services/ttql_environment_builder.dart';
import 'package:ttql/services/ttql_linter.dart';

/// Zero-dependency JSON-RPC 2.0 Language Server Protocol (LSP) implementation for TTQL.
/// Provides sub-millisecond real-time diagnostics (red squiggly error underlines) to IDEs.
class TtqlLspServer {
  final Stream<List<int>> inputStream;
  final IOSink outputSink;
  final String? configPath;

  final Map<String, String> _openDocuments = {};
  TtqlEnvironmentContext? _environmentContext;
  bool _isShutdown = false;

  TtqlLspServer({
    Stream<List<int>>? inputStream,
    IOSink? outputSink,
    this.configPath,
  })  : inputStream = inputStream ?? stdin,
        outputSink = outputSink ?? stdout {
    _initEnvironment();
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

  /// Starts the LSP server loop reading JSON-RPC frames from input stream.
  Future<void> start() async {
    final List<int> buffer = [];

    await for (final chunk in inputStream) {
      buffer.addAll(chunk);
      _processBuffer(buffer);
    }
  }


  void _processBuffer(List<int> buffer) {
    while (buffer.isNotEmpty) {
      final headerEnd = _findHeaderEnd(buffer);
      if (headerEnd == -1) break;

      final headerStr = utf8.decode(buffer.sublist(0, headerEnd));
      final contentLength = _parseContentLength(headerStr);
      if (contentLength == null) {
        buffer.clear();
        break;
      }

      final bodyStart = headerEnd + 4; // Skip \r\n\r\n
      if (buffer.length < bodyStart + contentLength) {
        // Incomplete body payload, wait for next chunk
        break;
      }

      final bodyBytes = buffer.sublist(bodyStart, bodyStart + contentLength);
      buffer.removeRange(0, bodyStart + contentLength);

      final bodyStr = utf8.decode(bodyBytes);
      _handleJsonRpcMessage(bodyStr);
    }
  }

  int _findHeaderEnd(List<int> bytes) {
    for (int i = 0; i < bytes.length - 3; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  int? _parseContentLength(String header) {
    for (final line in header.split('\r\n')) {
      final parts = line.split(':');
      if (parts.length == 2 && parts[0].trim().toLowerCase() == 'content-length') {
        return int.tryParse(parts[1].trim());
      }
    }
    return null;
  }

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
        _sendResponse(id, {
          'capabilities': {
            'textDocumentSync': 1, // Full document synchronization
            'hoverProvider': true,
          }
        });
        break;

      case 'initialized':
        // Server ready signal
        break;

      case 'textDocument/didOpen':
        final textDocument = params['textDocument'] as Map<String, dynamic>? ?? {};
        final uri = textDocument['uri'] as String? ?? '';
        final text = textDocument['text'] as String? ?? '';
        _openDocuments[uri] = text;
        _lintAndPublishDiagnostics(uri, text);
        break;

      case 'textDocument/didChange':
        final textDocument = params['textDocument'] as Map<String, dynamic>? ?? {};
        final uri = textDocument['uri'] as String? ?? '';
        final contentChanges = params['contentChanges'] as List<dynamic>? ?? [];
        if (contentChanges.isNotEmpty) {
          final lastChange = contentChanges.last as Map<String, dynamic>;
          final text = lastChange['text'] as String? ?? '';
          _openDocuments[uri] = text;
          _lintAndPublishDiagnostics(uri, text);
        }
        break;

      case 'textDocument/didSave':
        final textDocument = params['textDocument'] as Map<String, dynamic>? ?? {};
        final uri = textDocument['uri'] as String? ?? '';
        final text = _openDocuments[uri] ?? (params['text'] as String? ?? '');
        _lintAndPublishDiagnostics(uri, text);
        break;

      case 'textDocument/didClose':
        final textDocument = params['textDocument'] as Map<String, dynamic>? ?? {};
        final uri = textDocument['uri'] as String? ?? '';
        _openDocuments.remove(uri);
        _clearDiagnostics(uri);
        break;

      case 'textDocument/hover':
        _handleHover(id, params);
        break;

      case 'shutdown':
        _isShutdown = true;
        _sendResponse(id, null);
        break;

      case 'exit':
        exit(0);

      default:
        if (id != null) {
          _sendError(id, -32601, 'Method not found: $method');
        }
        break;
    }
  }

  void _lintAndPublishDiagnostics(String uri, String source) {
    final linter = TtqlLinter(environmentContext: _environmentContext);
    final diagnostics = linter.lint(source);

    final lspDiagnostics = diagnostics.map((d) => _mapToLspDiagnostic(d)).toList();

    _sendNotification('textDocument/publishDiagnostics', {
      'uri': uri,
      'diagnostics': lspDiagnostics,
    });
  }

  void _clearDiagnostics(String uri) {
    _sendNotification('textDocument/publishDiagnostics', {
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
      'severity': d.severity == 'error' ? 1 : 2, // 1 = Error, 2 = Warning
      'code': 'ttql_lint',
      'source': 'ttql',
      'message': d.message,
    };
  }

  void _handleHover(dynamic id, Map<String, dynamic> params) {
    _sendResponse(id, {
      'contents': {
        'kind': 'markdown',
        'value': '**TTQL Federated Query**\n\nRuns multi-database analytical queries across PostgreSQL, MongoDB, MySQL, SQLite, and Redis.',
      }
    });
  }

  void _sendResponse(dynamic id, dynamic result) {
    final payload = {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    _sendFrame(payload);
  }

  void _sendError(dynamic id, int code, String message) {
    final payload = {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    };
    _sendFrame(payload);
  }

  void _sendNotification(String method, dynamic params) {
    final payload = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    };
    _sendFrame(payload);
  }

  void _sendFrame(Map<String, dynamic> payload) {
    final jsonStr = jsonEncode(payload);
    final bytes = utf8.encode(jsonStr);
    final header = 'Content-Length: ${bytes.length}\r\n\r\n';

    outputSink.write(header);
    outputSink.add(bytes);
  }
}

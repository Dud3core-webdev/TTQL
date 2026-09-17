import 'dart:convert';
import 'dart:io';

/// Handles low-level JSON-RPC 2.0 framing, Content-Length headers, and byte transport.
class JsonRpcTransport {
  final Stream<List<int>> inputStream;
  final IOSink outputSink;
  void Function(String rawJson)? onMessage;

  JsonRpcTransport({
    required this.inputStream,
    required this.outputSink,
    this.onMessage,
  });

  /// Listens to [inputStream] and processes incoming frames.
  Future<void> listen() async {
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
        // Incomplete payload, await next chunk
        break;
      }

      final bodyBytes = buffer.sublist(bodyStart, bodyStart + contentLength);
      buffer.removeRange(0, bodyStart + contentLength);

      final bodyStr = utf8.decode(bodyBytes);
      onMessage?.call(bodyStr);
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

  /// Sends a successful JSON-RPC 2.0 response frame.
  void sendResponse(dynamic id, dynamic result) {
    sendFrame({
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    });
  }

  /// Sends a JSON-RPC 2.0 error frame.
  void sendError(dynamic id, int code, String message) {
    sendFrame({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }

  /// Sends a JSON-RPC 2.0 notification frame.
  void sendNotification(String method, dynamic params) {
    sendFrame({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  /// Encodes [payload] into a Content-Length framed byte payload and writes to [outputSink].
  void sendFrame(Map<String, dynamic> payload) {
    final jsonStr = jsonEncode(payload);
    final bytes = utf8.encode(jsonStr);
    final header = 'Content-Length: ${bytes.length}\r\n\r\n';

    outputSink.write(header);
    outputSink.add(bytes);
  }
}

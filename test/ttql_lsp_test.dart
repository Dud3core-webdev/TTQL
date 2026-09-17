import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ttql/ttql.dart';

void main() {
  group('TtqlLspServer JSON-RPC Unit Tests', () {
    test('handles initialize method and responds with server capabilities', () async {
      final inputController = StreamController<List<int>>();
      final outputBytes = <int>[];
      final outputController = StreamController<List<int>>();

      outputController.stream.listen((chunk) => outputBytes.addAll(chunk));

      final sink = IOSink(outputController.sink);
      final server = TtqlLspServer(
        inputStream: inputController.stream,
        outputSink: sink,
      );

      final serverFuture = server.start();

      final reqPayload = jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {},
      });

      final bodyBytes = utf8.encode(reqPayload);
      final headerStr = 'Content-Length: ${bodyBytes.length}\r\n\r\n';

      inputController.add(utf8.encode(headerStr));
      inputController.add(bodyBytes);

      await Future.delayed(const Duration(milliseconds: 50));
      await inputController.close();
      await serverFuture;

      final outputStr = utf8.decode(outputBytes);
      expect(outputStr, contains('Content-Length:'));
      expect(outputStr, contains('"id":1'));
      expect(outputStr, contains('"hoverProvider":true'));
    });

    test('emits textDocument/publishDiagnostics notification on didOpen with invalid TTQL script', () async {
      final inputController = StreamController<List<int>>();
      final outputBytes = <int>[];
      final outputController = StreamController<List<int>>();

      outputController.stream.listen((chunk) => outputBytes.addAll(chunk));

      final sink = IOSink(outputController.sink);
      final server = TtqlLspServer(
        inputStream: inputController.stream,
        outputSink: sink,
      );

      final serverFuture = server.start();

      // Send didOpen with invalid syntax
      final reqPayload = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'textDocument/didOpen',
        'params': {
          'textDocument': {
            'uri': 'file:///sample.ttql',
            'text': 'DELETE FROM orders;',
          }
        },
      });

      final bodyBytes = utf8.encode(reqPayload);
      final headerStr = 'Content-Length: ${bodyBytes.length}\r\n\r\n';

      inputController.add(utf8.encode(headerStr));
      inputController.add(bodyBytes);

      await Future.delayed(const Duration(milliseconds: 50));
      await inputController.close();
      await serverFuture;

      final outputStr = utf8.decode(outputBytes);
      expect(outputStr, contains('textDocument/publishDiagnostics'));
      expect(outputStr, contains('Mutation operation'));
      expect(outputStr, contains('file:///sample.ttql'));
    });

    test('responds to textDocument/completion with pipeline methods and schema items', () async {
      final inputController = StreamController<List<int>>();
      final outputBytes = <int>[];
      final outputController = StreamController<List<int>>();

      outputController.stream.listen((chunk) => outputBytes.addAll(chunk));

      final sink = IOSink(outputController.sink);
      final server = TtqlLspServer(
        inputStream: inputController.stream,
        outputSink: sink,
      );

      final serverFuture = server.start();

      // Open document first
      final openPayload = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'textDocument/didOpen',
        'params': {
          'textDocument': {
            'uri': 'file:///query.ttql',
            'text': 'from(pg.customers).\n',
          }
        },
      });

      final openBytes = utf8.encode(openPayload);
      inputController.add(utf8.encode('Content-Length: ${openBytes.length}\r\n\r\n'));
      inputController.add(openBytes);

      // Request completion after "."
      final compPayload = jsonEncode({
        'jsonrpc': '2.0',
        'id': 42,
        'method': 'textDocument/completion',
        'params': {
          'textDocument': {'uri': 'file:///query.ttql'},
          'position': {'line': 0, 'character': 19},
        },
      });

      final compBytes = utf8.encode(compPayload);
      inputController.add(utf8.encode('Content-Length: ${compBytes.length}\r\n\r\n'));
      inputController.add(compBytes);

      await Future.delayed(const Duration(milliseconds: 50));
      await inputController.close();
      await serverFuture;

      final outputStr = utf8.decode(outputBytes);
      expect(outputStr, contains('"id":42'));
      expect(outputStr, contains('"label":"select"'));
      expect(outputStr, contains('"label":"where"'));
      expect(outputStr, contains('"label":"groupBy"'));
      expect(outputStr, contains('"label":"having"'));
    });
  });
}

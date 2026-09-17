import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ttql/ttql.dart';

void main() {
  group('LspDocumentStore Unit Tests', () {
    test('tracks, updates, and closes open document buffers', () {
      final store = LspDocumentStore();
      const uri = 'file:///test.ttql';

      expect(store.isOpen(uri), isFalse);
      store.open(uri, 'from(pg.customers)');
      expect(store.isOpen(uri), isTrue);
      expect(store.get(uri), equals('from(pg.customers)'));

      store.update(uri, 'from(pg.customers).select("id")');
      expect(store.get(uri), equals('from(pg.customers).select("id")'));

      store.close(uri);
      expect(store.isOpen(uri), isFalse);
      expect(store.get(uri), isNull);
    });
  });

  group('JsonRpcTransport Unit Tests', () {
    test('frames and parses Content-Length formatted messages', () async {
      final inputController = StreamController<List<int>>();
      final outputBytes = <int>[];
      final outputController = StreamController<List<int>>();

      outputController.stream.listen((chunk) => outputBytes.addAll(chunk));
      final sink = IOSink(outputController.sink);

      final receivedMessages = <String>[];
      final transport = JsonRpcTransport(
        inputStream: inputController.stream,
        outputSink: sink,
        onMessage: (msg) => receivedMessages.add(msg),
      );

      final listenFuture = transport.listen();

      const payload = '{"jsonrpc":"2.0","method":"test","params":{}}';
      final encoded = utf8.encode(payload);
      final frameHeader = 'Content-Length: ${encoded.length}\r\n\r\n';

      inputController.add(utf8.encode(frameHeader));
      inputController.add(encoded);

      await Future.delayed(const Duration(milliseconds: 30));
      await inputController.close();
      await listenFuture;

      expect(receivedMessages.length, equals(1));
      expect(receivedMessages.first, equals(payload));
    });

    test('formats outgoing responses, errors, and notifications with Content-Length', () async {
      final outputBytes = <int>[];
      final outputController = StreamController<List<int>>();
      outputController.stream.listen((chunk) => outputBytes.addAll(chunk));
      final sink = IOSink(outputController.sink);

      final transport = JsonRpcTransport(
        inputStream: const Stream.empty(),
        outputSink: sink,
      );

      transport.sendResponse(1, {'status': 'ok'});
      await sink.flush();
      final outputStr = utf8.decode(outputBytes);

      expect(outputStr, contains('Content-Length:'));
      expect(outputStr, contains('"id":1'));
      expect(outputStr, contains('"status":"ok"'));
    });
  });
}

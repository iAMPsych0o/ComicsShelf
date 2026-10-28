import 'dart:convert';
import 'dart:io';

import 'package:comics_panini/db/app_database.dart';
import 'package:comics_panini/models.dart';
import 'package:comics_panini/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cifrado: se descifra con el PIN correcto y falla con otro', () async {
    final salt = List.generate(16, (i) => i);
    final key = await SyncCrypto.deriveKey('123456', salt);
    final payload = await SyncCrypto.encrypt(key, {'hola': 'mundo'});
    expect(payload, isNot(contains('mundo')));
    expect(await SyncCrypto.decrypt(key, payload), {'hola': 'mundo'});

    final wrong = await SyncCrypto.deriveKey('654321', salt);
    expect(() => SyncCrypto.decrypt(wrong, payload), throwsA(anything));
  });

  test(
    'el receptor contesta directo a quien pregunta (para Android)',
    () async {
      final receiver = SyncReceiver(deviceName: 'PC de alan');
      await receiver.start();
      addTearDown(receiver.stop);

      // Un "teléfono" que no recibe broadcast: pregunta y espera respuesta directa.
      final phone = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(phone.close);
      final reply = phone
          .where((e) => e == RawSocketEvent.read)
          .map((_) => phone.receive())
          .where((dg) => dg != null)
          .first
          .timeout(const Duration(seconds: 5));
      phone.send(
        utf8.encode(jsonEncode({'app': 'ComicShelf', 'v': 1, 'q': 1})),
        InternetAddress.loopbackIPv4,
        discoveryPort,
      );
      final dg = await reply;
      final peer = SyncPeer.fromJson(
        (jsonDecode(utf8.decode(dg!.data)) as Map).cast<String, Object?>(),
        dg.address.address,
      );
      expect(peer?.name, 'PC de alan');
      expect(peer?.port, receiver.port);
    },
  );

  group('envío por la red local', () {
    late SyncReceiver receiver;
    late SyncSender sender;

    setUp(() async {
      receiver = SyncReceiver(deviceName: 'Teléfono de alan', announce: false);
      await receiver.start();
      sender = SyncSender(deviceName: 'PC de alan');
    });

    tearDown(() async {
      sender.close();
      await receiver.stop();
    });

    test('PC → Móvil: llegan las colecciones y estados del usuario', () async {
      // "PC" con datos.
      final pc = AppDatabase.inMemory();
      final u = pc.insertUser('alan', 'h', 's');
      pc.upsertComics([
        const Comic(sku: 'QBATM001', name: 'Batman #1'),
        // En el catálogo de la PC pero en ninguna colección ni estado.
        const Comic(sku: 'QEXTRA01', name: 'Cómic extra'),
      ]);
      final c = pc.createCollection(u, 'Batman');
      pc.addToCollection(u, c, ['QBATM001']);
      pc.setStatus(u, ['QBATM001'], ComicStatus.owned);

      final peer = await sender.peerAt('127.0.0.1:${receiver.port}');
      expect(peer.name, 'Teléfono de alan');
      // Como la pantalla real: al recibir, el receptor deja de escuchar de
      // inmediato. El que envía no debe ver eso como error.
      final closed = receiver.received.then((_) => receiver.stop());
      await sender.send(
        peer,
        '${receiver.pin.substring(0, 3)} ${receiver.pin.substring(3)}',
        pc.exportUserData(u, fullCatalog: true),
      );

      await closed;
      final got = await receiver.received;
      expect(got.from, 'PC de alan');

      // "Teléfono" aplica lo recibido.
      final phone = AppDatabase.inMemory();
      final me = phone.insertUser('alan', 'h', 's');
      // El teléfono ya tenía Batman #1 con otro nombre: no debe cambiar.
      phone.upsertComics([
        const Comic(sku: 'QBATM001', name: 'Batman #1 (tel)'),
      ]);
      expect(phone.countNewComics(got.data), 1);
      phone.importUserData(me, got.data);
      expect(phone.comicCount(), 2);
      expect(phone.searchComics(query: 'extra').single.sku, 'QEXTRA01');
      expect(phone.searchComics(query: '(tel)').single.sku, 'QBATM001');
      expect(phone.collections(me).single.owned, 1);
      expect(phone.statuses(me), {'QBATM001': ComicStatus.owned});
    });

    test('PIN incorrecto se rechaza y tras 5 intentos se cierra', () async {
      final peer = await sender.peerAt('127.0.0.1:${receiver.port}');
      final wrong = receiver.pin == '000000' ? '111111' : '000000';
      final result = expectLater(
        receiver.received,
        throwsA(isA<SyncException>()),
      );
      for (var i = 0; i < 5; i++) {
        await expectLater(
          sender.send(peer, wrong, {'x': 1}),
          throwsA(
            isA<SyncException>().having(
              (e) => e.message,
              'message',
              'PIN incorrecto.',
            ),
          ),
        );
      }
      await result;
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('dirección sin ComicShelf da un error claro', () async {
      expect(
        () => sender.peerAt('no es una direccion'),
        throwsA(isA<SyncException>()),
      );
      expect(() => sender.peerAt('127.0.0.1:1'), throwsA(isA<SyncException>()));
    });
  });
}

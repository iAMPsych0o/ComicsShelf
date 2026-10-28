import 'dart:io';
import 'dart:typed_data';

import 'package:comics_panini/db/app_database.dart';
import 'package:comics_panini/models.dart';
import 'package:comics_panini/services/backup_actions.dart';
import 'package:comics_panini/services/cover_cache.dart';
import 'package:comics_panini/services/pdf_export.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('comicshelf_');
    db = AppDatabase.openAt(p.join(tmp.path, 'comics_panini.db'));
    db.upsertComics([
      const Comic(
        sku: 'QA',
        name: 'A',
        imageUrl: 'https://tienda.test/media/a_1200.jpg',
      ),
      const Comic(
        sku: 'QB',
        name: 'B',
        imageUrl: 'https://tienda.test/media/b_1200.jpg',
      ),
    ]);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('portadas', () {
    final webp = Uint8List.fromList([1, 2, 3, 4]);
    late List<Uri> requested;
    late MockClient client;

    setUp(() {
      requested = [];
      client = MockClient((req) async {
        requested.add(req.url);
        return http.Response.bytes(
          webp,
          200,
          headers: {'content-type': 'image/webp'},
        );
      });
    });

    CoverCache cacheOn(List<ConnectivityResult> network) => CoverCache.at(
      db,
      Directory(p.join(tmp.path, 'portadas'))..createSync(),
      client: client,
      network: network,
    );

    test('se pide reducida a la tienda', () {
      expect(
        CoverCache.thumbUrl('https://tienda.test/media/a_1200.jpg'),
        'https://tienda.test/media/a_1200.jpg?width=300&format=webp&quality=70',
      );
    });

    test('se descarga una sola vez y luego sale del disco', () async {
      final cache = cacheOn([ConnectivityResult.wifi]);
      const url = 'https://tienda.test/media/a_1200.jpg';
      expect(await cache.load(url), webp);
      expect(await cache.load(url), webp);
      expect(requested, hasLength(1));
      expect(requested.single.queryParameters['width'], '300');
      expect(cache.usage(), (count: 1, bytes: 4));
    });

    test('con datos móviles y "solo Wi-Fi" no descarga, pero muestra las '
        'guardadas', () async {
      final wifi = cacheOn([ConnectivityResult.wifi]);
      await wifi.load('https://tienda.test/media/a_1200.jpg');

      final mobile = cacheOn([ConnectivityResult.mobile]);
      expect(mobile.wifiOnly, isTrue); // activado por defecto
      expect(mobile.canDownload, isFalse);
      expect(await mobile.load('https://tienda.test/media/a_1200.jpg'), webp);
      expect(await mobile.load('https://tienda.test/media/b_1200.jpg'), isNull);
      expect(requested, hasLength(1));

      mobile.wifiOnly = false;
      expect(await mobile.load('https://tienda.test/media/b_1200.jpg'), webp);
      expect(requested, hasLength(2));
    });

    test('sin conexión no intenta descargar', () {
      expect(cacheOn([ConnectivityResult.none]).canDownload, isFalse);
    });

    test('si la tienda no devuelve imagen no se guarda nada', () async {
      client = MockClient((_) async => http.Response('no', 404));
      final cache = cacheOn([ConnectivityResult.wifi]);
      expect(await cache.load('https://tienda.test/media/a_1200.jpg'), isNull);
      expect(cache.usage().count, 0);
    });

    test('descargar todas y borrar', () async {
      final cache = cacheOn([ConnectivityResult.ethernet]);
      final progress = <int>[];
      expect(await cache.downloadAll(onProgress: (d, _) => progress.add(d)), 2);
      expect(progress, [1, 2]);
      expect(cache.missing(), isEmpty);
      expect(await cache.downloadAll(), 0); // ya no falta nada

      await cache.clear();
      expect(cache.usage().count, 0);
      expect(cache.missing(), hasLength(2));
    });
  });

  test('respaldos automáticos: quedan los últimos 3 de cada usuario', () {
    final alan = User(id: db.insertUser('alan', 'h', 's'), username: 'alan');
    final otro = User(id: db.insertUser('otro', 'h', 's'), username: 'otro');
    final folder = Directory(p.join(tmp.path, 'respaldos_automaticos'));

    importWithAutoBackup(db, otro, db.exportUserData(otro.id));
    final created = <String>[];
    for (var i = 0; i < 5; i++) {
      created.add(
        p.basename(importWithAutoBackup(db, alan, db.exportUserData(alan.id))!),
      );
    }

    final names = folder.listSync().map((f) => p.basename(f.path)).toList();
    final mine = names.where((n) => n.startsWith('alan_')).toSet();
    expect(mine, created.skip(2).toSet()); // los 3 más nuevos
    expect(names.where((n) => n.startsWith('otro_')), hasLength(1));
  });

  test('la base se compacta como máximo una vez al mes', () {
    expect(db.compactIfDue(), isTrue);
    expect(db.compactIfDue(), isFalse);
    db.setSetting(
      'last_vacuum',
      DateTime.now().subtract(const Duration(days: 31)).toIso8601String(),
    );
    expect(db.compactIfDue(), isTrue);
  });

  test('PDF: se genera con caracteres raros y sin portadas', () async {
    expect(pdfSafe('Spider-Man – “Ñandú” 日本'), 'Spider-Man – “Ñandú” ??');
    final bytes = await buildComicsPdf(
      title: 'Wishlist',
      username: 'alan',
      items: [
        for (var n = 0; n < 120; n++)
          CollectionItem(
            comic: Comic(
              sku: 'Q$n',
              name: 'Batman ★ #$n – Ñ',
              price: 89,
              stockStatus: n.isEven ? 'IN_STOCK' : 'OUT_OF_STOCK',
            ),
            status: n % 3 == 0 ? ComicStatus.owned : ComicStatus.wishlist,
          ),
      ],
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(2000));
  });
}

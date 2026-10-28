import 'package:comics_panini/db/app_database.dart';
import 'package:comics_panini/models.dart';
import 'package:comics_panini/screens/collection_detail_screen.dart';
import 'package:comics_panini/services/auth_service.dart';
import 'package:comics_panini/services/panini_scraper.dart';
import 'package:comics_panini/widgets/comic_widgets.dart';

import 'dart:convert';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _prices = {'QBATM001': 100.0, 'QBATM002': 250.0, 'QONEP001': 1000.0};

Comic _comic(String sku, String name, {String cat = 'DC Comics', int? n}) =>
    Comic(
      price: _prices[sku],
      sku: sku,
      name: name,
      series: cat == 'DC Comics' ? 'Batman' : 'One Piece',
      seriesCode: sku.substring(0, 5),
      number: n,
      categories: [cat],
    );

void main() {
  group('Orden por número', () {
    test('ordena la serie aunque la tienda use nombres distintos', () {
      final comics = [
        const Comic(sku: 'a', name: "Batman / Superman World's Finest Vol.32"),
        const Comic(
          sku: 'b',
          name: "Batman / Superman: World's Finest #11",
          number: 11,
        ),
        const Comic(sku: 'c', name: "BATMAN / SUPERMAN: WORLD'S FINEST #01"),
        const Comic(
          sku: 'd',
          name: "Batman / Superman: World's Finest #03",
          number: 3,
        ),
        const Comic(sku: 'e', name: 'Batman / Superman: Especial'),
        const Comic(sku: 'f', name: 'One Piece N.2'),
      ]..sort(compareByNumber);
      expect(comics.map((c) => c.sku), ['c', 'f', 'd', 'b', 'a', 'e']);
      expect(
        comicNumber(const Comic(sku: 'x', name: 'Nightwing 2025')),
        isNull,
      );
    });
  });

  test('migración: conserva lo marcado en colecciones de la versión anterior', () {
    final dir = Directory.systemTemp.createTempSync('comics_mig');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/test.db';

    // Crea datos y los deja como estaban en la versión 1.
    final db = AppDatabase.openAt(path);
    final u = db.insertUser('a', 'h', 's');
    db.upsertComics([
      _comic('QBATM001', 'Batman #1'),
      _comic('QBATM002', 'Batman #2'),
    ]);
    final c1 = db.createCollection(u, 'Uno');
    final c2 = db.createCollection(u, 'Dos');
    db.addToCollection(u, c1, ['QBATM001', 'QBATM002']);
    db.addToCollection(u, c2, ['QBATM001']);
    db.close();
    final v1 = raw.sqlite3.open(path)
      ..execute('DROP TABLE comic_status')
      ..execute(
        "UPDATE collection_items SET owned = 1 WHERE collection_id = $c1 AND sku = 'QBATM001'",
      )
      ..execute('PRAGMA user_version = 1');
    v1.close();

    final migrated = AppDatabase.openAt(path);
    addTearDown(migrated.close);
    expect(migrated.ownedSkus(u), {'QBATM001'});
    final byName = {for (final c in migrated.collections(u)) c.name: c};
    expect((byName['Uno']!.owned, byName['Dos']!.owned), (1, 1));
    expect(migrated.statuses(u), {'QBATM001': ComicStatus.owned});
  });

  group('Respaldos por usuario', () {
    late AppDatabase db;
    late int psych0o, ana;

    setUp(() {
      db = AppDatabase.inMemory();
      psych0o = db.insertUser('psych0o', 'hash-secreto', 'sal');
      ana = db.insertUser('ana', 'otro-hash', 'sal2');
      db.upsertComics([
        _comic('QBATM001', 'Batman #1', n: 1),
        _comic('QBATM002', 'Batman #2', n: 2),
        _comic('QONEP001', 'One Piece N.1', cat: 'Panini Manga'),
      ]);
      final c = db.createCollection(psych0o, 'Batman');
      db.addToCollection(psych0o, c, ['QBATM001', 'QBATM002']);
      db.setStatus(psych0o, ['QBATM001'], ComicStatus.owned);
      db.setStatus(psych0o, ['QBATM002'], ComicStatus.wishlist);
      final a = db.createCollection(ana, 'Manga de Ana');
      db.addToCollection(ana, a, ['QONEP001']);
      db.setStatus(ana, ['QONEP001'], ComicStatus.owned);
    });

    test('exporta solo los datos del usuario, sin contraseñas', () {
      final data = db.exportUserData(psych0o);
      final text = jsonEncode(data);
      expect(text, isNot(contains('hash-secreto')));
      expect(text, isNot(contains('Manga de Ana')));
      expect(text, isNot(contains('QONEP001'))); // cómic que solo usa Ana
      final summary = AppDatabase.inspectUserBackup(data);
      expect(summary.username, 'psych0o');
      expect((summary.collections, summary.owned, summary.wishlist), (1, 1, 1));
    });

    test('importar solo reemplaza los datos del usuario activo', () {
      final backup = db.exportUserData(psych0o);
      // Psych0o cambia sus datos después del respaldo.
      db.setStatus(psych0o, ['QBATM002'], ComicStatus.owned);
      db.createCollection(psych0o, 'Nueva');

      db.importUserData(psych0o, backup);
      expect(db.collections(psych0o).map((c) => c.name), ['Batman']);
      expect(db.statuses(psych0o), {
        'QBATM001': ComicStatus.owned,
        'QBATM002': ComicStatus.wishlist,
      });
      // Ana no se toca.
      expect(db.collections(ana).single.name, 'Manga de Ana');
      expect(db.statuses(ana), {'QONEP001': ComicStatus.owned});
    });

    test('en un dispositivo nuevo recrea colecciones, estados y cómics', () {
      final backup = jsonDecode(
        jsonEncode(db.exportUserData(psych0o)),
      ) as Map<String, Object?>;

      final other = AppDatabase.inMemory();
      final me = other.insertUser('psych0o_tel', 'h', 's');
      other.importUserData(me, backup);

      expect(other.comicCount(), 2); // los cómics de sus colecciones/estados
      final col = other.collections(me).single;
      expect((col.name, col.total, col.owned), ('Batman', 2, 1));
      expect(
        other.itemsWithStatus(me, ComicStatus.wishlist).single.comic.name,
        'Batman #2',
      );
    });

    test('no cambia cómics que ya existen en el catálogo', () {
      final backup = db.exportUserData(psych0o);
      ((backup['comics'] as List).first as Map)['name'] = 'Nombre viejo';
      db.importUserData(psych0o, backup);
      expect(db.searchComics(query: 'Nombre viejo'), isEmpty);
    });

    test('rechaza archivos que no son respaldos', () {
      for (final bad in [
        null,
        'hola',
        {'app': 'Otra'},
        {
          'app': 'ComicShelf',
          'format': 99,
          'collections': [],
          'statuses': [],
          'comics': [],
        },
        {
          'app': 'ComicShelf',
          'format': 1,
          'collections': 'x',
          'statuses': [],
          'comics': [],
        },
      ]) {
        expect(
          () => AppDatabase.inspectUserBackup(bad),
          throwsA(isA<BackupException>()),
          reason: '$bad',
        );
      }
    });
  });

  group('Auth', () {
    test('"Recuérdame" mantiene la sesión al reabrir la app', () {
      final db = AppDatabase.inMemory();
      AuthService(db).register('psych0o', 'secreto123', remember: true);

      // Al reabrir la app (nuevo AuthService) la sesión sigue activa.
      final reopened = AuthService(db);
      expect(reopened.currentUser?.username, 'psych0o');
      expect(reopened.isRemembered, isTrue);

      // Cerrar sesión la olvida.
      reopened.logout();
      expect(AuthService(db).isLoggedIn, isFalse);

      // Sin "Recuérdame" no se guarda.
      AuthService(db).login('psych0o', 'secreto123');
      expect(AuthService(db).isLoggedIn, isFalse);

      // Se puede activar o desactivar desde la sesión.
      final auth = AuthService(db)..login('psych0o', 'secreto123');
      auth.setRemembered(true);
      expect(AuthService(db).isLoggedIn, isTrue);
      auth.setRemembered(false);
      expect(AuthService(db).isLoggedIn, isFalse);
    });

    test('registro, login y errores', () {
      final db = AppDatabase.inMemory();
      final auth = AuthService(db);
      auth.register('psych0o', 'secreto123');
      expect(auth.currentUser!.username, 'psych0o');
      auth.logout();
      expect(auth.isLoggedIn, isFalse);
      expect(
        () => auth.login('psych0o', 'mala'),
        throwsA(isA<AuthException>()),
      );
      expect(
        () => auth.register('PSYCH0O', 'otra12345'),
        throwsA(isA<AuthException>()),
      );
      auth.login('Psych0o', 'secreto123');
      expect(auth.isLoggedIn, isTrue);
    });
  });

  test('preventa: categoría Preventas o fecha de salida futura', () {
    final today = DateTime(2026, 10, 27, 15);
    expect(
      const Comic(
        sku: 'A',
        name: 'A',
        categories: ['Preventas'],
      ).isPreorder(today),
      isTrue,
    );
    expect(
      const Comic(
        sku: 'B',
        name: 'B',
        releaseDate: '2026-10-28',
      ).isPreorder(today),
      isTrue,
    );
    // Sale hoy: ya no es preventa.
    expect(
      const Comic(
        sku: 'C',
        name: 'C',
        releaseDate: '2026-10-27',
      ).isPreorder(today),
      isFalse,
    );
    expect(const Comic(sku: 'D', name: 'D').isPreorder(today), isFalse);
  });

  test('filtro de disponibilidad del catálogo', () {
    final db = AppDatabase.inMemory();
    db.upsertComics([
      const Comic(sku: 'D', name: 'Disp', stockStatus: 'IN_STOCK'),
      const Comic(sku: 'A', name: 'Agot', stockStatus: 'OUT_OF_STOCK'),
      const Comic(
        sku: 'P1',
        name: 'Prev cat',
        categories: ['DC', 'Preventas'],
        stockStatus: 'IN_STOCK',
      ),
      const Comic(
        sku: 'P2',
        name: 'Prev fecha',
        releaseDate: '2099-01-01',
        stockStatus: 'OUT_OF_STOCK',
      ),
      // "Preventas Marvel" no es la categoría "Preventas".
      const Comic(sku: 'X', name: 'Viejo', categories: ['Preventas Marvel']),
    ]);
    Set<String> skus(Availability a) =>
        db.searchComics(availability: a).map((c) => c.sku).toSet();
    expect(skus(Availability.available), {'D', 'P1'});
    expect(skus(Availability.soldOut), {'A', 'P2'});
    expect(skus(Availability.preorder), {'P1', 'P2'});
    expect(db.availabilityCounts(), {
      Availability.available: 2,
      Availability.soldOut: 2,
      Availability.preorder: 2,
    });
  });

  test('cada colección suma lo que tienes, lo comprado y lo que falta', () {
    final db = AppDatabase.inMemory();
    final u = db.insertUser('a', 'h', 's');
    final otro = db.insertUser('b', 'h', 's');
    db.upsertComics([
      const Comic(sku: 'Q1', name: 'Uno', price: 100),
      const Comic(sku: 'Q2', name: 'Dos', price: 250.5),
      const Comic(sku: 'Q3', name: 'Tres', price: 80),
      const Comic(sku: 'Q4', name: 'Sin precio'),
    ]);
    final c = db.createCollection(u, 'Serie');
    db.addToCollection(u, c, ['Q1', 'Q2', 'Q3', 'Q4']);
    db.setStatus(u, ['Q1'], ComicStatus.owned);
    db.setStatus(u, ['Q2'], ComicStatus.purchased);
    // Lo que marque otro usuario no cuenta.
    db.setStatus(otro, ['Q3'], ComicStatus.owned);

    final counts = db.collections(u).single.counts;
    expect(counts.ownedValue, 100);
    expect(counts.purchasedValue, 250.5);
    expect(counts.missingValue, 80);
    expect(counts.totalValue, 430.5);
  });

  group('Catálogo y colecciones', () {
    late AppDatabase db;
    late int u1, u2;

    setUp(() {
      db = AppDatabase.inMemory();
      u1 = db.insertUser('a', 'h', 's');
      u2 = db.insertUser('b', 'h', 's');
      db.upsertComics([
        _comic('QBATM001', 'Batman #1', n: 1),
        _comic('QBATM002', 'Batman #2', n: 2),
        _comic('QONEP001', 'One Piece N.1', cat: 'Panini Manga'),
      ]);
    });

    test('búsqueda y categorías', () {
      expect(db.comicCount(), 3);
      expect(db.searchComics(query: 'batman').length, 2);
      expect(db.searchComics(category: 'Panini Manga').single.sku, 'QONEP001');
      expect(db.catalogCategories(), {'DC Comics': 2, 'Panini Manga': 1});
      expect(db.comicsInSeries('QBATM').map((c) => c.number), [1, 2]);
    });

    test('upsert actualiza sin duplicar', () {
      db.upsertComics([_comic('QBATM001', 'Batman #1 (nuevo nombre)', n: 1)]);
      expect(db.comicCount(), 3);
      expect(db.searchComics(query: 'nuevo').single.sku, 'QBATM001');
    });

    test('colecciones por usuario y marcar los que se tienen', () {
      final c = db.createCollection(u1, 'Batman');
      expect(db.addToCollection(u1, c, ['QBATM001', 'QBATM002']), 2);
      expect(db.addToCollection(u1, c, ['QBATM001']), 0);
      db.setStatus(u1, ['QBATM002'], ComicStatus.owned);

      final col = db.collections(u1).single;
      expect((col.total, col.owned), (2, 1));
      expect(
        db.collectionItems(u1, c).where((i) => i.owned).single.comic.sku,
        'QBATM002',
      );

      // Otro usuario no ve ni modifica la colección.
      expect(db.collections(u2), isEmpty);
      expect(db.collectionItems(u2, c), isEmpty);
      db.setStatus(u2, ['QBATM001'], ComicStatus.owned);
      expect(db.collections(u1).single.owned, 1);
      expect(db.ownedSkus(u2), {'QBATM001'});

      db.removeFromCollection(u1, c, 'QBATM001');
      expect(db.collections(u1).single.total, 1);
      db.deleteCollection(u1, c);
      expect(db.collections(u1), isEmpty);
    });

    test('"lo tengo" es del usuario y se ve en todas sus colecciones', () {
      final a = db.createCollection(u1, 'Batman');
      final b = db.createCollection(u1, 'Lo mejor de DC');
      db.addToCollection(u1, a, ['QBATM001', 'QBATM002']);
      db.addToCollection(u1, b, ['QBATM001', 'QONEP001']);

      db.setStatus(u1, ['QBATM001'], ComicStatus.owned);
      final byName = {for (final c in db.collections(u1)) c.name: c};
      expect(byName['Batman']!.owned, 1);
      expect(byName['Lo mejor de DC']!.owned, 1);
      expect(
        db
            .collectionItems(u1, b)
            .firstWhere((i) => i.comic.sku == 'QBATM001')
            .owned,
        isTrue,
      );

      // Quitarlo de una colección no borra que lo tienes.
      db.removeFromCollection(u1, a, 'QBATM001');
      expect(db.ownedSkus(u1), {'QBATM001'});
      expect(db.collections(u1).firstWhere((c) => c.id == b).owned, 1);

      db.setStatus(u1, ['QBATM001'], ComicStatus.unclassified);
      expect(db.collections(u1).every((c) => c.owned == 0), isTrue);
    });

    test('cinco estados para toda la tienda', () {
      // Todo empieza sin clasificar.
      var counts = db.catalogStatusCounts(u1);
      expect(counts[ComicStatus.unclassified], 3);

      db.setStatus(u1, ['QBATM001'], ComicStatus.owned);
      db.setStatus(u1, ['QBATM002'], ComicStatus.wishlist);
      db.setStatus(u1, ['QONEP001'], ComicStatus.notInterested);
      counts = db.catalogStatusCounts(u1);
      expect(
        [for (final s in ComicStatus.values) counts[s]],
        [
          0,
          1,
          1,
          0,
          1,
        ], // sin clasificar, no me interesa, wishlist, comprado, obtenido
      );
      // Cada usuario tiene sus propios estados.
      expect(db.catalogStatusCounts(u2)[ComicStatus.unclassified], 3);

      // Filtro del catálogo por estado.
      List<String> skus(ComicStatus s) =>
          db.searchComics(userId: u1, status: s).map((c) => c.sku).toList();
      expect(skus(ComicStatus.owned), ['QBATM001']);
      expect(skus(ComicStatus.notInterested), ['QONEP001']);
      expect(skus(ComicStatus.unclassified), isEmpty);
      expect(
        db.searchComics(userId: u1, status: ComicStatus.wishlist, query: 'one'),
        isEmpty,
      );

      // Wishlist = cómics con ese estado; al comprarlo sale de la wishlist.
      expect(
        db.itemsWithStatus(u1, ComicStatus.wishlist).single.comic.sku,
        'QBATM002',
      );
      db.setStatus(u1, ['QBATM002'], ComicStatus.purchased);
      expect(db.itemsWithStatus(u1, ComicStatus.wishlist), isEmpty);

      // En colecciones: obtenido / comprado / me falta (todo lo demás).
      final c = db.createCollection(u1, 'Todo');
      db.addToCollection(u1, c, ['QBATM001', 'QBATM002', 'QONEP001']);
      final col = db.collections(u1).single;
      expect((col.owned, col.purchased, col.counts.missing), (1, 1, 1));
      final totals = db.collectionTotals(u1);
      expect((totals.total, totals.owned, totals.purchased), (3, 1, 1));
      // Valor en pesos: 100 + 250 + 1000.
      expect(
        (totals.totalValue, totals.ownedValue, totals.purchasedValue),
        (1350.0, 100.0, 250.0),
      );
      expect(totals.missingValue, 1000.0);
      expect(formatPrice(1350), '\$1,350.00 MXN');
      expect(formatPrice(1234567.5), '\$1,234,567.50 MXN');
      expect(formatPrice(89), '\$89.00 MXN');

      // El dashboard también cuenta lo marcado fuera de colecciones,
      // pero no lo que "no me interesa".
      db.upsertComics([
        _comic('QFUER001', 'Fuera #1'),
        _comic('QFUER002', 'Fuera #2'),
        _comic('QFUER003', 'Fuera #3'),
      ]);
      db.setStatus(u1, ['QFUER001'], ComicStatus.owned);
      db.setStatus(u1, ['QFUER002'], ComicStatus.wishlist);
      db.setStatus(u1, ['QFUER003'], ComicStatus.notInterested);
      final all = db.collectionTotals(u1);
      expect((all.total, all.owned, all.purchased, all.missing), (5, 2, 1, 2));

      // Volver a "sin clasificar" borra el estado en bloque.
      db.setStatus(u1, [
        'QBATM001',
        'QBATM002',
        'QONEP001',
        'QFUER001',
        'QFUER002',
        'QFUER003',
      ], ComicStatus.unclassified);
      expect(db.statuses(u1), isEmpty);
    });

    test('productos ignorados', () {
      db.setIgnored({'QONEP001': 'One Piece'}, []);
      expect(db.ignoredSkus(), {'QONEP001'});
      db.setIgnored({}, ['QONEP001']);
      expect(db.ignoredSkus(), isEmpty);
    });
  });

  group('Scraper (simulado)', () {
    Map<String, dynamic> item(String sku, {bool attrs = true}) => {
      'sku': sku,
      'name': 'Batman #${int.parse(sku.substring(5))}',
      'url_key': sku.toLowerCase(),
      'stock_status': 'IN_STOCK',
      'categories': [
        {'name': 'DC Comics'},
      ],
      'small_image': {'url': 'https://x/$sku.jpg?optimize=medium'},
      'price_range': {
        'minimum_price': {
          'final_price': {'value': 99},
        },
      },
      if (attrs)
        'custom_attributesV2': {
          'items': [
            {'code': 'collection', 'value': 'BATMAN'},
            {'code': 'product_contains', 'value': '<p>Batman #1-6</p>'},
          ],
        },
    };

    test('recupera productos que la tienda entrega como null', () async {
      final queries = <String>[];
      final client = MockClient((req) async {
        final q = jsonDecode(req.body)['query'] as String;
        queries.add(q);
        final full = q.contains('custom_attributesV2');
        return http.Response(
          jsonEncode({
            'errors': full
                ? [
                    {'message': 'Internal server error'},
                  ]
                : null,
            'data': {
              'products': {
                'total_count': 3,
                'page_info': {'total_pages': 1},
                'items': full
                    ? [item('QBATM001'), null, item('QBATM003')]
                    : [
                        item('QBATM001', attrs: false),
                        item('QBATM002', attrs: false),
                        item('QBATM003', attrs: false),
                      ],
              },
            },
          }),
          200,
        );
      });
      final result = await PaniniScraper(client: client).scrape([
        const StoreCategory(id: 516, name: 'DC Comics', productCount: 3),
      ]);
      expect(result.warning, isNull);
      expect(queries.length, 2);
      expect(queries.last.contains('custom_attributesV2'), isFalse);
      final bySku = {for (final c in result.comics) c.sku: c};
      expect(bySku.keys, unorderedEquals(['QBATM001', 'QBATM002', 'QBATM003']));
      expect(bySku['QBATM001']!.series, 'Batman');
      expect(bySku['QBATM001']!.contains, 'Batman #1-6');
      expect(bySku['QBATM001']!.imageUrl, 'https://x/QBATM001.jpg');
      // El recuperado usa el SKU para serie y número.
      expect(bySku['QBATM002']!.seriesCode, 'QBATM');
      expect(bySku['QBATM002']!.number, 2);
    });

    test(
      'si una página falla siempre, regresa lo descargado con aviso',
      () async {
        var calls = 0;
        final client = MockClient((req) async {
          calls++;
          if (calls == 1) {
            return http.Response(
              jsonEncode({
                'data': {
                  'products': {
                    'page_info': {'total_pages': 2},
                    'items': [item('QBATM001')],
                  },
                },
              }),
              200,
            );
          }
          return http.Response('error', 500);
        });
        final result = await PaniniScraper(client: client).scrape([
          const StoreCategory(id: 516, name: 'DC Comics', productCount: 2),
        ]);
        expect(result.comics.single.sku, 'QBATM001');
        expect(result.warning, contains('página 2'));
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });

  group('Scraper (en línea)', () {
    test('categorías y primera página de la tienda', () async {
      final scraper = PaniniScraper();
      final cats = await scraper.fetchCategories();
      final dc = cats.firstWhere((c) => c.name == 'DC Comics');
      expect(dc.productCount, greaterThan(100));

      var pages = 0;
      final result = await scraper.scrape(
        [dc],
        onProgress: (p, t, n) => pages = p,
        isCancelled: () => pages >= 1,
      );
      scraper.close();
      final comics = result.comics;
      expect(result.warning, isNull);
      expect(comics.length, greaterThanOrEqualTo(50));
      expect(comics.every((c) => c.categories.contains('DC Comics')), isTrue);
      final withSeries = comics.where((c) => c.seriesCode != null).length;
      expect(withSeries / comics.length, greaterThan(0.8));

      for (final c in comics.take(5)) {
        // ignore: avoid_print
        print(
          '${c.sku} | ${c.name} | ${c.series} #${c.number} | ${c.price} | ${c.contains}',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

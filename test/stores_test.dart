import 'dart:convert';

import 'package:comics_panini/db/app_database.dart';
import 'package:comics_panini/models.dart';
import 'package:comics_panini/services/currency.dart';
import 'package:comics_panini/services/panini_scraper.dart';
import 'package:comics_panini/services/stores.dart';
import 'package:comics_panini/widgets/comic_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 1 USD = 20 MXN = 1000 CLP = 5 BRL.
const _rates = {'USD': 1.0, 'MXN': 20.0, 'CLP': 1000.0, 'BRL': 5.0};

void main() {
  tearDown(() => Money.forTest());

  group('moneda', () {
    test('convierte entre monedas y formatea', () {
      final m = Money.forTest(rates: _rates);
      expect(m.convert(1000, 'CLP'), 20); // 1 USD
      expect(m.convert(10, 'BRL'), 40);
      expect(m.convert(5, 'MXN'), 5);
      expect(m.convert(5, 'ARS'), isNull); // sin tipo de cambio
      expect(Money.formatIn(12345.5, 'MXN'), r'$12,345.50 MXN');
      expect(Money.formatIn(14000, 'CLP'), r'$14,000 CLP');
      expect(Money.formatIn(47.9, 'BRL'), r'R$47.90 BRL');

      m.setDisplay('CLP');
      expect(m.convert(20, 'MXN'), 1000);
      expect(
        formatComicPrice(
          const Comic(sku: 'x', name: 'x', price: 20, currency: 'MXN'),
        ),
        r'$1,000 CLP',
      );
    });

    test('sin tipo de cambio muestra la moneda original', () {
      Money.forTest();
      const c = Comic(sku: 'cl:A', name: 'A', price: 14000, currency: 'CLP');
      expect(formatComicPrice(c), r'$14,000 CLP');
      expect(comicValue(c), 0);
    });

    test('totales con tiendas en distintas monedas', () {
      Money.forTest(rates: _rates);
      final db = AppDatabase.inMemory();
      final u = db.insertUser('a', 'h', 's');
      db.upsertComics([
        const Comic(sku: 'Q1', name: 'MX', price: 100),
        const Comic(
          sku: 'cl:Q1',
          name: 'CL',
          price: 10000,
          store: 'cl',
          currency: 'CLP',
        ),
      ]);
      final col = db.createCollection(u, 'Mixta');
      db.addToCollection(u, col, ['Q1', 'cl:Q1']);
      db.setStatus(u, ['cl:Q1'], ComicStatus.owned);
      final counts = db.collections(u).single.counts;
      expect(counts.totalValue, 300); // 100 MXN + 10,000 CLP (= 200 MXN)
      expect(counts.ownedValue, 200);
      expect(counts.missingValue, 100);

      // Filtro y conteo por tienda.
      expect(db.storeCounts(), {'mx': 1, 'cl': 1});
      expect(db.searchComics(store: 'cl').single.sku, 'cl:Q1');
      expect(
        db.searchComics(store: 'cl').single.storeUrl,
        startsWith('https://tiendapanini.cl/'),
      );
    });

    test('el tipo de cambio se descarga y se guarda', () async {
      final db = AppDatabase.inMemory();
      final m = Money.load(db);
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'result': 'success', 'rates': _rates}),
          200,
        ),
      );
      expect(await m.refreshRates(client: client), isTrue);
      // Ya fresco: no vuelve a pedirlo.
      expect(await m.refreshRates(client: client), isFalse);
      expect(Money.load(db).convert(1000, 'CLP'), 20);
    });
  });

  test('scraper de otra tienda: encabezado, prefijo de SKU y moneda', () async {
    final requests = <http.Request>[];
    final client = MockClient((req) async {
      requests.add(req);
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if ((body['query'] as String).contains('categoryList')) {
        return _utf8Response(
          jsonEncode({
            'data': {
              'categoryList': [
                {'id': 7, 'name': 'Marvel Comic ', 'product_count': 2},
                {'id': 8, 'name': 'Vacía', 'product_count': 0},
              ],
            },
          }),
          200,
        );
      }
      return _utf8Response(
        jsonEncode({
          'data': {
            'products': {
              'total_count': 1,
              'page_info': {'total_pages': 1},
              'items': [
                {
                  'sku': 'SHMMA333',
                  'name': '100% Marvel 333',
                  'url_key': '100-marvel-333',
                  'stock_status': 'IN_STOCK',
                  'special_to_date': '2099-12-18 03:00:00',
                  'categories': [
                    {'name': 'Marvel Comic '},
                  ],
                  'small_image': {'url': 'https://tiendapanini.cl/a.png?x=1'},
                  'price_range': {
                    'minimum_price': {
                      'regular_price': {'value': 20000},
                      'final_price': {'value': 14000, 'currency': 'CLP'},
                    },
                  },
                  'custom_attributesV2': {'items': []},
                },
              ],
            },
          },
        }),
        200,
      );
    });
    final scraper = PaniniScraper(client: client, store: chile);
    final cats = await scraper.fetchCategories();
    expect(cats.single.name, 'Marvel Comic');
    final result = await scraper.scrape(cats);
    final c = result.comics.single;
    expect(c.sku, 'cl:SHMMA333');
    expect(c.seriesCode, 'cl:SHMMA');
    expect(c.number, 333);
    expect(c.store, 'cl');
    expect(c.currency, 'CLP');
    expect(c.price, 14000);
    expect(c.regularPrice, 20000);
    expect(c.promoEnds, '2099-12-18');
    expect(c.discountPercent, 30);
    expect(c.categories, ['Marvel Comic']);
    expect(c.storeUrl, 'https://tiendapanini.cl/100-marvel-333');
    expect(requests.every((r) => r.headers['Store'] == 'chile'), isTrue);
    expect(mexico.skuPrefix, '');
  });

  test('promociones del carrito: lee el descuento de cada cómic', () async {
    final carts = <String, List<String>>{};
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final query = body['query'] as String;
      final vars = body['variables'] as Map<String, dynamic>;
      Map<String, dynamic> data;
      if (query.contains('createEmptyCart')) {
        data = {'createEmptyCart': 'cart${carts.length}'};
        carts['cart${carts.length}'] = [];
      } else if (query.contains('addProductsToCart')) {
        // La tienda no encuentra X9: no se agrega y la respuesta no trae
        // descuentos (por eso el carrito se lee aparte).
        final skus = [
          for (final i in vars['items'] as List) i['sku'] as String,
        ];
        carts[vars['cart']]!.addAll(skus.where((s) => s != 'X9'));
        data = {
          'addProductsToCart': {
            'user_errors': [
              if (skus.contains('X9')) {'message': 'No existe X9'},
            ],
          },
        };
      } else {
        Map<String, dynamic> item(String sku, double total, List discounts) => {
          'product': {'sku': sku},
          'prices': {
            'row_total': {'value': total},
            'discounts': discounts,
          },
        };
        data = {
          'cart': {
            'items': [
              for (final sku in carts[vars['cart']]!)
                switch (sku) {
                  'A1' => item('A1', 899, [
                    {
                      'label': '30% - Descuentos espeluznantes ',
                      'amount': {'value': 269.7},
                    },
                  ]),
                  'B2' => item('B2', 139, []),
                  _ => item(sku, 100, [
                    {
                      'label': '10% - Preventa',
                      'amount': {'value': 10},
                    },
                    {
                      'label': '10% - Descuentos espeluznantes',
                      'amount': {'value': 9},
                    },
                  ]),
                },
            ],
          },
        };
      }
      return _utf8Response(jsonEncode({'data': data}), 200);
    });
    final scraper = PaniniScraper(client: client, store: chile);
    final comics = [
      for (final s in ['A1', 'B2', 'X9', 'C3'])
        Comic(sku: 'cl:$s', name: s, store: 'cl'),
    ];
    final result = await scraper.checkCartPromos(comics);
    // Sin prefijo para la tienda; un carrito para los 3.
    expect(carts.values.single, ['A1', 'B2', 'C3']);
    // X9 sí cuenta como revisado: la tienda no lo vende, no tiene promoción.
    expect(result.checked, {'cl:A1', 'cl:B2', 'cl:X9', 'cl:C3'});
    expect(result.promos.keys, unorderedEquals(['cl:A1', 'cl:C3']));
    expect(result.promos['cl:A1']!.percent, 30);
    expect(result.promos['cl:A1']!.label, 'Descuentos espeluznantes');
    expect(result.promos['cl:C3']!.percent, 19);
    expect(result.promos['cl:C3']!.label, 'Preventa, Descuentos espeluznantes');
    expect(result.warning, isNull);
  });
}

http.Response _utf8Response(String body, int status) =>
    http.Response.bytes(utf8.encode(body), status);

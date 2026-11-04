import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'stores.dart';

class ScrapeResult {
  final List<Comic> comics;

  /// Aviso si el scraping no pudo terminar (lo descargado sigue siendo útil).
  final String? warning;

  const ScrapeResult(this.comics, {this.warning});
}

/// Descuento que la tienda le aplica a un producto en el carrito.
class CartPromo {
  /// Porcentaje del precio (p. ej. 30.0).
  final double percent;

  /// Nombre de la promoción, sin el porcentaje ("Descuentos espeluznantes").
  final String label;

  const CartPromo(this.percent, this.label);
}

class CartPromoResult {
  /// SKU (con prefijo de tienda) de cada producto que sí se revisó.
  final Set<String> checked;

  /// Los revisados que tienen descuento.
  final Map<String, CartPromo> promos;

  /// Aviso si la revisión no pudo terminar (lo revisado sigue siendo útil).
  final String? warning;

  const CartPromoResult(this.checked, this.promos, {this.warning});
}

/// Descarga el catálogo de una tienda oficial de Panini (México, Chile,
/// Argentina o Brasil) usando la API pública GraphQL que usa su propio sitio
/// web. Las cuatro comparten servidor; el encabezado `Store` elige la tienda.
class PaniniScraper {
  PaniniScraper({http.Client? client, this.store = mexico})
    : _client = client ?? http.Client();

  final PaniniStore store;

  static final _endpoint = Uri.parse('https://tiendapanini.com.mx/graphql');

  /// Pausa entre páginas para no saturar el servidor.
  static const pageDelay = Duration(milliseconds: 1200);
  static const _pageSize = 100;

  final http.Client _client;

  Future<Map<String, dynamic>> _query(
    String query, [
    Map<String, dynamic>? variables,
  ]) async {
    final res = await _client
        .post(
          _endpoint,
          headers: {
            'Content-Type': 'application/json',
            'Store': store.storeCode,
            'User-Agent': 'ComicsPanini/1.0 (app personal de coleccion)',
          },
          body: jsonEncode({'query': query, 'variables': variables ?? {}}),
        )
        .timeout(const Duration(seconds: 90));
    if (res.statusCode != 200) {
      throw Exception('La tienda respondió con error ${res.statusCode}.');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final data = body['data'];
    if (data == null) {
      throw Exception('Respuesta inválida de la tienda: ${body['errors']}');
    }
    // Algunos productos fallan al pedir sus atributos extendidos; esos
    // errores son parciales y se manejan producto por producto.
    return data as Map<String, dynamic>;
  }

  Future<List<StoreCategory>> fetchCategories() async {
    final data = await _query(
      r'''
      query($parent: String) {
        categoryList(filters: { parent_id: { eq: $parent } }) {
          id name product_count
        }
      }
    ''',
      {'parent': store.rootCategoryId},
    );
    return (data['categoryList'] as List)
        .map(
          (c) => StoreCategory(
            id: c['id'] as int,
            name: (c['name'] as String).trim(),
            productCount: c['product_count'] as int,
          ),
        )
        .where((c) => c.productCount > 0)
        .toList();
  }

  static const _productsQuery = r'''
    query($cats: [String], $page: Int, $size: Int) {
      products(
        filter: { category_id: { in: $cats } }
        pageSize: $size
        currentPage: $page
        sort: { name: ASC }
      ) {
        total_count
        page_info { total_pages }
        items {
          sku name url_key stock_status special_to_date
          categories { name }
          small_image { url }
          price_range {
            minimum_price {
              regular_price { value }
              final_price { value currency }
            }
          }
          custom_attributesV2 {
            items {
              code
              ... on AttributeValue { value }
              ... on AttributeSelectedOptions { selected_options { label } }
            }
          }
        }
      }
    }
  ''';

  /// Igual que [_productsQuery] pero sin los atributos extendidos, que es lo
  /// que a veces hace fallar a la tienda.
  static final _basicProductsQuery = _productsQuery.replaceFirst(
    RegExp(r'custom_attributesV2 \{.*?\n          \}\n', dotAll: true),
    '',
  );

  static const _maxAttempts = 3;

  /// Descarga todos los productos de las categorías indicadas.
  ///
  /// [onProgress] recibe (página actual, total de páginas, productos).
  /// Si [isCancelled] devuelve true se detiene y regresa lo descargado.
  /// Si una página falla varias veces, se detiene y regresa lo descargado
  /// con un aviso en [ScrapeResult.warning].
  Future<ScrapeResult> scrape(
    List<StoreCategory> categories, {
    void Function(int page, int totalPages, int products)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final ids = categories.map((c) => c.id.toString()).toList();
    final bySku = <String, Comic>{};
    var page = 1;
    var totalPages = 1;
    do {
      if (isCancelled?.call() ?? false) break;
      try {
        totalPages = await _scrapePage(ids, page, bySku);
      } catch (e) {
        return ScrapeResult(
          bySku.values.toList(),
          warning: 'Se detuvo en la página $page de $totalPages: $e',
        );
      }
      onProgress?.call(page, totalPages, bySku.length);
      page++;
      if (page <= totalPages) await Future.delayed(pageDelay);
    } while (page <= totalPages);
    return ScrapeResult(bySku.values.toList());
  }

  /// Descarga una página (con reintentos) y devuelve el total de páginas.
  Future<int> _scrapePage(
    List<String> ids,
    int page,
    Map<String, Comic> bySku,
  ) async {
    final vars = {'cats': ids, 'page': page, 'size': _pageSize};
    Object? lastError;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final products =
            (await _query(_productsQuery, vars))['products']
                as Map<String, dynamic>?;
        if (products == null) {
          throw Exception('la tienda no devolvió productos');
        }
        final items = (products['items'] as List?) ?? const [];
        for (final item in items.whereType<Map<String, dynamic>>()) {
          final comic = _parseProduct(item);
          bySku[comic.sku] = comic;
        }
        // Productos que la tienda no pudo entregar completos: se piden de
        // nuevo sin atributos extendidos.
        if (items.any((i) => i == null)) {
          final basic =
              (await _query(_basicProductsQuery, vars))['products']
                  as Map<String, dynamic>?;
          for (final item
              in ((basic?['items'] as List?) ?? const [])
                  .whereType<Map<String, dynamic>>()) {
            if (!bySku.containsKey(item['sku'])) {
              final comic = _parseProduct(item);
              bySku[comic.sku] = comic;
            }
          }
        }
        return (products['page_info']?['total_pages'] as int?) ?? 1;
      } catch (e) {
        lastError = e;
        if (attempt < _maxAttempts) {
          await Future.delayed(Duration(seconds: 3 * attempt));
        }
      }
    }
    throw lastError!;
  }

  /// Productos por carrito al revisar promociones.
  static const cartBatch = 50;

  static const _addToCartQuery = r'''
    mutation($cart: String!, $items: [CartItemInput!]!) {
      addProductsToCart(cartId: $cart, cartItems: $items) {
        user_errors { message }
      }
    }
  ''';

  /// Se lee aparte: si algún producto no se pudo agregar (la tienda a veces
  /// lista SKU que ya no vende), la respuesta de agregar trae el carrito sin
  /// descuentos calculados.
  static const _cartQuery = r'''
    query($cart: String!) {
      cart(cart_id: $cart) {
        items {
          product { sku }
          prices { row_total { value } discounts { label amount { value } } }
        }
      }
    }
  ''';

  /// Revisa qué descuentos aplica la tienda en el carrito (promociones como
  /// "Descuentos espeluznantes", que no cambian el precio del catálogo).
  ///
  /// Mete [comics] en carritos de invitado de [cartBatch] en [cartBatch] y
  /// lee el descuento de cada uno. Los carritos no se compran: la tienda los
  /// borra sola con el tiempo.
  ///
  /// [onProgress] recibe (revisados, total, con descuento).
  /// Si [isCancelled] devuelve true se detiene y regresa lo revisado.
  Future<CartPromoResult> checkCartPromos(
    List<Comic> comics, {
    void Function(int done, int total, int found)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final prefix = store.skuPrefix;
    final checked = <String>{};
    final promos = <String, CartPromo>{};
    for (var start = 0; start < comics.length; start += cartBatch) {
      if (isCancelled?.call() ?? false) break;
      final batch = comics.skip(start).take(cartBatch).toList();
      try {
        final found = await _checkCartBatch([
          for (final c in batch) c.sku.substring(prefix.length),
        ]);
        for (final c in batch) {
          checked.add(c.sku);
          if (found[c.sku.substring(prefix.length)] case final promo?) {
            promos[c.sku] = promo;
          }
        }
      } catch (e) {
        return CartPromoResult(
          checked,
          promos,
          warning: 'Se detuvo en el cómic ${start + 1} de ${comics.length}: $e',
        );
      }
      onProgress?.call(checked.length, comics.length, promos.length);
      if (start + cartBatch < comics.length) await Future.delayed(pageDelay);
    }
    return CartPromoResult(checked, promos);
  }

  /// Un carrito nuevo con [skus] (sin prefijo); devuelve los que tienen
  /// descuento. Los que la tienda no deja agregar simplemente no aparecen.
  Future<Map<String, CartPromo>> _checkCartBatch(List<String> skus) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final cart =
            (await _query('mutation { createEmptyCart }'))['createEmptyCart']
                as String;
        await _query(_addToCartQuery, {
          'cart': cart,
          'items': [
            for (final s in skus) {'sku': s, 'quantity': 1},
          ],
        });
        final data = await _query(_cartQuery, {'cart': cart});
        final items = (data['cart']?['items'] as List?) ?? const [];
        return {
          for (final item in items.whereType<Map<String, dynamic>>())
            item['product']['sku'] as String: ?_parseCartPromo(item),
        };
      } catch (e) {
        lastError = e;
        if (attempt < _maxAttempts) {
          await Future.delayed(Duration(seconds: 3 * attempt));
        }
      }
    }
    throw lastError!;
  }

  static CartPromo? _parseCartPromo(Map<String, dynamic> item) {
    final prices = item['prices'] as Map<String, dynamic>?;
    final total = (prices?['row_total']?['value'] as num?)?.toDouble() ?? 0;
    final discounts = ((prices?['discounts'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final amount = discounts.fold<double>(
      0,
      (s, d) => s + ((d['amount']?['value'] as num?)?.toDouble() ?? 0),
    );
    if (total <= 0 || amount <= 0) return null;
    // "30% - Descuentos espeluznantes " → "Descuentos espeluznantes".
    final labels = {
      for (final d in discounts)
        ((d['label'] as String?) ?? '')
            .replaceFirst(RegExp(r'^\s*[\d.]+\s*%\s*-?\s*'), '')
            .trim(),
    }..remove('');
    final percent = (amount / total * 1000).round() / 10;
    return CartPromo(percent, labels.join(', '));
  }

  Comic _parseProduct(Map<String, dynamic> item) {
    final attrs = <String, String>{};
    final rawAttrs = item['custom_attributesV2']?['items'] as List?;
    for (final a in rawAttrs ?? const []) {
      final code = a['code'] as String;
      if (a['value'] != null) {
        attrs[code] = a['value'].toString();
      } else if (a['selected_options'] != null) {
        attrs[code] = (a['selected_options'] as List)
            .map((o) => o['label'])
            .join(', ');
      }
    }

    final sku = item['sku'] as String;
    final name = (item['name'] as String).trim();
    final fromSku = _parseSku(sku);

    var series = _clean(attrs['collection']);
    if (series != null) series = _titleCase(series);

    final prefix = store.skuPrefix;
    final seriesCode = _clean(attrs['collection_code']) ?? fromSku.code;
    final minPrice = item['price_range']?['minimum_price'];
    final finalPrice = minPrice?['final_price'];
    final price = (finalPrice?['value'] as num?)?.toDouble();
    final regular = (minPrice?['regular_price']?['value'] as num?)?.toDouble();
    // Solo se guarda el precio normal si la tienda lo tiene rebajado.
    final onSale = price != null && regular != null && regular > price;
    return Comic(
      sku: '$prefix$sku',
      store: store.key,
      currency: finalPrice?['currency'] as String? ?? store.currency,
      name: name,
      urlKey: item['url_key'] as String?,
      series: series ?? _seriesFromName(name),
      seriesCode: seriesCode == null ? null : '$prefix$seriesCode',
      number: int.tryParse(attrs['number'] ?? '') ?? fromSku.number,
      releaseDate: _clean(attrs['release_date']),
      isbn: _clean(attrs['isbn']),
      pages: int.tryParse(attrs['pages'] ?? ''),
      contains: _stripHtml(attrs['product_contains']),
      price: price,
      regularPrice: onSale ? regular : null,
      // "2026-12-18 03:00:00" → "2026-12-18".
      promoEnds: onSale
          ? _clean(item['special_to_date'] as String?)?.split(' ').first
          : null,
      imageUrl: _cleanImageUrl(item['small_image']?['url'] as String?),
      categories: ((item['categories'] as List?) ?? const [])
          .map((c) => (c['name'] as String).trim())
          .toSet()
          .toList(),
      itemType: _clean(attrs['item_type_description']),
      stockStatus: item['stock_status'] as String?,
    );
  }

  /// Los SKU de Panini siguen el patrón CODIGO + número de 3 dígitos,
  /// p. ej. QABSB002 → serie QABSB, número 2.
  static ({String? code, int? number}) _parseSku(String sku) {
    final m = RegExp(r'^([A-Z0-9]+?)(\d{3})([A-Z]*)$').firstMatch(sku);
    if (m == null) return (code: null, number: null);
    return (code: m.group(1), number: int.parse(m.group(2)!));
  }

  static String _seriesFromName(String name) => name
      .replaceFirst(
        RegExp(
          r'\s*(#|N\.?\s?|No\.?\s?|Vol\.?\s?|Tomo\s)\d+.*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();

  static String? _clean(String? v) {
    if (v == null) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  static String? _stripHtml(String? html) {
    if (html == null) return null;
    final text = html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n\s*\n+'), '\n')
        .trim();
    return text.isEmpty ? null : text;
  }

  static String? _cleanImageUrl(String? url) {
    if (url == null || url.contains('placeholder')) return null;
    final q = url.indexOf('?');
    return q == -1 ? url : url.substring(0, q);
  }

  static String _titleCase(String s) {
    // Solo convierte si viene todo en mayúsculas (p. ej. "ABSOLUTE BATMAN TPB").
    if (s != s.toUpperCase()) return s;
    const keepUpper = {'TPB', 'DC', 'HC', 'II', 'III', 'IV', 'X', 'SW', 'MX'};
    return s
        .split(' ')
        .map((w) {
          if (w.isEmpty || keepUpper.contains(w)) return w;
          return w[0] + w.substring(1).toLowerCase();
        })
        .join(' ');
  }

  void close() => _client.close();
}

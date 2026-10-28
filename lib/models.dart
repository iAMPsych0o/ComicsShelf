// Modelos de datos de la app.

import 'services/stores.dart';

class User {
  final int id;
  final String username;

  const User({required this.id, required this.username});
}

/// Un cómic del catálogo (ya migrado a la base de datos local).
class Comic {
  final String sku;
  final String name;
  final String? urlKey;
  final String? series;
  final String? seriesCode;
  final int? number;
  final String? releaseDate;
  final String? isbn;
  final int? pages;
  final String? contains;
  final double? price;
  final String? imageUrl;
  final List<String> categories;
  final String? itemType;
  final String? stockStatus;

  /// Tienda de donde viene ('mx', 'cl', 'ar', 'br') y moneda de [price].
  final String store;
  final String currency;

  const Comic({
    required this.sku,
    required this.name,
    this.urlKey,
    this.series,
    this.seriesCode,
    this.number,
    this.releaseDate,
    this.isbn,
    this.pages,
    this.contains,
    this.price,
    this.imageUrl,
    this.categories = const [],
    this.itemType,
    this.stockStatus,
    this.store = 'mx',
    this.currency = 'MXN',
  });

  PaniniStore get shop => storeByKey(store);

  String get storeUrl => '${shop.baseUrl}${urlKey ?? ''}';

  bool get inStock => stockStatus == 'IN_STOCK';

  /// Si la tienda dijo si hay existencias (los cómics muy viejos de la base
  /// pueden no tenerlo).
  bool get hasStockInfo => stockStatus != null;

  /// Preventa: la tienda lo tiene en la categoría "Preventas" o su fecha de
  /// salida todavía no llega. [today] es para pruebas.
  bool isPreorder([DateTime? today]) {
    if (categories.contains('Preventas') || categories.contains('Preventa')) {
      return true;
    }
    final release = DateTime.tryParse(releaseDate ?? '');
    if (release == null) return false;
    final now = today ?? DateTime.now();
    return release.isAfter(DateTime(now.year, now.month, now.day));
  }

  Map<String, Object?> toRow() => {
    'sku': sku,
    'name': name,
    'url_key': urlKey,
    'series': series,
    'series_code': seriesCode,
    'number': number,
    'release_date': releaseDate,
    'isbn': isbn,
    'pages': pages,
    'contains': contains,
    'price': price,
    'image_url': imageUrl,
    'categories': categories.join('|'),
    'item_type': itemType,
    'stock_status': stockStatus,
    'store': store,
    'currency': currency,
  };

  factory Comic.fromRow(Map<String, Object?> r) => Comic(
    sku: r['sku'] as String,
    name: r['name'] as String,
    urlKey: r['url_key'] as String?,
    series: r['series'] as String?,
    seriesCode: r['series_code'] as String?,
    number: r['number'] as int?,
    releaseDate: r['release_date'] as String?,
    isbn: r['isbn'] as String?,
    pages: r['pages'] as int?,
    contains: r['contains'] as String?,
    price: (r['price'] as num?)?.toDouble(),
    imageUrl: r['image_url'] as String?,
    categories: ((r['categories'] as String?) ?? '')
        .split('|')
        .where((c) => c.isNotEmpty)
        .toList(),
    itemType: r['item_type'] as String?,
    stockStatus: r['stock_status'] as String?,
    store: r['store'] as String? ?? 'mx',
    currency: r['currency'] as String? ?? 'MXN',
  );
}

/// Estado de un cómic para un usuario.
///
/// Cubre toda la tienda: lo que no has visto (sin clasificar), lo que no te
/// importa, lo que quieres, lo que ya pagaste y lo que ya tienes.
enum ComicStatus {
  unclassified('Sin clasificar'),
  notInterested('No me interesa'),
  wishlist('Wishlist'),
  purchased('Comprado'),
  owned('Obtenido');

  const ComicStatus(this.label);
  final String label;

  /// Valor guardado en la base de datos (null = sin clasificar).
  String? get dbValue => this == unclassified ? null : name;

  static ComicStatus fromDb(Object? v) =>
      values.firstWhere((s) => s.name == v, orElse: () => unclassified);
}

/// Conteo de cómics por estado.
/// Filtro de disponibilidad del catálogo. "Disponible" incluye las preventas
/// que todavía se pueden apartar.
enum Availability {
  available('Disponible'),
  soldOut('Agotado'),
  preorder('Preventa');

  const Availability(this.label);
  final String label;
}

class StatusCounts {
  final int total;
  final int owned;
  final int purchased;

  /// Valor en pesos (suma de precios de la tienda) de cada grupo.
  final double totalValue;
  final double ownedValue;
  final double purchasedValue;

  const StatusCounts({
    this.total = 0,
    this.owned = 0,
    this.purchased = 0,
    this.totalValue = 0,
    this.ownedValue = 0,
    this.purchasedValue = 0,
  });

  /// Lo que todavía no tienes ni has comprado.
  int get missing => total - owned - purchased;

  /// Cuánto costaría completar lo que falta.
  double get missingValue => totalValue - ownedValue - purchasedValue;
}

class Collection {
  final int id;
  final String name;
  final StatusCounts counts;

  const Collection({
    required this.id,
    required this.name,
    this.counts = const StatusCounts(),
  });

  int get total => counts.total;
  int get owned => counts.owned;
  int get purchased => counts.purchased;
  double get progress => total == 0 ? 0 : owned / total;
}

class CollectionItem {
  final Comic comic;
  final ComicStatus status;

  const CollectionItem({required this.comic, required this.status});

  bool get owned => status == ComicStatus.owned;
}

/// Categoría de la tienda (para elegir qué descargar).
class StoreCategory {
  final int id;
  final String name;
  final int productCount;

  const StoreCategory({
    required this.id,
    required this.name,
    required this.productCount,
  });
}

/// Pedido: cómics que ya pagaste, con la tienda y la guía de envío.
class Order {
  final int id;
  final String? store;
  final String? tracking;

  /// Clave de la paquetería (ver services/carriers.dart).
  final String? carrier;
  final String? notes;

  /// Pedido creado por la app para los cómics marcados "Comprado" que no
  /// estaban en ningún pedido. Deja de serlo al editarlo.
  final bool auto;
  final String createdAt;
  final String? receivedAt;
  final int count;
  final int ownedCount;
  final double total;

  const Order({
    required this.id,
    this.store,
    this.tracking,
    this.carrier,
    this.notes,
    this.auto = false,
    required this.createdAt,
    this.receivedAt,
    this.count = 0,
    this.ownedCount = 0,
    this.total = 0,
  });

  bool get received => receivedAt != null;

  String get title =>
      store ?? (auto ? 'Compras sin pedido' : 'Pedido sin tienda');
}

/// Carrito de futuras compras.
class Cart {
  final int id;
  final String name;
  final int count;
  final int soldOut;
  final double total;

  const Cart({
    required this.id,
    required this.name,
    this.count = 0,
    this.soldOut = 0,
    this.total = 0,
  });
}

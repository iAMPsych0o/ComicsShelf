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

  /// Precio sin descuento, solo si la tienda lo tiene en oferta ([price] es
  /// el precio rebajado), y último día de la oferta si la tienda lo indica.
  final double? regularPrice;
  final String? promoEnds;

  /// Descuento que la tienda aplica en el carrito (% del precio) y nombre de
  /// la promoción, según la última revisión de promociones del carrito.
  final double? cartDiscount;
  final String? cartPromo;

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
    this.regularPrice,
    this.promoEnds,
    this.cartDiscount,
    this.cartPromo,
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

  /// En oferta: la tienda lo tenía rebajado al actualizar el catálogo y la
  /// oferta no ha terminado, o tiene descuento en el carrito. Misma regla
  /// que el filtro "En oferta" de la base. [today] es para pruebas.
  bool isOnSale([DateTime? today]) => hasCatalogSale(today) || hasCartPromo;

  bool get hasCartPromo => (cartDiscount ?? 0) > 0;

  /// Rebajado en el catálogo (precio normal mayor que [price]).
  bool hasCatalogSale([DateTime? today]) {
    if (price == null || regularPrice == null || regularPrice! <= price!) {
      return false;
    }
    final ends = DateTime.tryParse(promoEnds ?? '');
    if (ends == null) return true;
    final now = today ?? DateTime.now();
    return !ends.isBefore(DateTime(now.year, now.month, now.day));
  }

  /// Precio sin ningún descuento: el normal si está rebajado en el catálogo;
  /// si no, [price].
  double? listPrice([DateTime? today]) =>
      hasCatalogSale(today) ? regularPrice : price;

  /// Lo que se paga: [price] (ya rebajado si hay oferta en el catálogo) menos
  /// el descuento del carrito.
  double? get finalPrice {
    if (price == null || !hasCartPromo) return price;
    return (price! * (100 - cartDiscount!)).round() / 100;
  }

  /// Descuento total redondeado (p. ej. 50 para "-50%"): de [listPrice] a
  /// [finalPrice]. Misma regla que el filtro por descuento de la base.
  int discountPercentAt([DateTime? today]) {
    final list = listPrice(today), paid = finalPrice;
    if (list == null || paid == null || list <= 0) return 0;
    return ((1 - paid / list) * 100).round();
  }

  int get discountPercent => discountPercentAt();

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
    'regular_price': regularPrice,
    'promo_ends': promoEnds,
    'cart_discount': cartDiscount,
    'cart_promo': cartPromo,
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
    regularPrice: (r['regular_price'] as num?)?.toDouble(),
    promoEnds: r['promo_ends'] as String?,
    cartDiscount: (r['cart_discount'] as num?)?.toDouble(),
    cartPromo: r['cart_promo'] as String?,
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
  preorder('Preventa'),
  onSale('En oferta');

  const Availability(this.label);
  final String label;
}

/// Opciones del filtro por descuento del catálogo ("10% o más", etc.).
const discountSteps = [10, 20, 30, 40, 50];

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

/// Lugar donde guardas cómics ("Closet 1"). Puede estar dentro de otro
/// ("Closet 1 › Bin 4").
class StorageLocation {
  final int id;
  final String name;
  final int? parentId;

  /// Nombre completo con los lugares que la contienen: "Closet 1 › Bin 4".
  final String path;

  /// 0 para las de primer nivel.
  final int depth;

  /// Cómics guardados directamente aquí.
  final int count;

  /// Cómics aquí y en todo lo que contiene.
  final int totalCount;

  const StorageLocation({
    required this.id,
    required this.name,
    this.parentId,
    required this.path,
    this.depth = 0,
    this.count = 0,
    this.totalCount = 0,
  });
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

/// Tiendas Panini que comparten el mismo servidor (Magento): solo cambian
/// el código de tienda, la categoría raíz, la moneda y el dominio.
class PaniniStore {
  final String key;
  final String name;

  /// Código que se manda en el encabezado `Store` de la API.
  final String storeCode;
  final String rootCategoryId;
  final String currency;
  final String baseUrl;

  /// Categorías que por defecto no se descargan (no son cómics).
  final Set<String> defaultExcluded;

  const PaniniStore({
    required this.key,
    required this.name,
    required this.storeCode,
    required this.rootCategoryId,
    required this.currency,
    required this.baseUrl,
    required this.defaultExcluded,
  });

  /// Prefijo de SKU: Chile y Argentina comparten códigos, así que fuera de
  /// México cada producto lleva la tienda (p. ej. "cl:SHMIN099"). México
  /// queda sin prefijo para no tocar los datos que ya existían.
  String get skuPrefix => key == mexico.key ? '' : '$key:';

  /// Código corto para las etiquetas de las cards.
  String get shortCode => key.toUpperCase();
}

const mexico = PaniniStore(
  key: 'mx',
  name: 'Panini México',
  storeCode: 'mexico',
  rootCategoryId: '510',
  currency: 'MXN',
  baseUrl: 'https://tiendapanini.com.mx/',
  defaultExcluded: {
    'Panini Manga',
    'Estampas y Tarjetas',
    'Estampas Faltantes',
    'FIFA',
    'Merchandising',
    'Figuras',
  },
);

const chile = PaniniStore(
  key: 'cl',
  name: 'Panini Chile',
  storeCode: 'chile',
  rootCategoryId: '468',
  currency: 'CLP',
  baseUrl: 'https://tiendapanini.cl/',
  defaultExcluded: {
    'Panini Manga',
    'FIFA WORLD CUP 2026',
    'Coleccionables',
    'Deportes',
  },
);

const argentina = PaniniStore(
  key: 'ar',
  name: 'Panini Argentina',
  storeCode: 'argentina',
  rootCategoryId: '447',
  currency: 'ARS',
  baseUrl: 'https://tiendapanini.com.ar/',
  defaultExcluded: {'Panini Manga', 'Figuritas y Cartas', 'Checklist'},
);

const brasil = PaniniStore(
  key: 'br',
  name: 'Panini Brasil',
  storeCode: 'default',
  rootCategoryId: '2',
  currency: 'BRL',
  baseUrl: 'https://panini.com.br/',
  defaultExcluded: {
    'Planet Mangá',
    'Colecionáveis',
    'Assinaturas Panini',
    'Campanha Meia-Noite',
  },
);

const paniniStores = [mexico, chile, argentina, brasil];

PaniniStore storeByKey(String? key) =>
    paniniStores.firstWhere((s) => s.key == key, orElse: () => mexico);

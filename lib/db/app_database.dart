import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import '../services/currency.dart';

/// Acceso a la base de datos SQLite local.
///
/// El catálogo (`comics`) es compartido por todos los usuarios del
/// dispositivo; las colecciones pertenecen a cada usuario.
class AppDatabase {
  AppDatabase._(this._db, this.directory);

  final Database _db;

  /// Carpeta del archivo de la base (null si está en memoria). Ahí se guardan
  /// los respaldos automáticos antes de importar.
  final String? directory;

  static const _schemaVersion = 6;

  static Future<AppDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    await Directory(dir.path).create(recursive: true);
    return AppDatabase.openAt(p.join(dir.path, 'comics_panini.db'));
  }

  /// Abre (o crea) la base de datos en un archivo concreto.
  factory AppDatabase.openAt(String path) {
    final db = sqlite3.open(path);
    // Modo clásico: cada transacción queda escrita en el archivo principal,
    // así un cierre brusco de la app no puede perder datos ya guardados.
    db.execute('PRAGMA journal_mode = DELETE;');
    db.execute('PRAGMA synchronous = FULL;');
    return AppDatabase._init(db, p.dirname(path));
  }

  /// Base de datos en memoria, para pruebas.
  factory AppDatabase.inMemory() =>
      AppDatabase._init(sqlite3.openInMemory(), null);

  factory AppDatabase._init(Database db, String? directory) {
    db.execute('PRAGMA foreign_keys = ON;');
    // Precio convertido a la moneda elegida, para sumar totales de tiendas
    // con monedas distintas (null si no hay tipo de cambio).
    db.createFunction(
      functionName: 'to_display',
      argumentCount: const AllowedArgumentCount(2),
      function: (args) => Money.instance.convert(
        (args[0] as num?)?.toDouble(),
        args[1] as String?,
      ),
    );
    final appDb = AppDatabase._(db, directory);
    appDb._migrate();
    return appDb;
  }

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version < 1) {
      _db.execute('''
        CREATE TABLE users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT NOT NULL UNIQUE COLLATE NOCASE,
          password_hash TEXT NOT NULL,
          salt TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        CREATE TABLE comics (
          sku TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          url_key TEXT,
          series TEXT,
          series_code TEXT,
          number INTEGER,
          release_date TEXT,
          isbn TEXT,
          pages INTEGER,
          contains TEXT,
          price REAL,
          image_url TEXT,
          categories TEXT,
          item_type TEXT,
          stock_status TEXT,
          updated_at TEXT NOT NULL
        );
        CREATE INDEX idx_comics_series ON comics(series_code, number);
        CREATE TABLE ignored_skus (
          sku TEXT PRIMARY KEY,
          name TEXT,
          ignored_at TEXT NOT NULL
        );
        CREATE TABLE collections (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        CREATE TABLE collection_items (
          collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
          sku TEXT NOT NULL REFERENCES comics(sku) ON DELETE CASCADE,
          owned INTEGER NOT NULL DEFAULT 0,
          added_at TEXT NOT NULL,
          PRIMARY KEY (collection_id, sku)
        );
      ''');
    }
    if (version < 2) {
      // "Lo tengo" pasa a ser del usuario, no de cada colección. Se conserva
      // todo lo que ya estaba marcado en cualquier colección.
      // (collection_items.owned queda sin uso.)
      _db.execute('''
        CREATE TABLE IF NOT EXISTS owned_comics (
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          sku TEXT NOT NULL REFERENCES comics(sku) ON DELETE CASCADE,
          owned_at TEXT NOT NULL,
          PRIMARY KEY (user_id, sku)
        );
        INSERT OR IGNORE INTO owned_comics (user_id, sku, owned_at)
          SELECT c.user_id, i.sku, i.added_at
          FROM collection_items i
          JOIN collections c ON c.id = i.collection_id
          WHERE i.owned = 1;
      ''');
    }
    if (version < 3) {
      // Estado de cada cómic para cada usuario (sin fila = sin clasificar).
      // Reemplaza a owned_comics conservando lo marcado como obtenido.
      _db.execute('''
        CREATE TABLE IF NOT EXISTS comic_status (
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          sku TEXT NOT NULL REFERENCES comics(sku) ON DELETE CASCADE,
          status TEXT NOT NULL CHECK (status IN
            ('notInterested', 'wishlist', 'purchased', 'owned')),
          updated_at TEXT NOT NULL,
          PRIMARY KEY (user_id, sku)
        );
        INSERT OR IGNORE INTO comic_status (user_id, sku, status, updated_at)
          SELECT user_id, sku, 'owned', owned_at FROM owned_comics;
        DROP TABLE owned_comics;
      ''');
    }
    if (version < 4) {
      // Ajustes del dispositivo (por ejemplo, la sesión recordada).
      _db.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY,
          value TEXT
        );
      ''');
    }
    if (version < 5) {
      // Pedidos (tienda, guía y cómics pagados) y carritos de futuras compras.
      _db.execute('''
        CREATE TABLE IF NOT EXISTS orders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          store TEXT,
          tracking TEXT,
          notes TEXT,
          auto INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          received_at TEXT
        );
        CREATE TABLE IF NOT EXISTS order_items (
          order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
          sku TEXT NOT NULL REFERENCES comics(sku) ON DELETE CASCADE,
          PRIMARY KEY (order_id, sku)
        );
        CREATE TABLE IF NOT EXISTS carts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cart_items (
          cart_id INTEGER NOT NULL REFERENCES carts(id) ON DELETE CASCADE,
          sku TEXT NOT NULL REFERENCES comics(sku) ON DELETE CASCADE,
          added_at TEXT NOT NULL,
          PRIMARY KEY (cart_id, sku)
        );
      ''');
      // Lo que ya estaba "Comprado" queda en "Compras sin pedido".
      for (final r in _db.select('SELECT id FROM users')) {
        _syncLooseOrder(r['id'] as int);
      }
    }
    if (version < 6) {
      // Varias tiendas: de dónde viene cada cómic y en qué moneda está.
      final cols = {
        for (final r in _db.select('PRAGMA table_info(comics)'))
          r['name'] as String,
      };
      if (!cols.contains('store')) {
        _db.execute(
          "ALTER TABLE comics ADD COLUMN store TEXT NOT NULL DEFAULT 'mx'",
        );
      }
      if (!cols.contains('currency')) {
        _db.execute(
          "ALTER TABLE comics ADD COLUMN currency TEXT NOT NULL DEFAULT 'MXN'",
        );
      }
    }
    _db.execute('PRAGMA user_version = $_schemaVersion');
  }

  /// Ejecuta [body] en una transacción (o dentro de la que ya esté abierta).
  T _inTx<T>(T Function() body) {
    if (!_db.autocommit) return body();
    _db.execute('BEGIN');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static String _now() => DateTime.now().toIso8601String();

  // ---------------------------------------------------------------- usuarios

  Map<String, Object?>? findUserRow(String username) {
    final rs = _db.select(
      'SELECT id, username, password_hash, salt FROM users WHERE username = ?',
      [username.trim()],
    );
    return rs.isEmpty ? null : Map.of(rs.first);
  }

  int insertUser(String username, String passwordHash, String salt) {
    _db.execute(
      'INSERT INTO users (username, password_hash, salt, created_at) VALUES (?, ?, ?, ?)',
      [username.trim(), passwordHash, salt, _now()],
    );
    return _db.lastInsertRowId;
  }

  /// Usuario por id (para restaurar la sesión recordada).
  Map<String, Object?>? findUserById(int id) {
    final rs = _db.select('SELECT id, username FROM users WHERE id = ?', [id]);
    return rs.isEmpty ? null : Map.of(rs.first);
  }

  String? getSetting(String key) {
    final rs = _db.select('SELECT value FROM app_settings WHERE key = ?', [
      key,
    ]);
    return rs.isEmpty ? null : rs.first['value'] as String?;
  }

  void setSetting(String key, String? value) {
    if (value == null) {
      _db.execute('DELETE FROM app_settings WHERE key = ?', [key]);
    } else {
      _db.execute(
        'INSERT INTO app_settings (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value],
      );
    }
  }

  // ---------------------------------------------------------------- catálogo

  int comicCount() =>
      _db.select('SELECT COUNT(*) AS n FROM comics').first['n'] as int;

  /// Busca cómics por nombre, serie o ISBN, opcionalmente filtrando por
  /// categoría y por el estado que les dio el usuario [userId].
  List<Comic> searchComics({
    String query = '',
    String? category,
    int? userId,
    ComicStatus? status,
    Availability? availability,
    String? store,
    int limit = 500,
    int offset = 0,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    var from = 'comics';
    if (userId != null && status != null) {
      from =
          'comics LEFT JOIN comic_status st '
          'ON st.user_id = $userId AND st.sku = comics.sku';
      if (status == ComicStatus.unclassified) {
        where.add('st.status IS NULL');
      } else {
        where.add('st.status = ?');
        args.add(status.dbValue);
      }
    }
    final q = query.trim();
    if (q.isNotEmpty) {
      for (final word in q.split(RegExp(r'\s+'))) {
        where.add(
          '(name LIKE ? OR series LIKE ? OR isbn LIKE ? OR comics.sku LIKE ?)',
        );
        final like = '%$word%';
        args.addAll([like, like, like, like]);
      }
    }
    if (category != null) {
      where.add("('|' || comics.categories || '|') LIKE ?");
      args.add('%|$category|%');
    }
    if (availability != null) where.add(_availabilitySql(availability));
    if (store != null) {
      where.add('comics.store = ?');
      args.add(store);
    }
    final sql = StringBuffer('SELECT comics.* FROM $from');
    if (where.isNotEmpty) sql.write(' WHERE ${where.join(' AND ')}');
    sql.write(' ORDER BY series COLLATE NOCASE, number, name COLLATE NOCASE');
    sql.write(' LIMIT ? OFFSET ?');
    args.addAll([limit, offset]);
    return _db
        .select(sql.toString(), args)
        .map((r) => Comic.fromRow(r))
        .toList();
  }

  /// Condición SQL de cada filtro de disponibilidad. La de preventa es la
  /// misma regla que [Comic.isPreorder].
  static String _availabilitySql(Availability a) => switch (a) {
    Availability.available => "comics.stock_status = 'IN_STOCK'",
    Availability.soldOut => "comics.stock_status = 'OUT_OF_STOCK'",
    Availability.preorder =>
      "(('|' || comics.categories || '|') LIKE '%|Preventas|%' "
          "OR ('|' || comics.categories || '|') LIKE '%|Preventa|%' "
          "OR comics.release_date > date('now', 'localtime'))",
  };

  /// Cuántos cómics del catálogo hay con cada disponibilidad.
  Map<Availability, int> availabilityCounts() => {
    for (final a in Availability.values)
      a:
          _db
                  .select(
                    'SELECT COUNT(*) AS n FROM comics '
                    'WHERE ${_availabilitySql(a)}',
                  )
                  .first['n']
              as int,
  };

  /// Cuántos cómics hay de cada tienda.
  Map<String, int> storeCounts() => {
    for (final r in _db.select(
      'SELECT store, COUNT(*) AS n FROM comics GROUP BY store',
    ))
      r['store'] as String: r['n'] as int,
  };

  /// Todas las categorías presentes en el catálogo, con su número de cómics.
  Map<String, int> catalogCategories() {
    final counts = <String, int>{};
    for (final r in _db.select('SELECT categories FROM comics')) {
      for (final c in ((r['categories'] as String?) ?? '').split('|')) {
        if (c.isEmpty) continue;
        counts[c] = (counts[c] ?? 0) + 1;
      }
    }
    return counts;
  }

  List<Comic> comicsInSeries(String seriesCode) => _db
      .select(
        'SELECT * FROM comics WHERE series_code = ? ORDER BY number, name',
        [seriesCode],
      )
      .map((r) => Comic.fromRow(r))
      .toList();

  /// Direcciones de todas las portadas del catálogo.
  List<String> coverUrls() => _db
      .select(
        'SELECT DISTINCT image_url FROM comics WHERE image_url IS NOT NULL',
      )
      .map((r) => r['image_url'] as String)
      .toList();

  /// Compacta el archivo de la base (VACUUM) si no se ha hecho en [every].
  /// Devuelve true si compactó.
  bool compactIfDue({Duration every = const Duration(days: 30)}) {
    final last = DateTime.tryParse(getSetting('last_vacuum') ?? '');
    final now = DateTime.now();
    if (last != null && now.difference(last) < every) return false;
    _db.execute('VACUUM');
    setSetting('last_vacuum', now.toIso8601String());
    return true;
  }

  Set<String> existingSkus() => _db
      .select('SELECT sku FROM comics')
      .map((r) => r['sku'] as String)
      .toSet();

  /// Inserta o actualiza los cómics seleccionados en la revisión del scraping.
  void upsertComics(List<Comic> comics) {
    final stmt = _db.prepare('''
      INSERT INTO comics (sku, name, url_key, series, series_code, number,
        release_date, isbn, pages, contains, price, image_url, categories,
        item_type, stock_status, store, currency, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(sku) DO UPDATE SET
        name = excluded.name, url_key = excluded.url_key,
        series = excluded.series, series_code = excluded.series_code,
        number = excluded.number, release_date = excluded.release_date,
        isbn = excluded.isbn, pages = excluded.pages,
        contains = excluded.contains, price = excluded.price,
        image_url = excluded.image_url, categories = excluded.categories,
        item_type = excluded.item_type, stock_status = excluded.stock_status,
        store = excluded.store, currency = excluded.currency,
        updated_at = excluded.updated_at
    ''');
    final now = _now();
    _db.execute('BEGIN');
    try {
      for (final c in comics) {
        final r = c.toRow();
        stmt.execute([
          r['sku'],
          r['name'],
          r['url_key'],
          r['series'],
          r['series_code'],
          r['number'],
          r['release_date'],
          r['isbn'],
          r['pages'],
          r['contains'],
          r['price'],
          r['image_url'],
          r['categories'],
          r['item_type'],
          r['stock_status'],
          r['store'],
          r['currency'],
          now,
        ]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      stmt.close();
    }
  }

  // ------------------------------------------------------ productos ignorados

  Set<String> ignoredSkus() => _db
      .select('SELECT sku FROM ignored_skus')
      .map((r) => r['sku'] as String)
      .toSet();

  /// Guarda qué productos se ignoraron para que la siguiente revisión
  /// los muestre desmarcados.
  void setIgnored(Map<String, String> ignored, Iterable<String> notIgnored) {
    final now = _now();
    _db.execute('BEGIN');
    try {
      final ins = _db.prepare(
        'INSERT OR REPLACE INTO ignored_skus (sku, name, ignored_at) VALUES (?, ?, ?)',
      );
      final del = _db.prepare('DELETE FROM ignored_skus WHERE sku = ?');
      ignored.forEach((sku, name) => ins.execute([sku, name, now]));
      for (final sku in notIgnored) {
        del.execute([sku]);
      }
      ins.close();
      del.close();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ------------------------------------------------------------- colecciones

  /// Colecciones del usuario con su conteo por estado.
  List<Collection> collections(int userId) => _db
      .select(
        '''
        SELECT c.id, c.name,
          COUNT(i.sku) AS total,
          COUNT(CASE WHEN s.status = 'owned' THEN 1 END) AS owned,
          COUNT(CASE WHEN s.status = 'purchased' THEN 1 END) AS purchased,
          COALESCE(SUM(to_display(k.price, k.currency)), 0) AS total_value,
          COALESCE(SUM(CASE WHEN s.status = 'owned' THEN to_display(k.price, k.currency) END), 0)
            AS owned_value,
          COALESCE(SUM(CASE WHEN s.status = 'purchased' THEN to_display(k.price, k.currency) END), 0)
            AS purchased_value
        FROM collections c
        LEFT JOIN collection_items i ON i.collection_id = c.id
        LEFT JOIN comics k ON k.sku = i.sku
        LEFT JOIN comic_status s ON s.user_id = c.user_id AND s.sku = i.sku
        WHERE c.user_id = ?
        GROUP BY c.id
        ORDER BY c.name COLLATE NOCASE
      ''',
        [userId],
      )
      .map(
        (r) => Collection(
          id: r['id'] as int,
          name: r['name'] as String,
          counts: StatusCounts(
            total: r['total'] as int,
            owned: r['owned'] as int,
            purchased: r['purchased'] as int,
            totalValue: (r['total_value'] as num).toDouble(),
            ownedValue: (r['owned_value'] as num).toDouble(),
            purchasedValue: (r['purchased_value'] as num).toDouble(),
          ),
        ),
      )
      .toList();

  /// Totales del dashboard: todo lo que le importa al usuario, contando cada
  /// cómic una vez. Es la unión de los cómics de sus colecciones y los que
  /// marcó como obtenido, comprado o wishlist (estén o no en una colección).
  StatusCounts collectionTotals(int userId) {
    final r = _db
        .select(
          '''
      SELECT COUNT(*) AS total,
        COUNT(CASE WHEN s.status = 'owned' THEN 1 END) AS owned,
        COUNT(CASE WHEN s.status = 'purchased' THEN 1 END) AS purchased,
        COALESCE(SUM(to_display(k.price, k.currency)), 0) AS total_value,
        COALESCE(SUM(CASE WHEN s.status = 'owned' THEN to_display(k.price, k.currency) END), 0) AS owned_value,
        COALESCE(SUM(CASE WHEN s.status = 'purchased' THEN to_display(k.price, k.currency) END), 0)
          AS purchased_value
      FROM (SELECT i.sku FROM collection_items i
            JOIN collections c ON c.id = i.collection_id
            WHERE c.user_id = ?
            UNION
            SELECT sku FROM comic_status
            WHERE user_id = ? AND status IN ('owned', 'purchased', 'wishlist')) x
      JOIN comics k ON k.sku = x.sku
      LEFT JOIN comic_status s ON s.user_id = ? AND s.sku = x.sku
    ''',
          [userId, userId, userId],
        )
        .first;
    return StatusCounts(
      total: r['total'] as int,
      owned: r['owned'] as int,
      purchased: r['purchased'] as int,
      totalValue: (r['total_value'] as num).toDouble(),
      ownedValue: (r['owned_value'] as num).toDouble(),
      purchasedValue: (r['purchased_value'] as num).toDouble(),
    );
  }

  int createCollection(int userId, String name) {
    _db.execute(
      'INSERT INTO collections (user_id, name, created_at) VALUES (?, ?, ?)',
      [userId, name.trim(), _now()],
    );
    return _db.lastInsertRowId;
  }

  void renameCollection(int userId, int collectionId, String name) {
    _db.execute(
      'UPDATE collections SET name = ? WHERE id = ? AND user_id = ?',
      [name.trim(), collectionId, userId],
    );
  }

  void deleteCollection(int userId, int collectionId) {
    _db.execute('DELETE FROM collections WHERE id = ? AND user_id = ?', [
      collectionId,
      userId,
    ]);
  }

  bool _ownsCollection(int userId, int collectionId) => _db.select(
    'SELECT 1 FROM collections WHERE id = ? AND user_id = ?',
    [collectionId, userId],
  ).isNotEmpty;

  /// Agrega cómics a una colección. Devuelve cuántos eran nuevos.
  int addToCollection(int userId, int collectionId, Iterable<String> skus) {
    if (!_ownsCollection(userId, collectionId)) return 0;
    final before = _itemCount(collectionId);
    final stmt = _db.prepare(
      'INSERT OR IGNORE INTO collection_items (collection_id, sku, owned, added_at) VALUES (?, ?, 0, ?)',
    );
    final now = _now();
    _db.execute('BEGIN');
    for (final sku in skus) {
      stmt.execute([collectionId, sku, now]);
    }
    _db.execute('COMMIT');
    stmt.close();
    return _itemCount(collectionId) - before;
  }

  int _itemCount(int collectionId) =>
      _db.select(
            'SELECT COUNT(*) AS n FROM collection_items WHERE collection_id = ?',
            [collectionId],
          ).first['n']
          as int;

  void removeFromCollection(int userId, int collectionId, String sku) {
    if (!_ownsCollection(userId, collectionId)) return;
    _db.execute(
      'DELETE FROM collection_items WHERE collection_id = ? AND sku = ?',
      [collectionId, sku],
    );
  }

  List<CollectionItem> collectionItems(int userId, int collectionId) {
    if (!_ownsCollection(userId, collectionId)) return const [];
    return _db
        .select(
          '''
          SELECT c.*, s.status AS user_status
          FROM collection_items i
          JOIN comics c ON c.sku = i.sku
          LEFT JOIN comic_status s ON s.user_id = ? AND s.sku = i.sku
          WHERE i.collection_id = ?
          ORDER BY c.series COLLATE NOCASE, c.number, c.name COLLATE NOCASE
        ''',
          [userId, collectionId],
        )
        .map(
          (r) => CollectionItem(
            comic: Comic.fromRow(r),
            status: ComicStatus.fromDb(r['user_status']),
          ),
        )
        .toList();
  }

  /// SKUs que ya están en alguna colección del usuario, con el nombre de la
  /// colección (para marcarlos en el catálogo).
  Map<String, List<String>> skuCollections(int userId) {
    final result = <String, List<String>>{};
    for (final r in _db.select(
      '''
      SELECT i.sku, c.name FROM collection_items i
      JOIN collections c ON c.id = i.collection_id
      WHERE c.user_id = ?
    ''',
      [userId],
    )) {
      (result[r['sku'] as String] ??= []).add(r['name'] as String);
    }
    return result;
  }

  // ----------------------------------------------------------------- estados

  /// Cambia el estado de uno o varios cómics para el usuario. Aplica en el
  /// catálogo, en todas sus colecciones y en la wishlist.
  ///
  /// "Comprado" lo controlan los pedidos: lo que se marque comprado sin estar
  /// en un pedido pendiente va a "Compras sin pedido", y lo que deje de estar
  /// comprado u obtenido sale de los pedidos pendientes.
  void setStatus(int userId, Iterable<String> skus, ComicStatus status) {
    final list = skus.toList();
    _inTx(() {
      _writeStatus(userId, list, status);
      if (status != ComicStatus.purchased && status != ComicStatus.owned) {
        _removeFromPendingOrders(userId, list);
      }
      _syncLooseOrder(userId);
    });
  }

  void _writeStatus(int userId, List<String> skus, ComicStatus status) {
    final stmt = status == ComicStatus.unclassified
        ? _db.prepare('DELETE FROM comic_status WHERE user_id = ? AND sku = ?')
        : _db.prepare('''
            INSERT INTO comic_status (user_id, sku, status, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(user_id, sku) DO UPDATE SET
              status = excluded.status, updated_at = excluded.updated_at
          ''');
    final now = _now();
    try {
      for (final sku in skus) {
        stmt.execute(
          status == ComicStatus.unclassified
              ? [userId, sku]
              : [userId, sku, status.dbValue, now],
        );
      }
    } finally {
      stmt.close();
    }
  }

  // ---------------------------------------------------------------- pedidos

  static const _orderSelect = '''
    SELECT o.*, COUNT(i.sku) AS n,
      COUNT(CASE WHEN s.status = 'owned' THEN 1 END) AS owned_n,
      COALESCE(SUM(to_display(k.price, k.currency)), 0) AS total
    FROM orders o
    LEFT JOIN order_items i ON i.order_id = o.id
    LEFT JOIN comics k ON k.sku = i.sku
    LEFT JOIN comic_status s ON s.user_id = o.user_id AND s.sku = i.sku
  ''';

  static Order _orderFromRow(Row r) => Order(
    id: r['id'] as int,
    store: r['store'] as String?,
    tracking: r['tracking'] as String?,
    notes: r['notes'] as String?,
    auto: r['auto'] == 1,
    createdAt: r['created_at'] as String,
    receivedAt: r['received_at'] as String?,
    count: r['n'] as int,
    ownedCount: r['owned_n'] as int,
    total: (r['total'] as num).toDouble(),
  );

  /// Pedidos del usuario: primero los pendientes, del más nuevo al más viejo.
  List<Order> orders(int userId) => _db
      .select(
        '$_orderSelect WHERE o.user_id = ? GROUP BY o.id '
        'ORDER BY o.received_at IS NOT NULL, '
        'COALESCE(o.received_at, o.created_at) DESC, o.id DESC',
        [userId],
      )
      .map(_orderFromRow)
      .toList();

  Order? order(int userId, int orderId) {
    final rs = _db.select(
      '$_orderSelect WHERE o.user_id = ? AND o.id = ? GROUP BY o.id',
      [userId, orderId],
    );
    return rs.isEmpty ? null : _orderFromRow(rs.first);
  }

  List<CollectionItem> orderItems(int userId, int orderId) =>
      _itemsOf('order_items', 'order_id', userId, orderId, 'orders');

  /// Tiendas usadas antes, para sugerirlas al crear un pedido.
  List<String> storeNames(int userId) => _db
      .select(
        'SELECT store FROM orders WHERE user_id = ? AND store IS NOT NULL '
        'GROUP BY store ORDER BY MAX(created_at) DESC',
        [userId],
      )
      .map((r) => r['store'] as String)
      .toList();

  static String? _blankToNull(String? v) =>
      v == null || v.trim().isEmpty ? null : v.trim();

  /// Crea un pedido pendiente con [skus] (pasan a "Comprado").
  int createOrder(
    int userId, {
    String? store,
    String? tracking,
    String? notes,
    Iterable<String> skus = const [],
  }) => _inTx(() {
    _db.execute(
      'INSERT INTO orders (user_id, store, tracking, notes, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        userId,
        _blankToNull(store),
        _blankToNull(tracking),
        _blankToNull(notes),
        _now(),
      ],
    );
    final id = _db.lastInsertRowId;
    addToOrder(userId, id, skus);
    return id;
  });

  /// Cambia tienda, guía y notas. Un pedido automático pasa a ser normal.
  void updateOrder(
    int userId,
    int orderId, {
    String? store,
    String? tracking,
    String? notes,
  }) => _db.execute(
    'UPDATE orders SET store = ?, tracking = ?, notes = ?, auto = 0 '
    'WHERE id = ? AND user_id = ?',
    [
      _blankToNull(store),
      _blankToNull(tracking),
      _blankToNull(notes),
      orderId,
      userId,
    ],
  );

  /// Agrega cómics a un pedido. Si está pendiente quedan "Comprado" (los ya
  /// obtenidos no cambian) y salen de cualquier otro pedido pendiente; si ya
  /// se recibió, quedan "Obtenido". Devuelve cuántos agregó.
  int addToOrder(int userId, int orderId, Iterable<String> skus) => _inTx(() {
    final o = order(userId, orderId);
    if (o == null) return 0;
    final list = skus.toSet().toList();
    if (!o.received) {
      _removeFromPendingOrders(userId, list, except: orderId);
    }
    var added = 0;
    for (final sku in list) {
      _db.execute(
        'INSERT OR IGNORE INTO order_items (order_id, sku) VALUES (?, ?)',
        [orderId, sku],
      );
      added += _db.updatedRows;
    }
    final owned = ownedSkus(userId);
    _writeStatus(
      userId,
      o.received ? list : list.where((s) => !owned.contains(s)).toList(),
      o.received ? ComicStatus.owned : ComicStatus.purchased,
    );
    _syncLooseOrder(userId);
    return added;
  });

  /// Quita cómics de un pedido. Si estaba pendiente y seguían "Comprado",
  /// vuelven a Wishlist.
  void removeFromOrder(int userId, int orderId, Iterable<String> skus) =>
      _inTx(() {
        final o = order(userId, orderId);
        if (o == null) return;
        final list = skus.toList();
        for (final sku in list) {
          _db.execute(
            'DELETE FROM order_items WHERE order_id = ? AND sku = ?',
            [orderId, sku],
          );
        }
        if (!o.received) _backToWishlist(userId, list);
        _syncLooseOrder(userId);
      });

  /// Marca el pedido como recibido (todo pasa a "Obtenido") o lo regresa a
  /// pendiente (lo obtenido vuelve a "Comprado").
  void setOrderReceived(int userId, int orderId, bool received) => _inTx(() {
    final o = order(userId, orderId);
    if (o == null || o.received == received) return;
    final skus = orderItems(userId, orderId).map((i) => i.comic.sku).toList();
    if (!received) {
      _removeFromPendingOrders(userId, skus, except: orderId);
    }
    _db.execute(
      'UPDATE orders SET received_at = ? WHERE id = ? AND user_id = ?',
      [received ? _now() : null, orderId, userId],
    );
    _writeStatus(
      userId,
      skus,
      received ? ComicStatus.owned : ComicStatus.purchased,
    );
    _syncLooseOrder(userId);
  });

  /// Borra un pedido. Si estaba pendiente, sus cómics vuelven a Wishlist.
  void deleteOrder(int userId, int orderId) => _inTx(() {
    final o = order(userId, orderId);
    if (o == null) return;
    final skus = orderItems(userId, orderId).map((i) => i.comic.sku).toList();
    _db.execute('DELETE FROM orders WHERE id = ? AND user_id = ?', [
      orderId,
      userId,
    ]);
    if (!o.received) _backToWishlist(userId, skus);
    _syncLooseOrder(userId);
  });

  /// Los que sigan "Comprado" y ya no estén en un pedido pendiente.
  void _backToWishlist(int userId, List<String> skus) {
    final inPending = _pendingOrderSkus(userId);
    final current = statuses(userId);
    _writeStatus(userId, [
      for (final s in skus)
        if (current[s] == ComicStatus.purchased && !inPending.contains(s)) s,
    ], ComicStatus.wishlist);
  }

  Set<String> _pendingOrderSkus(int userId) => {
    for (final r in _db.select(
      'SELECT i.sku FROM order_items i JOIN orders o ON o.id = i.order_id '
      'WHERE o.user_id = ? AND o.received_at IS NULL',
      [userId],
    ))
      r['sku'] as String,
  };

  void _removeFromPendingOrders(int userId, List<String> skus, {int? except}) {
    for (final sku in skus) {
      _db.execute(
        'DELETE FROM order_items WHERE sku = ? AND order_id IN '
        '(SELECT id FROM orders WHERE user_id = ? AND received_at IS NULL '
        'AND id != ?)',
        [sku, userId, except ?? -1],
      );
    }
  }

  /// Mantiene "Compras sin pedido": contiene los cómics "Comprado" que no
  /// están en ningún pedido pendiente, y desaparece si queda vacío.
  void _syncLooseOrder(int userId) {
    final purchased = _db
        .select(
          "SELECT sku FROM comic_status WHERE user_id = ? AND status = 'purchased'",
          [userId],
        )
        .map((r) => r['sku'] as String)
        .toSet();
    final loose = purchased.difference(_pendingOrderSkus(userId));
    final rs = _db.select(
      'SELECT id FROM orders WHERE user_id = ? AND auto = 1 '
      'AND received_at IS NULL',
      [userId],
    );
    int? id = rs.isEmpty ? null : rs.first['id'] as int;
    if (loose.isNotEmpty) {
      if (id == null) {
        _db.execute(
          'INSERT INTO orders (user_id, auto, created_at) VALUES (?, 1, ?)',
          [userId, _now()],
        );
        id = _db.lastInsertRowId;
      }
      for (final sku in loose) {
        _db.execute(
          'INSERT OR IGNORE INTO order_items (order_id, sku) VALUES (?, ?)',
          [id, sku],
        );
      }
    }
    if (id != null &&
        _db.select('SELECT 1 FROM order_items WHERE order_id = ?', [
          id,
        ]).isEmpty) {
      _db.execute('DELETE FROM orders WHERE id = ?', [id]);
    }
  }

  // --------------------------------------------------------------- carritos

  List<Cart> carts(int userId) => _db
      .select(
        '''
        SELECT c.id, c.name, COUNT(i.sku) AS n,
          COUNT(CASE WHEN k.stock_status = 'OUT_OF_STOCK' THEN 1 END) AS sold_out,
          COALESCE(SUM(to_display(k.price, k.currency)), 0) AS total
        FROM carts c
        LEFT JOIN cart_items i ON i.cart_id = c.id
        LEFT JOIN comics k ON k.sku = i.sku
        WHERE c.user_id = ?
        GROUP BY c.id
        ORDER BY c.created_at DESC, c.id DESC
      ''',
        [userId],
      )
      .map(
        (r) => Cart(
          id: r['id'] as int,
          name: r['name'] as String,
          count: r['n'] as int,
          soldOut: r['sold_out'] as int,
          total: (r['total'] as num).toDouble(),
        ),
      )
      .toList();

  int createCart(int userId, String name) {
    _db.execute(
      'INSERT INTO carts (user_id, name, created_at) VALUES (?, ?, ?)',
      [userId, name.trim(), _now()],
    );
    return _db.lastInsertRowId;
  }

  void renameCart(int userId, int cartId, String name) => _db.execute(
    'UPDATE carts SET name = ? WHERE id = ? AND user_id = ?',
    [name.trim(), cartId, userId],
  );

  void deleteCart(int userId, int cartId) => _db.execute(
    'DELETE FROM carts WHERE id = ? AND user_id = ?',
    [cartId, userId],
  );

  List<CollectionItem> cartItems(int userId, int cartId) =>
      _itemsOf('cart_items', 'cart_id', userId, cartId, 'carts');

  /// Agrega cómics al carrito (no cambia su estado). Devuelve cuántos agregó.
  int addToCart(int userId, int cartId, Iterable<String> skus) => _inTx(() {
    if (_db.select('SELECT 1 FROM carts WHERE id = ? AND user_id = ?', [
      cartId,
      userId,
    ]).isEmpty) {
      return 0;
    }
    var added = 0;
    final now = _now();
    for (final sku in skus.toSet()) {
      _db.execute(
        'INSERT OR IGNORE INTO cart_items (cart_id, sku, added_at) '
        'VALUES (?, ?, ?)',
        [cartId, sku, now],
      );
      added += _db.updatedRows;
    }
    return added;
  });

  void removeFromCart(int userId, int cartId, Iterable<String> skus) {
    for (final sku in skus) {
      _db.execute(
        'DELETE FROM cart_items WHERE sku = ? AND cart_id IN '
        '(SELECT id FROM carts WHERE id = ? AND user_id = ?)',
        [sku, cartId, userId],
      );
    }
  }

  /// "Ya lo compré": el carrito se convierte en un pedido pendiente.
  int cartToOrder(
    int userId,
    int cartId, {
    String? store,
    String? tracking,
    String? notes,
  }) => _inTx(() {
    final skus = cartItems(userId, cartId).map((i) => i.comic.sku).toList();
    final id = createOrder(
      userId,
      store: store,
      tracking: tracking,
      notes: notes,
      skus: skus,
    );
    deleteCart(userId, cartId);
    return id;
  });

  /// Cómics de un pedido o carrito del usuario, con su estado.
  List<CollectionItem> _itemsOf(
    String table,
    String column,
    int userId,
    int id,
    String parent,
  ) => _db
      .select(
        '''
        SELECT k.*, s.status AS user_status FROM $table i
        JOIN $parent p ON p.id = i.$column AND p.user_id = ?
        JOIN comics k ON k.sku = i.sku
        LEFT JOIN comic_status s ON s.user_id = ? AND s.sku = i.sku
        WHERE i.$column = ?
        ORDER BY k.series COLLATE NOCASE, k.number, k.name COLLATE NOCASE
      ''',
        [userId, userId, id],
      )
      .map(
        (r) => CollectionItem(
          comic: Comic.fromRow(r),
          status: ComicStatus.fromDb(r['user_status']),
        ),
      )
      .toList();

  /// Estado de cada cómic clasificado por el usuario.
  Map<String, ComicStatus> statuses(int userId) => {
    for (final r in _db.select(
      'SELECT sku, status FROM comic_status WHERE user_id = ?',
      [userId],
    ))
      r['sku'] as String: ComicStatus.fromDb(r['status']),
  };

  /// Cuántos cómics de la tienda hay en cada estado (para el catálogo).
  Map<ComicStatus, int> catalogStatusCounts(int userId) {
    final counts = {for (final s in ComicStatus.values) s: 0};
    for (final r in _db.select(
      '''
      SELECT s.status, COUNT(*) AS n FROM comics c
      LEFT JOIN comic_status s ON s.user_id = ? AND s.sku = c.sku
      GROUP BY s.status
    ''',
      [userId],
    )) {
      counts[ComicStatus.fromDb(r['status'])] = r['n'] as int;
    }
    return counts;
  }

  /// SKUs que el usuario ya tiene.
  Set<String> ownedSkus(int userId) => {
    for (final e in statuses(userId).entries)
      if (e.value == ComicStatus.owned) e.key,
  };

  /// Cómics en un estado, del cambio más reciente al más antiguo.
  List<CollectionItem> itemsWithStatus(int userId, ComicStatus status) => _db
      .select(
        '''
        SELECT c.* FROM comic_status s
        JOIN comics c ON c.sku = s.sku
        WHERE s.user_id = ? AND s.status = ?
        ORDER BY s.updated_at DESC
      ''',
        [userId, status.dbValue],
      )
      .map((r) => CollectionItem(comic: Comic.fromRow(r), status: status))
      .toList();

  // ---------------------------------------------------------------- respaldos

  /// Formato del archivo de respaldo (subir si cambia su estructura).
  static const backupFormat = 1;

  /// Respaldo de los datos de UN usuario: sus colecciones, el estado de sus
  /// cómics y los datos de catálogo de esos cómics. No incluye contraseñas
  /// ni nada de otros usuarios.
  ///
  /// Con [fullCatalog] incluye todo el catálogo del dispositivo (para la
  /// sincronización: el destino agrega los cómics que no tenga).
  Map<String, Object?> exportUserData(int userId, {bool fullCatalog = false}) {
    final user = findUserById(userId);
    if (user == null) throw BackupException('El usuario no existe.');

    final collections = [
      for (final c in _db.select(
        'SELECT id, name, created_at FROM collections WHERE user_id = ? ORDER BY id',
        [userId],
      ))
        {
          'name': c['name'],
          'created_at': c['created_at'],
          'items': [
            for (final i in _db.select(
              'SELECT sku, added_at FROM collection_items WHERE collection_id = ? ORDER BY added_at',
              [c['id']],
            ))
              {'sku': i['sku'], 'added_at': i['added_at']},
          ],
        },
    ];
    final statuses = [
      for (final s in _db.select(
        'SELECT sku, status, updated_at FROM comic_status WHERE user_id = ? ORDER BY sku',
        [userId],
      ))
        {'sku': s['sku'], 'status': s['status'], 'updated_at': s['updated_at']},
    ];
    final orders = [
      for (final o in _db.select(
        'SELECT * FROM orders WHERE user_id = ? ORDER BY id',
        [userId],
      ))
        {
          'store': o['store'],
          'tracking': o['tracking'],
          'notes': o['notes'],
          'auto': o['auto'] == 1,
          'created_at': o['created_at'],
          'received_at': o['received_at'],
          'items': [
            for (final i in _db.select(
              'SELECT sku FROM order_items WHERE order_id = ? ORDER BY sku',
              [o['id']],
            ))
              i['sku'],
          ],
        },
    ];
    final carts = [
      for (final c in _db.select(
        'SELECT id, name, created_at FROM carts WHERE user_id = ? ORDER BY id',
        [userId],
      ))
        {
          'name': c['name'],
          'created_at': c['created_at'],
          'items': [
            for (final i in _db.select(
              'SELECT sku, added_at FROM cart_items WHERE cart_id = ? ORDER BY added_at',
              [c['id']],
            ))
              {'sku': i['sku'], 'added_at': i['added_at']},
          ],
        },
    ];
    final skus = {
      for (final c in collections)
        for (final i in c['items'] as List) (i as Map)['sku'] as String,
      for (final s in statuses) s['sku'] as String,
      for (final o in orders)
        for (final sku in o['items'] as List) sku as String,
      for (final c in carts)
        for (final i in c['items'] as List) (i as Map)['sku'] as String,
    };
    final comics = fullCatalog
        ? [
            for (final r in _db.select('SELECT * FROM comics ORDER BY sku'))
              {for (final k in r.keys) k: r[k]},
          ]
        : [
            for (final sku in skus)
              for (final r in _db.select('SELECT * FROM comics WHERE sku = ?', [
                sku,
              ]))
                {for (final k in r.keys) k: r[k]},
          ];

    return {
      'app': 'ComicShelf',
      'format': backupFormat,
      'exported_at': _now(),
      'username': user['username'],
      'collections': collections,
      'statuses': statuses,
      'orders': orders,
      'carts': carts,
      'comics': comics,
    };
  }

  /// Cuántos cómics de [data] no existen todavía en este catálogo.
  int countNewComics(Map<String, Object?> data) {
    final known = existingSkus();
    return (data['comics'] as List? ?? const [])
        .where(
          (c) => c is Map && c['sku'] is String && !known.contains(c['sku']),
        )
        .length;
  }

  /// Revisa que [data] sea un respaldo válido y resume su contenido.
  /// Lanza [BackupException] si no lo es.
  static BackupSummary inspectUserBackup(Object? data) {
    if (data is! Map || data['app'] != 'ComicShelf') {
      throw BackupException('El archivo no es un respaldo de ComicShelf.');
    }
    final format = data['format'];
    if (format is! int || format > backupFormat) {
      throw BackupException(
        'El respaldo es de una versión más nueva de la app. Actualiza la app primero.',
      );
    }
    final collections = data['collections'];
    final statuses = data['statuses'];
    final comics = data['comics'];
    if (collections is! List || statuses is! List || comics is! List) {
      throw BackupException('El respaldo está incompleto o dañado.');
    }
    // Pedidos y carritos son opcionales (respaldos de versiones anteriores).
    final orders = data['orders'] ?? const [];
    final carts = data['carts'] ?? const [];
    if (orders is! List || carts is! List) {
      throw BackupException('El respaldo está incompleto o dañado.');
    }
    final counts = <String, int>{};
    for (final s in statuses) {
      if (s is! Map || s['sku'] is! String || s['status'] is! String) {
        throw BackupException('El respaldo está incompleto o dañado.');
      }
      counts[s['status'] as String] = (counts[s['status']] ?? 0) + 1;
    }
    return BackupSummary(
      username: data['username'] as String? ?? '',
      exportedAt: data['exported_at'] as String?,
      collections: collections.length,
      comics: comics.length,
      owned: counts['owned'] ?? 0,
      purchased: counts['purchased'] ?? 0,
      wishlist: counts['wishlist'] ?? 0,
      orders: orders.length,
      carts: carts.length,
    );
  }

  /// Reemplaza los datos del usuario [userId] con los del respaldo. Solo toca
  /// sus colecciones, estados, pedidos y carritos; los demás usuarios no se
  /// modifican. Del
  /// catálogo solo agrega los cómics que falten (no cambia los existentes).
  void importUserData(int userId, Map<String, Object?> data) {
    inspectUserBackup(data);
    final comicCols = {
      for (final r in _db.select('PRAGMA table_info(comics)'))
        r['name'] as String,
    };
    _db.execute('BEGIN');
    try {
      for (final raw in data['comics'] as List) {
        final c = (raw as Map).cast<String, Object?>();
        if (c['sku'] is! String || c['name'] is! String) continue;
        final cols = c.keys.where(comicCols.contains).toList();
        if (!cols.contains('updated_at')) cols.add('updated_at');
        _db.execute(
          'INSERT OR IGNORE INTO comics (${cols.join(', ')}) '
          'VALUES (${List.filled(cols.length, '?').join(', ')})',
          [for (final k in cols) k == 'updated_at' ? (c[k] ?? _now()) : c[k]],
        );
      }
      final known = existingSkus();

      _db.execute('DELETE FROM collections WHERE user_id = ?', [userId]);
      _db.execute('DELETE FROM comic_status WHERE user_id = ?', [userId]);
      _db.execute('DELETE FROM orders WHERE user_id = ?', [userId]);
      _db.execute('DELETE FROM carts WHERE user_id = ?', [userId]);

      for (final raw in data['collections'] as List) {
        final c = raw as Map;
        _db.execute(
          'INSERT INTO collections (user_id, name, created_at) VALUES (?, ?, ?)',
          [userId, '${c['name'] ?? 'Sin nombre'}', c['created_at'] ?? _now()],
        );
        final id = _db.lastInsertRowId;
        for (final i in (c['items'] as List? ?? const [])) {
          final sku = (i as Map)['sku'];
          if (sku is! String || !known.contains(sku)) continue;
          _db.execute(
            'INSERT OR IGNORE INTO collection_items (collection_id, sku, owned, added_at) '
            'VALUES (?, ?, 0, ?)',
            [id, sku, i['added_at'] ?? _now()],
          );
        }
      }
      const valid = {'notInterested', 'wishlist', 'purchased', 'owned'};
      for (final raw in data['statuses'] as List) {
        final s = raw as Map;
        if (!known.contains(s['sku']) || !valid.contains(s['status'])) continue;
        _db.execute(
          'INSERT OR REPLACE INTO comic_status (user_id, sku, status, updated_at) '
          'VALUES (?, ?, ?, ?)',
          [userId, s['sku'], s['status'], s['updated_at'] ?? _now()],
        );
      }
      String? text(Object? v) => v is String ? v : null;
      for (final raw in data['orders'] as List? ?? const []) {
        if (raw is! Map) continue;
        _db.execute(
          'INSERT INTO orders (user_id, store, tracking, notes, auto, '
          'created_at, received_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            userId,
            text(raw['store']),
            text(raw['tracking']),
            text(raw['notes']),
            raw['auto'] == true ? 1 : 0,
            text(raw['created_at']) ?? _now(),
            text(raw['received_at']),
          ],
        );
        final id = _db.lastInsertRowId;
        for (final sku in raw['items'] as List? ?? const []) {
          if (sku is! String || !known.contains(sku)) continue;
          _db.execute(
            'INSERT OR IGNORE INTO order_items (order_id, sku) VALUES (?, ?)',
            [id, sku],
          );
        }
      }
      for (final raw in data['carts'] as List? ?? const []) {
        if (raw is! Map) continue;
        _db.execute(
          'INSERT INTO carts (user_id, name, created_at) VALUES (?, ?, ?)',
          [
            userId,
            text(raw['name']) ?? 'Carrito',
            text(raw['created_at']) ?? _now(),
          ],
        );
        final id = _db.lastInsertRowId;
        for (final i in raw['items'] as List? ?? const []) {
          if (i is! Map) continue;
          final sku = i['sku'];
          if (sku is! String || !known.contains(sku)) continue;
          _db.execute(
            'INSERT OR IGNORE INTO cart_items (cart_id, sku, added_at) '
            'VALUES (?, ?, ?)',
            [id, sku, text(i['added_at']) ?? _now()],
          );
        }
      }
      // Respaldos sin pedidos: lo "Comprado" queda en "Compras sin pedido".
      _syncLooseOrder(userId);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => _db.close();
}

class BackupException implements Exception {
  final String message;
  BackupException(this.message);
  @override
  String toString() => message;
}

/// Resumen de lo que contiene un respaldo, para confirmar antes de importar.
class BackupSummary {
  final String username;
  final String? exportedAt;
  final int collections;
  final int comics;
  final int owned;
  final int purchased;
  final int wishlist;
  final int orders;
  final int carts;

  const BackupSummary({
    required this.username,
    required this.exportedAt,
    required this.collections,
    required this.comics,
    required this.owned,
    required this.purchased,
    required this.wishlist,
    this.orders = 0,
    this.carts = 0,
  });
}

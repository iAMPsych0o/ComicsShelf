import 'dart:io';

import 'package:comics_panini/db/app_database.dart';
import 'package:comics_panini/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase db;
  late int u;

  setUp(() {
    db = AppDatabase.inMemory();
    u = db.insertUser('alan', 'h', 's');
    db.upsertComics([
      for (var n = 1; n <= 5; n++)
        Comic(
          sku: 'Q$n',
          name: 'Cómic $n',
          price: n * 100.0,
          stockStatus: n == 5 ? 'OUT_OF_STOCK' : 'IN_STOCK',
        ),
    ]);
  });

  ComicStatus? st(String sku) => db.statuses(u)[sku];
  Set<String> itemsOf(int orderId) =>
      db.orderItems(u, orderId).map((i) => i.comic.sku).toSet();

  group('pedidos', () {
    test('crear un pedido marca sus cómics como comprados', () {
      final id = db.createOrder(
        u,
        store: ' Panini México ',
        tracking: 'MX123',
        skus: ['Q1', 'Q2'],
      );
      final o = db.order(u, id)!;
      expect(o.store, 'Panini México');
      expect(o.tracking, 'MX123');
      expect(o.count, 2);
      expect(o.total, 300);
      expect(o.received, isFalse);
      expect(st('Q1'), ComicStatus.purchased);
      expect(db.storeNames(u), ['Panini México']);
    });

    test('marcar "Comprado" a mano lo deja en "Compras sin pedido"', () {
      db.setStatus(u, ['Q1', 'Q2'], ComicStatus.purchased);
      final loose = db.orders(u).single;
      expect(loose.auto, isTrue);
      expect(loose.title, 'Compras sin pedido');
      expect(itemsOf(loose.id), {'Q1', 'Q2'});

      // Si deja de estar comprado, sale; si queda vacío, desaparece.
      db.setStatus(u, ['Q1'], ComicStatus.wishlist);
      expect(itemsOf(loose.id), {'Q2'});
      db.setStatus(u, ['Q2'], ComicStatus.unclassified);
      expect(db.orders(u), isEmpty);
    });

    test('pasarlo a un pedido real lo saca de "Compras sin pedido"', () {
      db.setStatus(u, ['Q1', 'Q2'], ComicStatus.purchased);
      final id = db.createOrder(u, store: 'Amazon', skus: ['Q1']);
      final loose = db.orders(u).firstWhere((o) => o.auto);
      expect(itemsOf(loose.id), {'Q2'});
      expect(itemsOf(id), {'Q1'});

      // Un cómic solo puede estar en un pedido pendiente.
      final other = db.createOrder(u, store: 'Otra', skus: ['Q1', 'Q2']);
      expect(itemsOf(id), isEmpty);
      expect(itemsOf(other), {'Q1', 'Q2'});
      expect(db.orders(u).where((o) => o.auto), isEmpty);
    });

    test('editar "Compras sin pedido" lo vuelve un pedido normal', () {
      db.setStatus(u, ['Q1'], ComicStatus.purchased);
      final loose = db.orders(u).single;
      db.updateOrder(u, loose.id, store: 'Panini', tracking: 'G1');
      final o = db.order(u, loose.id)!;
      expect(o.auto, isFalse);
      expect(o.title, 'Panini');
      // Lo próximo que se marque comprado va a un "sin pedido" nuevo.
      db.setStatus(u, ['Q2'], ComicStatus.purchased);
      expect(db.orders(u), hasLength(2));
    });

    test('recibir el pedido pasa todo a obtenido y se puede revertir', () {
      final id = db.createOrder(u, store: 'Panini', skus: ['Q1', 'Q2']);
      db.setOrderReceived(u, id, true);
      expect(db.order(u, id)!.received, isTrue);
      expect(db.order(u, id)!.ownedCount, 2);
      expect(st('Q1'), ComicStatus.owned);
      // Ya recibido: el historial no cambia aunque cambie el estado.
      db.setStatus(u, ['Q2'], ComicStatus.notInterested);
      expect(itemsOf(id), {'Q1', 'Q2'});

      db.setOrderReceived(u, id, false);
      expect(st('Q1'), ComicStatus.purchased);
      expect(st('Q2'), ComicStatus.purchased);
    });

    test('obtener un cómic suelto no lo saca del pedido pendiente', () {
      final id = db.createOrder(u, store: 'Panini', skus: ['Q1', 'Q2']);
      db.setStatus(u, ['Q1'], ComicStatus.owned);
      expect(itemsOf(id), {'Q1', 'Q2'});
      expect(db.order(u, id)!.ownedCount, 1);
      // Agregar uno ya obtenido a un pedido pendiente no lo regresa.
      db.addToOrder(u, id, ['Q3']);
      db.setStatus(u, ['Q4'], ComicStatus.owned);
      db.addToOrder(u, id, ['Q4']);
      expect(st('Q3'), ComicStatus.purchased);
      expect(st('Q4'), ComicStatus.owned);
    });

    test('quitar o borrar devuelve lo comprado a la wishlist', () {
      final id = db.createOrder(u, store: 'Panini', skus: ['Q1', 'Q2', 'Q3']);
      db.setStatus(u, ['Q3'], ComicStatus.owned);
      db.removeFromOrder(u, id, ['Q1']);
      expect(st('Q1'), ComicStatus.wishlist);
      expect(db.orders(u).where((o) => o.auto), isEmpty);

      db.deleteOrder(u, id);
      expect(st('Q2'), ComicStatus.wishlist);
      expect(st('Q3'), ComicStatus.owned);
      expect(db.orders(u), isEmpty);
    });

    test('no se pueden tocar pedidos de otro usuario', () {
      final otro = db.insertUser('otro', 'h', 's');
      final id = db.createOrder(otro, store: 'X', skus: ['Q1']);
      expect(db.order(u, id), isNull);
      expect(db.orderItems(u, id), isEmpty);
      expect(db.addToOrder(u, id, ['Q2']), 0);
      db.deleteOrder(u, id);
      db.setOrderReceived(u, id, true);
      expect(db.order(otro, id)!.count, 1);
      expect(db.order(otro, id)!.received, isFalse);
    });
  });

  group('carritos', () {
    test('suman el total, cuentan agotados y no cambian el estado', () {
      final c = db.createCart(u, 'Diciembre');
      expect(db.addToCart(u, c, ['Q1', 'Q5', 'Q1']), 2);
      expect(db.addToCart(u, c, ['Q1']), 0);
      final cart = db.carts(u).single;
      expect(cart.name, 'Diciembre');
      expect(cart.count, 2);
      expect(cart.total, 600);
      expect(cart.soldOut, 1);
      expect(st('Q1'), isNull);

      db.removeFromCart(u, c, ['Q5']);
      expect(db.cartItems(u, c).single.comic.sku, 'Q1');
      db.renameCart(u, c, 'Navidad');
      expect(db.carts(u).single.name, 'Navidad');
    });

    test('"Ya lo compré" lo convierte en pedido', () {
      final c = db.createCart(u, 'Diciembre');
      db.addToCart(u, c, ['Q1', 'Q2']);
      final id = db.cartToOrder(u, c, store: 'Panini', tracking: 'G9');
      expect(db.carts(u), isEmpty);
      expect(itemsOf(id), {'Q1', 'Q2'});
      expect(db.order(u, id)!.tracking, 'G9');
      expect(st('Q2'), ComicStatus.purchased);
    });

    test('otro usuario no puede agregar a mi carrito', () {
      final c = db.createCart(u, 'Mío');
      final otro = db.insertUser('otro', 'h', 's');
      expect(db.addToCart(otro, c, ['Q1']), 0);
      expect(db.cartItems(otro, c), isEmpty);
    });
  });

  test('respaldo: pedidos y carritos viajan y se restauran', () {
    final id = db.createOrder(u, store: 'Panini', tracking: 'G1', skus: ['Q1']);
    db.setOrderReceived(u, id, true);
    db.setStatus(u, ['Q2'], ComicStatus.purchased);
    final c = db.createCart(u, 'Futuro');
    db.addToCart(u, c, ['Q3']);
    final data = db.exportUserData(u);
    final summary = AppDatabase.inspectUserBackup(data);
    expect(summary.orders, 2);
    expect(summary.carts, 1);

    final other = AppDatabase.inMemory();
    final me = other.insertUser('alan', 'h', 's');
    other.importUserData(me, data);
    final orders = other.orders(me);
    expect(orders.map((o) => o.title), ['Compras sin pedido', 'Panini']);
    expect(orders.last.received, isTrue);
    expect(orders.last.tracking, 'G1');
    expect(other.carts(me).single.name, 'Futuro');
    expect(
      other.cartItems(me, other.carts(me).single.id).single.comic.sku,
      'Q3',
    );
  });

  test(
    'respaldo viejo sin pedidos: lo comprado queda en "Compras sin pedido"',
    () {
      db.setStatus(u, ['Q1'], ComicStatus.purchased);
      final data = db.exportUserData(u)
        ..remove('orders')
        ..remove('carts');
      final other = AppDatabase.inMemory();
      final me = other.insertUser('alan', 'h', 's');
      other.importUserData(me, data);
      expect(other.orders(me).single.auto, isTrue);
    },
  );

  test('migración v4 → v5: lo comprado queda en "Compras sin pedido"', () {
    final dir = Directory.systemTemp.createTempSync('cs_mig_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'old.db');
    // Base v4 mínima con un cómic comprado.
    final raw = sqlite3.open(path);
    raw.execute('''
      CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL UNIQUE COLLATE NOCASE, password_hash TEXT NOT NULL,
        salt TEXT NOT NULL, created_at TEXT NOT NULL);
      CREATE TABLE comics (sku TEXT PRIMARY KEY, name TEXT NOT NULL, url_key TEXT,
        series TEXT, series_code TEXT, number INTEGER, release_date TEXT,
        isbn TEXT, pages INTEGER, contains TEXT, price REAL, image_url TEXT,
        categories TEXT, item_type TEXT, stock_status TEXT, updated_at TEXT NOT NULL);
      CREATE TABLE ignored_skus (sku TEXT PRIMARY KEY);
      CREATE TABLE collections (id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL, name TEXT NOT NULL, created_at TEXT NOT NULL);
      CREATE TABLE collection_items (collection_id INTEGER NOT NULL, sku TEXT NOT NULL,
        owned INTEGER NOT NULL DEFAULT 0, added_at TEXT NOT NULL,
        PRIMARY KEY (collection_id, sku));
      CREATE TABLE comic_status (user_id INTEGER NOT NULL, sku TEXT NOT NULL,
        status TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (user_id, sku));
      CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT);
      INSERT INTO users VALUES (1, 'alan', 'h', 's', '2026');
      INSERT INTO comics (sku, name, updated_at) VALUES ('Q1', 'Uno', '2026');
      INSERT INTO comic_status VALUES (1, 'Q1', 'purchased', '2026');
      PRAGMA user_version = 4;
    ''');
    raw.close();

    final migrated = AppDatabase.openAt(path);
    addTearDown(migrated.close);
    final o = migrated.orders(1).single;
    expect(o.auto, isTrue);
    expect(o.count, 1);
  });
}

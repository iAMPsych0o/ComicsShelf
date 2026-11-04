import 'package:comics_panini/db/app_database.dart';
import 'package:comics_panini/models.dart';
import 'package:comics_panini/services/sync_flow.dart';
import 'package:comics_panini/services/sync_merge.dart';
import 'package:comics_panini/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un dispositivo de prueba con su usuario.
class Device {
  Device(this.name) : db = AppDatabase.inMemory() {
    user = User(id: db.insertUser('psych0o', 'h', 's'), username: 'psych0o');
    db.upsertComics([
      for (final sku in ['A', 'B', 'C', 'D', 'E'])
        Comic(sku: sku, name: 'Cómic $sku'),
    ]);
  }

  final AppDatabase db;
  late final User user;
  final String name;

  int get id => user.id;
}

/// Reemplazo [from] → [to]: los dos parten de lo mismo.
void replace(Device from, Device to) {
  final syncId = newSyncId();
  final revision = from.db.syncRevision(from.id);
  final data = replacePayload(from.db, from.id, syncId);
  applyReplace(to.db, to.user, ReceivedSync(from.name, data));
  confirmReplace(from.db, from.id, syncId, data, revision);
}

/// Combinación completa: [phone] pide y [pc] combina.
MergePlan merge(Device phone, Device pc) {
  final plan = planMerge(
    pc.db,
    pc.id,
    ReceivedSync(phone.name, mergePayload(phone.db, phone.id), merge: true),
  );
  applyMergeReply(phone.db, phone.user, plan.accepted);
  applyMerge(pc.db, pc.user, plan);
  return plan;
}

/// Datos comparables, sin ids locales ni "Compras sin pedido".
Map<String, Object?> content(Device d) =>
    SyncDoc.fromBackup(d.db.exportUserData(d.id)).toBackup();

void main() {
  late Device pc;
  late Device phone;

  setUp(() {
    pc = Device('PC');
    phone = Device('Teléfono');
  });
  tearDown(() {
    pc.db.close();
    phone.db.close();
  });

  void expectEqualDevices() {
    expect(content(phone), content(pc));
    expect(pc.db.hasUnsyncedChanges(pc.id), isFalse);
    expect(phone.db.hasUnsyncedChanges(phone.id), isFalse);
  }

  group('primera combinación, sin base y con uid distintos', () {
    /// El teléfono ya tenía lo de la PC, pero cada uno creó sus uid.
    void copyWithoutUids() {
      final data = pc.db.exportUserData(pc.id, fullCatalog: true);
      void strip(Object? rows) {
        for (final r in rows as List) {
          (r as Map).remove('uid');
        }
      }

      for (final section in ['collections', 'orders', 'carts', 'locations']) {
        strip(data[section]);
      }
      phone.db.importUserData(phone.id, data);
    }

    test('no duplica nada y junta lo de los dos lados', () {
      final c = pc.db.createCollection(pc.id, 'Batman');
      pc.db.addToCollection(pc.id, c, ['A']);
      pc.db.createCart(pc.id, 'Carrito');
      final shelf = pc.db.createLocation(pc.id, 'Closet');
      pc.db.setComicLocation(pc.id, ['A'], shelf);
      copyWithoutUids();

      pc.db.addToCollection(pc.id, c, ['B']);
      final id = phone.db.collections(phone.id).single.id;
      phone.db.addToCollection(phone.id, id, ['C']);
      phone.db.renameCollection(phone.id, id, 'Batman 2');

      final plan = merge(phone, pc);
      expect(plan.sharedBase, isFalse);
      expectEqualDevices();
      final merged = pc.db.collections(pc.id).single;
      // Sin base no se sabe quién renombró: se queda el nombre de la PC.
      expect(merged.name, 'Batman');
      expect(plan.result.notes.single, contains('el nombre'));
      expect(
        pc.db.collectionItems(pc.id, merged.id).map((i) => i.comic.sku),
        unorderedEquals(['A', 'B', 'C']),
      );
      expect(pc.db.carts(pc.id), hasLength(1));
      expect(pc.db.locations(pc.id), hasLength(1));
      expect(phone.db.syncId(phone.id), pc.db.syncId(pc.id));
    });

    test('pedidos con la misma fecha se distinguen por su guía', () {
      for (final tracking in ['G1', 'G2']) {
        pc.db.createOrder(
          pc.id,
          tracking: tracking,
          skus: [tracking == 'G1' ? 'A' : 'B'],
        );
      }
      final data = pc.db.exportUserData(pc.id, fullCatalog: true);
      for (final o in data['orders'] as List) {
        (o as Map)['created_at'] = '2026-09-16T12:00:00';
        o.remove('uid');
      }
      pc.db.importUserData(pc.id, {...data});
      for (final o in data['orders'] as List) {
        (o as Map).remove('uid');
      }
      phone.db.importUserData(phone.id, data);

      merge(phone, pc);
      expectEqualDevices();
      expect(pc.db.orders(pc.id), hasLength(2));
      expect(pc.db.orders(pc.id).map((o) => o.tracking).toSet(), {'G1', 'G2'});
    });

    test('lo creado aparte con el mismo nombre se junta', () {
      pc.db.createCollection(pc.id, 'Flash');
      phone.db.createCollection(phone.id, 'Flash');
      merge(phone, pc);
      expectEqualDevices();
      expect(pc.db.collections(pc.id), hasLength(1));
    });

    test('después ya hay base y los borrados se respetan', () {
      final c = pc.db.createCollection(pc.id, 'Se va');
      copyWithoutUids();
      merge(phone, pc);

      pc.db.deleteCollection(pc.id, pc.db.collections(pc.id).single.id);
      expect(c, isPositive);
      final plan = merge(phone, pc);
      expect(plan.sharedBase, isTrue);
      expectEqualDevices();
      expect(phone.db.collections(phone.id), isEmpty);
    });
  });

  test('el reemplazo conserva los uid y deja la misma base', () {
    final c = pc.db.createCollection(pc.id, 'Batman');
    pc.db.addToCollection(pc.id, c, ['A']);
    pc.db.createOrder(pc.id, tracking: 'G1', skus: ['B']);
    replace(pc, phone);

    expect(content(phone), content(pc));
    expect(phone.db.syncId(phone.id), pc.db.syncId(pc.id));
    expect(phone.db.syncBase(phone.id), pc.db.syncBase(pc.id));
    expect(phone.db.hasUnsyncedChanges(phone.id), isFalse);
    expect(pc.db.hasUnsyncedChanges(pc.id), isFalse);
  });

  test('cambios distintos en cada lado llegan a los dos', () {
    pc.db.setStatus(pc.id, ['A'], ComicStatus.wishlist);
    replace(pc, phone);

    pc.db.setStatus(pc.id, ['B'], ComicStatus.owned);
    pc.db.createCollection(pc.id, 'De la PC');
    phone.db.setStatus(phone.id, ['C'], ComicStatus.owned);
    phone.db.createCart(phone.id, 'Del teléfono');

    final plan = merge(phone, pc);
    expectEqualDevices();
    expect(plan.result.notes, isEmpty);
    expect(plan.result.toMine, 2);
    expect(plan.result.toTheirs, 2);
    expect(pc.db.statuses(pc.id), {
      'A': ComicStatus.wishlist,
      'B': ComicStatus.owned,
      'C': ComicStatus.owned,
    });
    expect(pc.db.collections(pc.id).single.name, 'De la PC');
    expect(pc.db.carts(pc.id).single.name, 'Del teléfono');
  });

  test('lo borrado en un lado se queda borrado', () {
    final c = pc.db.createCollection(pc.id, 'Batman');
    pc.db.addToCollection(pc.id, c, ['A', 'B']);
    final gone = pc.db.createCollection(pc.id, 'Se va');
    pc.db.setStatus(pc.id, ['C', 'D'], ComicStatus.wishlist);
    replace(pc, phone);

    pc.db.deleteCollection(pc.id, gone);
    pc.db.removeFromCollection(pc.id, c, 'A');
    phone.db.setStatus(phone.id, ['C'], ComicStatus.unclassified);

    merge(phone, pc);
    expectEqualDevices();
    final only = pc.db.collections(pc.id).single;
    expect(only.name, 'Batman');
    expect(pc.db.collectionItems(pc.id, only.id).single.comic.sku, 'B');
    expect(pc.db.statuses(pc.id), {'D': ComicStatus.wishlist});
  });

  test('cada lado cambia un campo distinto del mismo pedido', () {
    final o = pc.db.createOrder(pc.id, store: 'Panini', skus: ['A']);
    replace(pc, phone);

    pc.db.updateOrder(pc.id, o, store: 'Panini', notes: 'Regalo');
    final id = phone.db.orders(phone.id).single.id;
    phone.db.updateOrder(phone.id, id, store: 'Panini', tracking: 'G123');

    final plan = merge(phone, pc);
    expectEqualDevices();
    expect(plan.result.notes, isEmpty);
    final order = pc.db.orders(pc.id).single;
    expect(order.notes, 'Regalo');
    expect(order.tracking, 'G123');
  });

  test('el mismo estado cambiado en ambos: gana el más reciente', () async {
    pc.db.setStatus(pc.id, ['A'], ComicStatus.wishlist);
    replace(pc, phone);

    pc.db.setStatus(pc.id, ['A'], ComicStatus.notInterested);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    phone.db.setStatus(phone.id, ['A'], ComicStatus.owned);

    final plan = merge(phone, pc);
    expectEqualDevices();
    expect(plan.result.notes, hasLength(1));
    expect(pc.db.statuses(pc.id)['A'], ComicStatus.owned);
  });

  test('borrado en un lado y modificado en el otro se conserva', () {
    final c = pc.db.createCollection(pc.id, 'Batman');
    replace(pc, phone);

    pc.db.deleteCollection(pc.id, c);
    final id = phone.db.collections(phone.id).single.id;
    phone.db.addToCollection(phone.id, id, ['A']);

    final plan = merge(phone, pc);
    expectEqualDevices();
    expect(plan.result.notes.single, contains('Batman'));
    expect(pc.db.collections(pc.id).single.name, 'Batman');
  });

  test('un lugar borrado sigue si el otro guardó algo nuevo en él', () {
    final closet = pc.db.createLocation(pc.id, 'Closet');
    pc.db.setComicLocation(pc.id, ['A'], closet);
    replace(pc, phone);

    pc.db.deleteLocation(pc.id, closet);
    final id = phone.db.locations(phone.id).single.id;
    phone.db.setComicLocation(phone.id, ['B'], id);

    merge(phone, pc);
    expectEqualDevices();
    final place = pc.db.locations(pc.id).single;
    expect(place.name, 'Closet');
    expect(pc.db.locationItems(pc.id, place.id).single.comic.sku, 'B');
  });

  test('el orden de un lugar no se mezcla y los hijos sobreviven', () {
    final shelf = pc.db.createLocation(pc.id, 'Librero');
    final bin = pc.db.createLocation(pc.id, 'Caja', parentId: shelf);
    pc.db.setComicLocation(pc.id, ['A', 'B', 'C'], bin);
    pc.db.reorderLocation(pc.id, bin, ['A', 'B', 'C']);
    replace(pc, phone);

    final id = phone.db.locations(phone.id).last.id;
    phone.db.reorderLocation(phone.id, id, ['C', 'A', 'B']);
    pc.db.setStatus(pc.id, ['D'], ComicStatus.owned);

    merge(phone, pc);
    expectEqualDevices();
    final merged = pc.db.locations(pc.id).last;
    expect(merged.path, 'Librero › Caja');
    expect(pc.db.locationItems(pc.id, merged.id).map((i) => i.comic.sku), [
      'C',
      'A',
      'B',
    ]);
  });

  test('un cómic en dos pedidos pendientes queda en uno solo', () {
    replace(pc, phone);
    pc.db.createOrder(pc.id, tracking: 'PC', skus: ['A']);
    phone.db.createOrder(phone.id, tracking: 'TEL', skus: ['A']);

    final plan = merge(phone, pc);
    expectEqualDevices();
    expect(plan.result.notes, isNotEmpty);
    final withA = pc.db
        .orders(pc.id)
        .where((o) => pc.db.orderItems(pc.id, o.id).isNotEmpty);
    expect(withA, hasLength(1));
    expect(withA.single.tracking, 'TEL'); // el más nuevo
  });

  test('si ya no está comprado sale del pedido pendiente', () {
    final o = pc.db.createOrder(pc.id, tracking: 'G1', skus: ['A']);
    replace(pc, phone);

    // Un lado agrega otro cómic al pedido; el otro quita A marcándolo.
    pc.db.addToOrder(pc.id, o, ['B']);
    phone.db.setStatus(phone.id, ['A'], ComicStatus.wishlist);

    merge(phone, pc);
    expectEqualDevices();
    final order = pc.db.orders(pc.id).single;
    expect(pc.db.orderItems(pc.id, order.id).single.comic.sku, 'B');
    expect(pc.db.statuses(pc.id)['A'], ComicStatus.wishlist);
  });

  test('"Compras sin pedido" no se duplica', () {
    pc.db.setStatus(pc.id, ['A'], ComicStatus.purchased);
    replace(pc, phone);
    pc.db.setStatus(pc.id, ['B'], ComicStatus.purchased);
    phone.db.setStatus(phone.id, ['C'], ComicStatus.purchased);

    merge(phone, pc);
    expectEqualDevices();
    for (final d in [pc, phone]) {
      final auto = d.db.orders(d.id).where((o) => o.auto).single;
      expect(d.db.orderItems(d.id, auto.id).map((i) => i.comic.sku).toSet(), {
        'A',
        'B',
        'C',
      });
    }
  });

  test('los cómics que le faltan a cada catálogo llegan a los dos', () {
    replace(pc, phone);
    pc.db.upsertComics([const Comic(sku: 'SOLOPC', name: 'Solo PC')]);
    phone.db.upsertComics([const Comic(sku: 'SOLOTEL', name: 'Solo tel')]);
    phone.db.setStatus(phone.id, ['SOLOTEL'], ComicStatus.owned);

    merge(phone, pc);
    expectEqualDevices();
    expect(pc.db.statuses(pc.id)['SOLOTEL'], ComicStatus.owned);
    expect(pc.db.existingSkus(), contains('SOLOTEL'));
    expect(phone.db.existingSkus(), contains('SOLOPC'));
  });

  test('si la última combinación se cortó, no se borra nada', () {
    final keep = pc.db.createCollection(pc.id, 'Sigue');
    replace(pc, phone);
    pc.db.deleteCollection(pc.id, keep);
    // El teléfono aplicó una combinación que a la PC nunca le llegó.
    phone.db.saveSyncBase(phone.id, 'otra', content(phone));

    final plan = merge(phone, pc);
    expect(plan.sharedBase, isFalse);
    expectEqualDevices();
    expect(pc.db.collections(pc.id).single.name, 'Sigue');
  });

  test('combinar dos veces seguidas no cambia nada', () {
    pc.db.setStatus(pc.id, ['A'], ComicStatus.owned);
    replace(pc, phone);
    phone.db.createCart(phone.id, 'Carrito');
    merge(phone, pc);

    final again = merge(phone, pc);
    expect(again.result.toMine, 0);
    expect(again.result.toTheirs, 0);
    expect(again.result.notes, isEmpty);
    expectEqualDevices();
  });

  test('restaurar un respaldo solo cuenta lo que de verdad cambió', () {
    pc.db.setStatus(pc.id, ['A', 'B'], ComicStatus.wishlist);
    replace(pc, phone);
    final backup = phone.db.exportUserData(phone.id);
    phone.db.setStatus(phone.id, ['C'], ComicStatus.owned);
    phone.db.importUserData(phone.id, backup); // quita C de nuevo
    pc.db.setStatus(pc.id, ['D'], ComicStatus.owned);

    final plan = merge(phone, pc);
    expectEqualDevices();
    expect(plan.result.toMine, 0);
    expect(plan.result.toTheirs, 1);
  });
}

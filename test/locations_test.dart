import 'package:comics_panini/db/app_database.dart';
import 'package:comics_panini/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late int u;

  setUp(() {
    db = AppDatabase.inMemory();
    u = db.insertUser('psych0o', 'h', 's');
    db.upsertComics([
      for (var n = 1; n <= 4; n++)
        Comic(sku: 'L$n', name: 'Cómic $n', number: n, price: 100),
    ]);
  });

  test('los lugares se anidan y se listan en orden de árbol', () {
    final closet = db.createLocation(u, ' Closet 1 ');
    final bin4 = db.createLocation(u, 'Bin 4', parentId: closet);
    db.createLocation(u, 'Bin 2', parentId: closet);
    db.createLocation(u, 'Anaquel');
    db.setComicLocation(u, ['L1', 'L2'], bin4);
    db.setComicLocation(u, ['L3'], closet);

    final all = db.locations(u);
    expect(all.map((l) => l.path), [
      'Anaquel',
      'Closet 1',
      'Closet 1 › Bin 2',
      'Closet 1 › Bin 4',
    ]);
    final c = all.firstWhere((l) => l.id == closet);
    expect(c.count, 1);
    expect(c.totalCount, 3);
    expect(all.firstWhere((l) => l.id == bin4).depth, 1);
    expect(db.locationItems(u, bin4).map((i) => i.comic.sku), ['L1', 'L2']);
  });

  test('cada cómic está en un solo lugar: guardarlo en otro lo mueve', () {
    final a = db.createLocation(u, 'A');
    final b = db.createLocation(u, 'B');
    expect(db.setComicLocation(u, ['L1', 'L2'], a), 0);
    expect(db.setComicLocation(u, ['L1', 'L3'], b), 1);
    expect(db.skuLocations(u), {'L1': b, 'L2': a, 'L3': b});
    db.setComicLocation(u, ['L1'], null);
    expect(db.skuLocations(u).containsKey('L1'), isFalse);
  });

  test('borrar un lugar borra lo que contiene y libera sus cómics', () {
    final closet = db.createLocation(u, 'Closet');
    final bin = db.createLocation(u, 'Bin', parentId: closet);
    db.setComicLocation(u, ['L1'], bin);
    db.deleteLocation(u, closet);
    expect(db.locations(u), isEmpty);
    expect(db.skuLocations(u), isEmpty);
  });

  test('obtenidos sin ubicación', () {
    db.setStatus(u, ['L1', 'L2'], ComicStatus.owned);
    db.setComicLocation(u, ['L1'], db.createLocation(u, 'A'));
    expect(db.ownedWithoutLocation(u).map((i) => i.comic.sku), ['L2']);
  });

  test('no se pueden usar lugares de otro usuario', () {
    final other = db.insertUser('otro', 'h', 's');
    final theirs = db.createLocation(other, 'Suyo');
    db.setComicLocation(u, ['L1'], theirs);
    expect(db.skuLocations(u), isEmpty);
    expect(db.locationItems(u, theirs), isEmpty);
    expect(
      () => db.createLocation(u, 'Dentro', parentId: theirs),
      throwsArgumentError,
    );
  });

  test('el respaldo conserva lugares anidados y dónde está cada cómic', () {
    final closet = db.createLocation(u, 'Closet 1');
    final bin = db.createLocation(u, 'Bin 4', parentId: closet);
    db.setComicLocation(u, ['L1'], bin);
    db.setComicLocation(u, ['L2'], closet);
    final data = db.exportUserData(u);
    expect(AppDatabase.inspectUserBackup(data).locations, 2);

    final other = AppDatabase.inMemory();
    final me = other.insertUser('psych0o', 'h', 's');
    other.createLocation(me, 'Se reemplaza');
    other.importUserData(me, data);
    final places = other.locations(me);
    expect(places.map((l) => l.path), ['Closet 1', 'Closet 1 › Bin 4']);
    final byPath = {for (final l in places) l.path: l.id};
    expect(other.skuLocations(me), {
      'L1': byPath['Closet 1 › Bin 4'],
      'L2': byPath['Closet 1'],
    });
  });

  group('orden físico dentro de un lugar', () {
    late int bin;
    List<String> order() =>
        db.locationItems(u, bin).map((i) => i.comic.sku).toList();

    setUp(() {
      bin = db.createLocation(u, 'Bin');
      db.setComicLocation(u, ['L1', 'L2', 'L3'], bin);
    });

    test('sin acomodar sigue por número; acomodado respeta el orden', () {
      expect(order(), ['L1', 'L2', 'L3']);
      expect(db.hasManualOrder(u, bin), isFalse);
      db.reorderLocation(u, bin, ['L3', 'L1', 'L2']);
      expect(order(), ['L3', 'L1', 'L2']);
      expect(db.hasManualOrder(u, bin), isTrue);
    });

    test('lo que llega después queda al final', () {
      db.reorderLocation(u, bin, ['L3', 'L2', 'L1']);
      db.setComicLocation(u, ['L4'], bin);
      expect(order(), ['L3', 'L2', 'L1', 'L4']);
    });

    test('al salir y volver pierde su lugar, sin afectar a los demás', () {
      db.reorderLocation(u, bin, ['L3', 'L2', 'L1']);
      db.setComicLocation(u, ['L3'], null);
      expect(order(), ['L2', 'L1']);
      db.setComicLocation(u, ['L3'], bin);
      expect(order(), ['L2', 'L1', 'L3']);
    });

    test('no toca cómics de otro lugar ni de otro usuario', () {
      final other = db.createLocation(u, 'Otro');
      db.setComicLocation(u, ['L4'], other);
      db.reorderLocation(u, bin, ['L4', 'L2']);
      expect(db.hasManualOrder(u, other), isFalse);
      final stranger = db.insertUser('otro', 'h', 's');
      db.reorderLocation(stranger, bin, ['L3', 'L1']);
      expect(order(), ['L2', 'L1', 'L3']);
    });

    test('el respaldo conserva el orden, y acepta respaldos sin él', () {
      db.reorderLocation(u, bin, ['L2', 'L3', 'L1']);
      final data = db.exportUserData(u);

      final other = AppDatabase.inMemory();
      final me = other.insertUser('psych0o', 'h', 's');
      other.importUserData(me, data);
      final place = other.locations(me).single.id;
      expect(other.locationItems(me, place).map((i) => i.comic.sku), [
        'L2',
        'L3',
        'L1',
      ]);

      for (final s in data['stored'] as List) {
        (s as Map).remove('position');
      }
      other.importUserData(me, data);
      final again = other.locations(me).single.id;
      expect(other.hasManualOrder(me, again), isFalse);
    });
  });
}

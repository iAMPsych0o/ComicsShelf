import '../db/app_database.dart';

/// Combinación a tres bandas de los datos de un usuario entre dos dispositivos.
///
/// Se compara lo de cada dispositivo contra la copia base (cómo quedaron los
/// dos en la última sincronización): lo que cambió en un solo lado se aplica
/// y solo hay conflicto si cambió lo mismo en ambos. Sin base nada cuenta como
/// borrado, así que el resultado es una unión; además, como cada dispositivo
/// pudo crear sus propios uid, primero se empareja lo que es lo mismo.
///
/// Las reglas de conflicto: estados y ubicaciones se quedan con el cambio más
/// reciente; los demás campos, con el valor del dispositivo que combina; y lo
/// que se borró en un lado y se modificó en el otro se conserva.

/// Datos de un usuario listos para comparar: cada sección va por una clave
/// que es la misma en los dos dispositivos (uid o sku) y sin ids locales.
class SyncDoc {
  SyncDoc({
    Map<String, Map<String, Object?>>? collections,
    Map<String, Map<String, Object?>>? statuses,
    Map<String, Map<String, Object?>>? orders,
    Map<String, Map<String, Object?>>? carts,
    Map<String, Map<String, Object?>>? locations,
    Map<String, Map<String, Object?>>? stored,
  }) : collections = collections ?? {},
       statuses = statuses ?? {},
       orders = orders ?? {},
       carts = carts ?? {},
       locations = locations ?? {},
       stored = stored ?? {};

  final Map<String, Map<String, Object?>> collections;
  final Map<String, Map<String, Object?>> statuses;
  final Map<String, Map<String, Object?>> orders;
  final Map<String, Map<String, Object?>> carts;
  final Map<String, Map<String, Object?>> locations;
  final Map<String, Map<String, Object?>> stored;

  List<Map<String, Map<String, Object?>>> get _sections => [
    collections,
    statuses,
    orders,
    carts,
    locations,
    stored,
  ];

  /// Lee un respaldo. "Compras sin pedido" no se incluye: cada dispositivo la
  /// recalcula a partir de los estados.
  factory SyncDoc.fromBackup(Map<String, Object?> data) {
    // Sin uid (respaldos anteriores) cada fila es distinta aunque coincida
    // la fecha; al combinar se empareja por su contenido.
    var unnamed = 0;
    String uidOf(Map r) => r['uid'] as String? ?? 'sin-uid-${unnamed++}';
    List<Map> rows(String key) =>
        (data[key] as List? ?? const []).whereType<Map>().toList();
    Map<String, Object?> items(Object? raw) => {
      for (final i in raw as List? ?? const [])
        if (i is Map) i['sku'] as String: i['added_at'] else i as String: null,
    };
    Map<String, Object?> named(Map r) => {
      'name': r['name'],
      'created_at': r['created_at'],
      'items': items(r['items']),
    };

    final places = rows('locations');
    final placeUids = {for (final l in places) l['id']: uidOf(l)};
    return SyncDoc(
      collections: {for (final c in rows('collections')) uidOf(c): named(c)},
      carts: {for (final c in rows('carts')) uidOf(c): named(c)},
      statuses: {
        for (final s in rows('statuses'))
          s['sku'] as String: {
            'status': s['status'],
            'updated_at': s['updated_at'],
          },
      },
      orders: {
        for (final o in rows('orders'))
          if (o['auto'] != true || o['received_at'] != null)
            uidOf(o): {
              'store': o['store'],
              'tracking': o['tracking'],
              'carrier': o['carrier'],
              'notes': o['notes'],
              'auto': o['auto'] == true,
              'created_at': o['created_at'],
              'received_at': o['received_at'],
              'items': items(o['items']),
            },
      },
      locations: {
        for (final l in places)
          uidOf(l): {
            'name': l['name'],
            'created_at': l['created_at'],
            'parent': placeUids[l['parent']],
          },
      },
      stored: {
        for (final s in rows('stored'))
          if (placeUids[s['location']] != null)
            s['sku'] as String: {
              'location': placeUids[s['location']],
              'stored_at': s['stored_at'],
              'position': s['position'],
            },
      },
    );
  }

  /// Formato de respaldo, sin catálogo; los lugares usan su uid como id.
  Map<String, Object?> toBackup() {
    List<Map<String, Object?>> named(Map<String, Map<String, Object?>> rows) =>
        [
          for (final e in rows.entries)
            {
              'uid': e.key,
              'name': e.value['name'],
              'created_at': e.value['created_at'],
              'items': [
                for (final i in (e.value['items'] as Map).entries)
                  {'sku': i.key, 'added_at': i.value},
              ],
            },
        ];
    return {
      'app': 'ComicShelf',
      'format': AppDatabase.backupFormat,
      'collections': named(collections),
      'statuses': [
        for (final e in statuses.entries) {'sku': e.key, ...e.value},
      ],
      'orders': [
        for (final e in orders.entries)
          {
            'uid': e.key,
            ...e.value,
            'items': (e.value['items'] as Map).keys.toList(),
          },
      ],
      'carts': named(carts),
      'locations': [
        for (final e in locations.entries)
          {
            'id': e.key,
            'uid': e.key,
            'name': e.value['name'],
            'created_at': e.value['created_at'],
            'parent': e.value['parent'],
          },
      ],
      'stored': [
        for (final e in stored.entries) {'sku': e.key, ...e.value},
      ],
      'comics': const <Object?>[],
    };
  }

  /// Cuántos elementos habría que cambiar para pasar de esto a [other].
  int differencesWith(SyncDoc other) {
    var n = 0;
    final mine = _sections;
    final theirs = other._sections;
    for (var i = 0; i < mine.length; i++) {
      for (final key in {...mine[i].keys, ...theirs[i].keys}) {
        if (!_same(mine[i][key], theirs[i][key])) n++;
      }
    }
    return n;
  }
}

/// Resultado de combinar: [doc] va a los dos dispositivos.
class MergeResult {
  const MergeResult({
    required this.doc,
    required this.toMine,
    required this.toTheirs,
    required this.notes,
  });

  final SyncDoc doc;

  /// Cambios que llegan a cada dispositivo.
  final int toMine;
  final int toTheirs;

  /// Conflictos resueltos y ajustes, para mostrarlos en el resumen.
  final List<String> notes;
}

bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _same(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Combina [mine] y [theirs] (respaldos con catálogo) contra [base], o como
/// unión si no hay base común.
MergeResult mergeUserData({
  Map<String, Object?>? base,
  required Map<String, Object?> mine,
  required Map<String, Object?> theirs,
}) {
  final myDoc = SyncDoc.fromBackup(mine);
  final theirDoc = SyncDoc.fromBackup(theirs);
  final merge = _Merge(
    base == null ? SyncDoc() : SyncDoc.fromBackup(base),
    myDoc,
    base == null ? _alignedTo(myDoc, theirDoc) : theirDoc,
    {
      for (final source in [mine, theirs])
        for (final c in (source['comics'] as List? ?? const []))
          if (c is Map) c['sku']: c['name'],
    },
  );
  final doc = merge.run();
  return MergeResult(
    doc: doc,
    toMine: merge.m.differencesWith(doc),
    toTheirs: merge.t.differencesWith(doc),
    notes: merge.notes,
  );
}

const _fieldLabels = {
  'name': 'el nombre',
  'store': 'la tienda',
  'tracking': 'la guía',
  'carrier': 'la paquetería',
  'notes': 'las notas',
  'received_at': 'la recepción',
  'parent': 'el lugar padre',
};

/// Empareja cada fila de [theirs] con una de [mine] probando las [keys] en
/// orden, y devuelve uid de ellos → uid nuestro.
Map<String, String> _match(
  Map<String, Map<String, Object?>> mine,
  Map<String, Map<String, Object?>> theirs,
  List<String? Function(String uid, Map<String, Object?> row)> keys, {
  bool Function(Map<String, Object?> a, Map<String, Object?> b)? compatible,
}) {
  final renames = <String, String>{};
  final freeMine = mine.keys.where((k) => !theirs.containsKey(k)).toList();
  final freeTheirs = theirs.keys.where((k) => !mine.containsKey(k)).toList();
  for (final key in keys) {
    for (final uid in freeTheirs.toList()) {
      final wanted = key(uid, theirs[uid]!);
      if (wanted == null) continue;
      for (final candidate in freeMine) {
        if (key(candidate, mine[candidate]!) == wanted &&
            (compatible?.call(mine[candidate]!, theirs[uid]!) ?? true)) {
          renames[uid] = candidate;
          freeMine.remove(candidate);
          freeTheirs.remove(uid);
          break;
        }
      }
    }
  }
  return renames;
}

/// [theirs] con los uid de [mine] en lo que es lo mismo. Las colecciones y los
/// demás conservan `created_at` al sincronizar; si no coincide se comparan los
/// nombres, y los pedidos por su guía.
SyncDoc _alignedTo(SyncDoc mine, SyncDoc theirs) {
  String? created(String _, Map<String, Object?> r) =>
      r['created_at'] as String?;
  String? createdAndName(String _, Map<String, Object?> r) =>
      '${r['created_at']}|${r['name']}';
  String? name(String _, Map<String, Object?> r) => r['name'] as String?;

  String path(SyncDoc doc, String uid) {
    final row = doc.locations[uid];
    if (row == null) return '';
    return '${path(doc, row['parent'] as String? ?? '')}/${row['name']}';
  }

  final places = _match(mine.locations, theirs.locations, [
    createdAndName,
    created,
    (uid, r) => path(identical(r, theirs.locations[uid]) ? theirs : mine, uid),
  ]);
  final orders = _match(
    mine.orders,
    theirs.orders,
    [
      (_, r) => r['tracking'] as String?,
      (_, r) => '${r['created_at']}|${r['store']}',
    ],
    compatible: (a, b) =>
        a['tracking'] == null ||
        b['tracking'] == null ||
        a['tracking'] == b['tracking'],
  );
  Map<String, Map<String, Object?>> renamed(
    Map<String, Map<String, Object?>> rows,
    Map<String, String> renames,
  ) => {for (final e in rows.entries) renames[e.key] ?? e.key: e.value};

  final named = [createdAndName, created, name];
  return SyncDoc(
    collections: renamed(
      theirs.collections,
      _match(mine.collections, theirs.collections, named),
    ),
    carts: renamed(theirs.carts, _match(mine.carts, theirs.carts, named)),
    orders: renamed(theirs.orders, orders),
    statuses: theirs.statuses,
    locations: {
      for (final e in theirs.locations.entries)
        places[e.key] ?? e.key: {
          ...e.value,
          'parent': places[e.value['parent']] ?? e.value['parent'],
        },
    },
    stored: {
      for (final e in theirs.stored.entries)
        e.key: {
          ...e.value,
          'location': places[e.value['location']] ?? e.value['location'],
        },
    },
  );
}

class _Merge {
  _Merge(this.b, this.m, this.t, this.comicNames);

  final SyncDoc b;
  final SyncDoc m;
  final SyncDoc t;
  final Map<Object?, Object?> comicNames;
  final notes = <String>[];

  String _comic(String sku) => '"${comicNames[sku] ?? sku}"';
  static String _named(String kind, Map<String, Object?> row) =>
      '$kind "${row['name']}"';
  static String _order(Map<String, Object?> o) =>
      'el pedido ${o['tracking'] ?? o['store'] ?? o['created_at']}';

  SyncDoc run() {
    final locations = _section(
      b.locations,
      m.locations,
      t.locations,
      (row) => _named('el lugar', row),
      ['name', 'created_at', 'parent'],
    );
    final stored = _mergeStored();
    _keepUsedLocations(locations, stored);
    _mergePositions(stored);
    final doc = SyncDoc(
      collections: _section(
        b.collections,
        m.collections,
        t.collections,
        (row) => _named('la colección', row),
        ['name', 'created_at'],
      ),
      carts: _section(
        b.carts,
        m.carts,
        t.carts,
        (row) => _named('el carrito', row),
        ['name', 'created_at'],
      ),
      orders: _section(b.orders, m.orders, t.orders, _order, [
        'store',
        'tracking',
        'carrier',
        'notes',
        'auto',
        'created_at',
        'received_at',
      ]),
      statuses: _mergeStatuses(),
      locations: locations,
      stored: stored,
    );
    _repairOrders(doc);
    return doc;
  }

  /// Altas y bajas de una sección. [both] resuelve lo que está en los dos.
  Map<String, Map<String, Object?>> _threeWay(
    Map<String, Map<String, Object?>> base,
    Map<String, Map<String, Object?>> mine,
    Map<String, Map<String, Object?>> theirs,
    String Function(String key, Map<String, Object?> row) label,
    Map<String, Object?> Function(
      String key,
      Map<String, Object?>? base,
      Map<String, Object?> mine,
      Map<String, Object?> theirs,
    )
    both,
  ) {
    final out = <String, Map<String, Object?>>{};
    for (final key in {...mine.keys, ...theirs.keys}) {
      final mineRow = mine[key];
      final theirRow = theirs[key];
      if (mineRow != null && theirRow != null) {
        out[key] = both(key, base[key], mineRow, theirRow);
        continue;
      }
      final survivor = (mineRow ?? theirRow)!;
      final before = base[key];
      if (before == null) {
        out[key] = survivor; // nuevo en un lado
      } else if (!_same(before, survivor)) {
        out[key] = survivor; // borrado en uno y modificado en el otro
        notes.add(
          'Se conservó ${label(key, survivor)}: se borró en un dispositivo '
          'y se modificó en el otro.',
        );
      }
      // Sin cambios aquí y borrado allá: se queda borrado.
    }
    return out;
  }

  /// Sección cuyas filas se combinan campo por campo y por sus cómics.
  Map<String, Map<String, Object?>> _section(
    Map<String, Map<String, Object?>> base,
    Map<String, Map<String, Object?>> mine,
    Map<String, Map<String, Object?>> theirs,
    String Function(Map<String, Object?> row) label,
    List<String> fields,
  ) => _threeWay(base, mine, theirs, (_, row) => label(row), (
    _,
    bRow,
    mRow,
    tRow,
  ) {
    final out = {...mRow};
    for (final f in fields) {
      if (_same(mRow[f], tRow[f])) continue;
      if (bRow == null && f == 'created_at') continue;
      if (_same(mRow[f], bRow?[f])) {
        out[f] = tRow[f];
      } else if (f != 'created_at' && !_same(tRow[f], bRow?[f])) {
        notes.add(
          'En ${label(mRow)} cambió ${_fieldLabels[f] ?? f} en los dos dispositivos: '
          'se quedó el valor de este.',
        );
      }
    }
    if (mRow['items'] is Map) {
      out['items'] = _mergeItems(
        bRow?['items'] as Map?,
        mRow['items'] as Map,
        tRow['items'] as Map,
      );
    }
    return out;
  });

  static Map<String, Object?> _mergeItems(Map? base, Map mine, Map theirs) => {
    for (final e in mine.entries)
      if (theirs.containsKey(e.key) || !(base?.containsKey(e.key) ?? false))
        e.key as String: e.value,
    for (final e in theirs.entries)
      if (!mine.containsKey(e.key) && !(base?.containsKey(e.key) ?? false))
        e.key as String: e.value,
  };

  /// Elige entre dos filas por el campo [field]; si cambió en ambos, gana la
  /// fecha [date] más reciente.
  Map<String, Object?> _byDate(
    String field,
    String date,
    Map<String, Object?>? base,
    Map<String, Object?> mine,
    Map<String, Object?> theirs,
    String conflict,
  ) {
    bool newer(Map<String, Object?> a, Map<String, Object?> b) =>
        '${a[date]}'.compareTo('${b[date]}') >= 0;
    if (_same(mine[field], theirs[field])) {
      return newer(mine, theirs) ? mine : theirs;
    }
    if (_same(mine[field], base?[field])) return theirs;
    if (_same(theirs[field], base?[field])) return mine;
    notes.add(conflict);
    return newer(mine, theirs) ? mine : theirs;
  }

  Map<String, Map<String, Object?>> _mergeStatuses() => _threeWay(
    b.statuses,
    m.statuses,
    t.statuses,
    (sku, _) => 'el estado de ${_comic(sku)}',
    (sku, base, mine, theirs) => _byDate(
      'status',
      'updated_at',
      base,
      mine,
      theirs,
      'El estado de ${_comic(sku)} cambió en los dos dispositivos: '
          'quedó el más reciente.',
    ),
  );

  /// Dónde está cada cómic; el orden dentro de cada lugar va aparte.
  Map<String, Map<String, Object?>> _mergeStored() {
    Map<String, Map<String, Object?>> places(
      Map<String, Map<String, Object?>> rows,
    ) => {
      for (final e in rows.entries)
        e.key: {
          'location': e.value['location'],
          'stored_at': e.value['stored_at'],
        },
    };
    final out = <String, Map<String, Object?>>{};
    final mine = places(m.stored);
    final theirs = places(t.stored);
    final merged = _threeWay(
      places(b.stored),
      mine,
      theirs,
      (sku, _) => 'la ubicación de ${_comic(sku)}',
      (sku, base, mRow, tRow) => {
        ...mRow,
        ..._byDate(
          'location',
          'stored_at',
          base,
          mRow,
          tRow,
          'Un cómic se movió de lugar en los dos dispositivos: quedó el '
              'cambio más reciente.',
        ),
      },
    );
    for (final e in merged.entries) {
      out[e.key] = {...e.value, 'position': null};
    }
    return out;
  }

  /// Un lugar borrado en un lado sigue existiendo si el otro guardó algo
  /// nuevo en él o creó un lugar dentro.
  void _keepUsedLocations(
    Map<String, Map<String, Object?>> locations,
    Map<String, Map<String, Object?>> stored,
  ) {
    void keep(String? uid) {
      while (uid != null && !locations.containsKey(uid)) {
        final row = m.locations[uid] ?? t.locations[uid];
        if (row == null) return;
        locations[uid] = row;
        notes.add(
          'Se conservó el lugar "${row['name']}": se borró en un dispositivo '
          'y el otro lo seguía usando.',
        );
        uid = row['parent'] as String?;
      }
    }

    for (final s in stored.values) {
      keep(s['location'] as String?);
    }
    for (final uid in locations.keys.toList()) {
      keep(locations[uid]?['parent'] as String?);
    }
    stored.removeWhere((_, s) => !locations.containsKey(s['location']));
  }

  /// El orden de un lugar no se mezcla: gana el lado que lo cambió.
  void _mergePositions(Map<String, Map<String, Object?>> stored) {
    List<String> order(SyncDoc doc, Object? location) {
      final rows =
          doc.stored.entries
              .where(
                (e) =>
                    e.value['location'] == location &&
                    e.value['position'] != null,
              )
              .toList()
            ..sort(
              (x, y) => (x.value['position'] as int).compareTo(
                y.value['position'] as int,
              ),
            );
      return rows.map((e) => e.key).toList();
    }

    for (final location in stored.values.map((s) => s['location']).toSet()) {
      final mine = order(m, location);
      final theirs = order(t, location);
      final chosen = _same(mine, order(b, location)) ? theirs : mine;
      var position = 0;
      for (final sku in chosen) {
        final row = stored[sku];
        if (row != null && row['location'] == location) {
          row['position'] = position++;
        }
      }
    }
  }

  /// Deja los pedidos como los dejaría la app: el estado manda, un cómic que
  /// ya no está comprado sale de los pendientes y nadie queda en dos.
  void _repairOrders(SyncDoc doc) {
    final pending = doc.orders.entries
        .where((e) => e.value['received_at'] == null)
        .toList();
    // Del más nuevo al más viejo: cada cómic se queda en el primero.
    pending.sort((x, y) {
      final byDate = '${y.value['created_at']}'.compareTo(
        '${x.value['created_at']}',
      );
      return byDate != 0 ? byDate : x.key.compareTo(y.key);
    });
    final placed = <String>{};
    for (final o in pending) {
      final items = {...(o.value['items'] as Map)};
      for (final sku in items.keys.cast<String>().toList()) {
        final status = doc.statuses[sku]?['status'];
        if (status != 'purchased' && status != 'owned') {
          items.remove(sku);
          notes.add(
            '${_comic(sku)} salió de ${_order(o.value)}: ya no está marcado '
            'como comprado.',
          );
        } else if (!placed.add(sku)) {
          items.remove(sku);
          notes.add(
            '${_comic(sku)} estaba en dos pedidos pendientes: quedó en el '
            'más nuevo.',
          );
        }
      }
      o.value['items'] = items;
    }
  }
}

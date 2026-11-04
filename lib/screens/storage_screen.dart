import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../db/app_database.dart';
import '../models.dart';
import '../widgets/comic_picker.dart';
import '../widgets/comic_widgets.dart';
import 'home_shell.dart';

/// Almacenamiento: lugares donde guardas los cómics ("Closet 1 › Bin 4").
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key, required this.changes});

  final DataChanges changes;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  List<StorageLocation> _places = [];
  int _unlocated = 0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_reload);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _reload();
    }
  }

  @override
  void dispose() {
    widget.changes.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    final scope = AppScope.of(context);
    setState(() {
      _places = scope.db.locations(scope.user.id);
      _unlocated = scope.db.ownedWithoutLocation(scope.user.id).length;
    });
  }

  Future<void> _open(int? id) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            LocationDetailScreen(locationId: id, changes: widget.changes),
      ),
    );
    widget.changes.changed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stored = _places.fold(0, (s, l) => s + l.count);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new_location',
        onPressed: () => createLocation(context, widget.changes),
        icon: const Icon(Icons.add),
        label: const Text('Nueva ubicación'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              leading: const CircleAvatar(
                backgroundColor: Color(0xFF262626),
                child: Icon(Icons.shelves, color: Colors.white),
              ),
              title: Text(
                '$stored cómics guardados en ${_places.length} '
                '${_places.length == 1 ? 'ubicación' : 'ubicaciones'}',
                style: theme.textTheme.titleMedium,
              ),
              subtitle: Text(
                _unlocated == 0
                    ? 'Todos tus obtenidos tienen ubicación.'
                    : '$_unlocated obtenidos sin ubicación.',
              ),
              trailing: _unlocated == 0
                  ? null
                  : TextButton(
                      onPressed: () => _open(null),
                      child: const Text('Acomodar'),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          if (_places.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(
                    Icons.shelves,
                    size: 56,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Da de alta dónde guardas tus cómics: un mueble como '
                    '"Closet 1" y, dentro, cajas como "Bin 4".',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          for (final l in _places)
            Padding(
              padding: EdgeInsets.only(left: 24.0 * l.depth, bottom: 8),
              child: Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  leading: Icon(locationIcon(l.depth)),
                  title: Text(l.name, style: theme.textTheme.titleMedium),
                  subtitle: Text(_countText(l)),
                  onTap: () => _open(l.id),
                  trailing: LocationMenu(location: l, changes: widget.changes),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _countText(StorageLocation l) {
  final here = l.count == 1 ? '1 cómic' : '${l.count} cómics';
  return l.totalCount == l.count
      ? here
      : '$here · ${l.totalCount} con lo de adentro';
}

/// Pide el nombre y crea un lugar (dentro de [parent] si se indica).
Future<int?> createLocation(
  BuildContext context,
  DataChanges changes, {
  StorageLocation? parent,
}) async {
  final scope = AppScope.of(context);
  final name = await askText(
    context,
    title: parent == null
        ? 'Nueva ubicación'
        : 'Nueva dentro de ${parent.path}',
    label: parent == null ? 'Nombre (ej. Closet 1)' : 'Nombre (ej. Bin 4)',
  );
  if (name == null) return null;
  final id = scope.db.createLocation(scope.user.id, name, parentId: parent?.id);
  changes.changed();
  return id;
}

/// Menú ⋮ de un lugar: agregar dentro, renombrar y eliminar.
class LocationMenu extends StatelessWidget {
  const LocationMenu({
    super.key,
    required this.location,
    required this.changes,
    this.onDeleted,
  });

  final StorageLocation location;
  final DataChanges changes;
  final VoidCallback? onDeleted;

  Future<void> _rename(BuildContext context) async {
    final scope = AppScope.of(context);
    final name = await askText(
      context,
      title: 'Renombrar ubicación',
      label: 'Nombre',
      initial: location.name,
    );
    if (name == null) return;
    scope.db.renameLocation(scope.user.id, location.id, name);
    changes.changed();
  }

  Future<void> _delete(BuildContext context) async {
    final scope = AppScope.of(context);
    final inside = scope.db
        .locations(scope.user.id)
        .where(
          (l) => l.path.startsWith(
            '${location.path}${AppDatabase.locationSeparator}',
          ),
        )
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar ubicación'),
        content: Text(
          [
            '¿Eliminar "${location.path}"?',
            if (inside > 0)
              'También se eliminan las $inside ubicaciones que tiene dentro.',
            if (location.totalCount > 0)
              'Sus ${location.totalCount} cómics quedan sin ubicación '
                  '(siguen en tu colección).',
          ].join(' '),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    scope.db.deleteLocation(scope.user.id, location.id);
    changes.changed();
    onDeleted?.call();
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Opciones de la ubicación',
    onSelected: (v) => switch (v) {
      'inside' => createLocation(context, changes, parent: location),
      'rename' => _rename(context),
      _ => _delete(context),
    },
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: 'inside',
        child: ListTile(
          leading: Icon(Icons.create_new_folder_outlined),
          title: Text('Agregar dentro…'),
        ),
      ),
      PopupMenuItem(
        value: 'rename',
        child: ListTile(
          leading: Icon(Icons.edit_outlined),
          title: Text('Renombrar'),
        ),
      ),
      PopupMenuItem(
        value: 'delete',
        child: ListTile(
          leading: Icon(Icons.delete_outline),
          title: Text('Eliminar'),
        ),
      ),
    ],
  );
}

/// Cómics de un lugar, con lo que tiene dentro. Con [locationId] null
/// muestra los obtenidos que aún no tienen lugar, para acomodarlos.
class LocationDetailScreen extends StatefulWidget {
  const LocationDetailScreen({
    super.key,
    required this.locationId,
    required this.changes,
  });

  final int? locationId;
  final DataChanges changes;

  @override
  State<LocationDetailScreen> createState() => _LocationDetailScreenState();
}

class _LocationDetailScreenState extends State<LocationDetailScreen> {
  StorageLocation? _place;
  List<StorageLocation> _inside = [];
  List<CollectionItem> _items = [];
  final Set<String> _selected = {};
  bool _loaded = false;
  bool _gone = false;

  // Modo "Ordenar": el orden se ve en vivo en _items y se guarda al soltar.
  final _grid = GlobalKey();
  final _scroll = ScrollController();
  bool _ordering = false;
  String? _dragging;
  List<String> _orderBefore = const [];
  int _pointers = 0;
  double _edgeSpeed = 0;
  Timer? _edgeScroll;

  bool get _unlocated => widget.locationId == null;

  List<String> get _skus => [for (final i in _items) i.comic.sku];

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_reload);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _reload();
    }
  }

  @override
  void dispose() {
    widget.changes.removeListener(_reload);
    _edgeScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    final scope = AppScope.of(context);
    final uid = scope.user.id;
    final places = scope.db.locations(uid);
    setState(() {
      if (_unlocated) {
        _items = scope.db.ownedWithoutLocation(uid);
      } else {
        _place = places.where((l) => l.id == widget.locationId).firstOrNull;
        _gone = _place == null;
        _inside = [
          for (final l in places)
            if (l.parentId == widget.locationId) l,
        ];
        _items = _gone ? [] : scope.db.locationItems(uid, widget.locationId!);
      }
      _selected.retainAll(_items.map((i) => i.comic.sku));
    });
  }

  void _toggle(String sku) => setState(
    () => _selected.contains(sku) ? _selected.remove(sku) : _selected.add(sku),
  );

  Future<void> _addComics() async {
    final picked = await pickComics(
      context,
      title: 'Guardar en ${_place!.name}',
      already: {for (final i in _items) i.comic.sku},
      alreadyLabel: 'Ya está aquí',
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final scope = AppScope.of(context);
    final moved = scope.db.setComicLocation(
      scope.user.id,
      picked,
      widget.locationId,
    );
    widget.changes.changed();
    showNotice(
      ScaffoldMessenger.of(context),
      '${picked.length} guardado(s) en ${_place!.path}'
      '${moved > 0 ? ' ($moved venían de otra ubicación)' : ''}',
    );
  }

  void _startDrag(String sku) => setState(() {
    _dragging = sku;
    _orderBefore = _skus;
  });

  /// Abre el hueco en la celda sobre la que va pasando el cómic arrastrado.
  void _dragOver(String sku) {
    final from = _items.indexWhere((i) => i.comic.sku == _dragging);
    final to = _items.indexWhere((i) => i.comic.sku == sku);
    if (from < 0 || to < 0 || from == to) return;
    setState(() => _items.insert(to, _items.removeAt(from)));
  }

  void _pointerUp() {
    _pointers--;
    if (_pointers > 0 || _dragging == null) return;
    _edgeScroll?.cancel();
    _edgeScroll = null;
    _edgeSpeed = 0;
    final order = _skus;
    final changed = !_sameOrder(order, _orderBefore);
    setState(() => _dragging = null);
    if (!changed) return;
    final scope = AppScope.of(context);
    scope.db.reorderLocation(scope.user.id, widget.locationId!, order);
    widget.changes.changed();
  }

  /// Desplaza la cuadrícula mientras el arrastre esté cerca de un borde.
  void _pointerMove(PointerMoveEvent e) {
    if (_dragging == null) return;
    final box = _grid.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    const edge = 72.0;
    final y = box.globalToLocal(e.position).dy;
    final top = edge - y;
    final bottom = y - (box.size.height - edge);
    _edgeSpeed = top > 0
        ? -top.clamp(0, edge) / 4
        : bottom > 0
        ? bottom.clamp(0, edge) / 4
        : 0;
    _edgeScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_edgeSpeed == 0 || !_scroll.hasClients) return;
      final p = _scroll.position;
      _scroll.jumpTo(
        (p.pixels + _edgeSpeed).clamp(p.minScrollExtent, p.maxScrollExtent),
      );
    });
  }

  /// Deshacer: regresa [skus] y, si el lugar tenía orden propio, también su
  /// posición (hay que llamarlo antes de sacarlos).
  VoidCallback _undoTo(Set<String> skus) {
    final scope = AppScope.of(context);
    final uid = scope.user.id;
    final place = widget.locationId;
    final order = place != null && scope.db.hasManualOrder(uid, place)
        ? _skus
        : null;
    return () {
      scope.db.setComicLocation(uid, skus, place);
      if (order != null) scope.db.reorderLocation(uid, place!, order);
      widget.changes.changed();
    };
  }

  /// Mueve [skus] a otro lugar (o los saca con "Sin ubicación").
  Future<void> _move(Set<String> skus) async {
    final choice = await pickLocation(
      context,
      title: skus.length == 1 ? 'Mover a' : 'Mover ${skus.length} a',
      current: widget.locationId,
      allowNone: !_unlocated,
    );
    if (choice == null || choice.id == widget.locationId || !mounted) return;
    final scope = AppScope.of(context);
    final undo = _undoTo(skus);
    scope.db.setComicLocation(scope.user.id, skus, choice.id);
    final to = choice.id == null
        ? null
        : scope.db
              .locations(scope.user.id)
              .firstWhere((l) => l.id == choice.id)
              .path;
    _selected.clear();
    widget.changes.changed();
    showNotice(
      ScaffoldMessenger.of(context),
      to == null
          ? '${skus.length} cómic(s) sin ubicación'
          : '${skus.length} cómic(s) → $to',
      onUndo: undo,
    );
  }

  void _removeHere(Set<String> skus) {
    final scope = AppScope.of(context);
    final undo = _undoTo(skus);
    scope.db.setComicLocation(scope.user.id, skus, null);
    _selected.clear();
    widget.changes.changed();
    showNotice(
      ScaffoldMessenger.of(context),
      '${skus.length} cómic(s) sin ubicación',
      onUndo: undo,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Esta ubicación ya no existe.')),
      );
    }
    final theme = Theme.of(context);
    final place = _place;
    final selecting = _selected.isNotEmpty;
    final ordering = _ordering && !_unlocated;
    // Igual que al recibir un pedido: en el teléfono se arrastra con pulsación
    // larga para no pelear con el scroll.
    final touch =
        theme.platform == TargetPlatform.android ||
        theme.platform == TargetPlatform.iOS;
    return Scaffold(
      appBar: AppBar(
        title: Text(place?.path ?? 'Obtenidos sin ubicación'),
        actions: [
          if (ordering)
            TextButton(
              onPressed: () => setState(() => _ordering = false),
              child: const Text('Listo'),
            )
          else if (place != null && !selecting && _items.length > 1)
            IconButton(
              tooltip: 'Ordenar',
              icon: const Icon(Icons.swap_vert),
              onPressed: () => setState(() => _ordering = true),
            ),
          if (selecting)
            TextButton(
              onPressed: () => setState(
                () => _selected.addAll(_items.map((i) => i.comic.sku)),
              ),
              child: const Text('Todos'),
            ),
          if (place != null)
            LocationMenu(
              location: place,
              changes: widget.changes,
              onDeleted: () => Navigator.pop(context),
            ),
        ],
      ),
      floatingActionButton: place == null || selecting || ordering
          ? null
          : FloatingActionButton.extended(
              onPressed: _addComics,
              icon: const Icon(Icons.add),
              label: const Text('Guardar cómics aquí'),
            ),
      bottomNavigationBar: !selecting
          ? null
          : Material(
              elevation: 8,
              color: theme.colorScheme.surfaceContainer,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Cancelar selección',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(_selected.clear),
                      ),
                      Expanded(
                        child: Text(
                          '${_selected.length} seleccionados',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (!_unlocated)
                        TextButton(
                          onPressed: () => _removeHere(Set.of(_selected)),
                          child: const Text('Quitar'),
                        ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: () => _move(Set.of(_selected)),
                        icon: const Icon(Icons.drive_file_move_outlined),
                        label: Text(_unlocated ? 'Guardar en…' : 'Mover a…'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  ordering
                      ? touch
                            ? 'Mantén presionado un cómic y arrástralo al '
                                  'lugar que ocupa físicamente'
                            : 'Arrastra cada cómic al lugar que ocupa '
                                  'físicamente'
                      : _unlocated
                      ? '${_items.length} obtenidos por acomodar · mantén '
                            'presionado para elegir varios'
                      : _countText(place!),
                  style: theme.textTheme.titleSmall,
                ),
                if (!ordering)
                  for (final l in _inside)
                    ActionChip(
                      avatar: Icon(locationIcon(l.depth), size: 18),
                      label: Text('${l.name} (${l.totalCount})'),
                      tooltip: 'Abrir ${l.path}',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => LocationDetailScreen(
                            locationId: l.id,
                            changes: widget.changes,
                          ),
                        ),
                      ),
                    ),
                if (place != null && !ordering)
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Agregar dentro…'),
                    onPressed: () =>
                        createLocation(context, widget.changes, parent: place),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _unlocated
                            ? 'Todos tus obtenidos tienen ubicación.'
                            : 'Aún no hay cómics aquí.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                // El arrastre termina aquí y no en la celda: esta puede salir
                // de pantalla mientras la cuadrícula se desplaza.
                : Listener(
                    onPointerDown: (_) => _pointers++,
                    onPointerMove: _pointerMove,
                    onPointerUp: (_) => _pointerUp(),
                    onPointerCancel: (_) => _pointerUp(),
                    child: GridView.builder(
                      key: _grid,
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                      gridDelegate: comicGridDelegate,
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final item = _items[i];
                        final sku = item.comic.sku;
                        void detail() => showComicDetail(
                          context,
                          item.comic,
                          onChanged: widget.changes.changed,
                        );
                        if (ordering) return _orderCell(item, detail, touch);
                        return ComicStatusCard(
                          comic: item.comic,
                          status: item.status,
                          selected: selecting ? _selected.contains(sku) : null,
                          onSelect: () => _toggle(sku),
                          onTap: selecting ? () => _toggle(sku) : detail,
                          actions: [
                            CardAction('Ver ficha', Icons.info_outline, detail),
                            CardAction(
                              _unlocated ? 'Guardar en…' : 'Mover a…',
                              Icons.drive_file_move_outlined,
                              () => _move({sku}),
                            ),
                            if (!_unlocated)
                              CardAction(
                                'Quitar de aquí',
                                Icons.remove_circle_outline,
                                () => _removeHere({sku}),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Celda arrastrable del modo "Ordenar". La misma celda muestra el cómic
  /// que le toque según _items, así que el hueco se marca aquí y no con
  /// childWhenDragging, que se quedaría en la posición de origen.
  Widget _orderCell(CollectionItem item, VoidCallback detail, bool touch) {
    final sku = item.comic.sku;
    final card = ComicStatusCard(
      comic: item.comic,
      status: item.status,
      onTap: detail,
    );
    return LayoutBuilder(
      builder: (context, box) {
        final feedback = Material(
          type: MaterialType.transparency,
          child: SizedBox.fromSize(
            size: box.biggest,
            child: Opacity(opacity: 0.85, child: card),
          ),
        );
        final tile = Opacity(opacity: sku == _dragging ? 0.25 : 1, child: card);
        final drags = _dragging == null ? 1 : 0;
        return DragTarget<String>(
          onWillAcceptWithDetails: (_) {
            _dragOver(sku);
            return true;
          },
          builder: (_, _, _) => touch
              ? LongPressDraggable<String>(
                  data: sku,
                  delay: const Duration(milliseconds: 200),
                  maxSimultaneousDrags: drags,
                  feedback: feedback,
                  onDragStarted: () => _startDrag(sku),
                  child: tile,
                )
              : Draggable<String>(
                  data: sku,
                  maxSimultaneousDrags: drags,
                  feedback: feedback,
                  onDragStarted: () => _startDrag(sku),
                  child: tile,
                ),
        );
      },
    );
  }
}

bool _sameOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

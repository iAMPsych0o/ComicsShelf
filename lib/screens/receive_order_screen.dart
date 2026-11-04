import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../widgets/comic_widgets.dart';

/// Lo que llegó al recibir un pedido: sku → lugar donde se guarda (null si
/// queda sin ubicación).
class ReceiveResult {
  const ReceiveResult(this.placed);
  final Map<String, int?> placed;

  Set<String> get skus => placed.keys.toSet();
}

/// Recepción de un pedido: a la izquierda lo que falta; a la derecha un cajón
/// por cada ubicación elegida (y uno "Sin ubicación"), para ir acomodando lo
/// que llegó de una vez. Las cards se arrastran o se tocan.
class ReceiveOrderScreen extends StatefulWidget {
  const ReceiveOrderScreen({
    super.key,
    required this.title,
    required this.items,
  });

  final String title;
  final List<CollectionItem> items;

  @override
  State<ReceiveOrderScreen> createState() => _ReceiveOrderScreenState();
}

/// Cajón de lo que llegó sin ubicación (los ids de lugares empiezan en 1).
const _unsorted = 0;

class _ReceiveOrderScreenState extends State<ReceiveOrderScreen> {
  late final List<CollectionItem> _pending = [
    for (final i in widget.items)
      if (i.status != ComicStatus.owned) i,
  ];
  late final int _alreadyOwned = widget.items.length - _pending.length;

  /// Lo que llegó: sku → cajón.
  final Map<String, int> _placed = {};

  /// Cajón al que van los cómics que se tocan (y "Llegó todo").
  int _target = _unsorted;

  List<StorageLocation> _places = [];

  /// Lugares que se muestran como cajones, en el orden del árbol.
  List<int> _shown = [];
  bool _loaded = false;

  String get _settingKey => 'receive_locations_${AppScope.of(context).user.id}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final scope = AppScope.of(context);
    _places = scope.db.locations(scope.user.id);
    final saved = (scope.db.getSetting(_settingKey) ?? '')
        .split(',')
        .map(int.tryParse)
        .toSet();
    _shown = [
      for (final l in _places)
        if (saved.contains(l.id)) l.id,
    ];
  }

  void _place(String sku, int zone) => setState(() => _placed[sku] = zone);

  void _unplace(String sku) => setState(() => _placed.remove(sku));

  void _placeAll() => setState(() {
    for (final i in _pending) {
      _placed.putIfAbsent(i.comic.sku, () => _target);
    }
  });

  /// Elige qué ubicaciones aparecen como cajones (se recuerda).
  Future<void> _chooseZones() async {
    final picked = await showDialog<List<int>>(
      context: context,
      builder: (_) => _ZonePicker(selected: _shown.toSet()),
    );
    if (picked == null || !mounted) return;
    final scope = AppScope.of(context);
    scope.db.setSetting(_settingKey, picked.join(','));
    setState(() {
      _places = scope.db.locations(scope.user.id);
      _shown = [
        for (final l in _places)
          if (picked.contains(l.id)) l.id,
      ];
      // Lo que estaba en un cajón que se quitó pasa a "Sin ubicación".
      _placed.updateAll((_, zone) => _shown.contains(zone) ? zone : _unsorted);
      if (!_shown.contains(_target)) _target = _unsorted;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missing = [
      for (final i in _pending)
        if (!_placed.containsKey(i.comic.sku)) i,
    ];
    final all = missing.isEmpty;
    // En el teléfono se arrastra con pulsación larga para no pelear con el
    // scroll; con mouse basta con arrastrar.
    final touch =
        theme.platform == TargetPlatform.android ||
        theme.platform == TargetPlatform.iOS;

    // En pantallas angostas los botones de arriba van solo con ícono.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    Widget action(String label, IconData icon, VoidCallback onPressed) => narrow
        ? IconButton(tooltip: label, icon: Icon(icon), onPressed: onPressed)
        : TextButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          );

    final byId = {for (final l in _places) l.id: l};
    List<CollectionItem> inZone(int zone) => [
      for (final i in _pending)
        if (_placed[i.comic.sku] == zone) i,
    ];
    Widget zone(int id) {
      final place = byId[id];
      return _Zone(
        key: ValueKey('zone-$id'),
        title: place?.path ?? 'Sin ubicación',
        icon: place == null
            ? Icons.inventory_2_outlined
            : locationIcon(place.depth),
        items: inZone(id),
        isTarget: _target == id,
        onMakeTarget: () => setState(() => _target = id),
        accepts: (sku) => _placed[sku] != id,
        onDrop: (sku) => _place(sku, id),
        onTapItem: _unplace,
        touch: touch,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('¿Qué llegó? · ${widget.title}'),
        actions: [
          if (_placed.isNotEmpty)
            action('Regresar todo', Icons.undo, () {
              setState(_placed.clear);
            }),
          if (!all) action('Llegó todo', Icons.done_all, _placeAll),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _Panel(
              title: 'Por llegar',
              icon: Icons.local_shipping_outlined,
              color: purchasedColor,
              hint: touch
                  ? 'Toca o mantén presionado y arrastra a la derecha lo que llegó.'
                  : 'Toca o arrastra a la derecha lo que llegó.',
              empty: 'Ya llegó todo',
              items: missing,
              status: ComicStatus.purchased,
              accepts: _placed.containsKey,
              onDrop: _unplace,
              onTap: (sku) => _place(sku, _target),
              touch: touch,
            ),
          ),
          VerticalDivider(width: 1, color: theme.dividerColor),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 4, 0),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.inventory_2_outlined,
                        color: ownedColor,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Llegaron (${_placed.length})',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      narrow
                          ? IconButton(
                              tooltip: 'Elegir ubicaciones',
                              icon: const Icon(Icons.tune),
                              onPressed: _chooseZones,
                            )
                          : TextButton.icon(
                              onPressed: _chooseZones,
                              icon: const Icon(Icons.tune),
                              label: const Text('Ubicaciones'),
                            ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Text(
                    [
                      if (_shown.isEmpty)
                        'Elige ubicaciones para acomodar lo que llegó.'
                      else
                        'Arrastra cada cómic a donde lo guardas. Los que '
                            'toques van al cajón marcado (toca su nombre '
                            'para elegirlo).',
                      if (_alreadyOwned == 1)
                        '1 ya estaba obtenido.'
                      else if (_alreadyOwned > 1)
                        '$_alreadyOwned ya estaban obtenidos.',
                    ].join(' '),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                    children: [
                      for (final id in _shown) zone(id),
                      zone(_unsorted),
                      if (_shown.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: OutlinedButton.icon(
                            onPressed: _chooseZones,
                            icon: const Icon(Icons.shelves),
                            label: const Text('Elegir ubicaciones'),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Material(
        elevation: 8,
        color: theme.colorScheme.surfaceContainer,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    all
                        ? 'Llegó todo: el pedido queda recibido.'
                        : _placed.isEmpty
                        ? 'Faltan ${missing.length} por llegar.'
                        : 'Llegaron ${_placed.length} · faltan '
                              '${missing.length} (siguen como "Comprado").',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _placed.isEmpty
                      ? null
                      : () => Navigator.pop(
                          context,
                          ReceiveResult({
                            for (final e in _placed.entries)
                              e.key: e.value == _unsorted ? null : e.value,
                          }),
                        ),
                  icon: const Icon(Icons.check),
                  label: Text(
                    all ? 'Recibir pedido' : 'Recibir ${_placed.length}',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Envuelve [child] para arrastrarlo: con pulsación larga en el teléfono.
Widget _draggable({
  required String sku,
  required Widget child,
  required Widget feedback,
  required bool touch,
}) {
  final ghost = Opacity(opacity: 0.25, child: child);
  final fb = Material(type: MaterialType.transparency, child: feedback);
  return touch
      ? LongPressDraggable<String>(
          data: sku,
          feedback: fb,
          childWhenDragging: ghost,
          child: child,
        )
      : Draggable<String>(
          data: sku,
          feedback: fb,
          childWhenDragging: ghost,
          child: child,
        );
}

/// Lado izquierdo: lo que falta, con cards grandes.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.icon,
    required this.color,
    required this.hint,
    required this.empty,
    required this.items,
    required this.status,
    required this.accepts,
    required this.onDrop,
    required this.onTap,
    required this.touch,
  });

  final String title;
  final IconData icon;
  final Color color;
  final String? hint;
  final String empty;
  final List<CollectionItem> items;
  final ComicStatus status;
  final bool Function(String sku) accepts;
  final void Function(String sku) onDrop;
  final void Function(String sku) onTap;
  final bool touch;

  static const _grid = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 200,
    childAspectRatio: 0.52,
    crossAxisSpacing: 10,
    mainAxisSpacing: 10,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => accepts(d.data),
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: hovering ? color.withValues(alpha: 0.12) : null,
            border: Border.all(
              color: hovering ? color : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Row(
                  children: [
                    Icon(icon, color: color, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$title (${items.length})',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ),
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Text(hint!, style: theme.textTheme.bodySmall),
                ),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                hovering ? Icons.file_download : icon,
                                size: 48,
                                color: color.withValues(alpha: 0.6),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                empty,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      )
                    : GridView(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: _grid,
                        children: [
                          for (final i in items)
                            Builder(
                              builder: (context) {
                                final card = ComicStatusCard(
                                  comic: i.comic,
                                  status: status,
                                  onTap: () => onTap(i.comic.sku),
                                );
                                return _draggable(
                                  sku: i.comic.sku,
                                  touch: touch,
                                  child: card,
                                  feedback: SizedBox(
                                    width: 150,
                                    height: 290,
                                    child: Transform.rotate(
                                      angle: 0.04,
                                      child: card,
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Un cajón del lado derecho: una ubicación (o "Sin ubicación") con los
/// cómics que se van a guardar ahí, en renglones compactos.
class _Zone extends StatelessWidget {
  const _Zone({
    super.key,
    required this.title,
    required this.icon,
    required this.items,
    required this.isTarget,
    required this.onMakeTarget,
    required this.accepts,
    required this.onDrop,
    required this.onTapItem,
    required this.touch,
  });

  final String title;
  final IconData icon;
  final List<CollectionItem> items;
  final bool isTarget;
  final VoidCallback onMakeTarget;
  final bool Function(String sku) accepts;
  final void Function(String sku) onDrop;
  final void Function(String sku) onTapItem;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) => accepts(d.data),
        onAcceptWithDetails: (d) => onDrop(d.data),
        builder: (context, candidates, _) {
          final hovering = candidates.isNotEmpty;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: hovering
                  ? ownedColor.withValues(alpha: 0.18)
                  : theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hovering || isTarget
                    ? ownedColor
                    : theme.colorScheme.outlineVariant,
                width: hovering ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(10),
                  ),
                  onTap: onMakeTarget,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                    child: Row(
                      children: [
                        Icon(icon, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$title (${items.length})',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        Tooltip(
                          message: isTarget
                              ? 'Aquí van los cómics que toques'
                              : 'Mandar aquí los cómics que toques',
                          child: Icon(
                            isTarget
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 18,
                            color: isTarget
                                ? ownedColor
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                    child: Text(
                      hovering ? 'Suelta aquí' : 'Arrastra aquí',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: Column(
                      children: [
                        for (final i in items)
                          _draggable(
                            sku: i.comic.sku,
                            touch: touch,
                            child: _MiniTile(
                              comic: i.comic,
                              onTap: () => onTapItem(i.comic.sku),
                            ),
                            feedback: SizedBox(
                              width: 220,
                              child: _MiniTile(comic: i.comic, onTap: () {}),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Renglón compacto de un cómic acomodado: portada chica y nombre.
class _MiniTile extends StatelessWidget {
  const _MiniTile({required this.comic, required this.onTap});

  final Comic comic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: statusBackground(ComicStatus.owned),
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              ComicCover(url: comic.imageUrl, width: 32, height: 48),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  comic.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

/// Elige qué ubicaciones aparecen como cajones; también deja crear una.
class _ZonePicker extends StatefulWidget {
  const _ZonePicker({required this.selected});

  final Set<int> selected;

  @override
  State<_ZonePicker> createState() => _ZonePickerState();
}

class _ZonePickerState extends State<_ZonePicker> {
  late final Set<int> _selected = Set.of(widget.selected);
  List<StorageLocation> _places = [];
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _reload();
    }
  }

  void _reload() {
    final scope = AppScope.of(context);
    setState(() => _places = scope.db.locations(scope.user.id));
  }

  Future<void> _create() async {
    final scope = AppScope.of(context);
    final name = await askText(
      context,
      title: 'Nueva ubicación',
      label: 'Nombre (ej. Closet 1)',
    );
    if (name == null || !mounted) return;
    final id = scope.db.createLocation(scope.user.id, name);
    _selected.add(id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ubicaciones a la vista'),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            if (_places.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('Aún no tienes ubicaciones. Crea la primera.'),
              ),
            for (final l in _places)
              CheckboxListTile(
                value: _selected.contains(l.id),
                onChanged: (v) => setState(
                  () =>
                      v == true ? _selected.add(l.id) : _selected.remove(l.id),
                ),
                contentPadding: EdgeInsets.only(
                  left: 16.0 + 20 * l.depth,
                  right: 8,
                ),
                secondary: Icon(locationIcon(l.depth)),
                title: Text(l.name),
                subtitle: Text(
                  l.totalCount == 1 ? '1 cómic' : '${l.totalCount} cómics',
                ),
                controlAffinity: ListTileControlAffinity.trailing,
                dense: true,
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Nueva ubicación…'),
              dense: true,
              onTap: _create,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected.toList()),
          child: Text('Mostrar ${_selected.length}'),
        ),
      ],
    );
  }
}

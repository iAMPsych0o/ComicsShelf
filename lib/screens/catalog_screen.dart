import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../services/pdf_export.dart';
import '../widgets/comic_widgets.dart';
import '../widgets/refresh_menu.dart';
import '../services/stores.dart';
import 'home_shell.dart';

/// Muestra todos los cómics migrados desde el scraping, con el estado que
/// el usuario le dio a cada uno.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.changes,
    required this.onGoToScraper,
    this.onRefreshCatalog,
  });

  final DataChanges changes;
  final VoidCallback onGoToScraper;

  /// Descarga de nuevo el catálogo de Panini (botón junto a la búsqueda).
  final ValueChanged<PaniniStore>? onRefreshCatalog;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  static const _pageSize = 300;

  final _search = TextEditingController();
  Timer? _debounce;
  String? _category;

  /// null = todos los estados.
  ComicStatus? _statusFilter;
  Availability? _availability;
  String? _store;
  Map<String, int> _storeCounts = {};
  Map<Availability, int> _availabilityCounts = {};
  List<Comic> _comics = [];
  Map<String, int> _categories = {};
  Map<String, ComicStatus> _statuses = {};
  Map<ComicStatus, int> _statusCounts = {};
  int _total = 0;
  bool _hasMore = false;
  final _selected = <String>{};
  final _scaffold = GlobalKey<ScaffoldState>();
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
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  List<Comic> _query({int offset = 0}) {
    final scope = AppScope.of(context);
    return scope.db.searchComics(
      query: _search.text,
      category: _category,
      userId: scope.user.id,
      status: _statusFilter,
      availability: _availability,
      store: _store,
      limit: _pageSize + 1,
      offset: offset,
    );
  }

  void _reload() {
    final scope = AppScope.of(context);
    final results = _query();
    setState(() {
      _total = scope.db.comicCount();
      _categories = scope.db.catalogCategories();
      if (_category != null && !_categories.containsKey(_category)) {
        _category = null;
      }
      _hasMore = results.length > _pageSize;
      _comics = results.take(_pageSize).toList();
      _statuses = scope.db.statuses(scope.user.id);
      _statusCounts = scope.db.catalogStatusCounts(scope.user.id);
      _availabilityCounts = scope.db.availabilityCounts();
      _storeCounts = scope.db.storeCounts();
    });
  }

  void _loadMore() {
    final more = _query(offset: _comics.length);
    setState(() {
      _hasMore = more.length > _pageSize;
      _comics = [..._comics, ...more.take(_pageSize)];
    });
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _reload);
  }

  void _toggle(String sku) => setState(() {
    if (!_selected.remove(sku)) _selected.add(sku);
  });

  Future<void> _addToCollection(List<String> skus) async {
    final ok = await addComicsToCollection(context, skus);
    if (ok) {
      setState(_selected.clear);
      widget.changes.changed();
    }
  }

  Future<void> _addToCart(List<String> skus) async {
    final ok = await addComicsToCart(context, skus);
    if (ok) {
      setState(_selected.clear);
      widget.changes.changed();
    }
  }

  /// Exporta TODO lo que coincide con los filtros (no solo lo cargado).
  void _exportPdf() {
    final scope = AppScope.of(context);
    final comics = scope.db.searchComics(
      query: _search.text,
      category: _category,
      userId: scope.user.id,
      status: _statusFilter,
      availability: _availability,
      store: _store,
      limit: 100000,
    );
    final title = [
      ?_statusFilter?.label,
      ?_availability?.label,
      if (_store != null) storeByKey(_store).name,
      ?_category,
      if (_search.text.trim().isNotEmpty) '"${_search.text.trim()}"',
    ].join(' · ');
    exportComicsPdf(
      context,
      title: title.isEmpty ? 'Catálogo' : title,
      items: [
        for (final c in comics)
          CollectionItem(
            comic: c,
            status: _statuses[c.sku] ?? ComicStatus.unclassified,
          ),
      ],
    );
  }

  void _mark(Iterable<String> skus, ComicStatus status) {
    final scope = AppScope.of(context);
    final list = skus.toList();
    final previous = {
      for (final s in list) s: _statuses[s] ?? ComicStatus.unclassified,
    };
    scope.db.setStatus(scope.user.id, list, status);
    setState(_selected.clear);
    widget.changes.changed();
    showNotice(
      ScaffoldMessenger.of(context),
      list.length == 1
          ? 'Marcado: ${status.label}'
          : '${list.length} cómics marcados: ${status.label}',
      status: status,
      onUndo: () {
        for (final e in previous.entries) {
          scope.db.setStatus(scope.user.id, [e.key], e.value);
        }
        widget.changes.changed();
      },
    );
  }

  /// Barra completa (escritorio): todas las acciones a la vista.
  Widget _wideSelectionBar() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('${_selected.length} seleccionado(s):'),
        for (final s in ComicStatus.values.reversed)
          ActionChip(
            avatar: Icon(statusIcon(s), size: 16, color: statusColor(s)),
            label: Text(s.label),
            onPressed: () => _mark(_selected, s),
          ),
        ActionChip(
          avatar: const Icon(Icons.bookmark_add, size: 16),
          label: const Text('Agregar a colección'),
          onPressed: () => _addToCollection(_selected.toList()),
        ),
        ActionChip(
          avatar: const Icon(Icons.add_shopping_cart, size: 16),
          label: const Text('Agregar a carrito'),
          onPressed: () => _addToCart(_selected.toList()),
        ),
        TextButton(
          onPressed: () => setState(_selected.clear),
          child: const Text('Limpiar'),
        ),
      ],
    ),
  );

  /// Barra de una línea (teléfono): las acciones se abren desde abajo.
  Widget _compactSelectionBar(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 2, 12, 2),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Cancelar selección',
          icon: const Icon(Icons.close),
          onPressed: () => setState(_selected.clear),
        ),
        Expanded(child: Text('${_selected.length} seleccionado(s)')),
        FilledButton.icon(
          onPressed: () => _showSelectionActions(context),
          icon: const Icon(Icons.more_horiz),
          label: const Text('Acciones'),
        ),
      ],
    ),
  );

  Future<void> _showSelectionActions(BuildContext context) async {
    final action = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_selected.length} seleccionado(s)',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final s in ComicStatus.values.reversed)
                ListTile(
                  leading: Icon(statusIcon(s), color: statusColor(s)),
                  title: Text('Marcar: ${s.label}'),
                  onTap: () => Navigator.pop(ctx, s),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.bookmark_add),
                title: const Text('Agregar a colección…'),
                onTap: () => Navigator.pop(ctx, 'collection'),
              ),
              ListTile(
                leading: const Icon(Icons.add_shopping_cart),
                title: const Text('Agregar a carrito…'),
                onTap: () => Navigator.pop(ctx, 'cart'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action is ComicStatus) {
      _mark(_selected, action);
    } else if (action == 'cart') {
      await _addToCart(_selected.toList());
    } else {
      await _addToCollection(_selected.toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_total == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inventory_2_outlined, size: 64),
              const SizedBox(height: 12),
              const Text(
                'Todavía no hay cómics en el catálogo.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              const Text(
                'Descarga el catálogo de Panini México para empezar.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: widget.onGoToScraper,
                icon: const Icon(Icons.cloud_download),
                label: const Text('Actualizar catálogo'),
              ),
            ],
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final active =
        (_statusFilter == null ? 0 : 1) +
        (_category == null ? 0 : 1) +
        (_availability == null ? 0 : 1) +
        (_store == null ? 0 : 1);

    return Scaffold(
      key: _scaffold,
      endDrawer: _FiltersDrawer(
        total: _total,
        statusCounts: _statusCounts,
        categories: _categories,
        status: _statusFilter,
        category: _category,
        availabilityCounts: _availabilityCounts,
        availability: _availability,
        onAvailability: (a) {
          _availability = a;
          _reload();
        },
        storeCounts: _storeCounts,
        store: _store,
        onStore: (s) {
          _store = s;
          _reload();
        },
        onStatus: (s) {
          _statusFilter = s;
          _reload();
        },
        onCategory: (c) {
          _category = c;
          _reload();
        },
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                if (widget.onRefreshCatalog case final refresh?)
                  RefreshMenuButton(onRefresh: refresh),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Buscar por nombre, serie, ISBN…',
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _search.clear();
                                _reload();
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Badge(
                  isLabelVisible: active > 0,
                  label: Text('$active'),
                  child: OutlinedButton.icon(
                    onPressed: () => _scaffold.currentState?.openEndDrawer(),
                    icon: const Icon(Icons.filter_list),
                    label: const Text('Filtros'),
                  ),
                ),
              ],
            ),
          ),
          // Solo cuando hay filtros: una línea pequeña para verlos y quitarlos.
          if (active > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (_statusFilter != null)
                    InputChip(
                      avatar: Icon(
                        statusIcon(_statusFilter!),
                        size: 16,
                        color: statusColor(_statusFilter!),
                      ),
                      label: Text(_statusFilter!.label),
                      onDeleted: () {
                        _statusFilter = null;
                        _reload();
                      },
                      visualDensity: VisualDensity.compact,
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.picture_as_pdf_outlined, size: 16),
                    label: const Text('Exportar PDF'),
                    onPressed: _exportPdf,
                    visualDensity: VisualDensity.compact,
                  ),
                  if (_store case final s?)
                    InputChip(
                      avatar: const Icon(Icons.storefront_outlined, size: 16),
                      label: Text(storeByKey(s).name),
                      onDeleted: () {
                        _store = null;
                        _reload();
                      },
                      visualDensity: VisualDensity.compact,
                    ),
                  if (_availability case final a?)
                    InputChip(
                      avatar: Icon(
                        availabilityIcon(a),
                        size: 16,
                        color: availabilityColor(a),
                      ),
                      label: Text(a.label),
                      onDeleted: () {
                        _availability = null;
                        _reload();
                      },
                      visualDensity: VisualDensity.compact,
                    ),
                  if (_category != null)
                    InputChip(
                      avatar: const Icon(Icons.category_outlined, size: 16),
                      label: Text(_category!),
                      onDeleted: () {
                        _category = null;
                        _reload();
                      },
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          if (_selected.isNotEmpty)
            Material(
              color: theme.colorScheme.secondaryContainer,
              child: LayoutBuilder(
                builder: (context, c) => c.maxWidth < 720
                    ? _compactSelectionBar(context)
                    : _wideSelectionBar(),
              ),
            ),
          Expanded(
            child: _comics.isEmpty
                ? const Center(child: Text('No hay resultados.'))
                : CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.all(12),
                        sliver: SliverGrid.builder(
                          gridDelegate: comicGridDelegate,
                          itemCount: _comics.length,
                          itemBuilder: (context, i) {
                            final c = _comics[i];
                            final status =
                                _statuses[c.sku] ?? ComicStatus.unclassified;
                            return ComicStatusCard(
                              comic: c,
                              status: status,
                              selected: _selected.contains(c.sku),
                              onSelect: () => _toggle(c.sku),
                              onTap: () => showComicDetail(
                                context,
                                c,
                                onChanged: widget.changes.changed,
                              ),
                              actions: [
                                ...statusActions(
                                  status,
                                  (st) => _mark([c.sku], st),
                                ),
                                CardAction(
                                  'Agregar a colección…',
                                  Icons.bookmark_add,
                                  () => _addToCollection([c.sku]),
                                ),
                                CardAction(
                                  'Agregar a carrito…',
                                  Icons.add_shopping_cart,
                                  () => _addToCart([c.sku]),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      if (_hasMore)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: Center(
                              child: OutlinedButton(
                                onPressed: _loadMore,
                                child: const Text('Mostrar más'),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Panel lateral de filtros del catálogo: estado y categoría, con conteos.
class _FiltersDrawer extends StatelessWidget {
  const _FiltersDrawer({
    required this.total,
    required this.statusCounts,
    required this.categories,
    required this.status,
    required this.category,
    required this.availabilityCounts,
    required this.availability,
    required this.onAvailability,
    required this.storeCounts,
    required this.store,
    required this.onStore,
    required this.onStatus,
    required this.onCategory,
  });

  final Map<Availability, int> availabilityCounts;
  final Availability? availability;
  final ValueChanged<Availability?> onAvailability;
  final Map<String, int> storeCounts;
  final String? store;
  final ValueChanged<String?> onStore;

  final int total;
  final Map<ComicStatus, int> statusCounts;
  final Map<String, int> categories;
  final ComicStatus? status;
  final String? category;
  final ValueChanged<ComicStatus?> onStatus;
  final ValueChanged<String?> onCategory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final classified = total - (statusCounts[ComicStatus.unclassified] ?? 0);
    final sortedCats = categories.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );

    Widget option({
      required bool selected,
      required String label,
      required int count,
      required VoidCallback onTap,
      Widget? leading,
    }) => ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.15),
      leading: leading,
      title: Text(label),
      trailing: Text('$count'),
      onTap: onTap,
    );

    return Drawer(
      width: 320,
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: Text('Filtros', style: theme.textTheme.titleLarge),
              subtitle: Text('Clasificados $classified de $total'),
              trailing: IconButton(
                tooltip: 'Cerrar',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : classified / total,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  header('Estado'),
                  option(
                    selected: status == null,
                    label: 'Todos',
                    count: total,
                    leading: const Icon(Icons.select_all),
                    onTap: () => onStatus(null),
                  ),
                  for (final s in ComicStatus.values)
                    option(
                      selected: status == s,
                      label: s.label,
                      count: statusCounts[s] ?? 0,
                      leading: Icon(statusIcon(s), color: statusColor(s)),
                      onTap: () => onStatus(s),
                    ),
                  header('Tienda'),
                  option(
                    selected: store == null,
                    label: 'Todas',
                    count: total,
                    leading: const Icon(Icons.public),
                    onTap: () => onStore(null),
                  ),
                  for (final s in paniniStores)
                    option(
                      selected: store == s.key,
                      label: s.name,
                      count: storeCounts[s.key] ?? 0,
                      leading: const Icon(Icons.storefront_outlined),
                      onTap: () => onStore(s.key),
                    ),
                  header('Disponibilidad'),
                  option(
                    selected: availability == null,
                    label: 'Todas',
                    count: total,
                    leading: const Icon(Icons.storefront_outlined),
                    onTap: () => onAvailability(null),
                  ),
                  for (final a in Availability.values)
                    option(
                      selected: availability == a,
                      label: a.label,
                      count: availabilityCounts[a] ?? 0,
                      leading: Icon(
                        availabilityIcon(a),
                        color: availabilityColor(a),
                      ),
                      onTap: () => onAvailability(a),
                    ),
                  header('Categoría'),
                  option(
                    selected: category == null,
                    label: 'Todas',
                    count: total,
                    leading: const Icon(Icons.category_outlined),
                    onTap: () => onCategory(null),
                  ),
                  for (final e in sortedCats)
                    option(
                      selected: category == e.key,
                      label: e.key,
                      count: e.value,
                      onTap: () => onCategory(e.key),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed:
                        status == null &&
                            category == null &&
                            availability == null &&
                            store == null
                        ? null
                        : () {
                            onStatus(null);
                            onCategory(null);
                            onAvailability(null);
                            onStore(null);
                          },
                    child: const Text('Quitar filtros'),
                  ),

                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Listo'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

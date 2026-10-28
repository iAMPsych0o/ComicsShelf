import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../services/panini_scraper.dart';
import '../services/stores.dart';
import '../widgets/comic_widgets.dart';
import '../widgets/refresh_menu.dart';
import 'home_shell.dart';

enum _Stage { categories, running, review, done }

enum _Show { all, selected, ignored, newOnly }

/// Ejecuta el scraping de la tienda y deja revisar los productos antes de
/// migrarlos a la base de datos.
class ScraperScreen extends StatefulWidget {
  const ScraperScreen({super.key, required this.changes});

  final DataChanges changes;

  @override
  State<ScraperScreen> createState() => ScraperScreenState();
}

class ScraperScreenState extends State<ScraperScreen> {
  _Stage _stage = _Stage.categories;
  String? _error;
  String? _warning;

  // Paso 1: secciones de cada tienda (se cargan al abrir su acordeón).
  final _storeCategories = <String, List<StoreCategory>>{};
  final _chosen = <String, Set<int>>{};
  final _loading = <String>{};
  final _loadErrors = <String, String>{};
  final _expanded = <String>{mexico.key};

  // Paso 2: progreso
  PaniniScraper? _scraper;
  PaniniStore? _runningStore;
  int _page = 0, _totalPages = 0, _found = 0;
  bool _cancel = false;

  // Paso 3: revisión
  List<Comic> _scraped = [];
  final _selected = <String>{};
  Set<String> _existing = {};
  List<String> _reviewCategories = [];
  String? _categoryFilter;
  _Show _show = _Show.all;
  final _search = TextEditingController();
  List<Comic> _visible = [];
  final _collapsedReview = <String>{};

  // Paso 4: resultado
  int _migrated = 0, _ignored = 0;

  @override
  void initState() {
    super.initState();
    _loadCategories(mexico);
  }

  @override
  void dispose() {
    _cancel = true;
    _scraper?.close();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadCategories(PaniniStore store) async {
    if (_loading.contains(store.key)) return;
    setState(() {
      _loading.add(store.key);
      _loadErrors.remove(store.key);
    });
    try {
      final cats = await loadStoreCategories(store);
      if (!mounted) return;
      // Las secciones de la última vez; si no hay, las predeterminadas.
      final chosen = chosenCategories(AppScope.of(context).db, store, cats);
      setState(() {
        _storeCategories[store.key] = cats;
        _chosen[store.key] = chosen;
      });
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _loadErrors[store.key] = 'No se pudo conectar con la tienda: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _loading.remove(store.key));
    }
  }

  /// Descarga de inmediato [store] con las secciones elegidas en el menú del
  /// catálogo. Al terminar queda en la revisión.
  Future<void> refreshNow([PaniniStore store = mexico]) async {
    if (_stage == _Stage.running) return;
    setState(() {
      _stage = _Stage.categories;
      _expanded.add(store.key);
    });
    if (_storeCategories[store.key] == null) {
      await _loadCategories(store);
    } else {
      _chosen[store.key] = chosenCategories(
        AppScope.of(context).db,
        store,
        _storeCategories[store.key]!,
      );
    }
    if (!mounted || (_chosen[store.key]?.isEmpty ?? true)) return;
    await _run([store]);
  }

  /// Tiendas con secciones elegidas (solo las que se abrieron).
  List<PaniniStore> get _storesToRun => [
    for (final s in paniniStores)
      if (_storeCategories[s.key] != null &&
          (_chosen[s.key]?.isNotEmpty ?? false))
        s,
  ];

  Future<void> _run(List<PaniniStore> stores) async {
    final db = AppScope.of(context).db;
    setState(() {
      _stage = _Stage.running;
      _error = null;
      _warning = null;
      _cancel = false;
    });
    final all = <Comic>[];
    final names = <String>[];
    final warnings = <String>[];
    try {
      for (final store in stores) {
        if (_cancel) break;
        final cats = _storeCategories[store.key]!
            .where((c) => _chosen[store.key]!.contains(c.id))
            .toList();
        saveChosenCategories(db, store, _chosen[store.key]!);
        names.addAll(cats.map((c) => c.name));
        _scraper?.close();
        _scraper = PaniniScraper(store: store);
        setState(() {
          _runningStore = store;
          _page = 0;
          _totalPages = 0;
          _found = 0;
        });
        final result = await _scraper!.scrape(
          cats,
          isCancelled: () => _cancel,
          onProgress: (page, total, found) {
            if (mounted) {
              setState(() {
                _page = page;
                _totalPages = total;
                _found = found;
              });
            }
          },
        );
        all.addAll(result.comics);
        if (result.warning != null) {
          warnings.add('${store.name}: ${result.warning}');
        }
      }
      if (!mounted) return;
      _warning = warnings.isEmpty ? null : warnings.join('\n');
      _startReview(all, names.toSet().toList());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.categories;
        _error = 'El scraping falló: $e';
      });
    }
  }

  void _startReview(List<Comic> result, List<String> categoryNames) {
    final db = AppScope.of(context).db;
    final ignored = db.ignoredSkus();
    _existing = db.existingSkus();
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _scraped = result;
    _reviewCategories = categoryNames
        .where((n) => result.any((c) => c.categories.contains(n)))
        .toList();
    _selected
      ..clear()
      ..addAll(
        result
            .where(
              (c) =>
                  !ignored.contains(c.sku) &&
                  !c.categories.contains('Panini Manga') &&
                  !c.categories.contains('Planet Mangá'),
            )
            .map((c) => c.sku),
      );
    _categoryFilter = null;
    _show = _Show.all;
    _search.clear();
    setState(() => _stage = _Stage.review);
    _applyFilters();
  }

  void _applyFilters() {
    final words = _search.text
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty);
    setState(() {
      _visible = _scraped.where((c) {
        if (_categoryFilter != null &&
            !c.categories.contains(_categoryFilter)) {
          return false;
        }
        switch (_show) {
          case _Show.selected:
            if (!_selected.contains(c.sku)) return false;
          case _Show.ignored:
            if (_selected.contains(c.sku)) return false;
          case _Show.newOnly:
            if (_existing.contains(c.sku)) return false;
          case _Show.all:
            break;
        }
        final hay = '${c.name} ${c.series ?? ''} ${c.sku}'.toLowerCase();
        return words.every(hay.contains);
      }).toList();
    });
  }

  void _setVisible(bool selected) {
    setState(() {
      for (final c in _visible) {
        selected ? _selected.add(c.sku) : _selected.remove(c.sku);
      }
    });
    if (_show != _Show.all && _show != _Show.newOnly) _applyFilters();
  }

  Future<void> _migrate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Migrar a la base de datos'),
        content: Text(
          'Se guardarán ${_selected.length} productos en el catálogo.\n'
          '${_scraped.length - _selected.length} se marcarán como ignorados '
          'y aparecerán desmarcados la próxima vez.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Migrar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final db = AppScope.of(context).db;
    final toSave = _scraped.where((c) => _selected.contains(c.sku)).toList();
    final ignored = {
      for (final c in _scraped)
        if (!_selected.contains(c.sku)) c.sku: c.name,
    };
    db.upsertComics(toSave);
    db.setIgnored(ignored, toSave.map((c) => c.sku));
    widget.changes.changed();
    setState(() {
      _migrated = toSave.length;
      _ignored = ignored.length;
      _stage = _Stage.done;
    });
  }

  @override
  Widget build(BuildContext context) {
    return switch (_stage) {
      _Stage.categories => _buildCategories(context),
      _Stage.running => _buildRunning(context),
      _Stage.review => _buildReview(context),
      _Stage.done => _buildDone(context),
    };
  }

  // ------------------------------------------------------------- paso 1

  Widget _buildCategories(BuildContext context) {
    final theme = Theme.of(context);
    var total = 0;
    for (final s in _storesToRun) {
      total += _storeCategories[s.key]!
          .where((c) => _chosen[s.key]!.contains(c.id))
          .fold<int>(0, (sum, c) => sum + c.productCount);
    }
    // Aproximado: ~100 productos por página, ~5 s por página.
    final minutes = (total / 100 * 6.5 / 60).ceil();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Actualizar catálogo', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text(
          'Abre cada tienda y elige qué secciones descargar. Antes de guardar '
          'verás la lista completa para descartar lo que no quieras.',
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Card(
            color: theme.colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(_error!),
            ),
          ),
        for (final store in paniniStores) _storeAccordion(store, theme),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _storesToRun.isEmpty ? null : () => _run(_storesToRun),
              icon: const Icon(Icons.play_arrow),
              label: Text(
                _storesToRun.length > 1
                    ? 'Ejecutar scraping (${_storesToRun.length} tiendas)'
                    : 'Ejecutar scraping',
              ),
            ),
            if (total > 0)
              Text('Hasta $total productos · unos $minutes min aprox.'),
          ],
        ),
      ],
    );
  }

  Widget _storeAccordion(PaniniStore store, ThemeData theme) {
    final cats = _storeCategories[store.key];
    final chosen = _chosen[store.key] ?? const <int>{};
    final error = _loadErrors[store.key];
    final products = cats == null
        ? 0
        : cats
              .where((c) => chosen.contains(c.id))
              .fold<int>(0, (s, c) => s + c.productCount);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('store_${store.key}'),
        initiallyExpanded: _expanded.contains(store.key),
        onExpansionChanged: (open) {
          open ? _expanded.add(store.key) : _expanded.remove(store.key);
          if (open && cats == null) _loadCategories(store);
        },
        leading: CircleAvatar(
          backgroundColor: chosen.isEmpty
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.primary,
          child: Text(
            store.shortCode,
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
        ),
        title: Text('${store.name} (${store.currency})'),
        subtitle: Text(
          cats == null
              ? 'Ábrela para ver sus secciones'
              : chosen.isEmpty
              ? 'No se descargará'
              : '${chosen.length} secciones · hasta $products productos',
        ),
        children: [
          if (_loading.contains(store.key))
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          if (error != null)
            ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(error),
              trailing: TextButton(
                onPressed: () => _loadCategories(store),
                child: const Text('Reintentar'),
              ),
            ),
          if (cats != null) ...[
            OverflowBar(
              alignment: MainAxisAlignment.start,
              children: [
                TextButton(
                  onPressed: () => setState(
                    () => _chosen[store.key] = {for (final c in cats) c.id},
                  ),
                  child: const Text('Todas'),
                ),
                TextButton(
                  onPressed: () => setState(
                    () => _chosen[store.key] = defaultCategories(store, cats),
                  ),
                  child: const Text('Predeterminadas'),
                ),
                TextButton(
                  onPressed: () => setState(() => _chosen[store.key] = {}),
                  child: const Text('Ninguna'),
                ),
              ],
            ),
            for (final c in cats)
              CheckboxListTile(
                dense: true,
                value: chosen.contains(c.id),
                onChanged: (v) => setState(() {
                  final set = _chosen.putIfAbsent(store.key, () => {});
                  v == true ? set.add(c.id) : set.remove(c.id);
                }),
                title: Text(c.name),
                subtitle: Text('${c.productCount} productos'),
              ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------- paso 2

  Widget _buildRunning(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Descargando ${_runningStore?.name ?? 'catálogo'}…',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _totalPages == 0 ? null : _page / _totalPages,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 8),
              Text(
                _totalPages == 0
                    ? 'Conectando con la tienda…'
                    : 'Página $_page de $_totalPages · $_found productos',
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: _cancel
                    ? null
                    : () => setState(() => _cancel = true),
                child: Text(
                  _cancel ? 'Deteniendo…' : 'Detener y revisar lo descargado',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- paso 3

  Widget _buildReview(BuildContext context) {
    final theme = Theme.of(context);
    final newCount = _scraped.where((c) => !_existing.contains(c.sku)).length;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Revisa los productos a migrar',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 2),
          Text(
            '${_scraped.length} encontrados · $newCount nuevos · '
            '${_selected.length} seleccionados para migrar',
          ),
          if (_warning != null) ...[
            const SizedBox(height: 8),
            Card(
              color: theme.colorScheme.tertiaryContainer,
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.warning_amber),
                title: const Text('El scraping no terminó completo'),
                subtitle: Text(
                  '$_warning\nPuedes migrar lo descargado y '
                  'volver a ejecutarlo después.',
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => _applyFilters(),
                  decoration: const InputDecoration(
                    hintText: 'Filtrar…',
                    prefixIcon: Icon(Icons.filter_list),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              DropdownMenu<_Show>(
                initialSelection: _show,
                label: const Text('Mostrar'),
                width: 200,
                inputDecorationTheme: const InputDecorationTheme(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSelected: (v) {
                  _show = v ?? _Show.all;
                  _applyFilters();
                },
                dropdownMenuEntries: const [
                  DropdownMenuEntry(value: _Show.all, label: 'Todos'),
                  DropdownMenuEntry(
                    value: _Show.selected,
                    label: 'Seleccionados',
                  ),
                  DropdownMenuEntry(value: _Show.ignored, label: 'Ignorados'),
                  DropdownMenuEntry(value: _Show.newOnly, label: 'Solo nuevos'),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Todas'),
                  selected: _categoryFilter == null,
                  onSelected: (_) {
                    _categoryFilter = null;
                    _applyFilters();
                  },
                ),
                for (final cat in _reviewCategories) ...[
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: Text(cat),
                    selected: _categoryFilter == cat,
                    onSelected: (_) {
                      _categoryFilter = cat;
                      _applyFilters();
                    },
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${_visible.length} visibles:'),
              TextButton(
                onPressed: () => _setVisible(true),
                child: const Text('Marcar todos'),
              ),
              TextButton(
                onPressed: () => _setVisible(false),
                child: const Text('Ignorar todos'),
              ),
            ],
          ),
        ],
      ),
    );
    return Column(
      children: [
        Expanded(
          // El encabezado se desplaza con la lista (en el teléfono no cabe
          // fijo). Un acordeón por tienda; las filas se construyen al verse.
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: header),
              const SliverToBoxAdapter(child: Divider(height: 1)),
              for (final store in paniniStores) ..._reviewSection(store, theme),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => setState(() => _stage = _Stage.categories),
                child: const Text('Descartar'),
              ),
              FilledButton.icon(
                onPressed: _selected.isEmpty ? null : _migrate,
                icon: const Icon(Icons.save_alt),
                label: Text('Migrar ${_selected.length} a la base de datos'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Encabezado plegable de una tienda y sus productos en la revisión.
  List<Widget> _reviewSection(PaniniStore store, ThemeData theme) {
    final all = _scraped.where((c) => c.store == store.key);
    if (all.isEmpty) return const [];
    final visible = _visible.where((c) => c.store == store.key).toList();
    final selected = all.where((c) => _selected.contains(c.sku)).length;
    final open = !_collapsedReview.contains(store.key);
    return [
      SliverToBoxAdapter(
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: ListTile(
            leading: Icon(open ? Icons.expand_less : Icons.expand_more),
            title: Text('${store.name} (${store.currency})'),
            subtitle: Text(
              '${all.length} encontrados · $selected para migrar · '
              '${visible.length} visibles',
            ),
            onTap: () => setState(
              () => open
                  ? _collapsedReview.add(store.key)
                  : _collapsedReview.remove(store.key),
            ),
          ),
        ),
      ),
      if (open)
        SliverList.builder(
          itemCount: visible.length,
          itemBuilder: (context, i) => _reviewRow(visible[i], theme),
        ),
    ];
  }

  Widget _reviewRow(Comic c, ThemeData theme) {
    final isNew = !_existing.contains(c.sku);
    final top = _reviewCategories.where(c.categories.contains).join(', ');
    return CheckboxListTile(
      value: _selected.contains(c.sku),
      onChanged: (v) => setState(
        () => v == true ? _selected.add(c.sku) : _selected.remove(c.sku),
      ),
      secondary: ComicCover(url: c.imageUrl, width: 36, height: 54),
      title: Text(c.name),
      subtitle: Text(
        [
          top,
          formatComicPrice(c),
          c.sku,
        ].where((s) => s.isNotEmpty).join(' · '),
      ),
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
    ).withBadge(isNew ? 'Nuevo' : 'Actualizar', isNew, theme);
  }

  // ------------------------------------------------------------- paso 4

  Widget _buildDone(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 64, color: Colors.green),
            const SizedBox(height: 12),
            Text('Migración completa', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('$_migrated productos guardados · $_ignored ignorados'),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => setState(() => _stage = _Stage.categories),
              child: const Text('Volver'),
            ),
          ],
        ),
      ),
    );
  }
}

extension on Widget {
  /// Agrega una etiqueta "Nuevo"/"Actualizar" a la derecha de una fila.
  Widget withBadge(String text, bool highlight, ThemeData theme) => Row(
    children: [
      Expanded(child: this),
      Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: highlight
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(text, style: theme.textTheme.labelSmall),
        ),
      ),
    ],
  );
}

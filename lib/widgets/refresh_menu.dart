import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../db/app_database.dart';
import '../models.dart';
import '../services/panini_scraper.dart';
import '../services/stores.dart';

/// Ajuste donde se recuerdan las secciones elegidas la última vez en cada
/// tienda (el de México conserva el nombre de antes).
String savedCategoriesKey(PaniniStore store) => store.key == mexico.key
    ? 'scraper_categories'
    : 'scraper_categories_${store.key}';

/// Secciones a descargar: las de la última vez o, si no hay, las
/// predeterminadas (todo menos manga, estampas, figuras, etc.).
Set<int> chosenCategories(
  AppDatabase db,
  PaniniStore store,
  List<StoreCategory> cats,
) {
  final saved = (db.getSetting(savedCategoriesKey(store)) ?? '')
      .split(',')
      .map(int.tryParse)
      .whereType<int>()
      .toSet();
  final remembered = {
    for (final c in cats)
      if (saved.contains(c.id)) c.id,
  };
  return remembered.isNotEmpty ? remembered : defaultCategories(store, cats);
}

Set<int> defaultCategories(PaniniStore store, List<StoreCategory> cats) => {
  for (final c in cats)
    if (!store.defaultExcluded.contains(c.name)) c.id,
};

void saveChosenCategories(AppDatabase db, PaniniStore store, Set<int> ids) =>
    db.setSetting(savedCategoriesKey(store), ids.join(','));

/// Secciones de una tienda (con caché por sesión: casi no cambian).
final _categoryCache = <String, List<StoreCategory>>{};

Future<List<StoreCategory>> loadStoreCategories(PaniniStore store) async {
  if (RefreshMenuButton.loader case final load?) return load(store);
  if (_categoryCache[store.key] case final cached?) return cached;
  final scraper = PaniniScraper(store: store);
  try {
    return _categoryCache[store.key] = await scraper.fetchCategories();
  } finally {
    scraper.close();
  }
}

/// Botón ↻ del catálogo: abre un menú para elegir tienda y secciones y
/// lanzar la actualización. Al confirmar guarda la selección y llama a
/// [onRefresh].
class RefreshMenuButton extends StatefulWidget {
  const RefreshMenuButton({super.key, required this.onRefresh});

  final ValueChanged<PaniniStore> onRefresh;

  /// Cómo se piden las secciones a la tienda (solo para pruebas).
  @visibleForTesting
  static Future<List<StoreCategory>> Function(PaniniStore store)? loader;

  @override
  State<RefreshMenuButton> createState() => _RefreshMenuButtonState();
}

class _RefreshMenuButtonState extends State<RefreshMenuButton> {
  final _menu = MenuController();
  PaniniStore _store = mexico;
  List<StoreCategory>? _cats;
  Set<int> _chosen = {};
  bool _loading = false;
  String? _error;

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = _store;
      final cats = await loadStoreCategories(store);
      if (!mounted || store != _store) return;
      final db = AppScope.of(context).db;
      setState(() {
        _cats = cats;
        _chosen = chosenCategories(db, store, cats);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Sin conexión con la tienda');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open() {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    // Se recarga cada vez: la tienda puede agregar secciones.
    if (_cats != null) {
      _chosen = chosenCategories(AppScope.of(context).db, _store, _cats!);
    }
    _menu.open();
    _load();
  }

  void _refresh() {
    saveChosenCategories(AppScope.of(context).db, _store, _chosen);
    _menu.close();
    widget.onRefresh(_store);
  }

  void _toggle(int id, bool on) =>
      setState(() => on ? _chosen.add(id) : _chosen.remove(id));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );

    final cats = _cats;
    return MenuAnchor(
      controller: _menu,
      style: const MenuStyle(
        maximumSize: WidgetStatePropertyAll(Size(340, 560)),
      ),
      menuChildren: [
        label('Tienda'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: DropdownButton<PaniniStore>(
            value: _store,
            isExpanded: true,
            items: [
              for (final s in paniniStores)
                DropdownMenuItem(
                  value: s,
                  child: Text('${s.name} (${s.currency})'),
                ),
            ],
            onChanged: (v) {
              if (v == null || v == _store) return;
              setState(() {
                _store = v;
                _cats = null;
                _chosen = {};
              });
              _load();
            },
          ),
        ),
        label('Secciones'),
        if (cats == null && _loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (cats == null)
          MenuItemButton(
            leadingIcon: const Icon(Icons.wifi_off),
            onPressed: _load,
            closeOnActivate: false,
            child: Text('${_error ?? 'No se cargaron'} · Reintentar'),
          )
        else ...[
          Row(
            children: [
              TextButton(
                onPressed: () =>
                    setState(() => _chosen = {for (final c in cats) c.id}),
                child: const Text('Todas'),
              ),
              TextButton(
                onPressed: () =>
                    setState(() => _chosen = defaultCategories(_store, cats)),
                child: const Text('Predeterminadas'),
              ),
            ],
          ),
          for (final c in cats)
            CheckboxMenuButton(
              value: _chosen.contains(c.id),
              closeOnActivate: false,
              onChanged: (v) => _toggle(c.id, v ?? false),
              child: Text('${c.name} (${c.productCount})'),
            ),
        ],
        const Divider(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: FilledButton.icon(
            onPressed: _chosen.isEmpty ? null : _refresh,
            icon: const Icon(Icons.cloud_download_outlined),
            label: Text(
              'Actualizar ahora (${_chosen.length} '
              '${_chosen.length == 1 ? 'sección' : 'secciones'})',
            ),
          ),
        ),
      ],
      child: IconButton.outlined(
        tooltip: 'Actualizar catálogo de Panini',
        icon: const Icon(Icons.refresh),
        onPressed: _open,
      ),
    );
  }
}

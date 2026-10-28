import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../services/pdf_export.dart';
import '../widgets/comic_picker.dart';
import '../widgets/comic_widgets.dart';
import 'home_shell.dart';

enum _Filter { all, missing, purchased, owned }

enum _Sort { number, date, name }

/// Número del cómic: el de la tienda o, si no viene, el que aparece en el
/// nombre ("#12", "Vol.32", "N.5").
int? comicNumber(Comic c) {
  if (c.number != null) return c.number;
  final m = RegExp(
    r'(?:#\s*|\bVol\.?\s*|\bNo?\.\s*)(\d+)',
    caseSensitive: false,
  ).firstMatch(c.name);
  return m == null ? null : int.parse(m.group(1)!);
}

/// Ordena por número (los que no tienen número van al final), luego por
/// fecha de salida y nombre.
int compareByNumber(Comic a, Comic b) {
  final na = comicNumber(a), nb = comicNumber(b);
  if (na != nb) {
    if (na == null) return 1;
    if (nb == null) return -1;
    return na.compareTo(nb);
  }
  final d = (a.releaseDate ?? '9999').compareTo(b.releaseDate ?? '9999');
  return d != 0 ? d : a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// Cómics de una colección, con casillas para marcar cuáles ya se tienen.
class CollectionDetailScreen extends StatefulWidget {
  const CollectionDetailScreen({
    super.key,
    required this.collectionId,
    required this.changes,
  });

  final int collectionId;
  final DataChanges changes;

  @override
  State<CollectionDetailScreen> createState() => _CollectionDetailScreenState();
}

class _CollectionDetailScreenState extends State<CollectionDetailScreen> {
  List<CollectionItem> _items = [];
  String _name = '';
  _Filter _filter = _Filter.all;
  _Sort _sort = _Sort.number;
  final _search = TextEditingController();
  bool _loaded = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Aplica estado, búsqueda y orden.
  List<CollectionItem> _visibleItems() {
    final q = _search.text.trim().toLowerCase().replaceFirst('#', '');
    final asNumber = int.tryParse(q);
    final list = _items.where((i) {
      final ok = switch (_filter) {
        _Filter.all => true,
        _Filter.missing => !i.owned && i.status != ComicStatus.purchased,
        _Filter.purchased => i.status == ComicStatus.purchased,
        _Filter.owned => i.status == ComicStatus.owned,
      };
      if (!ok) return false;
      if (q.isEmpty) return true;
      // Un número busca ese número exacto; un texto busca en el nombre.
      if (asNumber != null) return comicNumber(i.comic) == asNumber;
      return i.comic.name.toLowerCase().contains(q);
    }).toList();
    switch (_sort) {
      case _Sort.number:
        list.sort((a, b) => compareByNumber(a.comic, b.comic));
      case _Sort.date:
        list.sort((a, b) {
          final d = (a.comic.releaseDate ?? '9999').compareTo(
            b.comic.releaseDate ?? '9999',
          );
          return d != 0 ? d : compareByNumber(a.comic, b.comic);
        });
      case _Sort.name:
        list.sort(
          (a, b) =>
              a.comic.name.toLowerCase().compareTo(b.comic.name.toLowerCase()),
        );
    }
    return list;
  }

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
    final col = scope.db
        .collections(scope.user.id)
        .where((c) => c.id == widget.collectionId)
        .firstOrNull;
    setState(() {
      _name = col?.name ?? '';
      _items = scope.db.collectionItems(scope.user.id, widget.collectionId);
    });
  }

  void _setStatus(CollectionItem item, ComicStatus status) {
    final scope = AppScope.of(context);
    scope.db.setStatus(scope.user.id, [item.comic.sku], status);
    _reload();
  }

  /// Tocar la tarjeta: lo que no tienes pasa a "obtenido" (por ejemplo,
  /// lo comprado que ya llegó); lo obtenido vuelve a "sin clasificar".
  void _toggle(CollectionItem item) => _setStatus(
    item,
    item.owned ? ComicStatus.unclassified : ComicStatus.owned,
  );

  void _remove(CollectionItem item) {
    final scope = AppScope.of(context);
    scope.db.removeFromCollection(
      scope.user.id,
      widget.collectionId,
      item.comic.sku,
    );
    _reload();
    showNotice(
      ScaffoldMessenger.of(context),
      'Quitado: ${item.comic.name}',
      onUndo: () {
        scope.db.addToCollection(scope.user.id, widget.collectionId, [
          item.comic.sku,
        ]);
        if (mounted) _reload();
      },
    );
  }

  Future<void> _addComics() async {
    final picked = await pickComics(
      context,
      already: {for (final i in _items) i.comic.sku},
      alreadyLabel: 'Ya está en la colección',
    );
    if (picked == null || !mounted) return;
    final scope = AppScope.of(context);
    scope.db.addToCollection(scope.user.id, widget.collectionId, picked);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    const value = sumValue;
    final owned = _items.where((i) => i.status == ComicStatus.owned);
    final purchased = _items.where((i) => i.status == ComicStatus.purchased);
    final counts = StatusCounts(
      total: _items.length,
      owned: owned.length,
      purchased: purchased.length,
      totalValue: value(_items),
      ownedValue: value(owned),
      purchasedValue: value(purchased),
    );
    final visible = _visibleItems();

    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: [
          IconButton(
            tooltip: 'Exportar PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: () => exportComicsPdf(
              context,
              title: switch (_filter) {
                _Filter.all => _name,
                _Filter.missing => '$_name (me faltan)',
                _Filter.purchased => '$_name (comprados)',
                _Filter.owned => '$_name (obtenidos)',
              },
              items: visible,
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addComics,
        icon: const Icon(Icons.add),
        label: const Text('Agregar cómics'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _items.isEmpty
                      ? 'Esta colección está vacía.'
                      : 'Obtenidos ${counts.owned} de ${counts.total} · '
                            'comprados ${counts.purchased} · faltan ${counts.missing}',
                ),
                if (_items.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  CollectionValues(counts: counts),
                ],
                const SizedBox(height: 6),
                StackedStatusBar(counts: counts, height: 10),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<_Filter>(
                      segments: const [
                        ButtonSegment(value: _Filter.all, label: Text('Todos')),
                        ButtonSegment(
                          value: _Filter.missing,
                          label: Text('Me faltan'),
                        ),
                        ButtonSegment(
                          value: _Filter.purchased,
                          label: Text('Comprados'),
                        ),
                        ButtonSegment(
                          value: _Filter.owned,
                          label: Text('Obtenidos'),
                        ),
                      ],
                      selected: {_filter},
                      onSelectionChanged: (s) =>
                          setState(() => _filter = s.first),
                    ),
                    DropdownMenu<_Sort>(
                      initialSelection: _sort,
                      label: const Text('Ordenar por'),
                      width: 190,
                      inputDecorationTheme: const InputDecorationTheme(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSelected: (v) =>
                          setState(() => _sort = v ?? _Sort.number),
                      dropdownMenuEntries: const [
                        DropdownMenuEntry(value: _Sort.number, label: 'Número'),
                        DropdownMenuEntry(
                          value: _Sort.date,
                          label: 'Fecha de salida',
                        ),
                        DropdownMenuEntry(value: _Sort.name, label: 'Nombre'),
                      ],
                    ),
                    SizedBox(
                      width: 240,
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: 'Buscar número o nombre',
                          prefixIcon: const Icon(Icons.search),
                          border: const OutlineInputBorder(),
                          isDense: true,
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () => setState(_search.clear),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      _items.isEmpty
                          ? 'Agrega cómics desde el catálogo o con el botón de abajo.'
                          : 'No hay cómics en este filtro.',
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                    gridDelegate: comicGridDelegate,
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final item = visible[i];
                      return ComicStatusCard(
                        comic: item.comic,
                        status: item.status,
                        onTap: () => _toggle(item),
                        actions: [
                          ...statusActions(
                            item.status,
                            (st) => _setStatus(item, st),
                          ),
                          CardAction(
                            'Ver ficha',
                            Icons.info_outline,
                            () => showComicDetail(
                              context,
                              item.comic,
                              onChanged: _reload,
                            ),
                          ),
                          CardAction(
                            'Quitar de la colección',
                            Icons.remove_circle_outline,
                            () => _remove(item),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

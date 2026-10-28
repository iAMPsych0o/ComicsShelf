import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../widgets/comic_widgets.dart';
import 'collection_detail_screen.dart';
import 'home_shell.dart';

class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({
    super.key,
    required this.changes,
    required this.onGoToCatalog,
  });

  final DataChanges changes;
  final VoidCallback onGoToCatalog;

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  List<Collection> _collections = [];
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

  StatusCounts _totals = const StatusCounts();

  void _reload() {
    final scope = AppScope.of(context);
    setState(() {
      _collections = scope.db.collections(scope.user.id);
      _totals = scope.db.collectionTotals(scope.user.id);
    });
  }

  Future<void> _create() async {
    final scope = AppScope.of(context);
    final name = await askText(
      context,
      title: 'Nueva colección',
      label: 'Nombre de la colección',
    );
    if (name == null) return;
    scope.db.createCollection(scope.user.id, name);
    widget.changes.changed();
  }

  Future<void> _rename(Collection c) async {
    final scope = AppScope.of(context);
    final name = await askText(
      context,
      title: 'Renombrar colección',
      label: 'Nombre',
      initial: c.name,
    );
    if (name == null) return;
    scope.db.renameCollection(scope.user.id, c.id, name);
    widget.changes.changed();
  }

  Future<void> _delete(Collection c) async {
    final scope = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar colección'),
        content: Text(
          '¿Eliminar "${c.name}"? Los cómics siguen en el catálogo.',
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
    scope.db.deleteCollection(scope.user.id, c.id);
    widget.changes.changed();
  }

  Future<void> _open(Collection c) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            CollectionDetailScreen(collectionId: c.id, changes: widget.changes),
      ),
    );
    widget.changes.changed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('Nueva colección'),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: _collections.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          if (i == 0) {
            return _Dashboard(
              totals: _totals,
              onGoToCatalog: widget.onGoToCatalog,
            );
          }
          final c = _collections[i - 1];
          final complete = c.total > 0 && c.owned == c.total;
          return Card(
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              leading: CircleAvatar(
                backgroundColor: complete
                    ? ownedColor
                    : const Color(0xFF262626),
                child: Icon(
                  complete ? Icons.check : Icons.collections_bookmark,
                  color: Colors.white,
                ),
              ),
              title: Text(c.name, style: theme.textTheme.titleMedium),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 6),
                  StackedStatusBar(counts: c.counts, height: 8),
                  const SizedBox(height: 4),
                  Text(
                    c.total == 0
                        ? 'Sin cómics'
                        : 'Obtenidos ${c.owned} de ${c.total} · comprados ${c.purchased}'
                              ' · faltan ${c.counts.missing}',
                  ),
                  if (c.total > 0) ...[
                    const SizedBox(height: 4),
                    CollectionValues(counts: c.counts),
                  ],
                ],
              ),
              onTap: () => _open(c),
              trailing: PopupMenuButton<String>(
                onSelected: (v) => v == 'rename' ? _rename(c) : _delete(c),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Renombrar')),
                  PopupMenuItem(value: 'delete', child: Text('Eliminar')),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Resumen de todas las colecciones: cifras principales, barra apilada del
/// total y leyenda. Cuenta cada cómic una vez aunque esté en varias colecciones.
class _Dashboard extends StatelessWidget {
  const _Dashboard({required this.totals, required this.onGoToCatalog});

  final StatusCounts totals;
  final VoidCallback onGoToCatalog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = totals.total == 0
        ? 0
        : (totals.owned * 100 / totals.total).round();

    Widget tile(
      String label,
      int value,
      double money,
      IconData icon,
      Color accent,
    ) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: accent, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$value',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            formatPrice(money),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Mi colección', style: theme.textTheme.titleLarge),
                const Spacer(),
                Text(
                  '$pct%',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('completo', style: theme.textTheme.bodySmall),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Cuatro tarjetas que ocupan todo el ancho (25% cada una);
            // en pantallas angostas pasan a dos por fila.
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 10.0;
                final perRow = constraints.maxWidth < 520 ? 2 : 4;
                final width =
                    (constraints.maxWidth - gap * (perRow - 1)) / perRow;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final t in [
                      tile(
                        'Total de cómics',
                        totals.total,
                        totals.totalValue,
                        Icons.menu_book,
                        Colors.white,
                      ),
                      tile(
                        'Obtenidos',
                        totals.owned,
                        totals.ownedValue,
                        statusIcon(ComicStatus.owned),
                        ownedColor,
                      ),
                      tile(
                        'Comprados',
                        totals.purchased,
                        totals.purchasedValue,
                        statusIcon(ComicStatus.purchased),
                        purchasedColor,
                      ),
                      tile(
                        'Me faltan',
                        totals.missing,
                        totals.missingValue,
                        Icons.close,
                        missingColor,
                      ),
                    ])
                      SizedBox(width: width, child: t),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            if (totals.total == 0)
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Agrega cómics a tus colecciones para ver tu avance.',
                    ),
                  ),
                  TextButton(
                    onPressed: onGoToCatalog,
                    child: const Text('Ir al catálogo'),
                  ),
                ],
              )
            else ...[
              StackedStatusBar(counts: totals, height: 16),
              const SizedBox(height: 8),
              Center(child: StatusLegend(counts: totals)),
            ],
          ],
        ),
      ),
    );
  }
}

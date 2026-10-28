import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../services/pdf_export.dart';
import '../widgets/comic_widgets.dart';
import 'home_shell.dart';

/// Cómics con estado "Wishlist": lo que quieres conseguir.
class WishlistScreen extends StatefulWidget {
  const WishlistScreen({
    super.key,
    required this.changes,
    required this.onGoToCatalog,
  });

  final DataChanges changes;
  final VoidCallback onGoToCatalog;

  @override
  State<WishlistScreen> createState() => _WishlistScreenState();
}

class _WishlistScreenState extends State<WishlistScreen> {
  List<CollectionItem> _items = [];
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
    setState(
      () => _items = scope.db.itemsWithStatus(
        scope.user.id,
        ComicStatus.wishlist,
      ),
    );
  }

  /// Al cambiar de estado sale de la wishlist; se puede deshacer.
  void _mark(CollectionItem item, ComicStatus status) {
    final scope = AppScope.of(context);
    scope.db.setStatus(scope.user.id, [item.comic.sku], status);
    widget.changes.changed();
    showNotice(
      ScaffoldMessenger.of(context),
      '"${item.comic.name}" → ${status.label}',
      status: status,
      onUndo: () {
        scope.db.setStatus(scope.user.id, [
          item.comic.sku,
        ], ComicStatus.wishlist);
        widget.changes.changed();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.favorite_border, size: 64),
              const SizedBox(height: 12),
              const Text(
                'Tu wishlist está vacía.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              const Text(
                'En el catálogo, abre el menú ⋮ de un cómic o su ficha y elige '
                '"Wishlist".',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: widget.onGoToCatalog,
                icon: const Icon(Icons.grid_view),
                label: const Text('Ir al catálogo'),
              ),
            ],
          ),
        ),
      );
    }

    final cost = sumValue(_items);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_items.length} cómics en tu wishlist',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (cost > 0)
                Text(
                  'Total estimado: ${formatPrice(cost)}',
                  style: theme.textTheme.titleSmall,
                ),
              IconButton(
                tooltip: 'Exportar PDF',
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: () =>
                    exportComicsPdf(context, title: 'Wishlist', items: _items),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: comicGridDelegate,
            itemCount: _items.length,
            itemBuilder: (context, i) {
              final item = _items[i];
              return ComicStatusCard(
                comic: item.comic,
                status: item.status,
                onTap: () => showComicDetail(
                  context,
                  item.comic,
                  onChanged: widget.changes.changed,
                ),
                actions: [
                  CardAction(
                    'Agregar a carrito…',
                    Icons.add_shopping_cart,
                    () async {
                      if (await addComicsToCart(context, [item.comic.sku])) {
                        widget.changes.changed();
                      }
                    },
                  ),
                  CardAction(
                    'Marcar: comprado',
                    statusIcon(ComicStatus.purchased),
                    () => _mark(item, ComicStatus.purchased),
                  ),
                  CardAction(
                    'Marcar: obtenido',
                    statusIcon(ComicStatus.owned),
                    () => _mark(item, ComicStatus.owned),
                  ),
                  CardAction(
                    'Ya no me interesa',
                    statusIcon(ComicStatus.notInterested),
                    () => _mark(item, ComicStatus.notInterested),
                  ),
                  CardAction(
                    'Quitar de wishlist',
                    Icons.heart_broken_outlined,
                    () => _mark(item, ComicStatus.unclassified),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

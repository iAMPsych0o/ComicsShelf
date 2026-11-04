import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../db/app_database.dart';
import 'settings_dialog.dart';
import 'catalog_screen.dart';
import 'collections_screen.dart';
import 'purchases_screen.dart';
import '../services/stores.dart';
import 'scraper_screen.dart';
import 'storage_screen.dart';
import 'sync_screen.dart';
import 'wishlist_screen.dart';

/// Avisa a las pantallas que los datos cambiaron (migración, colecciones).
class DataChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// Junto al nombre: aparece mientras haya cambios que el otro dispositivo
/// aún no recibió.
class SyncPendingIcon extends StatefulWidget {
  const SyncPendingIcon({
    super.key,
    required this.db,
    required this.userId,
    required this.onPressed,
  });

  final AppDatabase db;
  final int userId;
  final VoidCallback onPressed;

  @override
  State<SyncPendingIcon> createState() => _SyncPendingIconState();
}

class _SyncPendingIconState extends State<SyncPendingIcon> {
  late StreamSubscription<void> _changes;

  @override
  void initState() {
    super.initState();
    _changes = widget.db.syncStateChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _changes.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.db.hasUnsyncedChanges(widget.userId)) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: 'Hay cambios sin sincronizar con el otro dispositivo',
      visualDensity: VisualDensity.compact,
      icon: Icon(Icons.sync_problem, color: Colors.amber.shade700),
      onPressed: widget.onPressed,
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final _changes = DataChanges();
  final _scraperKey = GlobalKey<ScraperScreenState>();

  /// Botón de actualizar del catálogo: abre "Actualizar" y descarga ya.
  void _refreshCatalog(PaniniStore store) {
    _goTo(_scraperIndex);
    _scraperKey.currentState?.refreshNow(store);
  }

  static const _scraperIndex = 5;

  static const _destinations = [
    (
      icon: Icons.grid_view_outlined,
      selected: Icons.grid_view,
      label: 'Catálogo',
      short: 'Catálogo',
    ),
    (
      icon: Icons.collections_bookmark_outlined,
      selected: Icons.collections_bookmark,
      label: 'Colecciones',
      short: 'Colecciones',
    ),
    (
      icon: Icons.favorite_border,
      selected: Icons.favorite,
      label: 'Wishlist',
      short: 'Wishlist',
    ),
    (
      icon: Icons.shopping_cart_outlined,
      selected: Icons.shopping_cart,
      label: 'Compras',
      short: 'Compras',
    ),
    // En la barra de abajo del teléfono no cabe el nombre completo.
    (
      icon: Icons.shelves,
      selected: Icons.shelves,
      label: 'Almacenamiento',
      short: 'Almacén',
    ),
    (
      icon: Icons.cloud_download_outlined,
      selected: Icons.cloud_download,
      label: 'Actualizar',
      short: 'Actualizar',
    ),
  ];

  @override
  void dispose() {
    _changes.dispose();
    super.dispose();
  }

  void _goTo(int i) => setState(() => _index = i);

  void _openSync() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SyncScreen(onDataChanged: _changes.changed),
    ),
  );

  Future<void> _confirmLogout() async {
    final scope = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: Text('¿Cerrar la sesión de ${scope.user.username}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
    if (ok == true) scope.auth.logout();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final user = scope.user;
    final pages = [
      CatalogScreen(
        changes: _changes,
        onGoToScraper: () => _goTo(_scraperIndex),
        onRefreshCatalog: _refreshCatalog,
      ),
      CollectionsScreen(changes: _changes, onGoToCatalog: () => _goTo(0)),
      WishlistScreen(changes: _changes, onGoToCatalog: () => _goTo(0)),
      PurchasesScreen(changes: _changes, onGoToCatalog: () => _goTo(0)),
      StorageScreen(changes: _changes),
      ScraperScreen(key: _scraperKey, changes: _changes),
    ];
    final body = IndexedStack(index: _index, children: pages);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final appBar = AppBar(
          title: Text(_destinations[_index].label),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: Text(user.username)),
            ),
            SyncPendingIcon(
              key: ValueKey(user.id),
              db: scope.db,
              userId: user.id,
              onPressed: _openSync,
            ),
            // En pantallas angostas no hay panel lateral: configuración arriba.
            if (!wide)
              IconButton(
                tooltip: 'Configuración',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () =>
                    showSettings(context, onDataChanged: _changes.changed),
              ),
            IconButton(
              tooltip: 'Cerrar sesión',
              icon: const Icon(Icons.logout),
              onPressed: _confirmLogout,
            ),
          ],
        );

        if (wide) {
          return Scaffold(
            appBar: appBar,
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _goTo,
                  labelType: NavigationRailLabelType.all,
                  trailingAtBottom: true,
                  trailing: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: IconButton(
                      tooltip: 'Configuración',
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => showSettings(
                        context,
                        onDataChanged: _changes.changed,
                      ),
                    ),
                  ),
                  destinations: [
                    for (final d in _destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selected),
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          );
        }
        return Scaffold(
          appBar: appBar,
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _goTo,
            destinations: [
              for (final d in _destinations)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selected),
                  label: d.short,
                ),
            ],
          ),
        );
      },
    );
  }
}

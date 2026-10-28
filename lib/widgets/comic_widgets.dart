import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_scope.dart';
import '../models.dart';
import '../services/cover_cache.dart';
import '../services/currency.dart';
import '../services/stores.dart';

/// Portada de un cómic con un marcador de posición si no hay imagen.
class ComicCover extends StatelessWidget {
  const ComicCover({super.key, required this.url, this.width, this.height});

  final String? url;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(Icons.menu_book, color: scheme.onSurfaceVariant),
    );
    if (url == null) return placeholder;
    final cache = CoverCache.instance;
    return Image(
      image: cache == null
          ? NetworkImage(CoverCache.thumbUrl(url!))
          : CachedCover(cache, url!),
      width: width,
      height: height,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => placeholder,
      frameBuilder: (context, child, frame, sync) =>
          frame == null && !sync ? placeholder : child,
    );
  }
}

/// Cuánto vale lo que ya tienes, lo comprado y lo que te falta, con el color
/// de cada estado.
class CollectionValues extends StatelessWidget {
  const CollectionValues({super.key, required this.counts});

  final StatusCounts counts;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    Widget value(Color color, String label, double amount) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text('$label ${formatPrice(amount)}', style: style),
      ],
    );
    return Wrap(
      spacing: 14,
      runSpacing: 2,
      children: [
        value(ownedColor, 'Tienes', counts.ownedValue),
        if (counts.purchased > 0)
          value(purchasedColor, 'Comprado', counts.purchasedValue),
        value(missingColor, 'Te falta', counts.missingValue),
      ],
    );
  }
}

const preorderColor = Color(0xFF6A47B8);
const availableColor = Color(0xFF2F6FB0);
const soldOutColor = Color(0xFF2A2A2A);

Color availabilityColor(Availability a) => switch (a) {
  Availability.available => const Color(0xFF5A9BD8),
  // El gris de "agotado" de la card no se ve sobre el fondo del panel.
  Availability.soldOut => const Color(0xFF8A8A8A),
  Availability.preorder => const Color(0xFF9A7FE0),
};

IconData availabilityIcon(Availability a) => switch (a) {
  Availability.available => Icons.shopping_bag_outlined,
  Availability.soldOut => Icons.remove_shopping_cart_outlined,
  Availability.preorder => Icons.schedule,
};

/// "Preventa · Disponible", "Agotado", etc., para el detalle del cómic.
String availabilityText(Comic comic) => [
  if (comic.isPreorder())
    comic.releaseDate == null
        ? 'Preventa'
        : 'Preventa (sale el ${comic.releaseDate})',
  if (comic.hasStockInfo) comic.inStock ? 'Disponible' : 'Agotado',
].join(' · ');

/// Etiquetas sobre la portada: Preventa y Disponible / Agotado, para ver de
/// un vistazo qué se puede comprar.
class AvailabilityBadges extends StatelessWidget {
  const AvailabilityBadges({super.key, required this.comic});

  final Comic comic;

  @override
  Widget build(BuildContext context) {
    Widget badge(String text, Color color, {Color textColor = Colors.white}) =>
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: textColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        if (comic.store != mexico.key)
          badge(comic.shop.shortCode, const Color(0xFF8A5A00)),
        if (comic.isPreorder()) badge('Preventa', preorderColor),
        if (comic.hasStockInfo)
          comic.inStock
              ? badge('Disponible', availableColor)
              : badge(
                  'Agotado',
                  soldOutColor,
                  textColor: const Color(0xFFD0D0D0),
                ),
      ],
    );
  }
}

/// Cuadrícula de portadas usada en el catálogo y en las colecciones.
const comicGridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 190,
  childAspectRatio: 0.52,
  crossAxisSpacing: 10,
  mainAxisSpacing: 10,
);

/// Monto ya en la moneda elegida: 8745.5 → "$8,745.50 MXN".
String formatPrice(double? amount) => Money.instance.format(amount);

/// Precio de un cómic convertido a la moneda elegida.
String formatComicPrice(Comic c) =>
    Money.instance.formatFrom(c.price, c.currency);

/// Precio de un cómic en la moneda elegida, para sumar (0 si no se puede).
double comicValue(Comic c) => Money.instance.convert(c.price, c.currency) ?? 0;

/// Suma de precios en la moneda elegida.
double sumValue(Iterable<CollectionItem> items) =>
    items.fold(0, (s, i) => s + comicValue(i.comic));

/// Aviso breve abajo de la pantalla. Se cierra al hacer clic sobre él, con
/// la ✕ o solo a los 4 segundos, aunque tenga botón de deshacer (Flutter deja
/// fijos los avisos con botón si no se indica lo contrario).
///
/// [status] pinta el aviso con el color del estado que se aplicó; sin él,
/// usa un gris oscuro neutro.
void showNotice(
  ScaffoldMessengerState messenger,
  String text, {
  VoidCallback? onUndo,
  ComicStatus? status,
}) {
  final color = switch (status) {
    null => const Color(0xFF2A2A2A),
    ComicStatus.owned ||
    ComicStatus.purchased ||
    ComicStatus.wishlist => statusBackground(status),
    _ => statusColor(status),
  };
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: messenger.hideCurrentSnackBar,
          child: Row(
            children: [
              if (status != null) ...[
                Icon(statusIcon(status), color: Colors.white, size: 18),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(text, style: const TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
        backgroundColor: color,
        closeIconColor: Colors.white,
        behavior: SnackBarBehavior.floating,
        width: 520,
        duration: const Duration(seconds: 4),
        persist: false,
        showCloseIcon: true,
        action: onUndo == null
            ? null
            : SnackBarAction(
                label: 'Deshacer',
                textColor: Colors.white,
                onPressed: onUndo,
              ),
      ),
    );
}

/// Dialogo para elegir (o crear) una colección. Devuelve su id.
Future<int?> pickCollection(BuildContext context) {
  final scope = AppScope.of(context);
  return showDialog<int>(
    context: context,
    builder: (ctx) {
      final collections = scope.db.collections(scope.user.id);
      return SimpleDialog(
        title: const Text('Agregar a colección'),
        children: [
          for (final c in collections)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c.id),
              child: ListTile(
                leading: const Icon(Icons.collections_bookmark_outlined),
                title: Text(c.name),
                subtitle: Text('${c.total} cómics'),
              ),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final name = await askText(
                ctx,
                title: 'Nueva colección',
                label: 'Nombre de la colección',
              );
              if (name == null || !ctx.mounted) return;
              final id = scope.db.createCollection(scope.user.id, name);
              Navigator.pop(ctx, id);
            },
            child: const ListTile(
              leading: Icon(Icons.add),
              title: Text('Nueva colección…'),
            ),
          ),
        ],
      );
    },
  );
}

/// Pide un texto (nombre de colección, etc.).
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(title: title, label: label, initial: initial),
);

/// El diálogo es dueño de su controlador y lo libera al desmontarse, después
/// de la animación de cierre.
class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.initial,
  });

  final String title;
  final String label;
  final String initial;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _controller.text.trim();
    if (v.isNotEmpty) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Guardar')),
      ],
    );
  }
}

/// Agrega cómics a una colección elegida y muestra el resultado.
Future<bool> addComicsToCollection(
  BuildContext context,
  List<String> skus,
) async {
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final id = await pickCollection(context);
  if (id == null) return false;
  final added = scope.db.addToCollection(scope.user.id, id, skus);
  final name = scope.db
      .collections(scope.user.id)
      .firstWhere((c) => c.id == id)
      .name;
  final skipped = skus.length - added;
  showNotice(
    messenger,
    '$added agregado(s) a "$name"'
    '${skipped > 0 ? ' ($skipped ya estaban)' : ''}',
  );
  return true;
}

/// Elige un carrito (o crea uno nuevo). Devuelve su id.
Future<int?> pickCart(BuildContext context) {
  final scope = AppScope.of(context);
  return showDialog<int>(
    context: context,
    builder: (ctx) {
      final carts = scope.db.carts(scope.user.id);
      return SimpleDialog(
        title: const Text('Agregar a carrito'),
        children: [
          for (final c in carts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c.id),
              child: ListTile(
                leading: const Icon(Icons.shopping_cart_outlined),
                title: Text(c.name),
                subtitle: Text('${c.count} cómics · ${formatPrice(c.total)}'),
              ),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final name = await askText(
                ctx,
                title: 'Nuevo carrito',
                label: 'Nombre del carrito',
              );
              if (name == null || !ctx.mounted) return;
              Navigator.pop(ctx, scope.db.createCart(scope.user.id, name));
            },
            child: const ListTile(
              leading: Icon(Icons.add),
              title: Text('Nuevo carrito…'),
            ),
          ),
        ],
      );
    },
  );
}

/// Agrega cómics a un carrito elegido y muestra el resultado.
Future<bool> addComicsToCart(BuildContext context, List<String> skus) async {
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final id = await pickCart(context);
  if (id == null) return false;
  final added = scope.db.addToCart(scope.user.id, id, skus);
  final cart = scope.db.carts(scope.user.id).firstWhere((c) => c.id == id);
  final skipped = skus.length - added;
  showNotice(
    messenger,
    '$added agregado(s) a "${cart.name}" · total ${formatPrice(cart.total)}'
    '${skipped > 0 ? ' ($skipped ya estaban)' : ''}',
  );
  return true;
}

/// Ficha con los datos de un cómic.
Future<void> showComicDetail(
  BuildContext context,
  Comic comic, {
  VoidCallback? onChanged,
}) {
  return showDialog(
    context: context,
    builder: (ctx) {
      final scope = AppScope.of(ctx);
      final theme = Theme.of(ctx);
      final inCollections =
          scope.db.skuCollections(scope.user.id)[comic.sku] ?? const [];
      final series = comic.seriesCode == null
          ? const <Comic>[]
          : scope.db.comicsInSeries(comic.seriesCode!);
      var status =
          scope.db.statuses(scope.user.id)[comic.sku] ??
          ComicStatus.unclassified;

      return StatefulBuilder(
        builder: (ctx, setLocal) {
          Widget row(String label, String? value) =>
              value == null || value.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$label: ',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(text: value),
                      ],
                    ),
                  ),
                );

          final info = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(comic.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              StatusSelector(
                status: status,
                onChanged: (v) {
                  scope.db.setStatus(scope.user.id, [comic.sku], v);
                  setLocal(() => status = v);
                  onChanged?.call();
                },
              ),
              const SizedBox(height: 8),
              row('Serie', comic.series),
              row('Número', comic.number?.toString()),
              row(
                'Precio',
                comic.currency == Money.instance.display
                    ? formatComicPrice(comic)
                    : '${formatComicPrice(comic)} '
                          '(${Money.formatIn(comic.price ?? 0, comic.currency)} '
                          'en ${comic.shop.name})',
              ),
              row('Tienda', comic.shop.name),
              row('Fecha de salida', comic.releaseDate),
              row('Páginas', comic.pages?.toString()),
              row('ISBN', comic.isbn),
              row('SKU', comic.sku),
              row('Disponibilidad', availabilityText(comic)),
              row('Categorías', comic.categories.join(', ')),
              if (comic.contains != null) ...[
                const SizedBox(height: 8),
                Text('Contenido', style: theme.textTheme.titleSmall),
                Text(comic.contains!),
              ],
              if (inCollections.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final n in inCollections)
                      Chip(
                        avatar: const Icon(Icons.bookmark, size: 16),
                        label: Text(n),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
            ],
          );

          return AlertDialog(
            contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            content: SizedBox(
              width: 640,
              child: SingleChildScrollView(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final cover = ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ComicCover(
                        url: comic.imageUrl,
                        width: 180,
                        height: 270,
                      ),
                    );
                    if (c.maxWidth < 460) {
                      return Column(
                        children: [cover, const SizedBox(height: 16), info],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cover,
                        const SizedBox(width: 20),
                        Expanded(child: info),
                      ],
                    );
                  },
                ),
              ),
            ),
            actionsOverflowButtonSpacing: 4,
            actions: [
              TextButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('Ver en tienda'),
                onPressed: () => launchUrl(Uri.parse(comic.storeUrl)),
              ),
              if (series.length > 1)
                TextButton.icon(
                  icon: const Icon(Icons.library_add),
                  label: Text('Agregar serie (${series.length})'),
                  onPressed: () async {
                    final ok = await addComicsToCollection(
                      ctx,
                      series.map((s) => s.sku).toList(),
                    );
                    if (ok && ctx.mounted) {
                      onChanged?.call();
                      Navigator.pop(ctx);
                    }
                  },
                ),
              TextButton.icon(
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text('Carrito'),
                onPressed: () async {
                  final ok = await addComicsToCart(ctx, [comic.sku]);
                  if (ok && ctx.mounted) {
                    onChanged?.call();
                    Navigator.pop(ctx);
                  }
                },
              ),
              FilledButton.icon(
                icon: const Icon(Icons.bookmark_add),
                label: const Text('Agregar a colección'),
                onPressed: () async {
                  final ok = await addComicsToCollection(ctx, [comic.sku]);
                  if (ok && ctx.mounted) {
                    onChanged?.call();
                    Navigator.pop(ctx);
                  }
                },
              ),
            ],
          );
        },
      );
    },
  );
}

// ------------------------------------------------------------------ estados

/// Colores de estado: Obtenido verde, Comprado ámbar, Wishlist rojo.
/// Validados para daltonismo sobre el fondo oscuro (#161616, todos los
/// pares, ΔE ≥ 8); los otros dos son grises neutros que se distinguen por
/// intensidad, ícono y etiqueta. Para fondos con texto blanco encima se usan
/// los tonos oscuros de [statusBackground].
const ownedColor = Color(0xFF2FA67F);
const purchasedColor = Color(0xFFC0843E);
const wishlistColor = Color(0xFFB8323A);
const notInterestedColor = Color(0xFF4A4A4A);
const unclassifiedColor = Color(0xFF707070);

/// Alias usado en las gráficas de colecciones ("me falta").
const missingColor = unclassifiedColor;

Color statusColor(ComicStatus s) => switch (s) {
  ComicStatus.owned => ownedColor,
  ComicStatus.purchased => purchasedColor,
  ComicStatus.wishlist => wishlistColor,
  ComicStatus.notInterested => notInterestedColor,
  ComicStatus.unclassified => unclassifiedColor,
};

IconData statusIcon(ComicStatus s) => switch (s) {
  ComicStatus.owned => Icons.check,
  ComicStatus.purchased => Icons.local_shipping,
  ComicStatus.wishlist => Icons.favorite,
  ComicStatus.notInterested => Icons.block,
  ComicStatus.unclassified => Icons.help_outline,
};

/// Fondo de la zona de texto de la tarjeta: un color distinto por estado.
Color statusBackground(ComicStatus s) => switch (s) {
  ComicStatus.owned => const Color(0xFF1B6B50),
  ComicStatus.purchased => const Color(0xFF7A5220),
  ComicStatus.wishlist => const Color(0xFF8E2730),
  ComicStatus.notInterested => const Color(0xFF262626),
  ComicStatus.unclassified => const Color(0xFF161616),
};

/// Círculo con ✓ (lo tengo), camión (comprado) o ✗ (me falta).
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status, this.size = 30});

  final ComicStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final missing =
        status == ComicStatus.unclassified ||
        status == ComicStatus.notInterested;
    return Tooltip(
      message: status.label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: status == ComicStatus.unclassified
              ? Colors.black87
              : statusColor(status),
          shape: BoxShape.circle,
          border: Border.all(
            color: missing ? const Color(0xFF8A8A8A) : Colors.white,
            width: 2,
          ),
        ),
        child: Icon(
          statusIcon(status),
          size: size * 0.55,
          color: missing ? const Color(0xFFBDBDBD) : Colors.white,
        ),
      ),
    );
  }
}

/// Selector de estado: un chip por estado, con su color, ícono y etiqueta.
class StatusSelector extends StatelessWidget {
  const StatusSelector({
    super.key,
    required this.status,
    required this.onChanged,
  });

  final ComicStatus status;
  final ValueChanged<ComicStatus> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final s in ComicStatus.values)
          ChoiceChip(
            selected: s == status,
            showCheckmark: false,
            avatar: Icon(
              statusIcon(s),
              size: 16,
              color: s == status ? Colors.white : statusColor(s),
            ),
            label: Text(s.label),
            selectedColor: statusColor(s),
            labelStyle: s == status
                ? const TextStyle(color: Colors.white)
                : null,
            onSelected: (_) => onChanged(s),
          ),
      ],
    );
  }
}

/// Acción del menú de una tarjeta.
class CardAction {
  const CardAction(this.label, this.icon, this.onSelected);
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
}

/// Acciones para cambiar el estado (todas menos el estado actual).
List<CardAction> statusActions(
  ComicStatus current,
  void Function(ComicStatus) onStatus,
) => [
  for (final s in ComicStatus.values.reversed)
    if (s != current)
      CardAction(
        s == ComicStatus.wishlist
            ? 'Mover a wishlist'
            : 'Marcar: ${s.label.toLowerCase()}',
        statusIcon(s),
        () => onStatus(s),
      ),
];

/// Tarjeta de cómic con estado: la portada no cambia; la zona del texto y
/// la marca de la esquina muestran si lo tienes, si está comprado o si falta.
class ComicStatusCard extends StatelessWidget {
  const ComicStatusCard({
    super.key,
    required this.comic,
    required this.status,
    required this.onTap,
    this.actions = const [],
    this.selected,
    this.onSelect,
  });

  final Comic comic;
  final ComicStatus status;
  final VoidCallback onTap;
  final List<CardAction> actions;

  /// Si no es null se muestra la casilla de selección (catálogo).
  final bool? selected;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlighted =
        status == ComicStatus.owned ||
        status == ComicStatus.purchased ||
        status == ComicStatus.wishlist;
    final dimmed = status == ComicStatus.notInterested;
    final textColor = highlighted
        ? Colors.white
        : dimmed
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurface;
    final subColor = highlighted
        ? Colors.white70
        : theme.colorScheme.onSurfaceVariant;
    final isSelected = selected ?? false;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isSelected
            ? const BorderSide(color: Colors.white, width: 3)
            : BorderSide(
                color: status == ComicStatus.unclassified
                    ? const Color(0xFF2A2A2A)
                    : statusColor(status),
                width: 1.5,
              ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onSelect,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ComicCover(url: comic.imageUrl),
                  if (selected != null)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Material(
                        color: Colors.black54,
                        shape: const CircleBorder(),
                        child: Checkbox(
                          value: isSelected,
                          onChanged: (_) => onSelect?.call(),
                          side: const BorderSide(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: StatusBadge(status: status),
                  ),
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 6,
                    child: AvailabilityBadges(comic: comic),
                  ),
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              color: statusBackground(status),
              padding: const EdgeInsets.fromLTRB(8, 6, 0, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          comic.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: textColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                [
                                  status.label,
                                  if (comic.price != null)
                                    formatComicPrice(comic),
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: subColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (actions.isNotEmpty)
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: PopupMenuButton<int>(
                        padding: EdgeInsets.zero,
                        iconSize: 20,
                        iconColor: subColor,
                        tooltip: 'Más opciones',
                        onSelected: (i) => actions[i].onSelected(),
                        itemBuilder: (_) => [
                          for (var i = 0; i < actions.length; i++)
                            PopupMenuItem(
                              value: i,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(actions[i].icon, size: 18),
                                  const SizedBox(width: 12),
                                  Flexible(
                                    child: Text(
                                      actions[i].label,
                                      overflow: TextOverflow.ellipsis,
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
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- gráficas

/// Grupos de las gráficas de colecciones: obtenido, comprado y me falta
/// (todo lo demás). Cada uno con su color, ícono y etiqueta.
List<(String, IconData, Color, int)> progressGroups(StatusCounts c) => [
  (ComicStatus.owned.label, statusIcon(ComicStatus.owned), ownedColor, c.owned),
  (
    ComicStatus.purchased.label,
    statusIcon(ComicStatus.purchased),
    purchasedColor,
    c.purchased,
  ),
  ('Me falta', Icons.close, missingColor, c.missing),
];

/// Barra apilada de un todo dividido en: obtenido / comprado / me falta.
/// Cada segmento tiene tooltip; hay 2px de separación entre segmentos.
class StackedStatusBar extends StatelessWidget {
  const StackedStatusBar({super.key, required this.counts, this.height = 10});

  final StatusCounts counts;
  final double height;

  @override
  Widget build(BuildContext context) {
    final parts = progressGroups(counts).where((p) => p.$4 > 0).toList();
    if (parts.isEmpty) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF262626),
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            for (var i = 0; i < parts.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Expanded(
                flex: parts[i].$4,
                child: Tooltip(
                  message:
                      '${parts[i].$1}: ${parts[i].$4} '
                      '(${(parts[i].$4 * 100 / counts.total).round()}%)',
                  child: Container(color: parts[i].$3),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Leyenda con color + etiqueta + valor (no depende solo del color).
class StatusLegend extends StatelessWidget {
  const StatusLegend({super.key, required this.counts});

  final StatusCounts counts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final (label, _, color, n) in progressGroups(counts))
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text('$label $n', style: theme.textTheme.bodySmall),
            ],
          ),
      ],
    );
  }
}

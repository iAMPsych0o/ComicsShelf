import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_scope.dart';
import '../models.dart';
import '../services/carriers.dart';
import '../services/stores.dart';
import '../services/pdf_export.dart';
import '../widgets/comic_picker.dart';
import '../widgets/comic_widgets.dart';
import 'home_shell.dart';

/// Compras: carritos de futuras compras y pedidos ya pagados.
class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({
    super.key,
    required this.changes,
    required this.onGoToCatalog,
  });

  final DataChanges changes;
  final VoidCallback onGoToCatalog;

  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  List<Cart> _carts = [];
  List<Order> _orders = [];
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
      _carts = scope.db.carts(scope.user.id);
      _orders = scope.db.orders(scope.user.id);
    });
  }

  Future<void> _newCart() async {
    final scope = AppScope.of(context);
    final name = await askText(
      context,
      title: 'Nuevo carrito',
      label: 'Nombre (p. ej. "Quincena de noviembre")',
    );
    if (name == null || !mounted) return;
    final id = scope.db.createCart(scope.user.id, name);
    widget.changes.changed();
    await _openCart(id);
  }

  Future<void> _newOrder() async {
    final scope = AppScope.of(context);
    final form = await showOrderForm(context, title: 'Nuevo pedido');
    if (form == null || !mounted) return;
    final id = scope.db.createOrder(
      scope.user.id,
      store: form.store,
      tracking: form.tracking,
      carrier: form.carrier,
      notes: form.notes,
    );
    widget.changes.changed();
    await _openOrder(id);
  }

  Future<void> _openCart(int id) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => CartDetailScreen(cartId: id, changes: widget.changes),
    ),
  );

  Future<void> _openOrder(int id) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => OrderDetailScreen(orderId: id, changes: widget.changes),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pending = _orders.where((o) => !o.received).length;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kTextTabBarHeight),
          child: Material(
            child: TabBar(
              tabs: [
                Tab(text: 'Carritos (${_carts.length})'),
                Tab(text: 'Pedidos ($pending pendientes)'),
              ],
            ),
          ),
        ),
        floatingActionButton: Builder(
          builder: (context) {
            final tabs = DefaultTabController.of(context);
            return ListenableBuilder(
              listenable: tabs,
              builder: (context, _) => tabs.index == 0
                  ? FloatingActionButton.extended(
                      heroTag: 'new_cart',
                      onPressed: _newCart,
                      icon: const Icon(Icons.add_shopping_cart),
                      label: const Text('Nuevo carrito'),
                    )
                  : FloatingActionButton.extended(
                      heroTag: 'new_order',
                      onPressed: _newOrder,
                      icon: const Icon(Icons.add),
                      label: const Text('Nuevo pedido'),
                    ),
            );
          },
        ),
        body: TabBarView(children: [_cartsTab(), _ordersTab()]),
      ),
    );
  }

  Widget _empty(IconData icon, String title, String hint) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(hint, textAlign: TextAlign.center),
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

  Widget _cartsTab() {
    if (_carts.isEmpty) {
      return _empty(
        Icons.shopping_cart_outlined,
        'No tienes carritos.',
        'Arma carritos para planear tus próximas compras y ver cuánto '
            'costarían. En el catálogo usa "Agregar a carrito…".',
      );
    }
    final total = _carts.fold<double>(0, (s, c) => s + c.total);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text('Todos los carritos: ${formatPrice(total)}'),
        ),
        for (final c in _carts)
          Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xFF262626),
                child: Icon(Icons.shopping_cart, color: Colors.white),
              ),
              title: Text(c.name),
              subtitle: Text(
                '${c.count} cómics'
                '${c.soldOut > 0 ? ' · ${c.soldOut} agotado(s)' : ''}',
              ),
              trailing: Text(
                formatPrice(c.total),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              onTap: () => _openCart(c.id),
            ),
          ),
      ],
    );
  }

  Widget _ordersTab() {
    if (_orders.isEmpty) {
      return _empty(
        Icons.local_shipping_outlined,
        'No tienes pedidos.',
        'Registra lo que compraste con la tienda y la guía de envío. Los '
            'cómics que marques "Comprado" aparecen aquí.',
      );
    }
    final pending = _orders.where((o) => !o.received).toList();
    final received = _orders.where((o) => o.received).toList();
    final theme = Theme.of(context);
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 88),
      children: [
        if (pending.isNotEmpty) ...[
          header('Pendientes de recibir'),
          for (final o in pending) _OrderTile(order: o, onTap: _openOrder),
        ],
        if (received.isNotEmpty) ...[
          header('Recibidos'),
          for (final o in received) _OrderTile(order: o, onTap: _openOrder),
        ],
      ],
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order, required this.onTap});

  final Order order;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final o = order;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: o.received ? ownedColor : purchasedColor,
          child: Icon(
            o.received ? Icons.check : Icons.local_shipping,
            color: Colors.white,
          ),
        ),
        title: Text(o.title),
        subtitle: Text(
          [
            '${o.count} cómics · ${formatPrice(o.total)}',
            if (!o.received && o.ownedCount > 0)
              '${o.ownedCount} de ${o.count} ya llegaron',
            if (o.tracking != null)
              'Guía: ${o.tracking}'
                  '${o.carrier == null ? '' : ' · ${carrierByKey(o.carrier).name}'}',
          ].join('\n'),
        ),
        isThreeLine: o.tracking != null || o.ownedCount > 0,
        trailing: o.tracking == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Copiar guía',
                    icon: const Icon(Icons.copy),
                    onPressed: () => copyTracking(context, o.tracking!),
                  ),
                  IconButton(
                    tooltip: 'Rastrear',
                    icon: const Icon(Icons.travel_explore),
                    onPressed: () => trackOrder(o),
                  ),
                ],
              ),
        onTap: () => onTap(o.id),
      ),
    );
  }
}

/// Abre la página de rastreo de la paquetería del pedido con la guía.
Future<void> trackOrder(Order o) async {
  if (o.tracking == null) return;
  await launchUrl(
    carrierByKey(o.carrier).trackingUrl(o.tracking!),
    mode: LaunchMode.externalApplication,
  );
}

void copyTracking(BuildContext context, String tracking) {
  Clipboard.setData(ClipboardData(text: tracking));
  showNotice(ScaffoldMessenger.of(context), 'Guía copiada: $tracking');
}

// ------------------------------------------------------------ formulario

typedef OrderForm = ({
  String store,
  String tracking,
  String? carrier,
  String notes,
});

/// Pide tienda, guía y notas de un pedido.
Future<OrderForm?> showOrderForm(
  BuildContext context, {
  required String title,
  Order? initial,
  String confirm = 'Guardar',
}) {
  final scope = AppScope.of(context);
  final stores = {
    ...scope.db.storeNames(scope.user.id),
    for (final s in paniniStores) s.name,
  }.toList();
  return showDialog<OrderForm>(
    context: context,
    builder: (_) => _OrderFormDialog(
      title: title,
      initial: initial,
      stores: stores,
      confirm: confirm,
    ),
  );
}

class _OrderFormDialog extends StatefulWidget {
  const _OrderFormDialog({
    required this.title,
    required this.initial,
    required this.stores,
    required this.confirm,
  });

  final String title;
  final Order? initial;
  final List<String> stores;
  final String confirm;

  @override
  State<_OrderFormDialog> createState() => _OrderFormDialogState();
}

class _OrderFormDialogState extends State<_OrderFormDialog> {
  late final _store = TextEditingController(text: widget.initial?.store ?? '');
  late final _tracking = TextEditingController(
    text: widget.initial?.tracking ?? '',
  );
  late final _notes = TextEditingController(text: widget.initial?.notes ?? '');
  final _storeFocus = FocusNode();

  /// Paquetería elegida. Mientras el usuario no la elija a mano, se
  /// adivina por el formato de la guía.
  late String? _carrier = widget.initial?.carrier;
  late bool _carrierChosen = widget.initial?.carrier != null;

  @override
  void dispose() {
    _store.dispose();
    _tracking.dispose();
    _notes.dispose();
    _storeFocus.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, (
    store: _store.text,
    tracking: _tracking.text,
    carrier: _tracking.text.trim().isEmpty ? null : _carrier,
    notes: _notes.text,
  ));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RawAutocomplete<String>(
              textEditingController: _store,
              focusNode: _storeFocus,
              optionsBuilder: (v) => widget.stores.where(
                (s) =>
                    s.toLowerCase().contains(v.text.toLowerCase()) &&
                    s != v.text,
              ),
              fieldViewBuilder: (context, controller, focus, _) => TextField(
                controller: controller,
                focusNode: focus,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Tienda',
                  hintText: 'Dónde lo compraste',
                  prefixIcon: Icon(Icons.storefront_outlined),
                ),
              ),
              optionsViewBuilder: (context, onSelected, options) => Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: 200,
                      maxWidth: 380,
                    ),
                    child: ListView(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      children: [
                        for (final o in options)
                          ListTile(
                            dense: true,
                            title: Text(o),
                            onTap: () => onSelected(o),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tracking,
              textInputAction: TextInputAction.next,
              onChanged: (v) {
                if (_carrierChosen) return;
                setState(() => _carrier = detectCarrier(v)?.key);
              },
              decoration: const InputDecoration(
                labelText: 'Guía de envío (opcional)',
                prefixIcon: Icon(Icons.qr_code_2),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey(_carrier),
              initialValue: _carrier ?? otherCarrier.key,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Paquetería',
                prefixIcon: const Icon(Icons.local_shipping_outlined),
                helperText: _carrierChosen || _carrier == null
                    ? null
                    : 'Detectada por el formato de la guía',
              ),
              items: [
                for (final c in carriers)
                  DropdownMenuItem(value: c.key, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() {
                _carrier = v;
                _carrierChosen = true;
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Notas (opcional)',
                hintText: 'Paquetería, número de pedido…',
                prefixIcon: Icon(Icons.notes),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirm)),
      ],
    );
  }
}

// ------------------------------------------------------------- detalle

/// Barra con el total, debajo del título de un pedido o carrito.
class _Summary extends StatelessWidget {
  const _Summary({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    ),
  );
}

class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({
    super.key,
    required this.orderId,
    required this.changes,
  });

  final int orderId;
  final DataChanges changes;

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  Order? _order;
  List<CollectionItem> _items = [];
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
    setState(() {
      _order = scope.db.order(scope.user.id, widget.orderId);
      _items = scope.db.orderItems(scope.user.id, widget.orderId);
    });
  }

  void _changed() {
    widget.changes.changed();
    _reload();
  }

  Future<void> _edit() async {
    final scope = AppScope.of(context);
    final form = await showOrderForm(
      context,
      title: 'Editar pedido',
      initial: _order,
    );
    if (form == null) return;
    scope.db.updateOrder(
      scope.user.id,
      widget.orderId,
      store: form.store,
      tracking: form.tracking,
      carrier: form.carrier,
      notes: form.notes,
    );
    _changed();
  }

  Future<void> _addComics() async {
    final picked = await pickComics(
      context,
      already: {for (final i in _items) i.comic.sku},
      alreadyLabel: 'Ya está en el pedido',
    );
    if (picked == null || !mounted) return;
    final scope = AppScope.of(context);
    scope.db.addToOrder(scope.user.id, widget.orderId, picked);
    _changed();
  }

  void _setReceived(bool received) {
    final scope = AppScope.of(context);
    scope.db.setOrderReceived(scope.user.id, widget.orderId, received);
    _changed();
    showNotice(
      ScaffoldMessenger.of(context),
      received
          ? 'Pedido recibido: ${_items.length} cómics → Obtenido'
          : 'El pedido volvió a pendiente',
      status: received ? ComicStatus.owned : ComicStatus.purchased,
      onUndo: () {
        scope.db.setOrderReceived(scope.user.id, widget.orderId, !received);
        _changed();
      },
    );
  }

  void _remove(CollectionItem item) {
    final scope = AppScope.of(context);
    scope.db.removeFromOrder(scope.user.id, widget.orderId, [item.comic.sku]);
    _changed();
    showNotice(
      ScaffoldMessenger.of(context),
      _order!.received
          ? '"${item.comic.name}" quitado del pedido'
          : '"${item.comic.name}" quitado del pedido → Wishlist',
    );
  }

  Future<void> _delete() async {
    final o = _order!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar pedido'),
        content: Text(
          o.received
              ? 'Se borra el registro de "${o.title}". Tus cómics siguen '
                    'como obtenidos.'
              : 'Se borra "${o.title}" y los cómics que seguían como '
                    '"Comprado" vuelven a la wishlist.',
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
    if (ok != true || !mounted) return;
    final scope = AppScope.of(context);
    scope.db.deleteOrder(scope.user.id, widget.orderId);
    widget.changes.changed();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    if (o == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Este pedido ya no existe.')),
      );
    }
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(o.title),
        actions: [
          IconButton(
            tooltip: 'Exportar PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: () => exportComicsPdf(
              context,
              title: 'Pedido: ${o.title}',
              items: _items,
            ),
          ),
          IconButton(
            tooltip: 'Editar tienda y guía',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _edit,
          ),
          IconButton(
            tooltip: 'Eliminar pedido',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addComics,
        icon: const Icon(Icons.add),
        label: const Text('Agregar cómics'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (o.auto)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text(
                  'Aquí quedan los cómics marcados "Comprado" que no están en '
                  'otro pedido.',
                ),
                subtitle: const Text(
                  'Ponle tienda y guía para volverlo un pedido normal.',
                ),
                trailing: TextButton(
                  onPressed: _edit,
                  child: const Text('Completar'),
                ),
              ),
            ),
          _Summary(
            children: [
              Chip(
                avatar: Icon(
                  o.received ? Icons.check_circle : Icons.local_shipping,
                  color: o.received ? ownedColor : purchasedColor,
                  size: 18,
                ),
                label: Text(
                  o.received
                      ? 'Recibido el ${o.receivedAt!.substring(0, 10)}'
                      : 'Pendiente · comprado el ${o.createdAt.substring(0, 10)}',
                ),
              ),
              Text(
                '${o.count} cómics · ${formatPrice(o.total)}',
                style: theme.textTheme.titleSmall,
              ),
              if (o.tracking != null) ...[
                ActionChip(
                  avatar: const Icon(Icons.copy, size: 16),
                  label: Text('Guía: ${o.tracking}'),
                  tooltip: 'Copiar guía',
                  onPressed: () => copyTracking(context, o.tracking!),
                ),
                OutlinedButton.icon(
                  onPressed: () => trackOrder(o),
                  icon: const Icon(Icons.travel_explore),
                  label: Text('Rastrear en ${carrierByKey(o.carrier).name}'),
                ),
              ],
              if (o.received)
                OutlinedButton.icon(
                  onPressed: () => _setReceived(false),
                  icon: const Icon(Icons.undo),
                  label: const Text('Volver a pendiente'),
                )
              else
                FilledButton.icon(
                  onPressed: o.count == 0 ? null : () => _setReceived(true),
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: const Text('Marcar como recibido'),
                ),
            ],
          ),
          if (o.notes != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(o.notes!, style: theme.textTheme.bodySmall),
            ),
          const Divider(height: 1),
          Expanded(
            child: _items.isEmpty
                ? const Center(child: Text('Agrega los cómics que compraste.'))
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
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
                          onChanged: _changed,
                        ),
                        actions: [
                          CardAction(
                            'Ver ficha',
                            Icons.info_outline,
                            () => showComicDetail(
                              context,
                              item.comic,
                              onChanged: _changed,
                            ),
                          ),
                          CardAction(
                            'Quitar del pedido',
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

class CartDetailScreen extends StatefulWidget {
  const CartDetailScreen({
    super.key,
    required this.cartId,
    required this.changes,
  });

  final int cartId;
  final DataChanges changes;

  @override
  State<CartDetailScreen> createState() => _CartDetailScreenState();
}

class _CartDetailScreenState extends State<CartDetailScreen> {
  Cart? _cart;
  List<CollectionItem> _items = [];
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
    setState(() {
      _cart = scope.db
          .carts(scope.user.id)
          .where((c) => c.id == widget.cartId)
          .firstOrNull;
      _items = scope.db.cartItems(scope.user.id, widget.cartId);
    });
  }

  void _changed() {
    widget.changes.changed();
    _reload();
  }

  Future<void> _addComics() async {
    final picked = await pickComics(
      context,
      already: {for (final i in _items) i.comic.sku},
      alreadyLabel: 'Ya está en el carrito',
    );
    if (picked == null || !mounted) return;
    final scope = AppScope.of(context);
    scope.db.addToCart(scope.user.id, widget.cartId, picked);
    _changed();
  }

  void _remove(CollectionItem item) {
    final scope = AppScope.of(context);
    scope.db.removeFromCart(scope.user.id, widget.cartId, [item.comic.sku]);
    _changed();
    showNotice(
      ScaffoldMessenger.of(context),
      '"${item.comic.name}" quitado del carrito',
      onUndo: () {
        scope.db.addToCart(scope.user.id, widget.cartId, [item.comic.sku]);
        _changed();
      },
    );
  }

  Future<void> _rename() async {
    final scope = AppScope.of(context);
    final name = await askText(
      context,
      title: 'Renombrar carrito',
      label: 'Nombre',
      initial: _cart!.name,
    );
    if (name == null) return;
    scope.db.renameCart(scope.user.id, widget.cartId, name);
    _changed();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar carrito'),
        content: Text(
          'Se borra "${_cart!.name}". Los cómics no cambian de estado.',
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
    if (ok != true || !mounted) return;
    final scope = AppScope.of(context);
    scope.db.deleteCart(scope.user.id, widget.cartId);
    widget.changes.changed();
    Navigator.pop(context);
  }

  /// "Ya lo compré": pide tienda y guía y lo convierte en pedido.
  Future<void> _bought() async {
    final scope = AppScope.of(context);
    final navigator = Navigator.of(context);
    final form = await showOrderForm(
      context,
      title: 'Ya lo compré',
      confirm: 'Crear pedido',
    );
    if (form == null || !mounted) return;
    final id = scope.db.cartToOrder(
      scope.user.id,
      widget.cartId,
      store: form.store,
      tracking: form.tracking,
      carrier: form.carrier,
      notes: form.notes,
    );
    widget.changes.changed();
    navigator.pushReplacement(
      MaterialPageRoute(
        builder: (_) => OrderDetailScreen(orderId: id, changes: widget.changes),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _cart;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Este carrito ya no existe.')),
      );
    }
    final theme = Theme.of(context);
    final available = _items.where(
      (i) => i.comic.stockStatus != 'OUT_OF_STOCK',
    );
    final availableTotal = sumValue(available);
    return Scaffold(
      appBar: AppBar(
        title: Text(c.name),
        actions: [
          IconButton(
            tooltip: 'Exportar PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: () => exportComicsPdf(
              context,
              title: 'Carrito: ${c.name}',
              items: _items,
            ),
          ),
          IconButton(
            tooltip: 'Renombrar',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _rename,
          ),
          IconButton(
            tooltip: 'Eliminar carrito',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addComics,
        icon: const Icon(Icons.add),
        label: const Text('Agregar cómics'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Summary(
            children: [
              Text(
                'Total: ${formatPrice(c.total)}',
                style: theme.textTheme.titleMedium,
              ),
              Text('${c.count} cómics'),
              if (c.soldOut > 0)
                Text(
                  '${c.soldOut} agotado(s) · disponible: '
                  '${formatPrice(availableTotal)}',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              FilledButton.icon(
                onPressed: c.count == 0 ? null : _bought,
                icon: const Icon(Icons.shopping_bag_outlined),
                label: const Text('Ya lo compré'),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: _items.isEmpty
                ? const Center(
                    child: Text('Agrega los cómics que piensas comprar.'),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
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
                          onChanged: _changed,
                        ),
                        actions: [
                          CardAction(
                            'Ver ficha',
                            Icons.info_outline,
                            () => showComicDetail(
                              context,
                              item.comic,
                              onChanged: _changed,
                            ),
                          ),
                          CardAction(
                            'Quitar del carrito',
                            Icons.remove_shopping_cart_outlined,
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

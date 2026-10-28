import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../db/app_database.dart';
import '../services/backup_actions.dart';
import '../services/sync_service.dart';
import '../widgets/comic_widgets.dart';

/// Dirección de la sincronización.
enum SyncDirection { pcToPhone, phoneToPc }

bool get _isPhone => Platform.isAndroid || Platform.isIOS;

/// Pasa colecciones y estados entre la PC y el teléfono por Wi-Fi.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, this.onDataChanged});

  final VoidCallback? onDataChanged;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  SyncDirection? _direction;

  /// Este dispositivo envía si es el origen de la dirección elegida.
  bool get _sending => switch (_direction!) {
    SyncDirection.pcToPhone => !_isPhone,
    SyncDirection.phoneToPc => _isPhone,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sincronizar dispositivos'),
        leading: _direction == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _direction = null),
              ),
      ),
      body: _direction == null
          ? _ChooseDirection(onChosen: (d) => setState(() => _direction = d))
          : _sending
          ? _SendPanel(direction: _direction!)
          : _ReceivePanel(
              direction: _direction!,
              onDataChanged: widget.onDataChanged,
            ),
    );
  }
}

String _directionLabel(SyncDirection d) =>
    d == SyncDirection.pcToPhone ? 'PC → Móvil' : 'Móvil → PC';

class _ChooseDirection extends StatelessWidget {
  const _ChooseDirection({required this.onChosen});

  final ValueChanged<SyncDirection> onChosen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget option(
      SyncDirection d,
      IconData from,
      IconData to,
      String explain,
    ) => Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChosen(d),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(from, size: 36),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.arrow_forward, size: 28),
              ),
              Icon(to, size: 36),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_directionLabel(d), style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(explain),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Elige la misma opción en los dos dispositivos. Tienen que estar '
          'conectados a la misma red Wi-Fi y con sesión iniciada.',
        ),
        const SizedBox(height: 16),
        option(
          SyncDirection.pcToPhone,
          Icons.computer,
          Icons.phone_android,
          'Tus colecciones, estados, pedidos y carritos de la PC reemplazan los del teléfono.',
        ),
        const SizedBox(height: 8),
        option(
          SyncDirection.phoneToPc,
          Icons.phone_android,
          Icons.computer,
          'Tus colecciones, estados, pedidos y carritos del teléfono reemplazan los de la PC.',
        ),
        const SizedBox(height: 16),
        Text(
          'También se agregan al destino los cómics del catálogo que no tenga; '
          'los que ya existen no cambian. Los datos viajan cifrados con el PIN '
          'y solo dentro de tu red.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ recibir

class _ReceivePanel extends StatefulWidget {
  const _ReceivePanel({required this.direction, this.onDataChanged});

  final SyncDirection direction;
  final VoidCallback? onDataChanged;

  @override
  State<_ReceivePanel> createState() => _ReceivePanelState();
}

class _ReceivePanelState extends State<_ReceivePanel> {
  SyncReceiver? _receiver;
  List<String> _addresses = [];
  String? _error;
  String? _done;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _receiver?.stop();
    super.dispose();
  }

  Future<void> _start() async {
    final user = AppScope.of(context).user;
    final receiver = SyncReceiver(
      deviceName: '${_isPhone ? 'Teléfono' : 'PC'} de ${user.username}',
    );
    try {
      await receiver.start();
      final addresses = await localAddresses();
      if (!mounted) {
        await receiver.stop();
        return;
      }
      setState(() {
        _receiver = receiver;
        _addresses = addresses;
      });
      final got = await receiver.received;
      await receiver.stop();
      if (mounted) await _confirm(got);
    } on SyncException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'No se pudo esperar la conexión: $e');
      }
    }
  }

  Future<void> _confirm(ReceivedSync got) async {
    final scope = AppScope.of(context);
    final BackupSummary summary;
    try {
      summary = AppDatabase.inspectUserBackup(got.data);
    } on BackupException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    final newComics = scope.db.countNewComics(got.data);
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.sync),
        title: Text('Datos recibidos de ${got.from}'),
        content: Text(
          'Contiene:\n'
          '• ${summary.collections} colecciones\n'
          '• ${summary.owned} obtenidos, ${summary.purchased} comprados, '
          '${summary.wishlist} en wishlist\n'
          '• $newComics cómics nuevos para el catálogo de este dispositivo\n\n'
          'Se reemplazarán TUS colecciones, estados, pedidos y carritos en este dispositivo '
          '(${scope.user.username}). Antes se guardará un respaldo automático.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Rechazar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reemplazar mis datos'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok != true) {
      setState(
        () => _error = 'Rechazaste los datos recibidos. No cambió nada.',
      );
      return;
    }
    importWithAutoBackup(scope.db, scope.user, got.data);
    widget.onDataChanged?.call();
    setState(
      () => _done =
          'Listo: ${summary.collections} colecciones, '
          '${summary.owned + summary.purchased + summary.wishlist} estados y '
          '$newComics cómics nuevos en el catálogo.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final from = widget.direction == SyncDirection.pcToPhone
        ? 'la PC'
        : 'el teléfono';

    Widget centered(List<Widget> children) => Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );

    if (_done != null) {
      return centered([
        const Icon(Icons.check_circle, size: 64, color: ownedColor),
        const SizedBox(height: 12),
        Text(
          _done!,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ]);
    }
    if (_error != null) {
      return centered([
        Icon(Icons.error_outline, size: 56, color: theme.colorScheme.error),
        const SizedBox(height: 12),
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ]);
    }
    final r = _receiver;
    if (r == null) return const Center(child: CircularProgressIndicator());

    return centered([
      Text(
        _directionLabel(widget.direction),
        style: theme.textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      Text(
        'Este dispositivo va a RECIBIR. En $from abre ComicShelf, ve a '
        '⚙️ → Sincronizar, elige "${_directionLabel(widget.direction)}" y escribe este PIN:',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 20),
      SelectableText(
        '${r.pin.substring(0, 3)} ${r.pin.substring(3)}',
        style: theme.textTheme.displayMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 6,
        ),
      ),
      const SizedBox(height: 20),
      const LinearProgressIndicator(),
      const SizedBox(height: 8),
      const Text('Esperando al otro dispositivo…'),
      const SizedBox(height: 20),
      Text(
        'Si el otro no lo encuentra solo, que escriba esta dirección:',
        style: theme.textTheme.bodySmall,
        textAlign: TextAlign.center,
      ),
      for (final a in _addresses.take(2))
        SelectableText('$a:${r.port}', style: theme.textTheme.titleSmall),
      if (!_isPhone) ...[
        const SizedBox(height: 12),
        Text(
          'Si Windows pregunta por el firewall, permite el acceso en redes privadas.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    ]);
  }
}

// -------------------------------------------------------------------- enviar

class _SendPanel extends StatefulWidget {
  const _SendPanel({required this.direction});

  final SyncDirection direction;

  @override
  State<_SendPanel> createState() => _SendPanelState();
}

class _SendPanelState extends State<_SendPanel> {
  late final SyncSender _sender;
  StreamSubscription<SyncPeer>? _discovery;
  final _peers = <SyncPeer>[];
  SyncPeer? _selected;
  final _pin = TextEditingController();
  final _manual = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _done;

  @override
  void initState() {
    super.initState();
    final user = AppScope.of(context).user;
    _sender = SyncSender(
      deviceName: '${_isPhone ? 'Teléfono' : 'PC'} de ${user.username}',
    );
    _discovery = _sender.discover().listen(
      (peer) => setState(() {
        _peers.add(peer);
        _selected ??= peer;
      }),
      onError: (_) {}, // sin descubrimiento queda la dirección manual
    );
  }

  @override
  void dispose() {
    _discovery?.cancel();
    _sender.close();
    _pin.dispose();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _findManual() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final peer = await _sender.peerAt(_manual.text);
      setState(() {
        _peers.removeWhere((p) => p.address == peer.address);
        _peers.add(peer);
        _selected = peer;
      });
    } on SyncException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final scope = AppScope.of(context);
    final peer = _selected;
    if (peer == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _sender.send(
        peer,
        _pin.text,
        scope.db.exportUserData(scope.user.id, fullCatalog: true),
      );
      setState(
        () => _done =
            'Enviado a ${peer.name}. Confirma en ese dispositivo para terminar.',
      );
    } on SyncException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final to = widget.direction == SyncDirection.pcToPhone
        ? 'el teléfono'
        : 'la PC';

    if (_done != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.send, size: 56, color: ownedColor),
              const SizedBox(height: 12),
              Text(
                _done!,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cerrar'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          _directionLabel(widget.direction),
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          'Este dispositivo va a ENVIAR. En $to abre ⚙️ → Sincronizar, elige '
          '"${_directionLabel(widget.direction)}" y te mostrará un PIN.',
        ),
        const SizedBox(height: 16),
        Text('Dispositivos esperando', style: theme.textTheme.titleSmall),
        if (_peers.isEmpty)
          const ListTile(
            leading: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text('Buscando en tu red Wi-Fi…'),
          ),
        RadioGroup<String>(
          groupValue: _selected?.address,
          onChanged: (address) => setState(
            () => _selected = _peers.firstWhere((p) => p.address == address),
          ),
          child: Column(
            children: [
              for (final p in _peers)
                RadioListTile<String>(
                  value: p.address,
                  title: Text(p.name),
                  subtitle: Text(p.address),
                  secondary: Icon(
                    p.name.startsWith('Teléfono')
                        ? Icons.phone_android
                        : Icons.computer,
                  ),
                ),
            ],
          ),
        ),
        ExpansionTile(
          title: const Text('¿No aparece? Escribir la dirección'),
          tilePadding: EdgeInsets.zero,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manual,
                    decoration: const InputDecoration(
                      hintText: '192.168.1.20:54321',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _findManual,
                  child: const Text('Buscar'),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pin,
          keyboardType: TextInputType.number,
          maxLength: 7,
          decoration: const InputDecoration(
            labelText: 'PIN del otro dispositivo',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.pin_outlined),
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        FilledButton.icon(
          onPressed:
              _busy ||
                  _selected == null ||
                  _pin.text.replaceAll(' ', '').length != 6
              ? null
              : _send,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send),
          label: Text(
            _selected == null
                ? 'Elige un dispositivo'
                : 'Enviar a ${_selected!.name}',
          ),
        ),
      ],
    );
  }
}

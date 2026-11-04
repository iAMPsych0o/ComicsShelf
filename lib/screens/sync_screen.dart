import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../db/app_database.dart';
import '../models.dart';
import '../services/auth_service.dart';
import '../services/sync_flow.dart';
import '../services/sync_service.dart';
import '../widgets/comic_widgets.dart';

/// Qué hace la sincronización. Al combinar, la PC muestra el PIN y el teléfono
/// lo escribe.
enum SyncDirection { pcToPhone, phoneToPc, merge }

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
    SyncDirection.phoneToPc || SyncDirection.merge => _isPhone,
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
          ? _SendPanel(
              direction: _direction!,
              onDataChanged: widget.onDataChanged,
            )
          : _ReceivePanel(
              direction: _direction!,
              onDataChanged: widget.onDataChanged,
            ),
    );
  }
}

/// Recibe los datos de otro dispositivo desde el inicio de sesión: al llegar
/// se crea (o se entra a) la cuenta del respaldo y se importan sus datos.
class ReceiveAtLoginScreen extends StatelessWidget {
  const ReceiveAtLoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isPhone ? 'Recibir de la PC' : 'Recibir del teléfono'),
      ),
      body: _ReceivePanel(
        direction: _isPhone ? SyncDirection.pcToPhone : SyncDirection.phoneToPc,
        atLogin: true,
      ),
    );
  }
}

String _directionLabel(SyncDirection d) => switch (d) {
  SyncDirection.pcToPhone => 'PC → Móvil',
  SyncDirection.phoneToPc => 'Móvil → PC',
  SyncDirection.merge => 'Combinar',
};

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
      String explain, {
      IconData arrow = Icons.arrow_forward,
    }) => Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChosen(d),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(from, size: 36),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(arrow, size: 28),
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
          'conectados a la misma red Wi-Fi y con sesión iniciada. El que '
          'recibe también puede hacerlo desde el inicio de sesión, con '
          '"Recibir mis datos".',
        ),
        const SizedBox(height: 16),
        option(
          SyncDirection.pcToPhone,
          Icons.computer,
          Icons.phone_android,
          'Tus colecciones, estados, pedidos, carritos y ubicaciones de la PC reemplazan los del teléfono.',
        ),
        const SizedBox(height: 8),
        option(
          SyncDirection.phoneToPc,
          Icons.phone_android,
          Icons.computer,
          'Tus colecciones, estados, pedidos, carritos y ubicaciones del teléfono reemplazan los de la PC.',
        ),
        const SizedBox(height: 8),
        option(
          SyncDirection.merge,
          Icons.computer,
          Icons.phone_android,
          'Junta los cambios de los dos dispositivos sin perder los de '
          'ninguno. La primera vez haz un reemplazo.',
          arrow: Icons.sync_alt,
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
  const _ReceivePanel({
    required this.direction,
    this.onDataChanged,
    this.atLogin = false,
  });

  final SyncDirection direction;
  final VoidCallback? onDataChanged;

  /// Sin sesión iniciada: la cuenta se elige al recibir los datos.
  final bool atLogin;

  @override
  State<_ReceivePanel> createState() => _ReceivePanelState();
}

class _ReceivePanelState extends State<_ReceivePanel> {
  SyncReceiver? _receiver;
  List<String> _addresses = [];
  String? _error;
  String? _done;

  /// Ya se confirmó y se espera al otro dispositivo.
  bool _finishing = false;

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
    final device = _isPhone ? 'Teléfono' : 'PC';
    final receiver = SyncReceiver(
      deviceName: widget.atLogin
          ? '$device sin sesión'
          : '$device de ${AppScope.of(context).user.username}',
      acceptMerge: widget.direction == SyncDirection.merge && !widget.atLogin,
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
      receiver.stopAnnouncing();
      if (!mounted) return;
      // El servidor sigue abierto para responderle al que envió; se cierra al
      // salir de la pantalla.
      if (got.merge) {
        await _confirmMerge(got);
      } else {
        await _confirm(got);
      }
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
      await _receiver?.publishResult({'accepted': false, 'error': e.message});
      if (mounted) setState(() => _error = e.message);
      return;
    }
    final newComics = scope.db.countNewComics(got.data);
    if (!mounted) return;
    if (widget.atLogin) {
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => ClaimAccountDialog(
          from: got.from,
          summary: summary,
          newComics: newComics,
          // Se importa en el mismo paso que la sesión, antes de que se
          // dibuje la pantalla principal con los datos vacíos.
          onAuthenticated: (user) => applyReplace(scope.db, user, got),
        ),
      );
      await _receiver?.publishResult({'accepted': ok == true});
      if (!mounted) return;
      setState(() {
        if (ok == true) {
          _done =
              'Listo: ${summary.collections} colecciones, '
              '${summary.owned + summary.purchased + summary.wishlist} estados y '
              '$newComics cómics nuevos en el catálogo.';
        } else {
          _error = 'Rechazaste los datos recibidos. No cambió nada.';
        }
      });
      return;
    }
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
          'Se reemplazarán TUS colecciones, estados, pedidos, carritos y ubicaciones en este dispositivo '
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
      await _receiver?.publishResult({'accepted': false});
      setState(
        () => _error = 'Rechazaste los datos recibidos. No cambió nada.',
      );
      return;
    }
    applyReplace(scope.db, scope.user, got);
    await _receiver?.publishResult({'accepted': true});
    widget.onDataChanged?.call();
    setState(
      () => _done =
          'Listo: ${summary.collections} colecciones, '
          '${summary.owned + summary.purchased + summary.wishlist} estados y '
          '$newComics cómics nuevos en el catálogo.',
    );
  }

  Future<void> _confirmMerge(ReceivedSync got) async {
    final scope = AppScope.of(context);
    final receiver = _receiver!;
    final MergePlan plan;
    try {
      plan = planMerge(scope.db, scope.user.id, got);
    } on SyncException catch (e) {
      await receiver.publishResult({'accepted': false, 'error': e.message});
      if (mounted) setState(() => _error = e.message);
      return;
    }
    if (!mounted) return;
    final theirUser = got.data['username'] as String? ?? '';
    final otherUser =
        theirUser.toLowerCase() != scope.user.username.toLowerCase();
    final notes = plan.result.notes;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.sync_alt),
        title: Text('Combinar con ${got.from}'),
        content: SingleChildScrollView(
          child: Text(
            '• ${plan.result.toMine} cambios llegan a este dispositivo\n'
            '• ${plan.result.toTheirs} cambios van al otro dispositivo'
            '${notes.isEmpty ? '' : '\n\nConflictos resueltos:\n'
                      '${notes.take(5).map((n) => '• $n').join('\n')}'
                      '${notes.length > 5 ? '\n• …y ${notes.length - 5} más' : ''}'}'
            '${plan.sharedBase ? '' : '\n\nLa última sincronización no terminó '
                      'bien: esta vez se juntará todo sin borrar nada.'}'
            '${otherUser ? '\n\nOjo: los datos son de otro usuario ($theirUser).' : ''}'
            '\n\nAntes se guardará un respaldo automático en los dos '
            'dispositivos.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Rechazar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Combinar'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok != true) {
      await receiver.publishResult({'accepted': false});
      setState(() => _error = 'Rechazaste la combinación. No cambió nada.');
      return;
    }
    setState(() => _finishing = true);
    await receiver.publishResult(plan.accepted);
    final applied = await receiver.acknowledged.timeout(
      const Duration(minutes: 2),
      onTimeout: () => false,
    );
    if (!mounted) return;
    if (!applied) {
      setState(() {
        _finishing = false;
        _error =
            'El otro dispositivo no confirmó. Aquí no cambió nada; vuelve a '
            'intentarlo.';
      });
      return;
    }
    applyMerge(scope.db, scope.user, plan);
    widget.onDataChanged?.call();
    setState(() {
      _finishing = false;
      _done =
          'Listo: ${plan.result.toMine} cambios llegaron a este dispositivo.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final from = widget.direction == SyncDirection.pcToPhone
        ? 'la PC'
        : 'el teléfono';
    final merging = widget.direction == SyncDirection.merge;

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
          child: Text(widget.atLogin ? 'Entrar' : 'Cerrar'),
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
    if (_finishing) {
      return centered([
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        const Text('Aplicando en el otro dispositivo…'),
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
        'Este dispositivo va a ${merging ? 'COMBINAR' : 'RECIBIR'}. En $from abre ComicShelf, ve a '
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

/// Pide la cuenta en la que se guardan los datos recibidos sin sesión: si el
/// usuario del respaldo ya existe aquí se pide su contraseña, si no se crea.
class ClaimAccountDialog extends StatefulWidget {
  const ClaimAccountDialog({
    super.key,
    required this.from,
    required this.summary,
    required this.newComics,
    required this.onAuthenticated,
  });

  final String from;
  final BackupSummary summary;
  final int newComics;
  final void Function(User user) onAuthenticated;

  @override
  State<ClaimAccountDialog> createState() => ClaimAccountDialogState();
}

class ClaimAccountDialogState extends State<ClaimAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _user = TextEditingController(text: widget.summary.username);
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _remember = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _pass2.dispose();
    super.dispose();
  }

  bool get _exists =>
      AppScope.of(context).db.findUserRow(_user.text.trim()) != null;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // Deja que se pinte el indicador antes del cálculo del hash.
    await Future.delayed(const Duration(milliseconds: 16));
    if (!mounted) return;
    final auth = AppScope.of(context).auth;
    try {
      if (_exists) {
        auth.login(_user.text, _pass.text, remember: _remember);
      } else {
        auth.register(_user.text, _pass.text, remember: _remember);
      }
      widget.onAuthenticated(auth.currentUser!);
    } on AuthException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    final exists = _exists;
    return AlertDialog(
      icon: const Icon(Icons.sync),
      title: Text('Datos recibidos de ${widget.from}'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Contiene:\n'
                '• ${s.collections} colecciones\n'
                '• ${s.owned} obtenidos, ${s.purchased} comprados, '
                '${s.wishlist} en wishlist\n'
                '• ${s.orders} pedidos, ${s.locations} ubicaciones\n'
                '• ${widget.newComics} cómics nuevos para el catálogo',
              ),
              const SizedBox(height: 16),
              Text(
                exists
                    ? 'Ese usuario ya existe aquí: escribe su contraseña y '
                          'sus datos se reemplazarán (antes se guarda un '
                          'respaldo automático).'
                    : 'Se creará esta cuenta en este dispositivo. Elige una '
                          'contraseña; no tiene que ser la de la PC.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _user,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Usuario',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Escribe tu usuario'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pass,
                enabled: !_busy,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Contraseña',
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                ),
                onFieldSubmitted: exists ? (_) => _submit() : null,
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Escribe tu contraseña' : null,
              ),
              if (!exists) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _pass2,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirmar contraseña',
                    prefixIcon: Icon(Icons.lock_outline),
                    border: OutlineInputBorder(),
                  ),
                  onFieldSubmitted: (_) => _submit(),
                  validator: (v) =>
                      v != _pass.text ? 'Las contraseñas no coinciden' : null,
                ),
              ],
              CheckboxListTile(
                value: _remember,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _remember = v ?? false),
                title: const Text('Recuérdame'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Rechazar'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  exists ? 'Entrar y reemplazar' : 'Crear cuenta e importar',
                ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------- enviar

class _SendPanel extends StatefulWidget {
  const _SendPanel({required this.direction, this.onDataChanged});

  final SyncDirection direction;
  final VoidCallback? onDataChanged;

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

  /// Enviado; falta que el otro dispositivo responda.
  bool _waiting = false;

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
      if (widget.direction == SyncDirection.merge) {
        await _merge(scope, peer);
      } else {
        await _replace(scope, peer);
      }
    } on SyncException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on BackupException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _waiting = false;
        });
      }
    }
  }

  Future<void> _replace(AppScope scope, SyncPeer peer) async {
    final userId = scope.user.id;
    final revision = scope.db.syncRevision(userId);
    final syncId = newSyncId();
    final data = replacePayload(scope.db, userId, syncId);
    await _sender.send(peer, _pin.text, data);
    if (!mounted) return;
    setState(() => _waiting = true);
    final reply = await _sender.waitResult(peer);
    if (!mounted) return;
    if (reply['accepted'] != true) {
      setState(
        () => _error =
            reply['error'] as String? ?? '${peer.name} rechazó los datos.',
      );
      return;
    }
    confirmReplace(scope.db, userId, syncId, data, revision);
    setState(() => _done = 'Listo: ${peer.name} recibió tus datos.');
  }

  Future<void> _merge(AppScope scope, SyncPeer peer) async {
    await _sender.sendForMerge(
      peer,
      _pin.text,
      mergePayload(scope.db, scope.user.id),
    );
    if (!mounted) return;
    setState(() => _waiting = true);
    final reply = await _sender.waitResult(peer);
    if (!mounted) return;
    if (reply['accepted'] != true) {
      setState(
        () => _error =
            reply['error'] as String? ??
            '${peer.name} rechazó la combinación. No cambió nada.',
      );
      return;
    }
    try {
      applyMergeReply(scope.db, scope.user, reply);
    } catch (_) {
      await _sender.acknowledge(peer, ok: false);
      rethrow;
    }
    await _sender.acknowledge(peer, ok: true);
    widget.onDataChanged?.call();
    if (!mounted) return;
    setState(
      () => _done =
          'Listo: ${reply['changes']} cambios llegaron a este dispositivo.',
    );
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
          'Este dispositivo va a '
          '${widget.direction == SyncDirection.merge ? 'COMBINAR' : 'ENVIAR'}. '
          'En $to abre ⚙️ → Sincronizar, elige '
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
                : _waiting
                ? 'Esperando a ${_selected!.name}…'
                : '${widget.direction == SyncDirection.merge ? 'Combinar con' : 'Enviar a'} ${_selected!.name}',
          ),
        ),
      ],
    );
  }
}

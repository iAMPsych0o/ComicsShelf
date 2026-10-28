import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/backup_actions.dart';
import '../services/cover_cache.dart';
import '../services/currency.dart';
import '../widgets/comic_widgets.dart';
import 'sync_screen.dart';

/// Configuración de la sesión: respaldos y sesión recordada.
Future<void> showSettings(BuildContext context, {VoidCallback? onDataChanged}) {
  return showDialog(
    context: context,
    builder: (ctx) {
      final scope = AppScope.of(ctx);
      final theme = Theme.of(ctx);
      var remembered = scope.auth.isRemembered;

      Widget section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      );

      return StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.settings),
              SizedBox(width: 10),
              Text('Configuración'),
            ],
          ),
          scrollable: true,
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                section('Respaldos'),
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text('Exportar respaldo…'),
                  subtitle: const Text(
                    'Guarda tus colecciones, estados, pedidos y carritos en un archivo donde tú elijas',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    exportBackup(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('Importar respaldo…'),
                  subtitle: const Text(
                    'Reemplaza tus colecciones, estados, pedidos y carritos con los de un archivo',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    importBackup(context, onImported: onDataChanged);
                  },
                ),
                section('Dispositivos'),
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('Sincronizar PC y móvil…'),
                  subtitle: const Text(
                    'Pasa tus colecciones, estados, pedidos y carritos de un dispositivo al otro por Wi-Fi',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            SyncScreen(onDataChanged: onDataChanged),
                      ),
                    );
                  },
                ),
                if (CoverCache.instance case final cache?) ...[
                  section('Portadas'),
                  _CoverSettings(cache: cache),
                ],
                section('Moneda'),
                _CurrencySettings(onChanged: onDataChanged),
                section('Sesión'),
                SwitchListTile(
                  value: remembered,
                  secondary: const Icon(Icons.lock_clock_outlined),
                  title: const Text('Recordarme en este dispositivo'),
                  subtitle: Text(
                    'Entrar como ${scope.user.username} sin escribir la '
                    'contraseña al abrir la app',
                  ),
                  onChanged: (v) {
                    scope.auth.setRemembered(v);
                    setLocal(() => remembered = v);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
    },
  );
}

String _megabytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// Portadas guardadas: cuánto ocupan, descargarlas todas, solo con Wi-Fi y
/// borrarlas.
class _CoverSettings extends StatefulWidget {
  const _CoverSettings({required this.cache});

  final CoverCache cache;

  @override
  State<_CoverSettings> createState() => _CoverSettingsState();
}

class _CoverSettingsState extends State<_CoverSettings> {
  CoverCache get cache => widget.cache;

  Future<void> _downloadAll() async {
    final missing = cache.missing().length;
    if (missing == 0) {
      showNotice(
        ScaffoldMessenger.of(context),
        'Ya tienes todas las portadas.',
      );
      return;
    }
    if (!cache.canDownload) {
      showNotice(
        ScaffoldMessenger.of(context),
        cache.onMobileData
            ? 'Estás con datos móviles. Conéctate a Wi-Fi o desactiva '
                  '"Solo con Wi-Fi".'
            : 'Sin conexión a internet.',
      );
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadDialog(cache: cache),
    );
    if (mounted) setState(() {});
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar portadas guardadas'),
        content: const Text(
          'Se volverán a descargar cuando las veas (con Wi-Fi si tienes '
          'activado "Solo con Wi-Fi"). Tus colecciones no cambian.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await cache.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final usage = cache.usage();
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.image_outlined),
          title: Text('${usage.count} portadas guardadas'),
          subtitle: Text(
            'Ocupan ${_megabytes(usage.bytes)}. Se guardan la primera vez '
            'que las ves, ya reducidas, y después no gastan datos.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.download_for_offline_outlined),
          title: const Text('Descargar todas las portadas…'),
          subtitle: const Text('Para verlas sin internet'),
          onTap: _downloadAll,
        ),
        SwitchListTile(
          value: cache.wifiOnly,
          secondary: const Icon(Icons.wifi),
          title: const Text('Descargar portadas solo con Wi-Fi'),
          subtitle: const Text(
            'Con datos móviles solo se muestran las que ya están guardadas',
          ),
          onChanged: (v) => setState(() => cache.wifiOnly = v),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('Borrar portadas guardadas…'),
          enabled: usage.count > 0,
          onTap: _clear,
        ),
      ],
    );
  }
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.cache});

  final CoverCache cache;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  var _done = 0, _total = 0, _cancelled = false, _finished = false;
  int? _saved;

  @override
  void initState() {
    super.initState();
    widget.cache
        .downloadAll(
          cancelled: () => _cancelled,
          onProgress: (d, t) {
            if (!mounted) return;
            setState(() {
              _done = d;
              _total = t;
            });
          },
        )
        .then((saved) {
          if (mounted) {
            setState(() {
              _saved = saved;
              _finished = true;
            });
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    final failed = _finished ? _done - _saved! : 0;
    return AlertDialog(
      title: const Text('Descargando portadas'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
          const SizedBox(height: 12),
          Text(
            _finished
                ? 'Listo: $_saved portadas guardadas'
                      '${failed > 0 ? ' ($failed no se pudieron bajar)' : ''}'
                      '${_done < _total ? '. Se detuvo antes de terminar.' : '.'}'
                : '$_done de $_total',
          ),
        ],
      ),
      actions: [
        if (_finished)
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          )
        else
          TextButton(
            onPressed: _cancelled
                ? null
                : () => setState(() => _cancelled = true),
            child: const Text('Detener'),
          ),
      ],
    );
  }
}

/// Moneda en la que se ven precios y totales, y el tipo de cambio usado.
class _CurrencySettings extends StatefulWidget {
  const _CurrencySettings({this.onChanged});

  final VoidCallback? onChanged;

  @override
  State<_CurrencySettings> createState() => _CurrencySettingsState();
}

class _CurrencySettingsState extends State<_CurrencySettings> {
  bool _updating = false;

  Money get money => Money.instance;

  Future<void> _refresh() async {
    setState(() => _updating = true);
    final ok = await money.refreshRates(maxAge: Duration.zero);
    if (!mounted) return;
    setState(() => _updating = false);
    if (ok) widget.onChanged?.call();
    showNotice(
      ScaffoldMessenger.of(context),
      ok
          ? 'Tipo de cambio actualizado'
          : 'No se pudo actualizar el tipo de cambio',
    );
  }

  @override
  Widget build(BuildContext context) {
    final date = money.ratesDate;
    String two(int n) => n.toString().padLeft(2, '0');
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.payments_outlined),
          title: const Text('Mostrar precios y totales en'),
          subtitle: const Text(
            'Los precios de otras tiendas se convierten a esta moneda',
          ),
          trailing: DropdownButton<String>(
            value: money.display,
            items: [
              for (final c in Money.currencies)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => money.setDisplay(v));
              widget.onChanged?.call();
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.currency_exchange),
          title: Text(
            date == null
                ? 'Sin tipo de cambio todavía'
                : 'Tipo de cambio del ${two(date.day)}/${two(date.month)}/'
                      '${date.year}',
          ),
          subtitle: Text(
            date == null
                ? 'Se descarga al abrir la app con internet. Mientras, los '
                      'precios de otras tiendas se ven en su moneda y no suman.'
                : 'Fuente: ${Money.ratesSource}. Se actualiza una vez al día.',
          ),
          trailing: _updating
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  tooltip: 'Actualizar tipo de cambio',
                  icon: const Icon(Icons.refresh),
                  onPressed: _refresh,
                ),
        ),
      ],
    );
  }
}

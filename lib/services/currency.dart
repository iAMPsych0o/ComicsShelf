import 'dart:convert';

import 'package:http/http.dart' as http;

import '../db/app_database.dart';

/// Moneda en la que se muestran precios y totales, y conversión desde la
/// moneda de cada tienda con el tipo de cambio del día.
///
/// Tipo de cambio: ExchangeRate-API (https://www.exchangerate-api.com),
/// gratuito y sin clave; se guarda para usarse sin internet.
class Money {
  Money._();

  /// Instancia de la app. En pruebas queda en MXN sin tipos de cambio.
  static Money instance = Money._();

  static const _displayKey = 'display_currency';
  static const _ratesKey = 'fx_rates';
  static const ratesSource = 'ExchangeRate-API';
  static final _ratesUrl = Uri.parse('https://open.er-api.com/v6/latest/USD');

  /// Monedas que se pueden elegir.
  static const currencies = ['MXN', 'USD', 'EUR', 'CLP', 'ARS', 'BRL', 'COP'];

  AppDatabase? _db;
  String display = 'MXN';

  /// Unidades de cada moneda por 1 USD.
  Map<String, double> _rates = {};
  DateTime? ratesDate;

  /// Carga la moneda elegida y el último tipo de cambio guardado.
  static Money load(AppDatabase db) {
    final m = instance = Money._().._db = db;
    m.display = db.getSetting(_displayKey) ?? 'MXN';
    final saved = db.getSetting(_ratesKey);
    if (saved != null) {
      try {
        final j = jsonDecode(saved) as Map<String, dynamic>;
        m._rates = (j['rates'] as Map).map(
          (k, v) => MapEntry(k as String, (v as num).toDouble()),
        );
        m.ratesDate = DateTime.tryParse(j['date'] as String? ?? '');
      } catch (_) {}
    }
    return m;
  }

  /// Para pruebas: tipos de cambio fijos.
  static Money forTest({
    String display = 'MXN',
    Map<String, double> rates = const {},
  }) => instance = Money._()
    ..display = display
    .._rates = rates
    ..ratesDate = rates.isEmpty ? null : DateTime(2026, 10, 27);

  void setDisplay(String code) {
    display = code;
    _db?.setSetting(_displayKey, code);
  }

  bool get hasRates => _rates.isNotEmpty;

  /// Descarga el tipo de cambio si el guardado tiene más de [maxAge].
  /// Devuelve true si lo actualizó.
  Future<bool> refreshRates({
    Duration maxAge = const Duration(hours: 12),
    http.Client? client,
  }) async {
    if (ratesDate != null && DateTime.now().difference(ratesDate!) < maxAge) {
      return false;
    }
    final c = client ?? http.Client();
    try {
      final res = await c.get(_ratesUrl).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return false;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (j['result'] != 'success') return false;
      _rates = (j['rates'] as Map).map(
        (k, v) => MapEntry(k as String, (v as num).toDouble()),
      );
      ratesDate = DateTime.now();
      _db?.setSetting(
        _ratesKey,
        jsonEncode({'date': ratesDate!.toIso8601String(), 'rates': _rates}),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      if (client == null) c.close();
    }
  }

  /// [amount] en [from] convertido a la moneda elegida (null si no hay tipo
  /// de cambio para esa moneda).
  double? convert(double? amount, String? from) {
    if (amount == null) return null;
    final src = from ?? 'MXN';
    if (src == display) return amount;
    final a = _rates[src], b = _rates[display];
    if (a == null || b == null || a == 0) return null;
    return amount / a * b;
  }

  static int _decimals(String code) =>
      const {'CLP', 'COP', 'ARS'}.contains(code) ? 0 : 2;

  static String _symbol(String code) =>
      const {'BRL': r'R$', 'EUR': '€'}[code] ?? r'$';

  /// "$1,234.50 MXN".
  static String formatIn(double amount, String code) {
    final parts = amount.toStringAsFixed(_decimals(code)).split('.');
    final whole = parts[0].replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (m) => '${m[1]},',
    );
    final cents = parts.length > 1 ? '.${parts[1]}' : '';
    return '${_symbol(code)}$whole$cents $code';
  }

  /// Monto que ya está en la moneda elegida.
  String format(double? amount) =>
      amount == null ? '' : formatIn(amount, display);

  /// Precio de un producto en la moneda elegida; si no se puede convertir,
  /// en su moneda original.
  String formatFrom(double? amount, String? from) {
    if (amount == null) return '';
    final converted = convert(amount, from);
    return converted == null
        ? formatIn(amount, from ?? 'MXN')
        : formatIn(converted, display);
  }
}

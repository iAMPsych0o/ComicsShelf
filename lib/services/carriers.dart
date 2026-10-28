/// Paqueterías con página de rastreo que acepta la guía en la dirección.
/// Para las que no (o si no se sabe cuál es) se usa 17TRACK, que reconoce
/// cientos de paqueterías a partir del número.
class Carrier {
  final String key;
  final String name;

  /// Dirección de rastreo; `{n}` se reemplaza por la guía.
  final String urlTemplate;

  const Carrier(this.key, this.name, this.urlTemplate);

  Uri trackingUrl(String tracking) => Uri.parse(
    urlTemplate.replaceAll(
      '{n}',
      Uri.encodeComponent(tracking.replaceAll(RegExp(r'\s+'), '')),
    ),
  );
}

const _seventeen = 'https://t.17track.net/es#nums={n}';

const otherCarrier = Carrier('otra', 'Otra / no sé', _seventeen);

const carriers = [
  Carrier(
    'estafeta',
    'Estafeta',
    'https://cs.estafeta.com/es/Tracking/searchByGet?wayBill={n}'
        '&wayBillType=1&isShipmentDetail=False',
  ),
  Carrier(
    'dhl',
    'DHL',
    'https://www.dhl.com/mx-es/home/rastreo.html?tracking-id={n}&submit=1',
  ),
  Carrier('fedex', 'FedEx', 'https://www.fedex.com/fedextrack/?trknbr={n}'),
  Carrier('ups', 'UPS', 'https://www.ups.com/track?loc=es_MX&tracknum={n}'),
  Carrier(
    'paquetexpress',
    'Paquetexpress',
    'https://www.paquetexpress.com.mx/rastreo/{n}',
  ),
  // Correos de México no recibe la guía en la dirección: va por 17TRACK.
  Carrier('correos_mx', 'Correos de México', _seventeen),
  Carrier(
    '99minutos',
    '99minutos',
    'https://tracking.99minutos.com/search/{n}',
  ),
  Carrier(
    'jt',
    'J&T Express',
    'https://www.jtexpress.mx/trajectoryQuery?waybillNo={n}',
  ),
  Carrier('amazon', 'Amazon', 'https://track.amazon.com/tracking/{n}'),
  Carrier('mercadolibre', 'Mercado Libre', _seventeen),
  otherCarrier,
];

Carrier carrierByKey(String? key) =>
    carriers.firstWhere((c) => c.key == key, orElse: () => otherCarrier);

/// Adivina la paquetería por el formato de la guía (null si no se parece a
/// ninguno). Es solo una sugerencia: el usuario puede cambiarla.
Carrier? detectCarrier(String tracking) {
  final t = tracking.replaceAll(RegExp(r'\s+'), '').toUpperCase();
  if (t.isEmpty) return null;
  if (t.startsWith('TBA')) return carrierByKey('amazon');
  if (RegExp(r'^1Z[0-9A-Z]{16}$').hasMatch(t)) return carrierByKey('ups');
  // Formato postal internacional (UPU S10): 2 letras, 9 dígitos, país.
  if (RegExp(r'^[A-Z]{2}\d{9}MX$').hasMatch(t)) {
    return carrierByKey('correos_mx');
  }
  if (RegExp(r'^[0-9A-Z]{22}$').hasMatch(t)) return carrierByKey('estafeta');
  if (RegExp(r'^\d{10}$').hasMatch(t)) return carrierByKey('dhl');
  if (RegExp(r'^(\d{12}|\d{15}|\d{20})$').hasMatch(t)) {
    return carrierByKey('fedex');
  }
  return null;
}

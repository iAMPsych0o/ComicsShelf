import 'package:comics_panini/db/app_database.dart';
import 'package:comics_panini/services/carriers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adivina la paquetería por el formato de la guía', () {
    String? key(String t) => detectCarrier(t)?.key;
    expect(key('1Z999AA10123456784'), 'ups');
    expect(key('TBA123456789000'), 'amazon');
    expect(key('1234567890'), 'dhl');
    expect(key('1234 5678 9012'), 'fedex'); // con espacios
    expect(key('8055241528464720099314'), 'estafeta');
    expect(key('rr123456789mx'), 'correos_mx');
    expect(key('ABC-123'), isNull);
    expect(key(''), isNull);
  });

  test('arma el enlace de rastreo con la guía', () {
    expect(
      carrierByKey('fedex').trackingUrl(' 1234 5678 9012 ').toString(),
      'https://www.fedex.com/fedextrack/?trknbr=123456789012',
    );
    expect(
      carrierByKey('dhl').trackingUrl('1234567890').toString(),
      contains('tracking-id=1234567890'),
    );
    // Sin paquetería conocida: 17TRACK.
    expect(
      carrierByKey(null).trackingUrl('XYZ1').toString(),
      'https://t.17track.net/es#nums=XYZ1',
    );
  });

  test('la paquetería se guarda, se edita y viaja en el respaldo', () {
    final db = AppDatabase.inMemory();
    final u = db.insertUser('a', 'h', 's');
    final id = db.createOrder(
      u,
      store: 'Panini',
      tracking: '1234567890',
      carrier: 'dhl',
    );
    expect(db.order(u, id)!.carrier, 'dhl');
    db.updateOrder(
      u,
      id,
      store: 'Panini',
      tracking: '1Z999AA10123456784',
      carrier: 'ups',
    );
    expect(db.order(u, id)!.carrier, 'ups');

    final other = AppDatabase.inMemory();
    final me = other.insertUser('a', 'h', 's');
    other.importUserData(me, db.exportUserData(u));
    expect(other.orders(me).single.carrier, 'ups');
  });
}

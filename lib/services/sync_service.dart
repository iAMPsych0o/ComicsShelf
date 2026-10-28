import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

/// Sincronización directa entre dos dispositivos de la misma red Wi-Fi, sin
/// servidor. Siempre es en un solo sentido: el que envía reemplaza las
/// colecciones y estados del que recibe (previa confirmación de este).
///
/// - El que **recibe** abre un servidor HTTP local, genera un PIN de 6 dígitos
///   y se anuncia por UDP broadcast en la red.
/// - El que **envía** escucha los anuncios (o usa la dirección escrita a
///   mano), cifra los datos con una clave derivada del PIN y los manda.
///
/// Los datos van cifrados con AES-256-GCM; la clave sale del PIN con
/// PBKDF2 y una sal aleatoria por sesión. El receptor se cierra tras 5 PIN
/// incorrectos.
class SyncException implements Exception {
  final String message;
  SyncException(this.message);
  @override
  String toString() => message;
}

const discoveryPort = 47320;
const _protocol = 1;
const _maxAttempts = 5;

/// Cifrado de los datos con una clave derivada del PIN.
class SyncCrypto {
  static final _aes = AesGcm.with256bits();
  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 100000,
    bits: 256,
  );

  static Future<SecretKey> deriveKey(String pin, List<int> salt) =>
      _kdf.deriveKeyFromPassword(password: pin, nonce: salt);

  static Future<String> encrypt(
    SecretKey key,
    Map<String, Object?> data,
  ) async {
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(data)),
      secretKey: key,
    );
    return base64Encode(box.concatenation());
  }

  /// Lanza [SecretBoxAuthenticationError] si la clave (el PIN) no coincide.
  static Future<Map<String, Object?>> decrypt(
    SecretKey key,
    String payload,
  ) async {
    final box = SecretBox.fromConcatenation(
      base64Decode(payload),
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    final clear = await _aes.decrypt(box, secretKey: key);
    return (jsonDecode(utf8.decode(clear)) as Map).cast<String, Object?>();
  }
}

/// Un dispositivo que está esperando recibir datos.
class SyncPeer {
  final String name;
  final String host;
  final int port;
  final List<int> salt;

  const SyncPeer({
    required this.name,
    required this.host,
    required this.port,
    required this.salt,
  });

  String get address => '$host:$port';

  static SyncPeer? fromJson(Map<String, Object?> j, String host) {
    if (j['app'] != 'ComicShelf' || j['v'] != _protocol) return null;
    if (j['port'] is! int || j['salt'] is! String) return null;
    return SyncPeer(
      name: '${j['name'] ?? 'Dispositivo'}',
      host: host,
      port: j['port'] as int,
      salt: base64Decode(j['salt'] as String),
    );
  }
}

/// Datos recibidos y descifrados.
class ReceivedSync {
  final String from;
  final Map<String, Object?> data;
  const ReceivedSync(this.from, this.data);
}

/// Direcciones IPv4 de la red local de este dispositivo.
Future<List<String>> localAddresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  final all = [
    for (final i in interfaces)
      for (final a in i.addresses) a.address,
  ];
  // Primero las de redes domésticas típicas.
  all.sort(
    (a, b) => (a.startsWith('192.168.') ? 0 : 1).compareTo(
      b.startsWith('192.168.') ? 0 : 1,
    ),
  );
  return all;
}

/// Direcciones de broadcast de la red local: la general y la de cada /24.
Future<Set<String>> _broadcastTargets() async => {
  '255.255.255.255',
  for (final a in await localAddresses())
    '${a.substring(0, a.lastIndexOf('.'))}.255',
};

/// Mensaje con el que quien envía pregunta "¿quién está esperando?".
final _query = utf8.encode(
  jsonEncode({'app': 'ComicShelf', 'v': _protocol, 'q': 1}),
);

bool _isQuery(Datagram dg) {
  try {
    final j = jsonDecode(utf8.decode(dg.data));
    return j is Map && j['app'] == 'ComicShelf' && j['q'] == 1;
  } catch (_) {
    return false;
  }
}

/// Espera datos de otro dispositivo.
class SyncReceiver {
  SyncReceiver({required this.deviceName, this.announce = true});

  final String deviceName;

  /// Si se anuncia por UDP (se desactiva en pruebas).
  final bool announce;

  late final String pin;
  late final List<int> _salt;
  late final SecretKey _key;
  HttpServer? _server;
  RawDatagramSocket? _socket;
  Timer? _timer;
  int _failed = 0;
  final _received = Completer<ReceivedSync>();

  /// Se completa al recibir datos válidos (o con error si se agotan los
  /// intentos de PIN).
  Future<ReceivedSync> get received => _received.future;

  int get port => _server!.port;

  Map<String, Object?> get _info => {
    'app': 'ComicShelf',
    'v': _protocol,
    'name': deviceName,
    'port': port,
    'salt': base64Encode(_salt),
  };

  Future<void> start() async {
    final rnd = Random.secure();
    pin = List.generate(6, (_) => rnd.nextInt(10)).join();
    _salt = List.generate(16, (_) => rnd.nextInt(256));
    _key = await SyncCrypto.deriveKey(pin, _salt);

    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_handle);

    if (announce) {
      // Dos formas de que el otro nos encuentre:
      // 1. Anuncio por broadcast cada segundo (sirve cuando el que envía es
      //    la PC: Windows sí recibe broadcast).
      // 2. Respuesta directa a las preguntas del que envía (sirve cuando el
      //    que envía es un teléfono: muchos Android descartan los broadcast
      //    que reciben, pero sí reciben respuestas directas).
      _socket =
          await RawDatagramSocket.bind(
              InternetAddress.anyIPv4,
              discoveryPort,
              reuseAddress: true,
            )
            ..broadcastEnabled = true;
      _socket!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = _socket?.receive();
        if (dg == null || !_isQuery(dg)) return;
        try {
          _socket?.send(utf8.encode(jsonEncode(_info)), dg.address, dg.port);
        } catch (_) {}
      });
      final targets = await _broadcastTargets();
      void send() {
        final msg = utf8.encode(jsonEncode(_info));
        for (final t in targets) {
          try {
            _socket?.send(msg, InternetAddress(t), discoveryPort);
          } catch (_) {}
        }
      }

      send();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => send());
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response..headers.contentType = ContentType.json;
    // Lo que se avisa a la pantalla se hace DESPUÉS de responder: si no, la
    // pantalla cierra el servidor antes de que la respuesta llegue al otro
    // dispositivo y este cree que falló.
    void Function()? afterResponse;
    try {
      if (req.method == 'GET' && req.uri.path == '/info') {
        res.write(jsonEncode(_info));
      } else if (req.method == 'POST' && req.uri.path == '/sync') {
        if (_received.isCompleted) {
          res.statusCode = HttpStatus.conflict;
          res.write(jsonEncode({'error': 'Ya se recibieron datos.'}));
        } else {
          final body = jsonDecode(await utf8.decodeStream(req)) as Map;
          try {
            final data = await SyncCrypto.decrypt(_key, body['data'] as String);
            res.write(jsonEncode({'ok': true}));
            final got = ReceivedSync(
              '${body['from'] ?? 'Otro dispositivo'}',
              data,
            );
            afterResponse = () {
              if (!_received.isCompleted) _received.complete(got);
            };
          } on SecretBoxAuthenticationError {
            _failed++;
            res.statusCode = HttpStatus.forbidden;
            res.write(jsonEncode({'error': 'PIN incorrecto.'}));
            if (_failed >= _maxAttempts) {
              afterResponse = () {
                if (!_received.isCompleted) {
                  _received.completeError(
                    SyncException('Se escribió mal el PIN demasiadas veces.'),
                  );
                }
              };
            }
          }
        }
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      res.statusCode = HttpStatus.badRequest;
    } finally {
      try {
        await res.close();
      } catch (_) {}
      afterResponse?.call();
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _socket?.close();
    await _server?.close(force: true);
  }
}

/// Envía datos a otro dispositivo.
class SyncSender {
  SyncSender({required this.deviceName, http.Client? client})
    : _client = client ?? http.Client();

  final String deviceName;
  final http.Client _client;
  RawDatagramSocket? _socket;
  Timer? _askTimer;

  /// Dispositivos que se anuncian en la red, a medida que aparecen.
  Stream<SyncPeer> discover() async* {
    _socket =
        await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            discoveryPort,
            reuseAddress: true,
          )
          ..broadcastEnabled = true;
    final targets = await _broadcastTargets();
    void ask() {
      for (final t in targets) {
        try {
          _socket?.send(_query, InternetAddress(t), discoveryPort);
        } catch (_) {}
      }
    }

    ask();
    _askTimer = Timer.periodic(const Duration(seconds: 1), (_) => ask());
    final seen = <String>{};
    await for (final event in _socket!) {
      if (event != RawSocketEvent.read) continue;
      final dg = _socket!.receive();
      if (dg == null) continue;
      try {
        final j = (jsonDecode(utf8.decode(dg.data)) as Map)
            .cast<String, Object?>();
        final peer = SyncPeer.fromJson(j, dg.address.address);
        if (peer != null && seen.add(peer.address)) yield peer;
      } catch (_) {}
    }
  }

  /// Busca un dispositivo por dirección escrita a mano ("192.168.1.20:5000").
  Future<SyncPeer> peerAt(String address) async {
    final uri = Uri.tryParse('http://${address.trim()}/info');
    if (uri == null || uri.host.isEmpty || !uri.hasPort) {
      throw SyncException('Escribe la dirección como 192.168.1.20:54321.');
    }
    try {
      final res = await _client.get(uri).timeout(const Duration(seconds: 5));
      final peer = SyncPeer.fromJson(
        (jsonDecode(res.body) as Map).cast<String, Object?>(),
        uri.host,
      );
      if (peer == null) {
        throw SyncException('Ahí no hay un ComicShelf esperando.');
      }
      return peer;
    } on SyncException {
      rethrow;
    } catch (_) {
      throw SyncException('No se encontró ComicShelf en $address.');
    }
  }

  Future<void> send(
    SyncPeer peer,
    String pin,
    Map<String, Object?> data,
  ) async {
    final key = await SyncCrypto.deriveKey(
      pin.replaceAll(RegExp(r'\s'), ''),
      peer.salt,
    );
    final payload = await SyncCrypto.encrypt(key, data);
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('http://${peer.address}/sync'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'from': deviceName, 'data': payload}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw SyncException('No se pudo conectar con ${peer.name}.');
    }
    if (res.statusCode == HttpStatus.ok) return;
    final error = (() {
      try {
        return (jsonDecode(res.body) as Map)['error'] as String?;
      } catch (_) {
        return null;
      }
    })();
    throw SyncException(
      error ?? 'El otro dispositivo respondió con error ${res.statusCode}.',
    );
  }

  void close() {
    _askTimer?.cancel();
    _socket?.close();
    _client.close();
  }
}

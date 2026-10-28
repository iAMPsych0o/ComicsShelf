import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../db/app_database.dart';

/// Portadas guardadas en el dispositivo.
///
/// Cada portada se descarga una sola vez, ya reducida por el servidor de la
/// tienda (300 px de ancho, WebP), y se guarda en `portadas/`. Así se ven sin
/// internet, cargan rápido y no gastan datos móviles una y otra vez.
class CoverCache {
  CoverCache._(this._db, this.folder, {http.Client? client})
    : _client = client ?? http.Client();

  /// Caché activa de la app (null en pruebas: las portadas se piden directo).
  static CoverCache? instance;

  static const width = 300;
  static const _wifiOnlyKey = 'covers_wifi_only';

  final AppDatabase _db;
  final Directory folder;
  final http.Client _client;
  final _inFlight = <String, Future<Uint8List?>>{};
  List<ConnectivityResult> _network = const [ConnectivityResult.other];
  StreamSubscription<List<ConnectivityResult>>? _networkSub;

  /// Crea la caché junto a la base de datos y empieza a vigilar la red.
  static Future<CoverCache?> start(AppDatabase db) async {
    final dir = db.directory;
    if (dir == null) return null;
    final cache = CoverCache._(db, Directory(p.join(dir, 'portadas')));
    await cache.folder.create(recursive: true);
    try {
      final net = Connectivity();
      cache._network = await net.checkConnectivity();
      cache._networkSub = net.onConnectivityChanged.listen(
        (r) => cache._network = r,
      );
    } catch (_) {
      // Sin información de red: se asume que se puede descargar.
    }
    return instance = cache;
  }

  /// Crea una caché en una carpeta concreta, para pruebas.
  @visibleForTesting
  static CoverCache at(
    AppDatabase db,
    Directory folder, {
    http.Client? client,
    List<ConnectivityResult> network = const [ConnectivityResult.wifi],
  }) => CoverCache._(db, folder, client: client).._network = network;

  /// Dirección de la portada reducida que entrega el servidor de la tienda.
  static String thumbUrl(String url) {
    final uri = Uri.parse(url);
    return uri
        .replace(
          queryParameters: {
            'width': '$width',
            'format': 'webp',
            'quality': '70',
          },
        )
        .toString();
  }

  /// Solo descargar portadas con Wi-Fi (o cable). Activado por defecto.
  bool get wifiOnly => _db.getSetting(_wifiOnlyKey) != '0';
  set wifiOnly(bool v) => _db.setSetting(_wifiOnlyKey, v ? '1' : '0');

  /// Si ahora mismo se permite descargar portadas.
  bool get canDownload {
    if (_network.contains(ConnectivityResult.none) && _network.length == 1) {
      return false;
    }
    if (!wifiOnly) return true;
    return _network.any(
      (r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.other,
    );
  }

  /// Si la red actual es de datos móviles (para avisar en Configuración).
  bool get onMobileData =>
      _network.contains(ConnectivityResult.mobile) &&
      !_network.contains(ConnectivityResult.wifi) &&
      !_network.contains(ConnectivityResult.ethernet);

  File _fileFor(String url) =>
      File(p.join(folder.path, '${sha1.convert(url.codeUnits)}.webp'));

  bool isCached(String url) => _fileFor(url).existsSync();

  /// Bytes de la portada: del disco si ya está; si no, la descarga (cuando
  /// la red lo permite) y la guarda. Null si no se pudo obtener.
  Future<Uint8List?> load(String url) {
    final file = _fileFor(url);
    if (file.existsSync()) return file.readAsBytes();
    if (!canDownload) return Future.value();
    return _inFlight[url] ??= _download(url, file).whenComplete(() {
      // Sin devolver el Future quitado: whenComplete lo esperaría y se
      // quedaría esperándose a sí mismo.
      _inFlight.remove(url);
    });
  }

  Future<Uint8List?> _download(String url, File file) async {
    try {
      final res = await _client
          .get(Uri.parse(thumbUrl(url)))
          .timeout(const Duration(seconds: 30));
      final type = res.headers['content-type'] ?? '';
      if (res.statusCode != 200 || !type.startsWith('image/')) return null;
      // Se escribe aparte y se renombra: nunca queda un archivo a medias.
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(res.bodyBytes, flush: true);
      await tmp.rename(file.path);
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// Cuántas portadas hay guardadas y cuánto ocupan.
  ({int count, int bytes}) usage() {
    var count = 0, bytes = 0;
    if (!folder.existsSync()) return (count: 0, bytes: 0);
    for (final f in folder.listSync().whereType<File>()) {
      if (!f.path.endsWith('.webp')) continue;
      count++;
      bytes += f.lengthSync();
    }
    return (count: count, bytes: bytes);
  }

  /// Portadas del catálogo que aún no están guardadas.
  List<String> missing() => _db.coverUrls().where((u) => !isCached(u)).toList();

  /// Descarga todas las portadas que falten, de [parallel] en [parallel].
  /// Se detiene si [cancelled] devuelve true o si deja de haber red
  /// permitida. Devuelve cuántas se guardaron.
  Future<int> downloadAll({
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
    int parallel = 6,
  }) async {
    final urls = missing();
    var next = 0, done = 0, saved = 0;
    Future<void> worker() async {
      while (next < urls.length) {
        if (cancelled?.call() == true || !canDownload) return;
        final url = urls[next++];
        if (await load(url) != null) saved++;
        onProgress?.call(++done, urls.length);
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
    return saved;
  }

  /// Borra todas las portadas guardadas.
  Future<void> clear() async {
    if (folder.existsSync()) await folder.delete(recursive: true);
    await folder.create(recursive: true);
    PaintingBinding.instance.imageCache.clear();
  }

  void dispose() {
    _networkSub?.cancel();
    _client.close();
  }
}

/// Imagen de una portada que pasa por [CoverCache].
class CachedCover extends ImageProvider<CachedCover> {
  const CachedCover(this.cache, this.url);

  final CoverCache cache;
  final String url;

  @override
  Future<CachedCover> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    CachedCover key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final bytes = await cache.load(url);
    if (bytes == null) throw StateError('Portada no disponible: $url');
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) => other is CachedCover && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

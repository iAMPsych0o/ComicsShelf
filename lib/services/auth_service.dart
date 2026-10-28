import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../db/app_database.dart';
import '../models.dart';

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

/// Maneja las cuentas locales y la sesión activa.
///
/// La sesión vive solo en memoria: al cerrar la app hay que volver a
/// iniciar sesión.
class AuthService extends ChangeNotifier {
  /// Si hay una sesión recordada en este dispositivo, la restaura.
  AuthService(this._db) {
    final id = int.tryParse(_db.getSetting(_rememberKey) ?? '');
    final row = id == null ? null : _db.findUserById(id);
    if (row != null) {
      _current = User(
        id: row['id'] as int,
        username: row['username'] as String,
      );
    } else if (id != null) {
      _db.setSetting(_rememberKey, null); // el usuario ya no existe
    }
  }

  static const _rememberKey = 'remembered_user_id';

  final AppDatabase _db;
  User? _current;

  /// Si la sesión del usuario actual se mantiene al cerrar la app.
  bool get isRemembered =>
      _current != null && _db.getSetting(_rememberKey) == '${_current!.id}';

  void setRemembered(bool remember) {
    if (_current == null) return;
    _remember(remember);
    notifyListeners();
  }

  /// Guarda (o borra) la sesión recordada del usuario actual.
  void _remember(bool remember) =>
      _db.setSetting(_rememberKey, remember ? '${_current!.id}' : null);

  User? get currentUser => _current;
  bool get isLoggedIn => _current != null;

  static const _iterations = 120000;

  void register(String username, String password, {bool remember = false}) {
    final name = username.trim();
    if (name.length < 3) {
      throw AuthException('El usuario debe tener al menos 3 caracteres.');
    }
    if (password.length < 6) {
      throw AuthException('La contraseña debe tener al menos 6 caracteres.');
    }
    if (_db.findUserRow(name) != null) {
      throw AuthException('Ese usuario ya existe.');
    }
    final salt = _randomSalt();
    final id = _db.insertUser(name, _hash(password, salt), salt);
    _current = User(id: id, username: name);
    _remember(remember);
    notifyListeners();
  }

  void login(String username, String password, {bool remember = false}) {
    final row = _db.findUserRow(username);
    if (row == null ||
        !_constantTimeEquals(
          _hash(password, row['salt'] as String),
          row['password_hash'] as String,
        )) {
      throw AuthException('Usuario o contraseña incorrectos.');
    }
    final id = row['id'] as int;
    _current = User(id: id, username: row['username'] as String);
    _remember(remember);
    notifyListeners();
  }

  /// Cierra la sesión y olvida la sesión recordada.
  void logout() {
    _current = null;
    _db.setSetting(_rememberKey, null);
    notifyListeners();
  }

  static String _randomSalt() {
    final rnd = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
  }

  /// PBKDF2-HMAC-SHA256 (un bloque de 32 bytes).
  static String _hash(String password, String salt) {
    final hmac = Hmac(sha256, utf8.encode(password));
    final saltBytes = base64Decode(salt);
    final block = Uint8List(saltBytes.length + 4)
      ..setAll(0, saltBytes)
      ..setAll(saltBytes.length, [0, 0, 0, 1]);
    var u = hmac.convert(block).bytes;
    final out = Uint8List.fromList(u);
    for (var i = 1; i < _iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return base64Encode(out);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

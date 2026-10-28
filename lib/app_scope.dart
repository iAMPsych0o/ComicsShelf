import 'package:flutter/widgets.dart';

import 'db/app_database.dart';
import 'models.dart';
import 'services/auth_service.dart';

/// Da acceso a la base de datos y a la sesión desde cualquier pantalla.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.db,
    required this.auth,
    required super.child,
  });

  final AppDatabase db;
  final AuthService auth;

  /// Usuario con sesión activa. Solo se usa dentro de pantallas protegidas.
  User get user => auth.currentUser!;

  /// La base de datos y la sesión nunca se reemplazan, así que no hace falta
  /// registrar dependencias (y así se puede usar desde callbacks y diálogos).
  static AppScope of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      db != oldWidget.db || auth != oldWidget.auth;
}

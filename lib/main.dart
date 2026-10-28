import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'db/app_database.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';
import 'services/cover_cache.dart';
import 'services/currency.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  try {
    db.compactIfDue();
  } catch (_) {
    // Compactar es opcional: si falla, se intenta en otro arranque.
  }
  await CoverCache.start(db);
  // Tipo de cambio guardado; se actualiza en segundo plano (una vez al día).
  Money.load(db).refreshRates();
  final auth = AuthService(db);
  runApp(AppScope(db: db, auth: auth, child: const ComicsPaniniApp()));
}

class ComicsPaniniApp extends StatelessWidget {
  const ComicsPaniniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ComicShelf',
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      home: const AuthGate(),
    );
  }
}

/// Paleta negro y rojo.
const brandRed = Color(0xFFB8323A);

final appTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF0A0A0A),
  colorScheme: const ColorScheme.dark(
    primary: brandRed,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFF5E1A1E),
    onPrimaryContainer: Colors.white,
    secondary: Color(0xFFD06A70),
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFF3D1517),
    onSecondaryContainer: Colors.white,
    tertiary: Color(0xFFE09A94),
    tertiaryContainer: Color(0xFF5A2A00),
    onTertiaryContainer: Colors.white,
    error: Color(0xFFFF6B6B),
    errorContainer: Color(0xFF5C1010),
    onErrorContainer: Colors.white,
    surface: Color(0xFF0A0A0A),
    onSurface: Color(0xFFF2F2F2),
    onSurfaceVariant: Color(0xFFA8A8A8),
    surfaceContainerLowest: Color(0xFF050505),
    surfaceContainerLow: Color(0xFF111111),
    surfaceContainer: Color(0xFF161616),
    surfaceContainerHigh: Color(0xFF1C1C1C),
    surfaceContainerHighest: Color(0xFF262626),
    outline: Color(0xFF4A4A4A),
    outlineVariant: Color(0xFF2C2C2C),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF000000),
    foregroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
  ),
  navigationRailTheme: const NavigationRailThemeData(
    backgroundColor: Color(0xFF000000),
    indicatorColor: brandRed,
    selectedIconTheme: IconThemeData(color: Colors.white),
  ),
  navigationBarTheme: const NavigationBarThemeData(
    backgroundColor: Color(0xFF000000),
    indicatorColor: brandRed,
  ),
  // Los botones de texto usan un rojo más claro para leerse bien sobre negro.
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(foregroundColor: const Color(0xFFE07A80)),
  ),
  cardTheme: const CardThemeData(
    color: Color(0xFF161616),
    surfaceTintColor: Colors.transparent,
  ),
  dialogTheme: const DialogThemeData(
    backgroundColor: Color(0xFF161616),
    surfaceTintColor: Colors.transparent,
  ),
);

/// Muestra el login si no hay sesión activa; nada más es accesible sin ella.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AppScope.of(context).auth;
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) => auth.isLoggedIn
          ? HomeShell(key: ValueKey(auth.currentUser!.id))
          : const LoginScreen(),
    );
  }
}

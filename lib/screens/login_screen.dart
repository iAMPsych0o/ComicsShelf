import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _registering = false;
  bool _busy = false;
  bool _showPass = false;
  bool _remember = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _pass2.dispose();
    super.dispose();
  }

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
      if (_registering) {
        auth.register(_user.text, _pass.text, remember: _remember);
      } else {
        auth.login(_user.text, _pass.text, remember: _remember);
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Image.asset(
                            'assets/icon/icon_c.png',
                            width: 84,
                            height: 84,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'ComicShelf',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _registering
                            ? 'Crea tu cuenta'
                            : 'Inicia sesión para ver tu catálogo',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _user,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: 'Usuario',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                        textInputAction: TextInputAction.next,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Escribe tu usuario'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _pass,
                        obscureText: !_showPass,
                        decoration: InputDecoration(
                          labelText: 'Contraseña',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            tooltip: _showPass ? 'Ocultar' : 'Mostrar',
                            icon: Icon(
                              _showPass
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                            onPressed: () =>
                                setState(() => _showPass = !_showPass),
                          ),
                        ),
                        textInputAction: _registering
                            ? TextInputAction.next
                            : TextInputAction.done,
                        onFieldSubmitted: (_) =>
                            _registering ? null : _submit(),
                        validator: (v) => (v == null || v.isEmpty)
                            ? 'Escribe tu contraseña'
                            : null,
                      ),
                      if (_registering) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _pass2,
                          obscureText: !_showPass,
                          decoration: const InputDecoration(
                            labelText: 'Confirmar contraseña',
                            prefixIcon: Icon(Icons.lock_outline),
                            border: OutlineInputBorder(),
                          ),
                          onFieldSubmitted: (_) => _submit(),
                          validator: (v) => v != _pass.text
                              ? 'Las contraseñas no coinciden'
                              : null,
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        value: _remember,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _remember = v ?? false),
                        title: const Text('Recuérdame'),
                        subtitle: const Text(
                          'Mantener la sesión iniciada en este dispositivo',
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                _registering
                                    ? 'Crear cuenta'
                                    : 'Iniciar sesión',
                              ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _registering = !_registering;
                                _error = null;
                              }),
                        child: Text(
                          _registering
                              ? '¿Ya tienes cuenta? Inicia sesión'
                              : '¿No tienes cuenta? Crea una',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

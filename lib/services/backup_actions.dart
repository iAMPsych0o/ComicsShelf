import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_scope.dart';
import '../db/app_database.dart';
import '../models.dart';
import '../widgets/comic_widgets.dart';

String _today() {
  final d = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// Nombre seguro para archivos a partir del nombre de usuario.
String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

const _json = JsonEncoder.withIndent('  ');

/// Respaldos automáticos que se conservan por usuario.
const keepAutoBackups = 3;

/// Borra los respaldos automáticos más viejos de [username] y deja los
/// últimos [keepAutoBackups]. No toca los de otros usuarios.
void pruneAutoBackups(Directory folder, String username) {
  final prefix = '${_safe(username)}_antes_de_importar_';
  final mine =
      folder.listSync().whereType<File>().where((f) {
          final name = p.basename(f.path);
          return name.startsWith(prefix) && name.endsWith('.json');
        }).toList()
        // El nombre lleva la fecha y hora, así que ordenar por nombre es
        // ordenar por antigüedad.
        ..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
  for (final old in mine.skip(keepAutoBackups)) {
    try {
      old.deleteSync();
    } catch (_) {}
  }
}

/// Reemplaza los datos de [user] con [data], guardando antes un respaldo
/// automático de lo que tenía. Devuelve la ruta de ese respaldo (o null si
/// la base está en memoria).
String? importWithAutoBackup(
  AppDatabase db,
  User user,
  Map<String, Object?> data,
) {
  String? auto;
  final dir = db.directory;
  if (dir != null) {
    final folder = Directory(p.join(dir, 'respaldos_automaticos'))
      ..createSync(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    auto = p.join(
      folder.path,
      '${_safe(user.username)}_antes_de_importar_$stamp.json',
    );
    File(auto).writeAsStringSync(_json.convert(db.exportUserData(user.id)));
    pruneAutoBackups(folder, user.username);
  }
  db.importUserData(user.id, data);
  return auto;
}

/// Exporta los datos del usuario con sesión activa a un archivo que él elige.
Future<void> exportBackup(BuildContext context) async {
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final data = scope.db.exportUserData(scope.user.id);
    final saved = await FilePicker.saveFile(
      dialogTitle: 'Guardar respaldo de ComicShelf',
      fileName:
          'respaldo_comicshelf_${_safe(scope.user.username)}_${_today()}.json',
      bytes: utf8.encode(_json.convert(data)),
      mimeType: 'application/json',
    );
    if (saved == null) return; // canceló
    final where = saved.scheme == 'file'
        ? saved.toFilePath()
        : saved.toString();
    showNotice(messenger, 'Respaldo guardado en $where');
  } catch (e) {
    showNotice(messenger, 'No se pudo exportar el respaldo: $e');
  }
}

/// Importa un respaldo en la sesión activa. Solo reemplaza las colecciones y
/// estados de este usuario; antes guarda un respaldo automático de ellos.
Future<void> importBackup(
  BuildContext context, {
  VoidCallback? onImported,
}) async {
  final scope = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final user = scope.user;

  final picked = await FilePicker.pickFiles(
    dialogTitle: 'Elegir respaldo de ComicShelf',
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  if (picked.isEmpty || !context.mounted) return;

  final Map<String, Object?> data;
  final BackupSummary summary;
  try {
    final decoded = jsonDecode(
      utf8.decode(await picked.first.xFile.readAsBytes()),
    );
    summary = AppDatabase.inspectUserBackup(decoded);
    data = (decoded as Map).cast<String, Object?>();
  } on BackupException catch (e) {
    showNotice(messenger, e.message);
    return;
  } on FormatException {
    showNotice(messenger, 'El archivo no es un respaldo de ComicShelf.');
    return;
  }
  if (!context.mounted) return;

  final otherUser =
      summary.username.isNotEmpty &&
      summary.username.toLowerCase() != user.username.toLowerCase();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.warning_amber),
      title: const Text('Importar respaldo'),
      content: Text(
        'El respaldo "${picked.first.name}"'
        '${summary.username.isEmpty ? '' : ' de ${summary.username}'} contiene:\n'
        '• ${summary.collections} colecciones\n'
        '• ${summary.owned} obtenidos, ${summary.purchased} comprados, '
        '${summary.wishlist} en wishlist\n'
        '• ${summary.orders} pedidos, ${summary.carts} carritos\n\n'
        '${otherUser ? 'Ojo: el respaldo es de otro usuario.\n\n' : ''}'
        'Se reemplazarán TUS colecciones, estados, pedidos y carritos '
        '(${user.username}). '
        'Los demás usuarios no se modifican. Antes se guardará un respaldo '
        'automático de tus datos actuales.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Importar'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  try {
    final auto = importWithAutoBackup(scope.db, user, data);
    onImported?.call();
    showNotice(
      messenger,
      'Respaldo importado.'
      '${auto == null ? '' : ' Tus datos anteriores quedaron en: $auto'}',
    );
  } catch (e) {
    showNotice(messenger, 'No se pudo importar el respaldo: $e');
  }
}

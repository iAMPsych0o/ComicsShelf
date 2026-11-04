import '../db/app_database.dart';
import '../models.dart';
import 'backup_actions.dart';
import 'sync_merge.dart';
import 'sync_service.dart';

/// Lo que cada dispositivo hace con sus datos al sincronizar; las pantallas
/// solo muestran el avance y piden confirmación.

/// Datos para reemplazar los del otro dispositivo.
Map<String, Object?> replacePayload(
  AppDatabase db,
  int userId,
  String syncId,
) => {...db.exportUserData(userId, fullCatalog: true), 'sync_id': syncId};

/// El que recibe aplica un reemplazo aceptado.
void applyReplace(AppDatabase db, User user, ReceivedSync got) {
  importWithAutoBackup(db, user, got.data);
  final syncId = got.data['sync_id'];
  if (syncId is String) {
    db.saveSyncBase(user.id, syncId, SyncDoc.fromBackup(got.data).toBackup());
  } else {
    db.markSynced(user.id); // viene de una versión sin copia base
  }
}

/// El que envía guarda la base cuando el otro aceptó el reemplazo.
void confirmReplace(
  AppDatabase db,
  int userId,
  String syncId,
  Map<String, Object?> sent,
  int revision,
) => db.saveSyncBase(
  userId,
  syncId,
  SyncDoc.fromBackup(sent).toBackup(),
  revision: revision,
);

/// Datos para pedir una combinación.
Map<String, Object?> mergePayload(AppDatabase db, int userId) => {
  ...db.exportUserData(userId, fullCatalog: true),
  'base_sync_id': db.syncId(userId),
};

/// Combinación lista para confirmarse en el dispositivo que recibió la
/// petición; todavía no cambió nada.
class MergePlan {
  MergePlan({
    required this.result,
    required this.syncId,
    required this.sharedBase,
    required this.forHere,
    required this.forThere,
  });

  final MergeResult result;
  final String syncId;

  /// Sin base común (la última sincronización se interrumpió) nada se borra.
  final bool sharedBase;

  /// Resultado con el catálogo del otro y con el propio: cada lado agrega los
  /// cómics que le falten.
  final Map<String, Object?> forHere;
  final Map<String, Object?> forThere;

  Map<String, Object?> get accepted => {
    'accepted': true,
    'sync_id': syncId,
    'merged': forThere,
    'changes': result.toTheirs,
  };
}

/// Compara los datos recibidos con los de este dispositivo. Sin un reemplazo
/// previo no hay uids en común y todo saldría duplicado, así que se rechaza.
MergePlan planMerge(AppDatabase db, int userId, ReceivedSync got) {
  final myId = db.syncId(userId);
  final theirId = got.data['base_sync_id'];
  if (myId == null || theirId == null) {
    throw SyncException(
      'Todavía no hay una sincronización en común. Haz primero un reemplazo '
      '(PC → Móvil o Móvil → PC) y después ya podrás combinar.',
    );
  }
  final mine = db.exportUserData(userId, fullCatalog: true);
  final shared = myId == theirId;
  final result = mergeUserData(
    base: shared ? db.syncBase(userId) : null,
    mine: mine,
    theirs: got.data,
  );
  final merged = result.doc.toBackup();
  return MergePlan(
    result: result,
    syncId: newSyncId(),
    sharedBase: shared,
    forHere: {...merged, 'comics': got.data['comics']},
    forThere: {...merged, 'comics': mine['comics']},
  );
}

/// El dispositivo que combinó aplica el resultado (ya lo aplicó el otro).
void applyMerge(AppDatabase db, User user, MergePlan plan) {
  importWithAutoBackup(db, user, plan.forHere);
  db.saveSyncBase(user.id, plan.syncId, plan.result.doc.toBackup());
}

/// El que pidió la combinación aplica lo que le devolvieron.
void applyMergeReply(AppDatabase db, User user, Map<String, Object?> reply) {
  final merged = (reply['merged'] as Map).cast<String, Object?>();
  importWithAutoBackup(db, user, merged);
  db.saveSyncBase(
    user.id,
    reply['sync_id'] as String,
    SyncDoc.fromBackup(merged).toBackup(),
  );
}

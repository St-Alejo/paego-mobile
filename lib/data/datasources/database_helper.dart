import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Single SQLite source of truth for all offline-first data.
class DatabaseHelper {
  DatabaseHelper._();
  static final instance = DatabaseHelper._();
  static Database? _db;

  /// Archivo de la base. Cada archivo de pruebas usa el suyo: flutter test
  /// los corre en paralelo y compartirían el mismo `paego.db` en disco.
  @visibleForTesting
  static String nombreArchivo = 'paego.db';

  Future<Database> get database async {
    _db ??= await _initDB(nombreArchivo);
    return _db!;
  }

  /// Cierra la base (pruebas de migración: la siguiente lectura la reabre).
  @visibleForTesting
  Future<void> cerrar() async {
    await _db?.close();
    _db = null;
  }

  Future<Database> _initDB(String name) async {
    final path = kIsWeb ? name : join(await getDatabasesPath(), name);
    return openDatabase(
      path,
      version: 8,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createAppTextsTable(db);
    await _createSyncTables(db);
    await _createEstudiantesTables(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 3) {
      await _createAppTextsTable(db);
    }
    if (oldVersion < 4) {
      await _migrateAppTextsSyncColumns(db);
    }
    if (oldVersion < 5) {
      // La autenticación pasa a la API de oPAEGo: se elimina el admin local.
      await db.delete('users', where: 'LOWER(email) = ?', whereArgs: ['admin']);
      await _createSyncTables(db);
    }
    if (oldVersion < 6) {
      // Tablas del modo local previo a la API: ya no se usan.
      for (final tabla in _tablasObsoletas) {
        await db.execute('DROP TABLE IF EXISTS $tabla');
      }
      await _createAppTextsTable(db);
      await _createSyncTables(db);
    }
    if (oldVersion < 7) {
      await _createEstudiantesTables(db);
    }
    if (oldVersion < 8) {
      // La entrega del PAE pasa de reconocimiento facial a código QR: se
      // borran las plantillas faciales cifradas y las operaciones biométricas
      // que hayan quedado en la cola (el servidor ya no las acepta).
      await db.execute('DROP TABLE IF EXISTS plantillas_cache');
      await db.delete(
        'operaciones',
        where: 'tipo IN (?, ?, ?)',
        whereArgs: [
          'estudiante.autorizar',
          'estudiante.inscribir',
          'estudiante.revocar',
        ],
      );
    }
  }

  static const _tablasObsoletas = [
    'users',
    'school_locations',
    'delivery_orders',
    'delivery_reports',
    'tracking_points',
  ];

  Future<void> _createAppTextsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_texts (
        key         TEXT NOT NULL,
        locale      TEXT NOT NULL,
        value       TEXT NOT NULL,
        updated_at  TEXT,
        synced_at   TEXT,
        is_synced   INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (key, locale)
      )
    ''');
    await _migrateAppTextsSyncColumns(db);
  }

  Future<void> _migrateAppTextsSyncColumns(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(app_texts)');
    final names = columns.map((c) => c['name']).whereType<String>().toSet();

    if (!names.contains('synced_at')) {
      await db.execute('ALTER TABLE app_texts ADD COLUMN synced_at TEXT');
    }
    if (!names.contains('is_synced')) {
      await db.execute(
        'ALTER TABLE app_texts ADD COLUMN is_synced INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  /// Tablas de la integración con la API de oPAEGo (RF-38):
  /// - `envios_cache`: últimos envíos descargados, para trabajar sin conexión.
  /// - `operaciones`: cola de operaciones capturadas en el teléfono. Cada una
  ///   lleva un `uuid` (uuid_cliente) que hace idempotente su envío al servidor.
  Future<void> _createSyncTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS envios_cache (
        usuario_id     INTEGER NOT NULL,
        id             INTEGER NOT NULL,
        json           TEXT NOT NULL,
        actualizado_en TEXT NOT NULL,
        PRIMARY KEY (usuario_id, id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS operaciones (
        uuid         TEXT PRIMARY KEY,
        usuario_id   INTEGER NOT NULL,
        tipo         TEXT NOT NULL,
        envio_id     INTEGER,
        ocurrido_en  TEXT NOT NULL,
        datos        TEXT NOT NULL,
        resumen      TEXT NOT NULL DEFAULT '',
        estado       TEXT NOT NULL DEFAULT 'pendiente',
        respuesta    TEXT,
        intentos     INTEGER NOT NULL DEFAULT 0,
        creado_en    TEXT NOT NULL,
        enviado_en   TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS operaciones_usuario_estado '
      'ON operaciones (usuario_id, estado, ocurrido_en)',
    );
  }

  /// Supervisor PAE (sin conexión): `estudiantes_cache` con los estudiantes
  /// de su institución (identidad mínima + código QR); se borra al cerrar
  /// sesión.
  Future<void> _createEstudiantesTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS estudiantes_cache (
        usuario_id     INTEGER NOT NULL,
        id             INTEGER NOT NULL,
        json           TEXT NOT NULL,
        actualizado_en TEXT NOT NULL,
        PRIMARY KEY (usuario_id, id)
      )
    ''');
  }

  Future<Map<String, Map<String, String>>> getAppTexts() async {
    final db = await database;
    final rows = await db.query('app_texts');
    final texts = <String, Map<String, String>>{};
    for (final row in rows) {
      final key = row['key'] as String;
      final locale = row['locale'] as String;
      final value = row['value'] as String;
      texts.putIfAbsent(key, () => <String, String>{})[locale] = value;
    }
    return texts;
  }

  Future<List<Map<String, dynamic>>> getAppTextRows() async {
    final db = await database;
    final rows = await db.query('app_texts', orderBy: 'key ASC, locale ASC');
    return rows
        .map(
          (row) => {
            'key': row['key'] as String,
            'locale': row['locale'] as String,
            'value': row['value'] as String,
            'updated_at': row['updated_at'] as String?,
          },
        )
        .toList();
  }

  Future<void> upsertAppTextRows(
    List<Map<String, String>> rows, {
    bool markSynced = false,
  }) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().toIso8601String();

    for (final row in rows) {
      batch.insert('app_texts', {
        'key': row['key'],
        'locale': row['locale'],
        'value': row['value'],
        'updated_at': now,
        'synced_at': markSynced ? now : null,
        'is_synced': markSynced ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);
  }

  Future<void> markAllAppTextsSynced() async {
    final db = await database;
    await db.update('app_texts', {
      'synced_at': DateTime.now().toIso8601String(),
      'is_synced': 1,
    });
  }

  Future<void> upsertAppText({
    required String key,
    required String locale,
    required String value,
  }) async {
    final db = await database;
    await db.insert('app_texts', {
      'key': key,
      'locale': locale,
      'value': value,
      'updated_at': DateTime.now().toIso8601String(),
      'is_synced': 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}

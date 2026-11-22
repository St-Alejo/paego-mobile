import 'package:flutter_test/flutter_test.dart';
import 'package:opaego/data/datasources/database_helper.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Set<String>> tablas(Database db) async => (await db.rawQuery(
  "SELECT name FROM sqlite_master WHERE type = 'table'",
)).map((f) => f['name'] as String).toSet();

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    DatabaseHelper.nombreArchivo = 'prueba_migracion.db';
    databaseFactory = databaseFactoryFfi;
  });

  test('al actualizar desde la versión 5 borra las tablas del modo local '
      'y conserva los datos de la API', () async {
    final ruta = p.join(await getDatabasesPath(), DatabaseHelper.nombreArchivo);
    await databaseFactory.deleteDatabase(ruta);
    final vieja = await openDatabase(
      ruta,
      version: 5,
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY)');
        await db.execute(
          'CREATE TABLE delivery_orders (id INTEGER PRIMARY KEY)',
        );
        await db.execute(
          'CREATE TABLE envios_cache (usuario_id INTEGER NOT NULL, '
          'id INTEGER NOT NULL, json TEXT NOT NULL, '
          'actualizado_en TEXT NOT NULL, PRIMARY KEY (usuario_id, id))',
        );
        await db.insert('envios_cache', {
          'usuario_id': 7,
          'id': 119,
          'json': '{}',
          'actualizado_en': '2026-11-09T10:00:00',
        });
      },
    );
    await vieja.close();

    final db = await DatabaseHelper.instance.database;
    expect(await db.getVersion(), 8);
    final nombres = await tablas(db);
    expect(nombres, isNot(contains('users')));
    expect(nombres, isNot(contains('delivery_orders')));
    expect(
      nombres,
      containsAll([
        'operaciones',
        'envios_cache',
        'app_texts',
        // v7: supervisor PAE
        'estudiantes_cache',
      ]),
    );
    expect(nombres, isNot(contains('plantillas_cache')));
    // Los datos de la integración con la API no se pierden.
    expect(await db.query('envios_cache'), hasLength(1));
    await DatabaseHelper.instance.cerrar();
  });

  test('la versión 8 borra las plantillas faciales y las operaciones '
      'biométricas de la cola (el PAE se entrega con QR)', () async {
    final ruta = p.join(await getDatabasesPath(), DatabaseHelper.nombreArchivo);
    await databaseFactory.deleteDatabase(ruta);
    final vieja = await openDatabase(
      ruta,
      version: 7,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE app_texts (key TEXT NOT NULL, locale TEXT NOT NULL, '
          'value TEXT NOT NULL, updated_at TEXT, synced_at TEXT, '
          'is_synced INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (key, locale))',
        );
        await db.execute(
          'CREATE TABLE operaciones (uuid TEXT PRIMARY KEY, '
          'usuario_id INTEGER NOT NULL, tipo TEXT NOT NULL, envio_id INTEGER, '
          'ocurrido_en TEXT NOT NULL, datos TEXT NOT NULL, '
          "resumen TEXT NOT NULL DEFAULT '', "
          "estado TEXT NOT NULL DEFAULT 'pendiente', respuesta TEXT, "
          'intentos INTEGER NOT NULL DEFAULT 0, creado_en TEXT NOT NULL, '
          'enviado_en TEXT)',
        );
        await db.execute(
          'CREATE TABLE plantillas_cache (usuario_id INTEGER NOT NULL, '
          'curso TEXT NOT NULL, cifrado TEXT NOT NULL, '
          'actualizado_en TEXT NOT NULL, PRIMARY KEY (usuario_id, curso))',
        );
        for (final (uuid, tipo) in [
          ('a', 'estudiante.inscribir'),
          ('b', 'estudiante.entregar'),
          ('c', 'envio.salida'),
        ]) {
          await db.insert('operaciones', {
            'uuid': uuid,
            'usuario_id': 8,
            'tipo': tipo,
            'ocurrido_en': '2026-11-20T10:00:00Z',
            'datos': '{}',
            'creado_en': '2026-11-20T10:00:00Z',
          });
        }
      },
    );
    await vieja.close();

    final db = await DatabaseHelper.instance.database;
    expect(await db.getVersion(), 8);
    expect(await tablas(db), isNot(contains('plantillas_cache')));
    final tipos = (await db.query(
      'operaciones',
      orderBy: 'uuid',
    )).map((f) => f['tipo']);
    expect(tipos, ['estudiante.entregar', 'envio.salida']);
    await DatabaseHelper.instance.cerrar();
  });
}

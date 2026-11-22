import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opaego/data/datasources/database_helper.dart';
import 'package:opaego/data/models/estudiante.dart';
import 'package:opaego/data/models/user_role.dart';
import 'package:opaego/data/remote/api_client.dart';
import 'package:opaego/data/repositories/estudiantes_repository.dart';
import 'package:opaego/data/sync/sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

http.Response _json(Object cuerpo) => http.Response(
  jsonEncode(cuerpo),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Código QR de prueba del estudiante [id].
String codigoDe(int id) => 'cod-$id-AbC_x';

/// JSON de `GET /api/estudiantes/` (contrato con códigos QR).
Map<String, dynamic> estudianteJson(
  int id, {
  String grado = '7',
  String grupo = 'B',
  bool conQr = true,
  Map<String, dynamic>? entrega,
}) => {
  'id': id,
  'tipo_documento': 'TI',
  'numero_documento': '10$id',
  'nombres': 'Nombre$id',
  'apellidos': 'Apellido$id',
  'nombre_completo': 'Nombre$id Apellido$id',
  'grado': grado,
  'grado_etiqueta': '$grado°',
  'grupo': grupo,
  'curso': '$grado° $grupo',
  'jornada': 'MAÑANA',
  'codigo_qr': conQr ? codigoDe(id) : null,
  'entrega_del_dia': entrega,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('contenido del QR', () {
    test('solo acepta el prefijo PAEGO-E1 con un código', () {
      expect(codigoDeQr('PAEGO-E1:abc123'), 'abc123');
      expect(codigoDeQr('  PAEGO-E1:abc123\n'), 'abc123');
      expect(codigoDeQr('PAEGO-E1:'), isNull);
      expect(codigoDeQr('PAEGO-E2:abc'), isNull);
      expect(codigoDeQr('https://ejemplo.com'), isNull);
      expect(codigoDeQr(''), isNull);
      expect(codigoDeQr(null), isNull);
    });

    test('el estudiante arma el texto de su QR y lee el contrato', () {
      final e = Estudiante.fromJson(estudianteJson(3));
      expect(e.codigoQr, codigoDe(3));
      expect(e.contenidoQr, 'PAEGO-E1:${codigoDe(3)}');
      expect(codigoDeQr(e.contenidoQr), e.codigoQr);
      expect((e.jornada, e.gradoEtiqueta), ('MAÑANA', '7°'));
      // El rol institución puede no recibir el código.
      final sinQr = Estudiante.fromJson(estudianteJson(4, conQr: false));
      expect(sinQr.codigoQr, isNull);
      expect(sinQr.contenidoQr, isNull);
    });

    test('nombres legibles del método (incluye las entregas faciales '
        'anteriores)', () {
      expect(metodoEntregaLegible('QR'), 'Código QR');
      expect(metodoEntregaLegible('MANUAL'), 'Manual');
      expect(metodoEntregaLegible('FACIAL'), 'Reconocimiento facial');
      expect(
        metodoEntregaLegible('FACIAL', espanol: false),
        'Face recognition',
      );
    });
  });

  test('muestra la sigla del documento y la jornada legible del SIMAT', () {
    final e = Estudiante.fromJson({
      ...estudianteJson(1),
      'tipo_documento': '5',
      'tipo_documento_etiqueta': 'RC',
      'jornada': '6',
      'jornada_etiqueta': 'Única',
    });
    expect(e.documento, 'RC 101');
    expect(e.jornada, 'Única');
    // Sin etiquetas (servidor anterior) se usa el código tal cual.
    expect(Estudiante.fromJson(estudianteJson(2)).documento, 'TI 102');
  });

  test('rol SUPERVISOR del backend', () {
    final rol = UserRoleX.fromBackend('SUPERVISOR');
    expect(rol, UserRole.supervisor);
    expect(rol.canRegisterStudents, isTrue);
    expect(rol.canDriveRoute, isFalse);
    expect(UserRole.rector.canViewStudents, isTrue);
    expect(UserRole.driver.canViewStudents, isFalse);
  });

  group('repositorio', () {
    final repo = EstudiantesRepository.instance;
    late List<Map<String, dynamic>> enServidor;
    late List<Map<String, dynamic>> lotes;
    var hayRed = true;

    setUpAll(() async {
      sqfliteFfiInit();
      DatabaseHelper.nombreArchivo = 'prueba_estudiantes.db';
      databaseFactory = databaseFactoryFfi;
      await databaseFactory.deleteDatabase(
        p.join(await getDatabasesPath(), DatabaseHelper.nombreArchivo),
      );
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'paego_access': 'A',
        'paego_refresh': 'R',
      });
      final hoy = fechaDeHoy();
      enServidor = [
        estudianteJson(1),
        estudianteJson(2),
        estudianteJson(
          3,
          entrega: {
            'id': 9,
            'fecha': hoy,
            'metodo': 'QR',
            'ocurrido_en': DateTime.now().toUtc().toIso8601String(),
          },
        ),
        estudianteJson(4, grado: '11', grupo: 'A'),
      ];
      lotes = [];
      hayRed = true;
      ApiClient.usarCliente(
        MockClient((r) async {
          if (!hayRed) throw http.ClientException('sin red');
          switch (r.url.path) {
            case '/api/estudiantes/':
              return _json({'count': 4, 'next': null, 'results': enServidor});
            case '/api/sincronizacion/lote/':
              final cuerpo = jsonDecode(r.body) as Map<String, dynamic>;
              lotes.add(cuerpo);
              return _json({
                'resultados': [
                  for (final op in cuerpo['operaciones'] as List)
                    {
                      'uuid_cliente': op['uuid_cliente'],
                      'tipo': op['tipo'],
                      'resultado': 'ok',
                      'respuesta': {'id': 1},
                    },
                ],
              });
          }
          return http.Response('', 404);
        }),
      );
      await ApiClient.instance.cargarTokens();
      final db = await DatabaseHelper.instance.database;
      await db.delete('operaciones');
      await db.delete('estudiantes_cache');
      await SyncService.instance.iniciar(8);
      await repo.iniciar(8);
    });

    tearDown(() async {
      await repo.detener();
      await SyncService.instance.detener();
    });

    test('descarga la institución y arma el avance por curso', () async {
      await repo.descargar();
      final cursos = repo.cursos();
      expect(cursos.map((c) => c.curso), ['7° B', '11° A']);
      final septimo = cursos.first;
      expect((septimo.activos, septimo.recibieron), (3, 1));
      expect(septimo.avance, closeTo(1 / 3, 1e-9));
      expect(repo.delCurso('7', 'B').map((e) => e.id), [1, 2, 3]);
    });

    test('busca por código QR en la caché, sin red', () async {
      await repo.descargar();
      hayRed = false;
      // Al reabrir la app sin red, la lista sale de la caché.
      await repo.detener();
      await repo.iniciar(8);

      final ok = repo.porCodigoQr('PAEGO-E1:${codigoDe(2)}');
      expect(ok.estado, EstadoLecturaQr.listo);
      expect(ok.estudiante!.id, 2);
      expect(ok.codigo, codigoDe(2));

      expect(
        repo.porCodigoQr('PAEGO-E1:${codigoDe(3)}').estado,
        EstadoLecturaQr.yaRecibio,
      );
      expect(
        repo.porCodigoQr('PAEGO-E1:otro-colegio').estado,
        EstadoLecturaQr.noEncontrado,
      );
      expect(repo.porCodigoQr(codigoDe(2)).estado, EstadoLecturaQr.ajeno);
      expect(
        repo.porCodigoQr('https://paego.co').estado,
        EstadoLecturaQr.ajeno,
      );
    });

    test('sin red: la entrega por QR se encola y se ve al instante', () async {
      await repo.descargar();
      hayRed = false;
      final lectura = repo.porCodigoQr('PAEGO-E1:${codigoDe(2)}');
      await repo.entregar(
        lectura.estudiante!,
        metodo: 'QR',
        codigo: lectura.codigo,
      );
      final despues = repo.porId(2)!;
      expect(despues.recibioHoy, isTrue);
      expect(despues.entregaPendiente, isTrue);
      expect(despues.entregaMetodo, 'QR');
      expect(SyncService.instance.estado.value.pendientes, 1);
      // Volver a escanearlo hoy avisa que ya recibió.
      expect(
        repo.porCodigoQr('PAEGO-E1:${codigoDe(2)}').estado,
        EstadoLecturaQr.yaRecibio,
      );
      // Y una segunda entrega el mismo día se bloquea en el teléfono.
      expect(
        () => repo.entregar(despues, metodo: 'MANUAL', motivo: 'x'),
        throwsStateError,
      );

      // Vuelve la red: se envía con la fecha del día y el código leído.
      hayRed = true;
      await SyncService.instance.sincronizar();
      final op = (lotes.last['operaciones'] as List).single as Map;
      expect(op['tipo'], 'estudiante.entregar');
      expect(op['datos'], {
        'estudiante': 2,
        'metodo': 'QR',
        'fecha': fechaDeHoy(),
        'codigo': codigoDe(2),
      });
      final historial = await SyncService.instance.historial(
        prefijo: 'estudiante.',
      );
      expect(historial.single.resumen, contains('Entrega (QR)'));
    });

    test('la entrega manual exige motivo y lo envía', () async {
      await repo.descargar();
      final e = repo.porId(1)!;
      expect(
        () => repo.entregar(e, metodo: 'MANUAL', motivo: '  '),
        throwsArgumentError,
      );
      expect(() => repo.entregar(e, metodo: 'FACIAL'), throwsArgumentError);
      hayRed = false;
      await repo.entregar(e, metodo: 'MANUAL', motivo: ' No trajo el carné ');
      final op = (await SyncService.instance.pendientes()).single;
      expect(op.datos, {
        'estudiante': 1,
        'metodo': 'MANUAL',
        'fecha': fechaDeHoy(),
        'motivo': 'No trajo el carné',
      });
    });

    test('al cerrar sesión se borran los estudiantes', () async {
      await repo.descargar();
      await repo.borrarDatos();
      final db = await DatabaseHelper.instance.database;
      expect(await db.query('estudiantes_cache'), isEmpty);
      expect(repo.estudiantes.value, isEmpty);
    });

    test('la caché de ayer no cuenta como entrega de hoy', () async {
      final ayer = DateTime.now().subtract(const Duration(days: 1));
      enServidor = [
        estudianteJson(
          5,
          entrega: {
            'id': 1,
            'fecha': fechaDeHoy(ayer),
            'metodo': 'FACIAL',
            'ocurrido_en': ayer.toUtc().toIso8601String(),
          },
        ),
      ];
      await repo.descargar();
      final e = repo.porId(5)!;
      expect(e.recibioHoy, isFalse);
      expect(CursoResumen.de([e]).single.recibieron, 0);
      // Se le puede registrar la entrega de hoy por QR.
      final lectura = repo.porCodigoQr('PAEGO-E1:${codigoDe(5)}');
      expect(lectura.estado, EstadoLecturaQr.listo);
    });
  });
}

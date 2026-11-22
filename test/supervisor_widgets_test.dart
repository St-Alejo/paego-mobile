import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:opaego/core/l10n/app_strings.dart';
import 'package:opaego/data/datasources/database_helper.dart';
import 'package:opaego/data/models/estudiante.dart';
import 'package:opaego/data/remote/api_client.dart';
import 'package:opaego/data/repositories/estudiantes_repository.dart';
import 'package:opaego/data/sync/sync_service.dart';
import 'package:opaego/features/supervisor/curso_screen.dart';
import 'package:opaego/features/supervisor/cursos_screen.dart';
import 'package:opaego/features/supervisor/escaner_qr_screen.dart';
import 'package:opaego/features/supervisor/estudiante_screen.dart';
import 'package:opaego/features/supervisor/historial_screen.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'estudiantes_test.dart' show codigoDe, estudianteJson;

/// Lector falso: un botón por texto que "lee" la cámara.
ConstructorLector lectorFalso(List<String> textos) =>
    (context, alLeer) => ColoredBox(
      color: Colors.black,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final (i, t) in textos.indexed)
            TextButton(
              key: Key('leer_$i'),
              onPressed: () => alLeer(t),
              child: Text('leer $i'),
            ),
        ],
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final repo = EstudiantesRepository.instance;

  setUpAll(() async {
    S.guardarTextosNuevos = false;
    await initializeDateFormatting('es');
    sqfliteFfiInit();
    DatabaseHelper.nombreArchivo = 'prueba_supervisor_ui.db';
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
    ApiClient.usarCliente(
      MockClient((r) async {
        // Sin red: la app trabaja con lo guardado y encola.
        throw http.ClientException('sin red');
      }),
    );
    await ApiClient.instance.cargarTokens();
    final db = await DatabaseHelper.instance.database;
    await db.delete('operaciones');
    await db.delete('estudiantes_cache');
    final ahora = DateTime.now().toUtc().toIso8601String();
    for (final (id, grupo) in [(1, 'B'), (2, 'B'), (3, 'A')]) {
      await db.insert('estudiantes_cache', {
        'usuario_id': 8,
        'id': id,
        'json': jsonEncode(estudianteJson(id, grupo: grupo)),
        'actualizado_en': ahora,
      });
    }
    await SyncService.instance.iniciar(8);
    await repo.iniciar(8);
  });

  tearDown(() async {
    EscanerQrScreen.lectorDePrueba = null;
    await repo.detener();
    await SyncService.instance.detener();
  });

  Future<void> esperar(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  testWidgets('la ficha muestra el QR del estudiante', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(home: EstudianteScreen(estudianteId: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nombre1 Apellido1'), findsOneWidget);
      expect(find.text('TI 101'), findsOneWidget);
      expect(find.textContaining('7° B'), findsOneWidget);
      expect(find.textContaining('Mañana'), findsOneWidget);
      final qr = tester.widget<QrImageView>(
        find.byKey(const Key('qr_estudiante')),
      );
      expect(qr, isNotNull);
      expect(find.text('Pendiente'), findsOneWidget);
      expect(find.byKey(const Key('entrega_manual')), findsOneWidget);
      // El texto del QR es el que lee el escáner.
      expect(repo.porCodigoQr(repo.porId(1)!.contenidoQr).estudiante?.id, 1);
    });
  });

  testWidgets('entrega manual con motivo desde la ficha', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(home: EstudianteScreen(estudianteId: 2)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('entrega_manual')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('entrega_manual')));
      await tester.pumpAndSettle();
      final guardar = find.byKey(const Key('guardar_manual'));
      // Sin motivo no se puede registrar.
      expect(tester.widget<FilledButton>(guardar).onPressed, isNull);
      await tester.tap(find.text('No trajo el carné'));
      await tester.pump();
      await tester.tap(guardar);
      await esperar(tester);

      expect(find.textContaining('Recibió'), findsOneWidget);
      expect(find.textContaining('Manual'), findsOneWidget);
      expect(find.byKey(const Key('entrega_manual')), findsNothing);
      final op = (await SyncService.instance.pendientes()).single;
      expect(op.tipo, 'estudiante.entregar');
      expect(op.datos['metodo'], 'MANUAL');
      expect(op.datos['motivo'], 'No trajo el carné');
    });
  });

  testWidgets('escaneo: confirma, registra y sigue; avisa los QR inválidos '
      'y a quien ya recibió', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: EscanerQrScreen(
            grado: '7',
            grupo: 'B',
            lector: lectorFalso([
              'PAEGO-E1:${codigoDe(1)}',
              'https://no-es-paego.co',
              'PAEGO-E1:de-otra-institucion',
              'PAEGO-E1:${codigoDe(3)}',
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('0 de 2'), findsOneWidget);

      // QR válido → hoja de confirmación con nombre y curso.
      await tester.tap(find.byKey(const Key('leer_0')));
      await tester.pumpAndSettle();
      expect(find.text('Nombre1 Apellido1'), findsOneWidget);
      expect(find.textContaining('Curso 7° B · TI 101'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirmar_qr')));
      await esperar(tester);
      expect(find.textContaining('entrega registrada'), findsOneWidget);
      expect(find.text('Registradas en esta sesión: 1'), findsOneWidget);
      expect(find.textContaining('1 de 2'), findsOneWidget);
      final op = (await SyncService.instance.pendientes()).single;
      expect(op.datos['metodo'], 'QR');
      expect(op.datos['codigo'], codigoDe(1));

      // El mismo QR otra vez (pasado el antirrebote): ya recibió.
      await Future<void>.delayed(const Duration(seconds: 3));
      await tester.tap(find.byKey(const Key('leer_0')));
      await tester.pumpAndSettle();
      expect(find.textContaining('ya recibió el PAE hoy'), findsOneWidget);
      expect(find.byKey(const Key('confirmar_qr')), findsNothing);

      await tester.tap(find.byKey(const Key('leer_1')));
      await tester.pumpAndSettle();
      expect(find.text('Este QR no es de PAEGo.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('leer_2')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('no encontrado en tu institución'),
        findsOneWidget,
      );

      // De otro curso: se avisa, y cancelar no registra nada.
      await tester.tap(find.byKey(const Key('leer_3')));
      await tester.pumpAndSettle();
      expect(find.text('Es de otro curso.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cancelar_qr')));
      await esperar(tester);
      expect(await SyncService.instance.pendientes(), hasLength(1));
      expect(repo.porId(3)!.recibioHoy, isFalse);

      // Deja que venza el temporizador del aviso.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('del curso al escáner y a la ficha; el historial lo muestra', (
    tester,
  ) async {
    await tester.runAsync(() async {
      EscanerQrScreen.lectorDePrueba = lectorFalso(['PAEGO-E1:${codigoDe(2)}']);
      await tester.pumpWidget(
        const MaterialApp(
          home: CursoScreen(grado: '7', grupo: 'B'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Apellido1, Nombre1'), findsOneWidget);
      expect(find.text('Apellido3, Nombre3'), findsNothing); // otro curso
      expect(find.text('Pendiente'), findsNWidgets(2));

      await tester.enterText(find.byKey(const Key('buscar')), '102');
      await tester.pumpAndSettle();
      expect(find.text('Apellido1, Nombre1'), findsNothing);
      expect(find.text('Apellido2, Nombre2'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('buscar')), '');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('escanear')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('leer_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmar_qr')));
      await esperar(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.textContaining('Recibió'), findsOneWidget);
      await tester.tap(find.textContaining('Pendientes'));
      await tester.pumpAndSettle();
      expect(find.text('Apellido2, Nombre2'), findsNothing);
      await tester.tap(find.textContaining('Todos'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Apellido2, Nombre2'));
      await tester.pumpAndSettle();
      expect(find.byType(EstudianteScreen), findsOneWidget);
      expect(find.textContaining('Código QR'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        const MaterialApp(home: HistorialSupervisorScreen()),
      );
      await esperar(tester);
      expect(find.textContaining('Entrega (QR)'), findsOneWidget);
    });
  });

  testWidgets('cursos: resumen del día sin red', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(home: SupervisorCursosScreen()),
      );
      await esperar(tester);
      expect(find.textContaining('Sin conexión'), findsOneWidget);
      expect(find.text('0 de 3'), findsOneWidget);
      expect(find.text('Curso 7° A'), findsOneWidget);
      expect(find.text('Curso 7° B'), findsOneWidget);
      expect(find.byKey(const Key('escanear_todos')), findsOneWidget);
      expect(repo.estudiantes.value.map((Estudiante e) => e.id), hasLength(3));
    });
  });
}

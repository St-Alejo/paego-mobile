import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../datasources/database_helper.dart';
import '../models/estudiante.dart';
import '../remote/api_client.dart';
import '../sync/sync_service.dart';

/// Qué pasó al leer un QR con la cámara.
enum EstadoLecturaQr {
  /// El texto no es un QR de estudiante de PAEGo.
  ajeno,

  /// Es de PAEGo, pero el estudiante no está en la institución descargada.
  noEncontrado,

  /// El estudiante ya recibió el PAE hoy.
  yaRecibio,

  /// Se puede registrar la entrega.
  listo,
}

/// Resultado de [EstudiantesRepository.porCodigoQr].
class LecturaQr {
  const LecturaQr(this.estado, {this.estudiante, this.codigo});

  final EstadoLecturaQr estado;
  final Estudiante? estudiante;

  /// Código leído (sin el prefijo `PAEGO-E1:`).
  final String? codigo;
}

/// Estudiantes de la institución del supervisor PAE, con caché para trabajar
/// sin conexión (igual que [EnvioRepository] con los envíos).
///
/// La entrega diaria (`estudiante.entregar`, por QR o manual con motivo) se
/// encola en [SyncService] y se refleja al instante en la lista; el servidor
/// aplica las mismas reglas al sincronizar (una entrega por día, el código QR
/// debe ser el del estudiante).
class EstudiantesRepository {
  EstudiantesRepository._();
  static final instance = EstudiantesRepository._();

  final estudiantes = ValueNotifier<List<Estudiante>>(const []);

  /// Hora de la última descarga completa (null: nunca o solo caché).
  DateTime? descargadoEn;

  int? _usuarioId;
  StreamSubscription<List<Operacion>>? _sub;

  Future<Database> get _db => DatabaseHelper.instance.database;

  Future<void> iniciar(int usuarioId) async {
    await _sub?.cancel();
    _usuarioId = usuarioId;
    estudiantes.value = await _desdeCache();
    _sub = SyncService.instance.onAplicadas.listen((ops) {
      if (ops.any((o) => o.tipo.startsWith('estudiante.'))) {
        descargar().then((_) {}, onError: (_) {});
      }
    });
  }

  Future<void> detener() async {
    await _sub?.cancel();
    _sub = null;
    _usuarioId = null;
    estudiantes.value = const [];
    descargadoEn = null;
  }

  /// Borra del teléfono los datos de los estudiantes (al cerrar sesión). La
  /// cola de operaciones pendientes se conserva.
  Future<void> borrarDatos() async {
    final db = await _db;
    await db.delete('estudiantes_cache');
    estudiantes.value = const [];
  }

  // ── Lectura ───────────────────────────────────────────────────────────────

  /// Descarga la institución completa (con el estado de hoy).
  /// Lanza [SinConexionException]/[ApiException]; la caché queda intacta.
  Future<List<Estudiante>> descargar() async {
    final usuarioId = _usuarioId;
    if (usuarioId == null) return const [];
    final lista = await ApiClient.instance.getTodos(
      '/estudiantes/',
      query: {'page_size': '500'},
      maxPaginas: 20,
    );
    final db = await _db;
    final ahora = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      await txn.delete(
        'estudiantes_cache',
        where: 'usuario_id = ?',
        whereArgs: [usuarioId],
      );
      final batch = txn.batch();
      for (final j in lista) {
        batch.insert('estudiantes_cache', {
          'usuario_id': usuarioId,
          'id': j['id'],
          'json': jsonEncode(j),
          'actualizado_en': ahora,
        });
      }
      await batch.commit(noResult: true);
    });
    descargadoEn = DateTime.now();
    final resultado = await _aplicarPendientes(
      lista.map(Estudiante.fromJson).toList(),
    );
    estudiantes.value = resultado;
    return resultado;
  }

  List<CursoResumen> cursos() => CursoResumen.de(estudiantes.value);

  List<Estudiante> delCurso(String grado, String grupo) {
    final lista = estudiantes.value
        .where((e) => e.grado == grado && e.grupo == grupo)
        .toList();
    lista.sort((a, b) {
      final c = a.apellidos.compareTo(b.apellidos);
      return c != 0 ? c : a.nombres.compareTo(b.nombres);
    });
    return lista;
  }

  Estudiante? porId(int id) {
    for (final e in estudiantes.value) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Interpreta el texto leído de un QR y busca al estudiante en la caché
  /// (funciona sin red). No registra nada.
  LecturaQr porCodigoQr(String? texto) {
    final codigo = codigoDeQr(texto);
    if (codigo == null) return const LecturaQr(EstadoLecturaQr.ajeno);
    for (final e in estudiantes.value) {
      if (e.codigoQr == codigo) {
        return LecturaQr(
          e.recibioHoy ? EstadoLecturaQr.yaRecibio : EstadoLecturaQr.listo,
          estudiante: e,
          codigo: codigo,
        );
      }
    }
    return LecturaQr(EstadoLecturaQr.noEncontrado, codigo: codigo);
  }

  // ── Acciones (cola sin conexión) ──────────────────────────────────────────

  /// Registra la entrega de hoy. [metodo] `QR` (con el [codigo] leído; por
  /// defecto el del estudiante) o `MANUAL` (con [motivo] obligatorio).
  Future<void> entregar(
    Estudiante e, {
    required String metodo,
    String? codigo,
    String motivo = '',
  }) {
    if (e.recibioHoy) {
      throw StateError('${e.nombreCompleto} ya recibió el PAE hoy.');
    }
    final datos = <String, dynamic>{'metodo': metodo, 'fecha': fechaDeHoy()};
    switch (metodo) {
      case 'QR':
        final c = codigo ?? e.codigoQr;
        if (c == null || c.isEmpty) {
          throw ArgumentError('La entrega por QR necesita el código leído.');
        }
        datos['codigo'] = c;
      case 'MANUAL':
        if (motivo.trim().isEmpty) {
          throw ArgumentError('La entrega manual necesita un motivo.');
        }
        datos['motivo'] = motivo.trim();
      default:
        throw ArgumentError.value(metodo, 'metodo', 'QR o MANUAL');
    }
    return _encolar(
      'estudiante.entregar',
      e,
      datos,
      '${metodo == 'QR' ? 'Entrega (QR)' : 'Entrega (manual)'} · '
          '${e.nombreCompleto} · ${e.curso}',
    );
  }

  Future<void> _encolar(
    String tipo,
    Estudiante e,
    Map<String, dynamic> datos,
    String resumen,
  ) async {
    await SyncService.instance.encolar(
      tipo: tipo,
      datos: {'estudiante': e.id, ...datos},
      resumen: resumen,
    );
    estudiantes.value = await _aplicarPendientes(
      await _desdeCacheSinPendientes(),
    );
  }

  // ── Caché + pendientes ────────────────────────────────────────────────────

  Future<List<Estudiante>> _desdeCache() async =>
      _aplicarPendientes(await _desdeCacheSinPendientes());

  Future<List<Estudiante>> _desdeCacheSinPendientes() async {
    final usuarioId = _usuarioId;
    if (usuarioId == null) return const [];
    final db = await _db;
    final filas = await db.query(
      'estudiantes_cache',
      where: 'usuario_id = ?',
      whereArgs: [usuarioId],
    );
    return [
      for (final f in filas)
        Estudiante.fromJson(
          (jsonDecode(f['json'] as String) as Map).cast<String, dynamic>(),
        ),
    ];
  }

  /// Refleja en la lista las entregas que aún no llegan al servidor.
  Future<List<Estudiante>> _aplicarPendientes(List<Estudiante> lista) async {
    final pendientes = await SyncService.instance.pendientes();
    final hoy = fechaDeHoy();
    final entregas = pendientes.where(
      (o) => o.tipo == 'estudiante.entregar' && o.datos['fecha'] == hoy,
    );
    if (entregas.isEmpty) return lista;
    final porId = {for (final e in lista) e.id: e};
    for (final op in entregas) {
      final id = op.datos['estudiante'];
      final e = porId[id];
      if (e == null) continue;
      porId[id as int] = e.copyWith(
        entregaFecha: hoy,
        entregaMetodo: op.datos['metodo'] as String?,
        entregaHora: op.ocurridoEn,
        entregaPendiente: true,
      );
    }
    return lista.map((e) => porId[e.id]!).toList();
  }
}

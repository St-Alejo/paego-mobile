import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../datasources/database_helper.dart';
import '../remote/api_client.dart';

/// Genera un UUID v4 (el `uuid_cliente` de cada operación, RF-38).
String nuevoUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Una operación capturada en el teléfono (tabla `operaciones`).
class Operacion {
  Operacion.fromMap(Map<String, dynamic> m)
    : uuid = m['uuid'] as String,
      tipo = m['tipo'] as String,
      envioId = m['envio_id'] as int?,
      ocurridoEn = DateTime.parse(m['ocurrido_en'] as String).toLocal(),
      datos = (jsonDecode(m['datos'] as String) as Map).cast<String, dynamic>(),
      resumen = m['resumen'] as String? ?? '',
      estado = m['estado'] as String,
      respuesta = m['respuesta'] == null
          ? null
          : jsonDecode(m['respuesta'] as String),
      intentos = m['intentos'] as int? ?? 0;

  final String uuid;
  final String tipo;
  final int? envioId;
  final DateTime ocurridoEn;
  final Map<String, dynamic> datos;
  final String resumen;

  /// pendiente | ok | rechazado
  final String estado;
  final dynamic respuesta;
  final int intentos;

  bool get pendiente => estado == 'pendiente';
  bool get rechazada => estado == 'rechazado';

  String get motivoRechazo => ApiClient.mensajeDeError(respuesta);
}

@immutable
class EstadoSync {
  const EstadoSync({
    this.pendientes = 0,
    this.rechazadas = 0,
    this.enLinea = true,
    this.sincronizando = false,
    this.sesionVencida = false,
    this.ultimaSincronizacion,
    this.ultimoError,
  });

  final int pendientes;
  final int rechazadas;
  final bool enLinea;
  final bool sincronizando;
  final bool sesionVencida;
  final DateTime? ultimaSincronizacion;
  final String? ultimoError;

  EstadoSync copyWith({
    int? pendientes,
    int? rechazadas,
    bool? enLinea,
    bool? sincronizando,
    bool? sesionVencida,
    DateTime? ultimaSincronizacion,
    String? ultimoError,
    bool limpiarError = false,
  }) => EstadoSync(
    pendientes: pendientes ?? this.pendientes,
    rechazadas: rechazadas ?? this.rechazadas,
    enLinea: enLinea ?? this.enLinea,
    sincronizando: sincronizando ?? this.sincronizando,
    sesionVencida: sesionVencida ?? this.sesionVencida,
    ultimaSincronizacion: ultimaSincronizacion ?? this.ultimaSincronizacion,
    ultimoError: limpiarError ? null : (ultimoError ?? this.ultimoError),
  );
}

/// Cola de operaciones sin conexión (RF-38 / RNF-21).
///
/// Todo lo que el usuario registra en la app (salida, ubicaciones, llegada,
/// novedades, confirmación de recepción) se guarda primero aquí y luego se
/// envía a `POST /api/sincronizacion/lote/`. El servidor aplica las
/// operaciones en orden cronológico (`ocurrido_en`) con las mismas reglas que
/// en línea y es idempotente por `uuid_cliente`, así que reintentar es seguro.
class SyncService {
  SyncService._();
  static final instance = SyncService._();

  static const _maxPorLote = 200;
  static const _maxBytesPorLote = 4 * 1024 * 1024; // fotos en base64
  static const _intervaloReintento = Duration(seconds: 30);

  final estado = ValueNotifier<EstadoSync>(const EstadoSync());

  /// Avisa cuando el servidor aplicó operaciones (para recargar los envíos).
  final _aplicadas = StreamController<List<Operacion>>.broadcast();
  Stream<List<Operacion>> get onAplicadas => _aplicadas.stream;

  int? _usuarioId;
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _conectividad;
  StreamSubscription<void>? _vencida;
  Future<void>? _enCurso;
  bool _repetir = false;

  Future<Database> get _db => DatabaseHelper.instance.database;

  Future<void> iniciar(int usuarioId) async {
    await detener();
    _usuarioId = usuarioId;
    estado.value = const EstadoSync();
    _vencida = ApiClient.instance.onSesionVencida.listen((_) {
      estado.value = estado.value.copyWith(sesionVencida: true);
    });
    try {
      _conectividad = Connectivity().onConnectivityChanged.listen((r) {
        final hayRed = r.any((c) => c != ConnectivityResult.none);
        if (hayRed) unawaited(sincronizar());
      });
    } catch (_) {
      // Plataforma sin plugin de conectividad: queda el reintento periódico.
    }
    _timer = Timer.periodic(
      _intervaloReintento,
      (_) => unawaited(sincronizar()),
    );
    await _actualizarConteos();
    unawaited(sincronizar());
  }

  Future<void> detener() async {
    _timer?.cancel();
    _timer = null;
    await _conectividad?.cancel();
    _conectividad = null;
    await _vencida?.cancel();
    _vencida = null;
    _usuarioId = null;
  }

  /// Guarda la operación y trata de enviarla de inmediato.
  Future<String> encolar({
    required String tipo,
    required Map<String, dynamic> datos,
    int? envioId,
    String resumen = '',
    DateTime? ocurridoEn,
  }) async {
    final usuarioId = _usuarioId;
    if (usuarioId == null) throw StateError('No hay una sesión iniciada.');
    final uuid = nuevoUuid();
    final ahora = DateTime.now();
    final db = await _db;
    await db.insert('operaciones', {
      'uuid': uuid,
      'usuario_id': usuarioId,
      'tipo': tipo,
      'envio_id': envioId,
      'ocurrido_en': (ocurridoEn ?? ahora).toUtc().toIso8601String(),
      'datos': jsonEncode(datos),
      'resumen': resumen,
      'estado': 'pendiente',
      'creado_en': ahora.toUtc().toIso8601String(),
    });
    await _actualizarConteos();
    unawaited(sincronizar());
    return uuid;
  }

  /// Operaciones pendientes del usuario (para aplicarlas sobre la caché).
  Future<List<Operacion>> pendientes() async {
    final usuarioId = _usuarioId;
    if (usuarioId == null) return const [];
    final db = await _db;
    final filas = await db.query(
      'operaciones',
      where: 'usuario_id = ? AND estado = ?',
      whereArgs: [usuarioId, 'pendiente'],
      orderBy: 'ocurrido_en ASC',
    );
    return filas.map(Operacion.fromMap).toList();
  }

  /// Historial de operaciones del usuario (sin los puntos de ubicación).
  /// Con [prefijo] solo las de ese tipo (p. ej. `estudiante.`).
  Future<List<Operacion>> historial({int limite = 100, String? prefijo}) async {
    final usuarioId = _usuarioId;
    if (usuarioId == null) return const [];
    final db = await _db;
    final filas = await db.query(
      'operaciones',
      where: prefijo == null
          ? 'usuario_id = ? AND tipo != ?'
          : 'usuario_id = ? AND tipo LIKE ?',
      whereArgs: [usuarioId, prefijo == null ? 'envio.ubicacion' : '$prefijo%'],
      orderBy: 'ocurrido_en DESC',
      limit: limite,
    );
    return filas.map(Operacion.fromMap).toList();
  }

  /// Descarta una operación rechazada (ya no se puede aplicar).
  Future<void> descartar(String uuid) async {
    final db = await _db;
    await db.delete(
      'operaciones',
      where: 'uuid = ? AND estado = ?',
      whereArgs: [uuid, 'rechazado'],
    );
    await _actualizarConteos();
  }

  /// Envía las operaciones pendientes. Si ya hay un envío en curso, se
  /// comparte y se hace una pasada más al terminar (pudo llegar algo nuevo).
  Future<void> sincronizar() {
    final enCurso = _enCurso;
    if (enCurso != null) {
      _repetir = true;
      return enCurso;
    }
    return _enCurso = _ciclo().whenComplete(() => _enCurso = null);
  }

  Future<void> _ciclo() async {
    do {
      _repetir = false;
      await _sincronizar();
    } while (_repetir &&
        _usuarioId != null &&
        estado.value.enLinea &&
        !estado.value.sesionVencida);
  }

  Future<void> _sincronizar() async {
    final usuarioId = _usuarioId;
    if (usuarioId == null) return;
    estado.value = estado.value.copyWith(sincronizando: true);
    try {
      while (true) {
        final lote = await _siguienteLote(usuarioId);
        if (lote.isEmpty) break;
        final respuesta = await ApiClient.instance.post(
          '/sincronizacion/lote/',
          cuerpo: {
            'operaciones': [
              for (final op in lote)
                {
                  'uuid_cliente': op.uuid,
                  'tipo': op.tipo,
                  'ocurrido_en': op.ocurridoEn.toUtc().toIso8601String(),
                  'datos': op.datos,
                },
            ],
          },
        );
        final aplicadas = await _guardarResultados(lote, respuesta);
        if (aplicadas.isNotEmpty) _aplicadas.add(aplicadas);
        if (lote.length < _maxPorLote) break;
      }
      await _limpiarUbicacionesViejas(usuarioId);
      estado.value = estado.value.copyWith(
        enLinea: true,
        sesionVencida: false,
        ultimaSincronizacion: DateTime.now(),
        limpiarError: true,
      );
    } on SinConexionException {
      estado.value = estado.value.copyWith(enLinea: false);
    } on SesionVencidaException {
      estado.value = estado.value.copyWith(sesionVencida: true, enLinea: true);
    } on ApiException catch (e) {
      estado.value = estado.value.copyWith(
        enLinea: true,
        ultimoError: e.mensaje,
      );
    } catch (e) {
      estado.value = estado.value.copyWith(ultimoError: e.toString());
    } finally {
      estado.value = estado.value.copyWith(sincronizando: false);
      await _actualizarConteos();
    }
  }

  Future<List<Operacion>> _siguienteLote(int usuarioId) async {
    final db = await _db;
    final filas = await db.query(
      'operaciones',
      where: 'usuario_id = ? AND estado = ?',
      whereArgs: [usuarioId, 'pendiente'],
      orderBy: 'ocurrido_en ASC',
      limit: _maxPorLote,
    );
    final lote = <Operacion>[];
    var bytes = 0;
    for (final f in filas) {
      bytes += (f['datos'] as String).length;
      if (lote.isNotEmpty && bytes > _maxBytesPorLote) break;
      lote.add(Operacion.fromMap(f));
    }
    return lote;
  }

  Future<List<Operacion>> _guardarResultados(
    List<Operacion> lote,
    dynamic respuesta,
  ) async {
    final resultados = ((respuesta as Map)['resultados'] as List).cast<Map>();
    final porUuid = {
      for (final r in resultados) r['uuid_cliente'].toString(): r,
    };
    final db = await _db;
    final ahora = DateTime.now().toUtc().toIso8601String();
    final aplicadas = <Operacion>[];
    final batch = db.batch();
    for (final op in lote) {
      final r = porUuid[op.uuid];
      if (r == null) continue;
      final rechazada = r['resultado'] == 'rechazado';
      batch.update(
        'operaciones',
        {
          'estado': rechazada ? 'rechazado' : 'ok',
          'respuesta': jsonEncode(r['respuesta']),
          'intentos': op.intentos + 1,
          'enviado_en': ahora,
          // La foto ya está en el servidor: no se guarda dos veces en el teléfono.
          if (!rechazada) 'datos': jsonEncode(_sinFotos(op.datos)),
        },
        where: 'uuid = ?',
        whereArgs: [op.uuid],
      );
      if (!rechazada) aplicadas.add(op);
    }
    await batch.commit(noResult: true);
    return aplicadas;
  }

  static Map<String, dynamic> _sinFotos(Map<String, dynamic> datos) {
    final copia = Map<String, dynamic>.from(datos);
    if (copia['foto'] != null) copia['foto'] = '(enviada)';
    final novedad = copia['novedad'];
    if (novedad is Map && novedad['foto'] != null) {
      copia['novedad'] = {...novedad, 'foto': '(enviada)'};
    }
    return copia;
  }

  Future<void> _limpiarUbicacionesViejas(int usuarioId) async {
    final db = await _db;
    final limite = DateTime.now()
        .subtract(const Duration(days: 2))
        .toUtc()
        .toIso8601String();
    await db.delete(
      'operaciones',
      where: 'usuario_id = ? AND tipo = ? AND estado = ? AND ocurrido_en < ?',
      whereArgs: [usuarioId, 'envio.ubicacion', 'ok', limite],
    );
  }

  Future<void> _actualizarConteos() async {
    final usuarioId = _usuarioId;
    if (usuarioId == null) return;
    final db = await _db;
    final filas = await db.rawQuery(
      'SELECT estado, COUNT(*) AS c FROM operaciones WHERE usuario_id = ? '
      'AND estado IN (?, ?) GROUP BY estado',
      [usuarioId, 'pendiente', 'rechazado'],
    );
    var pendientes = 0;
    var rechazadas = 0;
    for (final f in filas) {
      if (f['estado'] == 'pendiente') pendientes = f['c'] as int;
      if (f['estado'] == 'rechazado') rechazadas = f['c'] as int;
    }
    estado.value = estado.value.copyWith(
      pendientes: pendientes,
      rechazadas: rechazadas,
    );
  }
}

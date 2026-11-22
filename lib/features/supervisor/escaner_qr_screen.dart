import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/theme.dart';
import '../../core/l10n/app_strings.dart';
import '../../data/models/estudiante.dart';
import '../../data/repositories/estudiantes_repository.dart';
import 'supervisor_comun.dart';

/// Construye el lector de QR; llama a `alLeer` con cada texto leído.
typedef ConstructorLector =
    Widget Function(BuildContext context, ValueChanged<String> alLeer);

/// Lector continuo de los QR de los estudiantes: cada lectura válida abre una
/// confirmación (nombre y curso); al confirmar se registra la entrega (en la
/// cola sin conexión) y el lector sigue con el siguiente estudiante.
class EscanerQrScreen extends StatefulWidget {
  const EscanerQrScreen({super.key, this.grado, this.grupo, this.lector});

  /// Curso desde el que se abrió (solo para mostrar su avance).
  final String? grado;
  final String? grupo;

  /// Lector a usar; por defecto la cámara ([MobileScanner]).
  final ConstructorLector? lector;

  /// Lector que usan las pruebas cuando la pantalla se abre desde otra.
  @visibleForTesting
  static ConstructorLector? lectorDePrueba;

  @override
  State<EscanerQrScreen> createState() => _EscanerQrScreenState();
}

enum _Tono { ok, aviso, error }

class _EscanerQrScreenState extends State<EscanerQrScreen> {
  bool _ocupado = false;
  String? _ultimo;
  DateTime _ultimoEn = DateTime.fromMillisecondsSinceEpoch(0);
  (String, _Tono)? _mensaje;
  Timer? _ocultar;
  int _registrados = 0;

  @override
  void dispose() {
    _ocultar?.cancel();
    super.dispose();
  }

  void _mostrar(String texto, _Tono tono) {
    _ocultar?.cancel();
    setState(() => _mensaje = (texto, tono));
    _ocultar = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _mensaje = null);
    });
  }

  Future<void> _alLeer(String texto) async {
    if (_ocupado || !mounted) return;
    // La cámara lee el mismo QR varias veces por segundo.
    final ahora = DateTime.now();
    if (texto == _ultimo && ahora.difference(_ultimoEn).inSeconds < 3) return;
    _ultimo = texto;
    _ultimoEn = ahora;

    final lectura = repoEstudiantes.porCodigoQr(texto);
    switch (lectura.estado) {
      case EstadoLecturaQr.ajeno:
        unawaited(HapticFeedback.heavyImpact());
        _mostrar(
          S.text(
            'qr.ajeno',
            'Este QR no es de PAEGo.',
            'This QR is not a PAEGo code.',
          ),
          _Tono.error,
        );
      case EstadoLecturaQr.noEncontrado:
        unawaited(HapticFeedback.heavyImpact());
        _mostrar(
          S.text(
            'qr.no_encontrado',
            'Estudiante no encontrado en tu institución. Si es nuevo, '
                'actualiza la lista con conexión.',
            'Student not found in your school. If new, refresh the list '
                'online.',
          ),
          _Tono.error,
        );
      case EstadoLecturaQr.yaRecibio:
        final e = lectura.estudiante!;
        unawaited(HapticFeedback.heavyImpact());
        _mostrar(
          '${e.nombreCompleto} '
          '${S.text('qr.ya_recibio', 'ya recibió el PAE hoy', 'already received today')}'
          '${e.entregaHora == null ? '' : ' (${horaCorta(e.entregaHora)})'}.',
          _Tono.aviso,
        );
      case EstadoLecturaQr.listo:
        await _confirmar(lectura);
    }
  }

  Future<void> _confirmar(LecturaQr lectura) async {
    final e = lectura.estudiante!;
    setState(() {
      _ocupado = true;
      _mensaje = null;
    });
    unawaited(HapticFeedback.mediumImpact());
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: true,
      showDragHandle: true,
      builder: (_) => _HojaConfirmacion(
        estudiante: e,
        otroCurso:
            widget.grado != null &&
            (e.grado != widget.grado || e.grupo != widget.grupo),
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      try {
        await repoEstudiantes.entregar(e, metodo: 'QR', codigo: lectura.codigo);
        unawaited(HapticFeedback.lightImpact());
        _registrados++;
        if (mounted) {
          _mostrar(
            '✓ ${e.nombreCompleto} · '
            '${S.text('sup.registrada', 'entrega registrada', 'delivery recorded')}',
            _Tono.ok,
          );
        }
      } on StateError catch (err) {
        if (mounted) _mostrar(err.message, _Tono.aviso);
      }
    }
    if (mounted) setState(() => _ocupado = false);
  }

  @override
  Widget build(BuildContext context) {
    final lector =
        widget.lector ??
        EscanerQrScreen.lectorDePrueba ??
        (context, alLeer) => _LectorCamara(alLeer: alLeer);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.35),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(S.text('sup.escanear', 'Escanear QR', 'Scan QR')),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          lector(context, _alLeer),
          const IgnorePointer(child: _Marco()),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 8),
                _Avance(grado: widget.grado, grupo: widget.grupo),
                const Spacer(),
                if (_mensaje != null)
                  _Banner(texto: _mensaje!.$1, tono: _mensaje!.$2)
                else
                  _Banner(
                    texto: S.text(
                      'qr.apunte',
                      'Apunte la cámara al QR del carné del estudiante.',
                      'Point the camera at the student\'s ID card QR.',
                    ),
                    tono: null,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Text(
                    '${S.text('qr.sesion', 'Registradas en esta sesión', 'Recorded this session')}: '
                    '$_registrados',
                    key: const Key('registrados'),
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Avance del curso (o de la institución) mientras se escanea.
class _Avance extends StatelessWidget {
  const _Avance({this.grado, this.grupo});

  final String? grado;
  final String? grupo;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Estudiante>>(
      valueListenable: repoEstudiantes.estudiantes,
      builder: (context, todos, _) {
        final lista = grado == null
            ? todos
            : repoEstudiantes.delCurso(grado!, grupo!);
        if (lista.isEmpty) return const SizedBox.shrink();
        final recibieron = lista.where((e) => e.recibioHoy).length;
        final etiqueta = grado == null
            ? S.text('qr.institucion', 'Institución', 'School')
            : '${S.text('sup.curso', 'Curso', 'Class')} ${lista.first.curso}';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$etiqueta · $recibieron ${S.text('sup.de', 'de', 'of')} '
            '${lista.length}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.texto, required this.tono});

  final String texto;
  final _Tono? tono;

  @override
  Widget build(BuildContext context) {
    final (color, icono) = switch (tono) {
      _Tono.ok => (PaeColors.statusDelivered, Icons.check_circle_rounded),
      _Tono.aviso => (PaeColors.warning, Icons.info_rounded),
      _Tono.error => (PaeColors.error, Icons.error_rounded),
      null => (Colors.black.withValues(alpha: 0.6), Icons.qr_code_2_rounded),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Container(
        key: ValueKey(texto),
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icono, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                texto,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Recuadro guía en el centro de la cámara.
class _Marco extends StatelessWidget {
  const _Marco();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: LayoutBuilder(
        builder: (context, c) {
          final lado = (c.biggest.shortestSide * 0.65).clamp(160.0, 300.0);
          return Container(
            width: lado,
            height: lado,
            decoration: BoxDecoration(
              border: Border.all(color: PaeColors.accent, width: 3),
              borderRadius: BorderRadius.circular(24),
            ),
          );
        },
      ),
    );
  }
}

class _HojaConfirmacion extends StatelessWidget {
  const _HojaConfirmacion({required this.estudiante, required this.otroCurso});

  final Estudiante estudiante;
  final bool otroCurso;

  @override
  Widget build(BuildContext context) {
    final e = estudiante;
    final tema = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.verified_user_rounded,
              size: 40,
              color: PaeColors.primary,
            ),
            const SizedBox(height: 8),
            Text(
              e.nombreCompleto,
              textAlign: TextAlign.center,
              style: tema.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              '${S.text('sup.curso', 'Curso', 'Class')} ${e.curso} · '
              '${e.documento}',
              textAlign: TextAlign.center,
              style: tema.bodyMedium?.copyWith(color: PaeColors.textSecondary),
            ),
            if (otroCurso) ...[
              const SizedBox(height: 8),
              Text(
                S.text(
                  'qr.otro_curso',
                  'Es de otro curso.',
                  'From another class.',
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(color: PaeColors.warning),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('confirmar_qr'),
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.check_rounded),
              label: Text(
                S.text('sup.confirmar', 'Registrar entrega', 'Record delivery'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('cancelar_qr'),
              onPressed: () => Navigator.pop(context, false),
              child: Text(S.text('comun.cancelar', 'Cancelar', 'Cancel')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lector real con la cámara trasera (solo QR).
class _LectorCamara extends StatefulWidget {
  const _LectorCamara({required this.alLeer});

  final ValueChanged<String> alLeer;

  @override
  State<_LectorCamara> createState() => _LectorCamaraState();
}

class _LectorCamaraState extends State<_LectorCamara> {
  final _controlador = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  @override
  void dispose() {
    _controlador.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controlador,
          onDetect: (captura) {
            for (final b in captura.barcodes) {
              final texto = b.rawValue;
              if (texto != null && texto.isNotEmpty) {
                widget.alLeer(texto);
                return;
              }
            }
          },
          errorBuilder: (context, error) => _ErrorCamara(error: error),
        ),
        Positioned(
          right: 12,
          bottom: 140,
          child: ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controlador,
            builder: (context, estado, _) {
              if (estado.torchState == TorchState.unavailable) {
                return const SizedBox.shrink();
              }
              return IconButton.filled(
                tooltip: S.text('qr.linterna', 'Linterna', 'Torch'),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.55),
                ),
                onPressed: _controlador.toggleTorch,
                icon: Icon(
                  estado.torchState == TorchState.on
                      ? Icons.flashlight_off_rounded
                      : Icons.flashlight_on_rounded,
                  color: Colors.white,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ErrorCamara extends StatelessWidget {
  const _ErrorCamara({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final sinPermiso =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.no_photography_rounded,
                color: Colors.white70,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                sinPermiso
                    ? S.text(
                        'qr.sin_permiso',
                        'Sin permiso para usar la cámara. Actívelo en los '
                            'ajustes del teléfono, o registre la entrega '
                            'manual desde la ficha del estudiante.',
                        'No camera permission. Enable it in settings, or '
                            'record a manual delivery from the student page.',
                      )
                    : S.text(
                        'qr.sin_camara',
                        'No se pudo abrir la cámara. Registre la entrega '
                            'manual desde la ficha del estudiante.',
                        'Could not open the camera. Record a manual delivery '
                            'from the student page.',
                      ),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

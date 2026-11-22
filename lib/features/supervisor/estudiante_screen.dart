import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/theme.dart';
import '../../core/l10n/app_strings.dart';
import '../../data/models/estudiante.dart';
import 'supervisor_comun.dart';

/// Ficha del estudiante: datos, su código QR y el estado de hoy.
class EstudianteScreen extends StatelessWidget {
  const EstudianteScreen({super.key, required this.estudianteId});

  final int estudianteId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Estudiante>>(
      valueListenable: repoEstudiantes.estudiantes,
      builder: (context, _, _) {
        final e = repoEstudiantes.porId(estudianteId);
        if (e == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Text(
                S.text(
                  'sup.no_encontrado',
                  'Estudiante no encontrado.',
                  'Student not found.',
                ),
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(S.text('sup.ficha', 'Estudiante', 'Student')),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _Encabezado(estudiante: e),
              const SizedBox(height: 16),
              _TarjetaQr(estudiante: e),
              const SizedBox(height: 16),
              _TarjetaHoy(estudiante: e),
            ],
          ),
        );
      },
    );
  }
}

String _capitalizar(String t) =>
    t.isEmpty ? t : t[0].toUpperCase() + t.substring(1).toLowerCase();

class _Encabezado extends StatelessWidget {
  const _Encabezado({required this.estudiante});

  final Estudiante estudiante;

  @override
  Widget build(BuildContext context) {
    final e = estudiante;
    final tema = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(
          e.nombreCompleto,
          textAlign: TextAlign.center,
          style: tema.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          e.documento,
          style: tema.bodyMedium?.copyWith(color: PaeColors.textSecondary),
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            _Dato(
              icono: Icons.class_outlined,
              texto: '${S.text('sup.curso', 'Curso', 'Class')} ${e.curso}',
            ),
            if (e.jornada.isNotEmpty)
              _Dato(
                icono: Icons.schedule_rounded,
                texto:
                    '${S.text('sup.jornada', 'Jornada', 'Shift')} '
                    '${_capitalizar(e.jornada)}',
              ),
          ],
        ),
      ],
    );
  }
}

class _Dato extends StatelessWidget {
  const _Dato({required this.icono, required this.texto});

  final IconData icono;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icono, size: 16, color: PaeColors.primary),
      label: Text(texto),
      visualDensity: VisualDensity.compact,
      side: BorderSide.none,
      backgroundColor: PaeColors.primary.withValues(alpha: 0.08),
    );
  }
}

class _TarjetaQr extends StatelessWidget {
  const _TarjetaQr({required this.estudiante});

  final Estudiante estudiante;

  @override
  Widget build(BuildContext context) {
    final contenido = estudiante.contenidoQr;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (contenido == null) ...[
              const Icon(
                Icons.qr_code_2_rounded,
                size: 64,
                color: PaeColors.inactive,
              ),
              const SizedBox(height: 8),
              Text(
                S.text(
                  'sup.sin_qr',
                  'Este estudiante aún no tiene código QR. Actualice la lista '
                      'con conexión a internet.',
                  'This student has no QR code yet. Refresh the list online.',
                ),
                textAlign: TextAlign.center,
              ),
            ] else ...[
              LayoutBuilder(
                builder: (context, c) {
                  final lado = c.maxWidth.clamp(0, 280).toDouble();
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: PaeColors.divider),
                    ),
                    child: QrImageView(
                      key: const Key('qr_estudiante'),
                      data: contenido,
                      size: lado - 24,
                      padding: EdgeInsets.zero,
                      backgroundColor: Colors.white,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: PaeColors.textPrimary,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: PaeColors.textPrimary,
                      ),
                      semanticsLabel: S.text(
                        'sup.qr_de',
                        'Código QR del estudiante',
                        'Student QR code',
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              Text(
                S.text(
                  'sup.qr_ayuda',
                  'Este es el código del carné. Escanéelo con «Escanear QR» '
                      'para registrar la entrega del día.',
                  'This is the ID card code. Scan it with "Scan QR" to '
                      'record today\'s delivery.',
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(color: PaeColors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TarjetaHoy extends StatelessWidget {
  const _TarjetaHoy({required this.estudiante});

  final Estudiante estudiante;

  @override
  Widget build(BuildContext context) {
    final e = estudiante;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  S.text('sup.estado_hoy', 'Hoy', 'Today'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                EstadoHoy(estudiante: e),
              ],
            ),
            const SizedBox(height: 8),
            if (e.recibioHoy)
              Text(
                '${S.text('sup.metodo', 'Registrado por', 'Recorded by')}: '
                '${metodoLegible(e.entregaMetodo)}'
                '${e.entregaHora == null ? '' : ' · ${horaCorta(e.entregaHora)}'}'
                '${e.entregaPendiente ? ' · ${S.text('sup.sin_enviar', 'pendiente de enviar', 'not sent yet')}' : ''}',
              )
            else ...[
              Text(
                S.text(
                  'sup.hoy_pendiente',
                  'Aún no recibe el PAE hoy. Si no puede escanear el QR, '
                      'registre la entrega manual indicando el motivo.',
                  'No meal recorded today. If the QR cannot be scanned, '
                      'record a manual delivery with a reason.',
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const Key('entrega_manual'),
                  onPressed: () => registrarEntregaManual(context, e),
                  icon: const Icon(Icons.edit_note_rounded),
                  label: Text(
                    S.text('sup.manual', 'Entrega manual', 'Manual delivery'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

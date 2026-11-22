import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../data/models/estudiante.dart';
import '../../data/repositories/estudiantes_repository.dart';

/// Piezas compartidas por las pantallas del supervisor PAE.

EstudiantesRepository get repoEstudiantes => EstudiantesRepository.instance;

void avisar(BuildContext context, String texto, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(texto),
        backgroundColor: error ? PaeColors.error : null,
      ),
    );
}

String horaCorta(DateTime? d) => d == null ? '' : DateFormat.Hm().format(d);

String metodoLegible(String? metodo) =>
    metodoEntregaLegible(metodo, espanol: S.isSpanish);

/// Tarjeta "Recibieron hoy: X de Y" con barra de avance.
class ResumenEntrega extends StatelessWidget {
  const ResumenEntrega({
    super.key,
    required this.recibieron,
    required this.activos,
    this.titulo,
  });

  final int recibieron;
  final int activos;
  final String? titulo;

  @override
  Widget build(BuildContext context) {
    final avance = activos == 0 ? 0.0 : recibieron / activos;
    final tema = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titulo ??
                        S.text('sup.hoy', 'Recibieron hoy', 'Received today'),
                    style: tema.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$recibieron ${S.text('sup.de', 'de', 'of')} $activos',
                    style: tema.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: avance,
                      minHeight: 8,
                      color: PaeColors.statusDelivered,
                      backgroundColor: PaeColors.divider,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Text(
              '${(avance * 100).round()} %',
              style: tema.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: PaeColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Estado de hoy del estudiante (pendiente / recibió a las HH:mm).
class EstadoHoy extends StatelessWidget {
  const EstadoHoy({super.key, required this.estudiante});

  final Estudiante estudiante;

  @override
  Widget build(BuildContext context) {
    final e = estudiante;
    if (!e.recibioHoy) {
      return StatusBadge(
        label: S.text('sup.pendiente', 'Pendiente', 'Pending'),
        color: PaeColors.statusAssigned,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (e.entregaPendiente)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Tooltip(
              message: S.text(
                'sup.por_enviar',
                'Guardado en el teléfono; se enviará al haber conexión',
                'Saved on the phone; will be sent when online',
              ),
              child: const Icon(
                Icons.cloud_upload_outlined,
                size: 16,
                color: PaeColors.warning,
              ),
            ),
          ),
        StatusBadge(
          label:
              '${S.text('sup.recibio', 'Recibió', 'Received')} '
              '${horaCorta(e.entregaHora)}',
          color: PaeColors.statusDelivered,
        ),
      ],
    );
  }
}

/// Fila de un estudiante en la lista del curso.
class FilaEstudiante extends StatelessWidget {
  const FilaEstudiante({
    super.key,
    required this.estudiante,
    required this.onTap,
  });

  final Estudiante estudiante;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = estudiante;
    final iniciales = [
      e.nombres,
      e.apellidos,
    ].where((t) => t.isNotEmpty).map((t) => t[0].toUpperCase()).join();
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: e.recibioHoy
            ? PaeColors.statusDelivered.withValues(alpha: 0.15)
            : PaeColors.primary.withValues(alpha: 0.1),
        foregroundColor: e.recibioHoy
            ? PaeColors.statusDelivered
            : PaeColors.primary,
        child: e.recibioHoy
            ? const Icon(Icons.check_rounded)
            : Text(
                iniciales,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
      ),
      title: Text('${e.apellidos}, ${e.nombres}'),
      subtitle: Text(e.documento),
      trailing: EstadoHoy(estudiante: e),
    );
  }
}

/// Pide el motivo y registra la entrega manual. Devuelve si se registró.
Future<bool> registrarEntregaManual(BuildContext context, Estudiante e) async {
  final motivo = await showDialog<String>(
    context: context,
    builder: (_) => DialogoMotivo(estudiante: e),
  );
  if (motivo == null || !context.mounted) return false;
  try {
    await repoEstudiantes.entregar(e, metodo: 'MANUAL', motivo: motivo);
    if (context.mounted) {
      avisar(
        context,
        '✓ ${e.nombreCompleto} · '
        '${S.text('sup.registrada', 'entrega registrada', 'delivery recorded')}',
      );
    }
    return true;
  } on StateError catch (err) {
    if (context.mounted) avisar(context, err.message, error: true);
    return false;
  }
}

/// Motivo de la entrega manual (obligatorio): se usa cuando no se puede leer
/// el QR del estudiante.
class DialogoMotivo extends StatefulWidget {
  const DialogoMotivo({super.key, required this.estudiante});

  final Estudiante estudiante;

  @override
  State<DialogoMotivo> createState() => _DialogoMotivoState();
}

class _DialogoMotivoState extends State<DialogoMotivo> {
  static final _motivos = [
    S.text('sup.m_sin_carne', 'No trajo el carné', 'Forgot the ID card'),
    S.text(
      'sup.m_qr_danado',
      'El QR está dañado o no se lee',
      'QR damaged or unreadable',
    ),
    S.text('sup.m_sin_camara', 'Cámara no disponible', 'Camera not available'),
  ];
  String? _elegido;
  final _otro = TextEditingController();

  @override
  void dispose() {
    _otro.dispose();
    super.dispose();
  }

  String get _motivo =>
      _elegido == '_otro' ? _otro.text.trim() : (_elegido ?? '');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(S.text('sup.manual_t', 'Entrega manual', 'Manual delivery')),
      content: SingleChildScrollView(
        child: RadioGroup<String>(
          groupValue: _elegido,
          onChanged: (v) => setState(() => _elegido = v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.estudiante.nombreCompleto,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                S.text(
                  'sup.manual_motivo',
                  '¿Por qué no se escanea el QR?',
                  'Why is the QR not scanned?',
                ),
              ),
              const SizedBox(height: 4),
              for (final m in _motivos)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: m,
                  title: Text(m),
                ),
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                value: '_otro',
                title: TextField(
                  key: const Key('motivo_otro'),
                  controller: _otro,
                  onTap: () => setState(() => _elegido = '_otro'),
                  onChanged: (_) => setState(() => _elegido = '_otro'),
                  decoration: InputDecoration(
                    hintText: S.text('sup.otro', 'Otro motivo', 'Other reason'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(S.text('comun.cancelar', 'Cancelar', 'Cancel')),
        ),
        FilledButton(
          key: const Key('guardar_manual'),
          onPressed: _motivo.isEmpty
              ? null
              : () => Navigator.pop(context, _motivo),
          child: Text(S.text('sup.registrar', 'Registrar', 'Record')),
        ),
      ],
    );
  }
}

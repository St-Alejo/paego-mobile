import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../data/sync/sync_service.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Historial (lo registrado desde este teléfono y su estado)
// ═══════════════════════════════════════════════════════════════════════════

class HistorialSupervisorScreen extends StatefulWidget {
  const HistorialSupervisorScreen({super.key});

  @override
  State<HistorialSupervisorScreen> createState() =>
      _HistorialSupervisorScreenState();
}

class _HistorialSupervisorScreenState extends State<HistorialSupervisorScreen> {
  late Future<List<Operacion>> _ops = _cargar();

  Future<List<Operacion>> _cargar() =>
      SyncService.instance.historial(limite: 300, prefijo: 'estudiante.');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GradientHeader(
        title: S.text('sup.historial', 'Historial', 'History'),
        subtitle: S.text(
          'sup.historial_sub',
          'Lo que registró y su estado en la plataforma',
          'What you recorded and its status',
        ),
      ),
      body: ValueListenableBuilder<EstadoSync>(
        valueListenable: SyncService.instance.estado,
        builder: (context, _, _) {
          _ops = _cargar();
          return FutureBuilder<List<Operacion>>(
            future: _ops,
            builder: (context, snap) {
              final ops = snap.data ?? const [];
              if (snap.connectionState != ConnectionState.done && ops.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              if (ops.isEmpty) {
                return Center(
                  child: Text(
                    S.text(
                      'sup.historial_vacio',
                      'Aún no ha registrado nada.',
                      'Nothing recorded yet.',
                    ),
                  ),
                );
              }
              return ListView.separated(
                itemCount: ops.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final op = ops[i];
                  final (icono, color) = op.pendiente
                      ? (Icons.cloud_upload_outlined, PaeColors.warning)
                      : op.rechazada
                      ? (Icons.error_outline_rounded, PaeColors.error)
                      : (Icons.cloud_done_outlined, PaeColors.success);
                  return ListTile(
                    leading: Icon(icono, color: color),
                    title: Text(op.resumen),
                    subtitle: Text(
                      [
                        DateFormat('d MMM HH:mm', 'es').format(op.ocurridoEn),
                        if (op.rechazada) op.motivoRechazo,
                      ].join(' · '),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

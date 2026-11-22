import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../data/models/estudiante.dart';
import '../../data/remote/api_client.dart';
import 'curso_screen.dart';
import 'escaner_qr_screen.dart';
import 'supervisor_comun.dart';

/// Pestaña principal del supervisor PAE: avance del día por curso.
class SupervisorCursosScreen extends StatefulWidget {
  const SupervisorCursosScreen({super.key});

  @override
  State<SupervisorCursosScreen> createState() => _SupervisorCursosScreenState();
}

class _SupervisorCursosScreenState extends State<SupervisorCursosScreen> {
  bool _cargando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _descargar();
  }

  Future<void> _descargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      await repoEstudiantes.descargar();
    } on SinConexionException {
      _error = S.text(
        'sup.sin_red',
        'Sin conexión: se muestran los datos guardados en el teléfono.',
        'Offline: showing the data saved on the phone.',
      );
    } on ApiException catch (e) {
      _error = e.mensaje;
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GradientHeader(
        title: S.text('sup.titulo', 'Entrega del PAE', 'School meal delivery'),
        subtitle: DateFormat.yMMMMEEEEd(
          S.isSpanish ? 'es' : 'en',
        ).format(DateTime.now()),
        actions: [
          IconButton(
            tooltip: S.text('sup.actualizar', 'Actualizar', 'Refresh'),
            onPressed: _cargando ? null : _descargar,
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
          ),
        ],
      ),
      floatingActionButton: ValueListenableBuilder<List<Estudiante>>(
        valueListenable: repoEstudiantes.estudiantes,
        builder: (context, estudiantes, _) => estudiantes.isEmpty
            ? const SizedBox.shrink()
            : FloatingActionButton.extended(
                key: const Key('escanear_todos'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const EscanerQrScreen()),
                ),
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: Text(S.text('sup.escanear', 'Escanear QR', 'Scan QR')),
              ),
      ),
      body: ValueListenableBuilder<List<Estudiante>>(
        valueListenable: repoEstudiantes.estudiantes,
        builder: (context, estudiantes, _) {
          final cursos = CursoResumen.de(estudiantes);
          final recibieron = estudiantes.where((e) => e.recibioHoy).length;
          return RefreshIndicator(
            onRefresh: _descargar,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                if (_cargando)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: LinearProgressIndicator(),
                  ),
                if (_error != null) _Aviso(texto: _error!),
                if (estudiantes.isEmpty && !_cargando)
                  const _Vacio()
                else if (estudiantes.isNotEmpty) ...[
                  ResumenEntrega(
                    recibieron: recibieron,
                    activos: estudiantes.length,
                  ),
                  const SizedBox(height: 16),
                  SectionHeader(
                    title: S.text('sup.cursos', 'Cursos', 'Classes'),
                    trailing: Text(
                      '${cursos.length}',
                      style: const TextStyle(color: PaeColors.textSecondary),
                    ),
                  ),
                  for (final c in cursos) _TarjetaCurso(curso: c),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso({required this.texto});

  final String texto;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PaeColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: PaeColors.warning),
          const SizedBox(width: 10),
          Expanded(child: Text(texto)),
        ],
      ),
    );
  }
}

class _Vacio extends StatelessWidget {
  const _Vacio();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 64),
      child: Column(
        children: [
          const Icon(
            Icons.groups_outlined,
            size: 56,
            color: PaeColors.inactive,
          ),
          const SizedBox(height: 12),
          Text(
            S.text(
              'sup.vacio',
              'No hay estudiantes descargados. Conéctese a internet y '
                  'actualice. Si sigue vacío, el administrador debe importar '
                  'los estudiantes del SIMAT.',
              'No students downloaded. Connect and refresh. If it stays '
                  'empty, the administrator must import them.',
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _TarjetaCurso extends StatelessWidget {
  const _TarjetaCurso({required this.curso});

  final CursoResumen curso;

  @override
  Widget build(BuildContext context) {
    final completo = curso.activos > 0 && curso.recibieron == curso.activos;
    final color = completo ? PaeColors.statusDelivered : PaeColors.primary;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CursoScreen(grado: curso.grado, grupo: curso.grupo),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: completo
                    ? Icon(Icons.check_rounded, color: color)
                    : Text(
                        curso.curso,
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${S.text('sup.curso', 'Curso', 'Class')} ${curso.curso}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: curso.avance,
                        minHeight: 6,
                        color: color,
                        backgroundColor: PaeColors.divider,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${curso.recibieron} ${S.text('sup.de', 'de', 'of')} '
                      '${curso.activos} '
                      '${S.text('sup.recibieron', 'recibieron', 'received')}',
                      style: const TextStyle(
                        color: PaeColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

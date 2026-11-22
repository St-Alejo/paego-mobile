import 'package:flutter/material.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../data/remote/api_client.dart';
import 'supervisor_comun.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Institución (rector): solo lectura, en línea
// ═══════════════════════════════════════════════════════════════════════════

class EstudiantesHoyScreen extends StatefulWidget {
  const EstudiantesHoyScreen({super.key});

  @override
  State<EstudiantesHoyScreen> createState() => _EstudiantesHoyScreenState();
}

class _EstudiantesHoyScreenState extends State<EstudiantesHoyScreen> {
  late Future<Map<String, dynamic>> _datos = _cargar();

  Future<Map<String, dynamic>> _cargar() async =>
      ((await ApiClient.instance.get('/estudiantes/cursos/')) as Map)
          .cast<String, dynamic>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GradientHeader(
        title: S.text('rector.estudiantes', 'Estudiantes', 'Students'),
        subtitle: S.text(
          'rector.estudiantes_sub',
          'Quién recibió el PAE hoy',
          'Who received the school meal today',
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          setState(() => _datos = _cargar());
          await _datos;
        },
        child: FutureBuilder<Map<String, dynamic>>(
          future: _datos,
          builder: (context, snap) {
            if (snap.hasError) {
              return ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      snap.error is SinConexionException
                          ? S.text(
                              'rector.sin_red',
                              'Sin conexión. Deslice para reintentar.',
                              'Offline. Pull to retry.',
                            )
                          : snap.error is ApiException
                          ? (snap.error as ApiException).mensaje
                          : snap.error.toString(),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final cob = (snap.data!['cobertura'] as Map)
                .cast<String, dynamic>();
            final cursos = (snap.data!['cursos'] as List).cast<Map>();
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ResumenEntrega(
                  recibieron: cob['recibieron'] as int,
                  activos: cob['activos'] as int,
                ),
                const SizedBox(height: 12),
                for (final c in cursos)
                  Card(
                    child: ListTile(
                      title: Text('${c['curso']}'),
                      subtitle: LinearProgressIndicator(
                        value: (c['activos'] as int) == 0
                            ? 0
                            : (c['recibieron'] as int) / (c['activos'] as int),
                      ),
                      trailing: Text('${c['recibieron']} / ${c['activos']}'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

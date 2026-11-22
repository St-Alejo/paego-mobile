import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/l10n/app_strings.dart';
import '../../data/models/estudiante.dart';
import 'escaner_qr_screen.dart';
import 'estudiante_screen.dart';
import 'supervisor_comun.dart';

enum _Filtro { todos, pendientes, recibieron }

/// Un curso: lista del día con búsqueda y el lector de QR como acción
/// principal.
class CursoScreen extends StatefulWidget {
  const CursoScreen({super.key, required this.grado, required this.grupo});

  final String grado;
  final String grupo;

  @override
  State<CursoScreen> createState() => _CursoScreenState();
}

class _CursoScreenState extends State<CursoScreen> {
  final _busqueda = TextEditingController();
  _Filtro _filtro = _Filtro.todos;

  @override
  void dispose() {
    _busqueda.dispose();
    super.dispose();
  }

  List<Estudiante> _filtrar(List<Estudiante> lista) {
    final q = _busqueda.text.trim().toLowerCase();
    return lista.where((e) {
      final pasaFiltro = switch (_filtro) {
        _Filtro.todos => true,
        _Filtro.pendientes => !e.recibioHoy,
        _Filtro.recibieron => e.recibioHoy,
      };
      if (!pasaFiltro) return false;
      if (q.isEmpty) return true;
      return e.nombreCompleto.toLowerCase().contains(q) ||
          '${e.apellidos} ${e.nombres}'.toLowerCase().contains(q) ||
          e.numeroDocumento.startsWith(q);
    }).toList();
  }

  void _escanear() => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => EscanerQrScreen(grado: widget.grado, grupo: widget.grupo),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final curso = repoEstudiantes
        .delCurso(widget.grado, widget.grupo)
        .firstOrNull
        ?.curso;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${S.text('sup.curso', 'Curso', 'Class')} ${curso ?? ''}'.trim(),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('escanear'),
        onPressed: _escanear,
        icon: const Icon(Icons.qr_code_scanner_rounded),
        label: Text(S.text('sup.escanear', 'Escanear QR', 'Scan QR')),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: ValueListenableBuilder<List<Estudiante>>(
        valueListenable: repoEstudiantes.estudiantes,
        builder: (context, _, _) {
          final lista = repoEstudiantes.delCurso(widget.grado, widget.grupo);
          final recibieron = lista.where((e) => e.recibioHoy).length;
          final filtrada = _filtrar(lista);
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverList.list(
                  children: [
                    ResumenEntrega(
                      recibieron: recibieron,
                      activos: lista.length,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('buscar'),
                      controller: _busqueda,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded),
                        hintText: S.text(
                          'sup.buscar',
                          'Buscar por nombre o documento',
                          'Search by name or ID',
                        ),
                        suffixIcon: _busqueda.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear_rounded),
                                onPressed: () =>
                                    setState(() => _busqueda.clear()),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        _chip(
                          _Filtro.todos,
                          S.text('sup.f_todos', 'Todos', 'All'),
                          lista.length,
                        ),
                        _chip(
                          _Filtro.pendientes,
                          S.text('sup.f_pendientes', 'Pendientes', 'Pending'),
                          lista.length - recibieron,
                        ),
                        _chip(
                          _Filtro.recibieron,
                          S.text('sup.f_recibieron', 'Recibieron', 'Received'),
                          recibieron,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
              if (filtrada.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(
                      S.text(
                        'sup.sin_resultados',
                        'No hay estudiantes que coincidan.',
                        'No matching students.',
                      ),
                      style: const TextStyle(color: PaeColors.textSecondary),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 96),
                  sliver: SliverList.separated(
                    itemCount: filtrada.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 72),
                    itemBuilder: (_, i) => FilaEstudiante(
                      estudiante: filtrada[i],
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              EstudianteScreen(estudianteId: filtrada[i].id),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _chip(_Filtro f, String texto, int n) => ChoiceChip(
    label: Text('$texto ($n)'),
    selected: _filtro == f,
    onSelected: (_) => setState(() => _filtro = f),
  );
}

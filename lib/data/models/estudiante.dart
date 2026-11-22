/// Estudiante beneficiario del PAE (identidad mínima del SIMAT, Ley 1581).
///
/// Viene de `GET /api/estudiantes/` con su estado del día; la app le aplica
/// encima las operaciones que aún no llegan al servidor (cola RF-38).
class Estudiante {
  const Estudiante({
    required this.id,
    required this.nombres,
    required this.apellidos,
    required this.tipoDocumento,
    required this.numeroDocumento,
    required this.grado,
    required this.grupo,
    required this.curso,
    this.gradoEtiqueta = '',
    this.jornada = '',
    this.codigoQr,
    this.entregaFecha,
    this.entregaMetodo,
    this.entregaHora,
    this.entregaPendiente = false,
  });

  factory Estudiante.fromJson(Map<String, dynamic> j) {
    final entrega = (j['entrega_del_dia'] as Map?)?.cast<String, dynamic>();
    final qr = (j['codigo_qr'] as String?)?.trim() ?? '';
    // El SIMAT trae códigos (tipo de documento "5", jornada "6"); el servidor
    // manda además la sigla/nombre legible, que es lo que se muestra.
    String legible(String etiqueta, String codigo) {
      final e = (j[etiqueta] as String?)?.trim() ?? '';
      return e.isNotEmpty ? e : (j[codigo] as String?)?.trim() ?? '';
    }

    return Estudiante(
      id: j['id'] as int,
      nombres: j['nombres'] as String? ?? '',
      apellidos: j['apellidos'] as String? ?? '',
      tipoDocumento: legible('tipo_documento_etiqueta', 'tipo_documento'),
      numeroDocumento: j['numero_documento'] as String? ?? '',
      grado: '${j['grado'] ?? ''}',
      grupo: '${j['grupo'] ?? ''}',
      curso: j['curso'] as String? ?? '${j['grado']} ${j['grupo']}',
      gradoEtiqueta: j['grado_etiqueta'] as String? ?? '',
      jornada: legible('jornada_etiqueta', 'jornada'),
      codigoQr: qr.isEmpty ? null : qr,
      entregaFecha: entrega?['fecha'] as String?,
      entregaMetodo: entrega?['metodo'] as String?,
      entregaHora: entrega?['ocurrido_en'] == null
          ? null
          : DateTime.tryParse(entrega!['ocurrido_en'] as String)?.toLocal(),
    );
  }

  final int id;
  final String nombres;
  final String apellidos;
  final String tipoDocumento;
  final String numeroDocumento;
  final String grado;
  final String grupo;

  /// Etiqueta del curso, p. ej. "7° B".
  final String curso;

  /// Grado legible, p. ej. "7°" o "Transición".
  final String gradoEtiqueta;

  /// Jornada legible (Mañana, Única…); código SIMAT si el servidor no la manda.
  final String jornada;

  /// Token del carné QR (`PAEGO-E1:<codigo>`). El rol institución puede no
  /// recibirlo.
  final String? codigoQr;

  /// Día (AAAA-MM-DD) de la última entrega conocida.
  final String? entregaFecha;

  /// QR | MANUAL (FACIAL en entregas anteriores al cambio a QR).
  final String? entregaMetodo;
  final DateTime? entregaHora;

  /// La entrega está en el teléfono y aún no llega al servidor.
  final bool entregaPendiente;

  String get nombreCompleto => '$nombres $apellidos'.trim();
  String get documento => '$tipoDocumento $numeroDocumento'.trim();

  /// ¿Recibió el PAE hoy? (la caché puede ser de un día anterior).
  bool get recibioHoy => entregaFecha == fechaDeHoy();

  /// Texto que lleva el QR impreso del estudiante.
  String? get contenidoQr => codigoQr == null ? null : '$prefijoQr$codigoQr';

  Estudiante copyWith({
    String? entregaFecha,
    String? entregaMetodo,
    DateTime? entregaHora,
    bool? entregaPendiente,
  }) => Estudiante(
    id: id,
    nombres: nombres,
    apellidos: apellidos,
    tipoDocumento: tipoDocumento,
    numeroDocumento: numeroDocumento,
    grado: grado,
    grupo: grupo,
    curso: curso,
    gradoEtiqueta: gradoEtiqueta,
    jornada: jornada,
    codigoQr: codigoQr,
    entregaFecha: entregaFecha ?? this.entregaFecha,
    entregaMetodo: entregaMetodo ?? this.entregaMetodo,
    entregaHora: entregaHora ?? this.entregaHora,
    entregaPendiente: entregaPendiente ?? this.entregaPendiente,
  );
}

/// Avance de un curso en el día.
class CursoResumen {
  const CursoResumen({
    required this.grado,
    required this.grupo,
    required this.curso,
    required this.activos,
    required this.recibieron,
  });

  final String grado;
  final String grupo;
  final String curso;
  final int activos;
  final int recibieron;

  double get avance => activos == 0 ? 0 : recibieron / activos;

  /// Agrupa los estudiantes por curso, ordenados por grado y grupo.
  static List<CursoResumen> de(Iterable<Estudiante> estudiantes) {
    final grupos = <String, List<Estudiante>>{};
    for (final e in estudiantes) {
      grupos.putIfAbsent('${e.grado}|${e.grupo}', () => []).add(e);
    }
    final lista = [
      for (final l in grupos.values)
        CursoResumen(
          grado: l.first.grado,
          grupo: l.first.grupo,
          curso: l.first.curso,
          activos: l.length,
          recibieron: l.where((e) => e.recibioHoy).length,
        ),
    ];
    lista.sort((a, b) {
      final g = ordenGrado(a.grado).compareTo(ordenGrado(b.grado));
      return g != 0 ? g : a.grupo.compareTo(b.grupo);
    });
    return lista;
  }
}

/// Prefijo del contenido de los QR de PAEGo (versión 1 del formato).
const prefijoQr = 'PAEGO-E1:';

/// Extrae el código de un texto leído por la cámara; null si el QR no es de
/// un estudiante de PAEGo.
String? codigoDeQr(String? texto) {
  final t = texto?.trim() ?? '';
  if (!t.startsWith(prefijoQr)) return null;
  final codigo = t.substring(prefijoQr.length).trim();
  return codigo.isEmpty ? null : codigo;
}

/// Nombre legible del método de entrega.
String metodoEntregaLegible(String? metodo, {bool espanol = true}) =>
    switch (metodo) {
      'QR' => espanol ? 'Código QR' : 'QR code',
      'MANUAL' => espanol ? 'Manual' : 'Manual',
      'FACIAL' => espanol ? 'Reconocimiento facial' : 'Face recognition',
      _ => metodo ?? '',
    };

/// Orden de los grados del SIMAT: preescolar (-2..0) antes de 1..11; los
/// códigos no numéricos (ciclos de adultos) al final.
int ordenGrado(String grado) => int.tryParse(grado) ?? 1000;

String fechaDeHoy([DateTime? ahora]) {
  final d = ahora ?? DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

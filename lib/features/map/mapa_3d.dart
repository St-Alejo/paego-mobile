import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;

import '../../app/theme.dart';

/// Qué representa un punto del mapa 3D (decide su ícono).
enum TipoPunto { institucion, vehiculo, conductorPropio, yo }

/// Un marcador del mapa 3D.
class PuntoMapa {
  const PuntoMapa({
    required this.id,
    required this.posicion,
    required this.tipo,
    this.color,
    this.etiqueta,
  });

  final String id;
  final LatLng posicion;
  final TipoPunto tipo;

  /// Color del pin de una institución (estado del envío).
  final Color? color;

  /// Texto bajo el ícono (placa del vehículo).
  final String? etiqueta;

  /// Nombre de la imagen de estilo que usa el punto.
  String get icono => switch (tipo) {
    TipoPunto.institucion =>
      'paego-inst-${(color ?? PaeColors.primary).toARGB32()}',
    TipoPunto.vehiculo || TipoPunto.conductorPropio => 'paego-vehiculo',
    TipoPunto.yo => 'paego-yo',
  };
}

/// Mueve la cámara del [Mapa3D] desde fuera (carrusel, "mi ubicación").
class Mapa3DController {
  mb.MapboxMap? _mapa;

  Future<void> mover(LatLng destino, double zoom) async {
    await _mapa?.flyTo(
      mb.CameraOptions(
        center: _punto(destino),
        zoom: zoom,
        pitch: Mapa3D.inclinacion,
      ),
      mb.MapAnimationOptions(duration: 1200),
    );
  }
}

mb.Point _punto(LatLng p) =>
    mb.Point(coordinates: mb.Position(p.longitude, p.latitude));

/// Preset de luz de Mapbox Standard según la hora (o noche en tema oscuro).
@visibleForTesting
String presetDeLuz(DateTime ahora, {required bool oscuro}) {
  if (oscuro) return 'night';
  final h = ahora.hour;
  if (h >= 5 && h < 7) return 'dawn';
  if (h >= 7 && h < 17) return 'day';
  if (h >= 17 && h < 19) return 'dusk';
  return 'night';
}

/// GeoJSON de los puntos (cada uno con su id, ícono y etiqueta).
@visibleForTesting
String geojsonPuntos(List<PuntoMapa> puntos) => jsonEncode({
  'type': 'FeatureCollection',
  'features': [
    for (final p in puntos)
      {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [p.posicion.longitude, p.posicion.latitude],
        },
        'properties': {
          'id': p.id,
          'icono': p.icono,
          'etiqueta': p.etiqueta ?? '',
        },
      },
  ],
});

/// GeoJSON de la línea del recorrido.
@visibleForTesting
String geojsonRecorrido(List<LatLng> puntos) => jsonEncode({
  'type': 'FeatureCollection',
  'features': [
    if (puntos.length > 1)
      {
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (final p in puntos) [p.longitude, p.latitude],
          ],
        },
        'properties': <String, Object>{},
      },
  ],
});

/// Mapa principal en 3D: estilo **Mapbox Standard** (edificios 3D, árboles,
/// iluminación según la hora) con el SDK oficial de Mapbox, que funciona en
/// Android, iOS y web.
///
/// Los marcadores y el recorrido son capas del propio mapa (fuentes GeoJSON),
/// no anotaciones: así se ven igual en las tres plataformas (las anotaciones
/// del SDK no existen en web) y quedan por encima de los edificios.
class Mapa3D extends StatefulWidget {
  const Mapa3D({
    super.key,
    required this.centro,
    required this.puntos,
    required this.recorrido,
    required this.oscuro,
    required this.controller,
    required this.margenInferior,
    this.onTapPunto,
  });

  /// Inclinación de la cámara (grados) para ver los edificios en 3D.
  static const inclinacion = 58.0;

  final LatLng centro;
  final List<PuntoMapa> puntos;
  final List<LatLng> recorrido;
  final bool oscuro;
  final Mapa3DController controller;

  /// Alto de lo que tapa la parte de abajo (panel de envíos): el logo y la
  /// atribución de Mapbox se dibujan encima.
  final double margenInferior;
  final void Function(String id)? onTapPunto;

  @override
  State<Mapa3D> createState() => _Mapa3DState();
}

class _Mapa3DState extends State<Mapa3D> {
  static const _fuentePuntos = 'paego-puntos';
  static const _fuenteRecorrido = 'paego-recorrido';
  static const _capaPuntos = 'paego-puntos-capa';
  static const _capaYo = 'paego-yo-capa';

  mb.MapboxMap? _mapa;
  bool _estiloListo = false;
  final Set<String> _iconos = {};

  @override
  void didUpdateWidget(Mapa3D anterior) {
    super.didUpdateWidget(anterior);
    if (!_estiloListo) return;
    _sincronizar();
    if (anterior.oscuro != widget.oscuro) _aplicarLuz();
    if (anterior.margenInferior != widget.margenInferior) _ornamentos();
  }

  void _alCrear(mb.MapboxMap mapa) {
    _mapa = mapa;
    widget.controller._mapa = mapa;
    _ornamentos();
    mapa.addInteraction(
      mb.TapInteraction(mb.FeaturesetDescriptor(layerId: _capaPuntos), (
        feature,
        _,
      ) {
        final id = feature.properties['id'];
        if (id is String) widget.onTapPunto?.call(id);
      }),
    );
  }

  static const _esYo = [
    '==',
    ['get', 'icono'],
    'paego-yo',
  ];

  Future<void> _ornamentos() async {
    final mapa = _mapa;
    if (mapa == null) return;
    final abajo = widget.margenInferior + 8;
    await mapa.logo.updateSettings(mb.LogoSettings(marginBottom: abajo));
    await mapa.attribution.updateSettings(
      mb.AttributionSettings(marginBottom: abajo),
    );
    await mapa.scaleBar.updateSettings(mb.ScaleBarSettings(enabled: false));
    // La brújula va abajo a la derecha, sobre el botón de atribución (arriba
    // la tapa el encabezado de la pantalla).
    await mapa.compass.updateSettings(
      mb.CompassSettings(
        position: mb.OrnamentPosition.BOTTOM_RIGHT,
        marginBottom: abajo + 36,
        marginRight: 8,
      ),
    );
  }

  Future<void> _aplicarLuz() async {
    await _mapa?.setStyleImportConfigProperty(
      'basemap',
      'lightPreset',
      presetDeLuz(DateTime.now(), oscuro: widget.oscuro),
    );
  }

  Future<void> _alCargarEstilo(mb.StyleLoadedEventData _) async {
    final mapa = _mapa;
    if (mapa == null) return;
    await _aplicarLuz();
    final estilo = mapa;
    await estilo.addSource(
      mb.GeoJsonSource(id: _fuenteRecorrido, data: geojsonRecorrido(const [])),
    );
    await estilo.addLayer(
      mb.LineLayer(
        id: 'paego-recorrido-capa',
        sourceId: _fuenteRecorrido,
        slot: 'middle',
        lineColor: PaeColors.accent.toARGB32(),
        lineWidth: 6,
        lineCap: mb.LineCap.ROUND,
        lineJoin: mb.LineJoin.ROUND,
        lineEmissiveStrength: 1,
      ),
    );
    await estilo.addSource(
      mb.GeoJsonSource(id: _fuentePuntos, data: geojsonPuntos(const [])),
    );
    await estilo.addLayer(
      mb.SymbolLayer(
        id: _capaPuntos,
        sourceId: _fuentePuntos,
        // Encima de edificios y etiquetas del mapa base.
        slot: 'top',
        filter: const ['!', _esYo],
        iconImageExpression: const ['get', 'icono'],
        iconAnchor: mb.IconAnchor.BOTTOM,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
        iconEmissiveStrength: 1,
        textFieldExpression: const ['get', 'etiqueta'],
        textAnchor: mb.TextAnchor.TOP,
        textOffset: const [0, 0.4],
        textSize: 12,
        textAllowOverlap: true,
        textColor: const Color(0xFF1F1F1F).toARGB32(),
        textHaloColor: Colors.white.toARGB32(),
        textHaloWidth: 1.6,
        textEmissiveStrength: 1,
      ),
    );
    // La posición propia es un punto centrado en la coordenada (no un pin).
    await estilo.addLayer(
      mb.SymbolLayer(
        id: _capaYo,
        sourceId: _fuentePuntos,
        slot: 'top',
        filter: _esYo,
        iconImage: 'paego-yo',
        iconAnchor: mb.IconAnchor.CENTER,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
        iconEmissiveStrength: 1,
      ),
    );
    _iconos.clear();
    _estiloListo = true;
    await _sincronizar();
  }

  Future<void> _sincronizar() async {
    final mapa = _mapa;
    if (mapa == null || !_estiloListo) return;
    final estilo = mapa;
    for (final p in widget.puntos) {
      if (_iconos.add(p.icono)) {
        await mapa.addImage(p.icono, _Iconos.escala, await _Iconos.dibujar(p));
      }
    }
    await estilo.setStyleSourceProperty(
      _fuentePuntos,
      'data',
      geojsonPuntos(widget.puntos),
    );
    await estilo.setStyleSourceProperty(
      _fuenteRecorrido,
      'data',
      geojsonRecorrido(widget.recorrido),
    );
  }

  @override
  Widget build(BuildContext context) => mb.MapWidget(
    key: const ValueKey('paego-mapa-3d'),
    styleUri: mb.MapboxStyles.STANDARD,
    viewport: mb.CameraViewportState(
      center: _punto(widget.centro),
      zoom: 14.6,
      pitch: Mapa3D.inclinacion,
      bearing: -12,
    ),
    onMapCreated: _alCrear,
    onStyleLoadedListener: _alCargarEstilo,
  );
}

/// Íconos de los marcadores, dibujados en un lienzo (no hace falta assets).
class _Iconos {
  /// Píxeles por punto lógico: imágenes nítidas en pantallas densas.
  static const escala = 3.0;

  static Future<mb.StyleImage> dibujar(PuntoMapa p) async {
    final (fondo, icono, lado) = switch (p.tipo) {
      TipoPunto.institucion => (
        p.color ?? PaeColors.primary,
        Icons.school_rounded,
        40.0,
      ),
      TipoPunto.vehiculo || TipoPunto.conductorPropio => (
        PaeColors.primary,
        Icons.local_shipping_rounded,
        40.0,
      ),
      TipoPunto.yo => (PaeColors.secondary, null, 22.0),
    };
    final punta = p.tipo == TipoPunto.yo ? 0.0 : 9.0;
    final ancho = lado + 8;
    final alto = lado + 8 + punta;
    // Halo azul claro alrededor del punto propio.
    final halo = p.tipo == TipoPunto.yo;

    final grabadora = ui.PictureRecorder();
    final c = Canvas(grabadora)..scale(escala);
    final centro = Offset(ancho / 2, lado / 2 + 4);
    final radio = lado / 2;

    if (halo) {
      c.drawCircle(
        centro,
        radio + 3,
        Paint()..color = fondo.withValues(alpha: 0.25),
      );
    }
    // Sombra suave.
    c.drawCircle(
      centro.translate(0, 2),
      radio,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    // Punta del pin.
    if (punta > 0) {
      final path = ui.Path()
        ..moveTo(centro.dx - 8, centro.dy + radio - 4)
        ..lineTo(centro.dx, centro.dy + radio + punta)
        ..lineTo(centro.dx + 8, centro.dy + radio - 4)
        ..close();
      c.drawPath(path, Paint()..color = fondo);
    }
    c.drawCircle(centro, radio, Paint()..color = Colors.white);
    c.drawCircle(centro, radio - 2.5, Paint()..color = fondo);
    if (icono != null) {
      final texto = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icono.codePoint),
          style: TextStyle(
            fontFamily: icono.fontFamily,
            package: icono.fontPackage,
            fontSize: lado * 0.52,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      texto.paint(c, centro - Offset(texto.width / 2, texto.height / 2));
    }
    final imagen = await grabadora.endRecording().toImage(
      (ancho * escala).ceil(),
      (alto * escala).ceil(),
    );
    return mb.StyleImage.fromImage(imagen);
  }
}

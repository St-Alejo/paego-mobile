import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:opaego/features/map/mapa_3d.dart';

void main() {
  group('presetDeLuz', () {
    DateTime a(int hora) => DateTime(2026, 11, 22, hora);

    test('sigue la hora del día', () {
      expect(presetDeLuz(a(6), oscuro: false), 'dawn');
      expect(presetDeLuz(a(12), oscuro: false), 'day');
      expect(presetDeLuz(a(18), oscuro: false), 'dusk');
      expect(presetDeLuz(a(22), oscuro: false), 'night');
      expect(presetDeLuz(a(3), oscuro: false), 'night');
    });

    test('en tema oscuro siempre es de noche', () {
      expect(presetDeLuz(a(12), oscuro: true), 'night');
    });
  });

  test('geojsonPuntos lleva id, ícono y etiqueta en orden lng/lat', () {
    final datos =
        jsonDecode(
              geojsonPuntos(const [
                PuntoMapa(
                  id: 'envio-7',
                  posicion: LatLng(1.21, -77.28),
                  tipo: TipoPunto.institucion,
                  color: Color(0xFF00A000),
                ),
                PuntoMapa(
                  id: 'vivo-0',
                  posicion: LatLng(1.22, -77.29),
                  tipo: TipoPunto.vehiculo,
                  etiqueta: 'ABC123',
                ),
                PuntoMapa(
                  id: 'yo',
                  posicion: LatLng(1, -77),
                  tipo: TipoPunto.yo,
                ),
              ]),
            )
            as Map<String, dynamic>;
    final features = datos['features'] as List;
    expect(features, hasLength(3));
    expect(features[0]['geometry']['coordinates'], [-77.28, 1.21]);
    expect(features[0]['properties']['id'], 'envio-7');
    expect(features[0]['properties']['icono'], 'paego-inst-${0xFF00A000}');
    expect(features[1]['properties']['icono'], 'paego-vehiculo');
    expect(features[1]['properties']['etiqueta'], 'ABC123');
    expect(features[2]['properties']['icono'], 'paego-yo');
  });

  test('geojsonRecorrido solo dibuja la línea con dos puntos o más', () {
    Map<String, dynamic> leer(List<LatLng> p) =>
        jsonDecode(geojsonRecorrido(p)) as Map<String, dynamic>;
    expect(leer(const [LatLng(1, -77)])['features'], isEmpty);
    final linea = leer(const [LatLng(1, -77), LatLng(1.1, -77.1)]);
    expect(linea['features'][0]['geometry']['type'], 'LineString');
    expect(linea['features'][0]['geometry']['coordinates'], [
      [-77, 1],
      [-77.1, 1.1],
    ]);
  });
}

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opaego/core/config/mapa_base.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('sin clave de ArcGIS', () {
    setUp(() => dotenv.testLoad(fileInput: 'PAEGO_API_URL=http://x'));

    test('solo ofrece OpenStreetMap', () {
      expect(MapaBase.hayArcgis, isFalse);
      expect(MapaBase.disponibles, [EstiloMapa.openStreetMap]);
    });

    test('un estilo de ArcGIS guardado vuelve a OpenStreetMap', () async {
      SharedPreferences.setMockInitialValues({
        'paego_estilo_mapa': EstiloMapa.calles.name,
      });
      await MapaBase.cargar();
      expect(MapaBase.estilo.value, EstiloMapa.openStreetMap);
    });

    test('la capa usa las teselas de OpenStreetMap', () {
      final capa = MapaBase.capa(EstiloMapa.navegacion);
      expect(capa.urlTemplate, contains('tile.openstreetmap.org'));
      final atribucion =
          MapaBase.atribuciones(EstiloMapa.navegacion).single
              as TextSourceAttribution;
      expect(atribucion.text, contains('OpenStreetMap'));
    });
  });

  group('con clave de ArcGIS', () {
    setUp(() => dotenv.testLoad(fileInput: 'ARCGIS_API_KEY=clave-de-prueba'));

    test('ofrece los estilos de ArcGIS y navegación por defecto', () async {
      expect(MapaBase.disponibles, contains(EstiloMapa.navegacion));
      await MapaBase.cargar();
      expect(MapaBase.estilo.value, EstiloMapa.navegacion);
    });

    test('la capa pide teselas de 512 px con fila antes que columna', () {
      final capa = MapaBase.capa(EstiloMapa.calles);
      expect(
        capa.urlTemplate,
        'https://static-map-tiles-api.arcgis.com/arcgis/rest/services/'
        'static-basemap-tiles-service/v1/arcgis/streets/static/tile/'
        '{z}/{y}/{x}?token={token}',
      );
      expect(capa.additionalOptions['token'], 'clave-de-prueba');
      expect(capa.tileSize, 512);
      expect(capa.zoomOffset, -1);
    });

    test('recuerda el estilo elegido', () async {
      await MapaBase.elegir(EstiloMapa.nocturno);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('paego_estilo_mapa'), EstiloMapa.nocturno.name);
      MapaBase.estilo.value = EstiloMapa.navegacion;
      await MapaBase.cargar();
      expect(MapaBase.estilo.value, EstiloMapa.nocturno);
    });

    test('muestra la atribución de Esri', () {
      final textos = MapaBase.atribuciones(
        EstiloMapa.exterior,
      ).map((a) => (a as TextSourceAttribution).text);
      expect(textos, contains('Powered by Esri'));
    });
  });

  group('con token de Mapbox', () {
    setUp(
      () => dotenv.testLoad(
        fileInput: 'MAPBOX_ACCESS_TOKEN=pk.prueba\nARCGIS_API_KEY=clave',
      ),
    );

    test('el mapa 3D de Mapbox es el principal y va primero', () async {
      await MapaBase.cargar();
      expect(MapaBase.estilo.value, EstiloMapa.mapbox3d);
      expect(MapaBase.estilo.value.es3d, isTrue);
      expect(MapaBase.disponibles.first, EstiloMapa.mapbox3d);
      expect(MapaBase.disponibles, contains(EstiloMapa.mapboxNavegacion));
      expect(MapaBase.disponibles, contains(EstiloMapa.calles));
      expect(MapaBase.disponibles.last, EstiloMapa.openStreetMap);
    });

    test('la capa raster del 3D (respaldo) usa Calles', () {
      expect(
        MapaBase.capa(EstiloMapa.mapbox3d).urlTemplate,
        contains('mapbox/streets-v12'),
      );
    });

    test('la capa usa la Static Tiles API con teselas de 512 px', () {
      final capa = MapaBase.capa(EstiloMapa.mapboxCalles, retina: true);
      expect(
        capa.urlTemplate,
        'https://api.mapbox.com/styles/v1/mapbox/streets-v12/tiles/512/'
        '{z}/{x}/{y}{r}?access_token={token}',
      );
      expect(capa.additionalOptions['token'], 'pk.prueba');
      expect(capa.tileSize, 512);
      expect(capa.zoomOffset, -1);
    });

    test('en tema oscuro la navegación pasa a la nocturna sin invertir', () {
      expect(
        MapaBase.efectivo(EstiloMapa.mapboxNavegacion, oscuro: true),
        EstiloMapa.mapboxNocturno,
      );
      expect(
        MapaBase.efectivo(EstiloMapa.mapboxSatelite, oscuro: true),
        EstiloMapa.mapboxSatelite,
      );
      expect(MapaBase.invertirEnOscuro(EstiloMapa.mapboxCalles), isFalse);
      expect(MapaBase.invertirEnOscuro(EstiloMapa.openStreetMap), isTrue);
    });

    test('muestra el logo y la atribución de Mapbox y OpenStreetMap', () {
      final atribuciones = MapaBase.atribuciones(EstiloMapa.mapboxClaro);
      expect(atribuciones.whereType<LogoSourceAttribution>(), hasLength(1));
      final textos = atribuciones.whereType<TextSourceAttribution>().map(
        (a) => a.text,
      );
      expect(textos, containsAll(['© Mapbox', '© OpenStreetMap']));
      expect(textos, contains('Mejorar este mapa'));
    });
  });

  test(
    'sin token, un estilo de Mapbox guardado vuelve al de por defecto',
    () async {
      dotenv.testLoad(fileInput: 'PAEGO_API_URL=http://x');
      SharedPreferences.setMockInitialValues({
        'paego_estilo_mapa': EstiloMapa.mapboxSatelite.name,
      });
      await MapaBase.cargar();
      expect(MapaBase.estilo.value, EstiloMapa.openStreetMap);
    },
  );
}

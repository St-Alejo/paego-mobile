import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart'
    show MapboxOptions;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Quién sirve las teselas del mapa base.
enum ProveedorMapa { mapbox, arcgis, openStreetMap }

/// Estilos de mapa base disponibles.
///
/// Todos se dibujan con `flutter_map` (teselas raster), así funcionan igual en
/// Android, iOS y web:
/// - **Mapbox** (principal): Static Tiles API de los estilos oficiales de
///   Mapbox. Necesita `MAPBOX_ACCESS_TOKEN` (token público `pk.…`) en `.env`.
/// - **ArcGIS**: "Static Basemap Tiles" de ArcGIS Location Platform, con
///   `ARCGIS_API_KEY` en `.env`.
/// - **OpenStreetMap**: siempre disponible, sin clave.
enum EstiloMapa {
  /// Mapbox Standard en 3D (edificios, árboles, luz según la hora). Se dibuja
  /// con el SDK oficial de Mapbox, no con teselas raster.
  mapbox3d(ProveedorMapa.mapbox, 'mapbox/standard', '3D', '3D'),
  mapboxNavegacion(
    ProveedorMapa.mapbox,
    'mapbox/navigation-day-v1',
    'Navegación',
    'Navigation',
  ),
  mapboxCalles(ProveedorMapa.mapbox, 'mapbox/streets-v12', 'Calles', 'Streets'),
  mapboxRelieve(
    ProveedorMapa.mapbox,
    'mapbox/outdoors-v12',
    'Relieve',
    'Outdoors',
  ),
  mapboxClaro(ProveedorMapa.mapbox, 'mapbox/light-v11', 'Claro', 'Light'),
  mapboxNocturno(
    ProveedorMapa.mapbox,
    'mapbox/navigation-night-v1',
    'Nocturno',
    'Night',
  ),
  mapboxSatelite(
    ProveedorMapa.mapbox,
    'mapbox/satellite-streets-v12',
    'Satélite',
    'Satellite',
  ),
  navegacion(
    ProveedorMapa.arcgis,
    'arcgis/navigation',
    'Navegación',
    'Navigation',
  ),
  calles(ProveedorMapa.arcgis, 'arcgis/streets', 'Calles', 'Streets'),
  exterior(ProveedorMapa.arcgis, 'arcgis/outdoor', 'Relieve', 'Outdoor'),
  grisClaro(
    ProveedorMapa.arcgis,
    'arcgis/light-gray',
    'Gris claro',
    'Light gray',
  ),
  nocturno(
    ProveedorMapa.arcgis,
    'arcgis/navigation-night',
    'Nocturno',
    'Night',
  ),
  openStreetMap(
    ProveedorMapa.openStreetMap,
    null,
    'OpenStreetMap',
    'OpenStreetMap',
  );

  const EstiloMapa(this.proveedor, this.ruta, this.nombreEs, this.nombreEn);

  final ProveedorMapa proveedor;

  /// `{usuario}/{estilo}` (Mapbox) o `{familia}/{estilo}` (ArcGIS); null en OSM.
  final String? ruta;
  final String nombreEs;
  final String nombreEn;

  bool get esMapbox => proveedor == ProveedorMapa.mapbox;

  /// Mapa vectorial 3D (SDK de Mapbox) en vez de teselas en `flutter_map`.
  bool get es3d => this == mapbox3d;
  bool get esArcgis => proveedor == ProveedorMapa.arcgis;

  /// El estilo ya es oscuro: no hay que invertir colores en el tema oscuro.
  bool get esOscuro => this == mapboxNocturno || this == nocturno;

  /// Nombre del proveedor para mostrar en el selector.
  String get nombreProveedor => switch (proveedor) {
    ProveedorMapa.mapbox => 'Mapbox',
    ProveedorMapa.arcgis => 'ArcGIS',
    ProveedorMapa.openStreetMap => 'OpenStreetMap',
  };
}

/// Mapa base de la app: qué estilo usar, su capa de teselas y su atribución.
class MapaBase {
  MapaBase._();

  static const _kEstilo = 'paego_estilo_mapa';
  static const _servicioArcgis =
      'https://static-map-tiles-api.arcgis.com/arcgis/rest/services/'
      'static-basemap-tiles-service/v1';

  /// Estilo elegido por el usuario (se recuerda entre sesiones).
  static final estilo = ValueNotifier<EstiloMapa>(_porDefecto);

  static EstiloMapa get _porDefecto => hayMapbox
      ? EstiloMapa.mapbox3d
      : hayArcgis
      ? EstiloMapa.navegacion
      : EstiloMapa.openStreetMap;

  static String? _leer(String clave) {
    try {
      final valor = dotenv.env[clave]?.trim();
      return (valor == null || valor.isEmpty) ? null : valor;
    } catch (_) {
      return null; // dotenv no se cargó (por ejemplo en pruebas).
    }
  }

  /// Token público de Mapbox (`pk.…`), o null si no está configurado.
  static String? get tokenMapbox => _leer('MAPBOX_ACCESS_TOKEN');

  /// Clave de ArcGIS Location Platform, o null si no está configurada.
  static String? get claveArcgis => _leer('ARCGIS_API_KEY');

  static bool get hayMapbox => tokenMapbox != null;

  /// Registra el token en el SDK de Mapbox (mapa 3D). Se llama al arrancar,
  /// después de cargar `.env`.
  static void configurar() {
    final token = tokenMapbox;
    if (token != null) MapboxOptions.setAccessToken(token);
  }

  static bool get hayArcgis => claveArcgis != null;

  /// Estilos que se pueden elegir con la configuración actual.
  static List<EstiloMapa> get disponibles => [
    for (final e in EstiloMapa.values)
      if (e.esMapbox ? hayMapbox : (e.esArcgis ? hayArcgis : true)) e,
  ];

  /// Lee el estilo guardado. Si su proveedor ya no tiene clave, usa el de
  /// por defecto.
  static Future<void> cargar() async {
    final prefs = await SharedPreferences.getInstance();
    final guardado = EstiloMapa.values
        .where((e) => e.name == prefs.getString(_kEstilo))
        .firstOrNull;
    estilo.value = (guardado != null && disponibles.contains(guardado))
        ? guardado
        : _porDefecto;
  }

  static Future<void> elegir(EstiloMapa nuevo) async {
    if (!disponibles.contains(nuevo)) return;
    estilo.value = nuevo;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEstilo, nuevo.name);
  }

  /// Estilo que realmente se dibuja: en tema oscuro, la navegación de Mapbox
  /// pasa a su versión nocturna (en vez de invertir los colores de la imagen).
  static EstiloMapa efectivo(EstiloMapa e, {required bool oscuro}) =>
      oscuro && e == EstiloMapa.mapboxNavegacion
      ? EstiloMapa.mapboxNocturno
      : e;

  /// Hay que invertir los colores de las teselas en tema oscuro (solo para
  /// estilos claros que no tienen versión nocturna propia).
  static bool invertirEnOscuro(EstiloMapa e) => !e.esMapbox && !e.esOscuro;

  /// URL de una tesela de Mapbox (Static Tiles API, 512 px; `{r}` = `@2x` en
  /// pantallas de alta densidad).
  @visibleForTesting
  static String plantillaMapbox(String ruta) =>
      'https://api.mapbox.com/styles/v1/$ruta/tiles/512/{z}/{x}/{y}{r}'
      '?access_token={token}';

  /// URL de una tesela de ArcGIS (z/y/x: el servicio pide fila antes que columna).
  @visibleForTesting
  static String plantillaArcgis(String ruta) =>
      '$_servicioArcgis/$ruta/static/tile/{z}/{y}/{x}?token={token}';

  /// Capa de teselas del estilo indicado. [retina] pide teselas `@2x`.
  static TileLayer capa(EstiloMapa e, {bool retina = false}) {
    final token = tokenMapbox;
    final clave = claveArcgis;
    if (e.esMapbox && token != null) {
      return TileLayer(
        // Teselas de 512 px: con zoomOffset -1 se ven a la escala normal y se
        // piden 4 veces menos (cuenta para la capa gratuita de 200 000 al mes).
        // El 3D no tiene teselas raster: si se pide su capa, va Calles.
        urlTemplate: plantillaMapbox(
          e.es3d ? EstiloMapa.mapboxCalles.ruta! : e.ruta!,
        ),
        additionalOptions: {'token': token},
        tileSize: 512,
        zoomOffset: -1,
        maxNativeZoom: 22,
        retinaMode: retina,
        userAgentPackageName: 'com.paego.app',
      );
    }
    if (e.esArcgis && clave != null) {
      return TileLayer(
        urlTemplate: plantillaArcgis(e.ruta!),
        additionalOptions: {'token': clave},
        tileSize: 512,
        zoomOffset: -1,
        maxNativeZoom: 22,
        userAgentPackageName: 'com.paego.app',
      );
    }
    return TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.paego.app',
    );
  }

  static void _abrir(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  /// Atribución obligatoria del proveedor del mapa base.
  static List<SourceAttribution> atribuciones(EstiloMapa e) {
    if (e.esMapbox && hayMapbox) {
      return [
        const LogoSourceAttribution(_LogoMapbox(), tooltip: 'Mapbox'),
        TextSourceAttribution(
          '© Mapbox',
          onTap: () => _abrir('https://www.mapbox.com/about/maps/'),
        ),
        TextSourceAttribution(
          '© OpenStreetMap',
          onTap: () => _abrir('https://www.openstreetmap.org/copyright'),
        ),
        TextSourceAttribution(
          'Mejorar este mapa',
          prependCopyright: false,
          onTap: () => _abrir('https://www.mapbox.com/map-feedback/'),
        ),
      ];
    }
    if (e.esArcgis && hayArcgis) {
      return const [
        TextSourceAttribution('Powered by Esri'),
        TextSourceAttribution('Esri y sus proveedores de datos'),
      ];
    }
    return const [TextSourceAttribution('© OpenStreetMap contributors')];
  }
}

/// Marca "mapbox" que exigen los términos de Mapbox junto al mapa.
class _LogoMapbox extends StatelessWidget {
  const _LogoMapbox();

  @override
  Widget build(BuildContext context) => const Text(
    'mapbox',
    style: TextStyle(
      fontWeight: FontWeight.w800,
      fontSize: 15,
      letterSpacing: -0.3,
      color: Color(0xFF1F1F1F),
    ),
  );
}

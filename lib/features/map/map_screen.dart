import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../app/theme.dart';
import '../../core/config/mapa_base.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../data/models/envio.dart';
import '../../data/models/user_model.dart';
import '../../data/models/user_role.dart';
import '../../data/remote/api_client.dart';
import '../../data/repositories/envio_repository.dart';
import '../../data/services/rastreo_service.dart';
import '../envios/envio_widgets.dart';
import 'mapa_3d.dart';

/// Mapa con los envíos del usuario y su posición real.
///
/// - Conductor: sus envíos activos, su ubicación (que se transmite a la web)
///   y los botones de salida / llegada / novedad.
/// - Institución: los envíos que van hacia ella y el botón de confirmar.
/// - Administrador: todos los envíos activos y los conductores en vivo.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.user});

  final AppUser user;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _ConductorEnVivo {
  _ConductorEnVivo(Map<String, dynamic> j)
    : nombre = j['nombre'] as String? ?? '',
      placa = j['placa'] as String?,
      posicion = LatLng(
        ((j['posicion'] as List)[0] as num).toDouble(),
        ((j['posicion'] as List)[1] as num).toDouble(),
      );

  final String nombre;
  final String? placa;
  final LatLng posicion;
}

class _MapScreenState extends State<MapScreen> {
  // Pasto, Nariño.
  static const _centroPorDefecto = LatLng(1.2136, -77.2811);

  final _mapCtrl = MapController();
  final _mapa3d = Mapa3DController();
  final List<LatLng> _recorrido = [];
  List<_ConductorEnVivo> _enVivo = [];
  Timer? _timerEnVivo;
  bool _centrado = false;
  bool _cargando = false;

  bool get _esAdmin => widget.user.role.canViewAllReports;

  @override
  void initState() {
    super.initState();
    MapaBase.cargar();
    RastreoService.instance.posicion.addListener(_alMoverse);
    if (_esAdmin) {
      _cargarEnVivo();
      _timerEnVivo = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _cargarEnVivo(),
      );
    }
  }

  @override
  void dispose() {
    RastreoService.instance.posicion.removeListener(_alMoverse);
    _timerEnVivo?.cancel();
    super.dispose();
  }

  void _alMoverse() {
    final p = RastreoService.instance.posicion.value;
    if (p == null || !mounted) return;
    final enCamino = EnvioRepository.instance.envios.value.any(
      (e) => e.estado == EstadoEnvio.enTransito && e.llegadaEn == null,
    );
    setState(() {
      if (widget.user.role.canDriveRoute && enCamino) {
        if (_recorrido.isEmpty ||
            const Distance().as(LengthUnit.Meter, _recorrido.last, p) > 5) {
          _recorrido.add(p);
        }
      } else {
        _recorrido.clear();
      }
    });
    if (!_centrado) {
      _centrado = true;
      _mover(p, 15.2);
    }
  }

  Future<void> _cargarEnVivo() async {
    try {
      final datos = await ApiClient.instance.get(
        '/monitoreo/conductores-en-vivo/',
      );
      if (!mounted) return;
      setState(() {
        _enVivo = (datos as List)
            .map((e) => _ConductorEnVivo((e as Map).cast<String, dynamic>()))
            .toList();
      });
    } catch (_) {
      // Sin red: se conserva la última lista.
    }
  }

  Future<void> _refrescar() async {
    setState(() => _cargando = true);
    try {
      await EnvioRepository.instance.refrescar();
      if (_esAdmin) await _cargarEnVivo();
    } on SinConexionException {
      _aviso(
        S.text(
          'mapa.sin_conexion',
          'Sin conexión: se muestran los últimos datos guardados.',
          'Offline: showing the last saved data.',
        ),
      );
    } catch (e) {
      _aviso(e.toString());
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _elegirEstiloMapa() async {
    final elegido = await showModalBottomSheet<EstiloMapa>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                S.text('mapa.estilo', 'Estilo del mapa', 'Map style'),
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (final e in MapaBase.disponibles)
              ListTile(
                leading: Icon(
                  e == MapaBase.estilo.value
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: PaeColors.primary,
                ),
                title: Text(S.isSpanish ? e.nombreEs : e.nombreEn),
                subtitle: Text(e.nombreProveedor),
                onTap: () => Navigator.pop(ctx, e),
              ),
          ],
        ),
      ),
    );
    if (elegido != null) await MapaBase.elegir(elegido);
  }

  void _aviso(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  void _mover(LatLng destino, double zoom) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MapaBase.estilo.value.es3d && MapaBase.hayMapbox) {
        _mapa3d.mover(destino, zoom);
        return;
      }
      try {
        _mapCtrl.move(destino, zoom);
      } catch (_) {
        // El mapa todavía no está listo.
      }
    });
  }

  void _irAMiUbicacion() {
    final p = RastreoService.instance.posicion.value;
    if (p == null) {
      RastreoService.instance.reintentar();
      _aviso(
        RastreoService.instance.problema.value ??
            S.text(
              'gps.sin_posicion',
              'Esperando la señal del GPS…',
              'Waiting for GPS signal…',
            ),
      );
      return;
    }
    _mover(p, 15.5);
  }

  /// Mapa principal: Mapbox Standard en 3D.
  Widget _mapaEn3d(List<Envio> activos, bool isDark) {
    return ValueListenableBuilder<LatLng?>(
      valueListenable: RastreoService.instance.posicion,
      builder: (context, yo, _) => Mapa3D(
        controller: _mapa3d,
        oscuro: isDark,
        margenInferior: activos.isEmpty ? 96 : 224,
        centro:
            yo ??
            activos.map((e) => e.institucion.latLng).nonNulls.firstOrNull ??
            _centroPorDefecto,
        recorrido: List.of(_recorrido),
        puntos: [
          for (final e in activos)
            if (e.institucion.latLng != null)
              PuntoMapa(
                id: 'envio-${e.id}',
                posicion: e.institucion.latLng!,
                tipo: TipoPunto.institucion,
                color: e.estado.color,
              ),
          for (final (i, c) in _enVivo.indexed)
            PuntoMapa(
              id: 'vivo-$i',
              posicion: c.posicion,
              tipo: TipoPunto.vehiculo,
              etiqueta: c.placa ?? c.nombre,
            ),
          if (yo != null)
            PuntoMapa(
              id: 'yo',
              posicion: yo,
              tipo: widget.user.role.canDriveRoute
                  ? TipoPunto.conductorPropio
                  : TipoPunto.yo,
            ),
        ],
        onTapPunto: (id) {
          final envio = activos.where((e) => 'envio-${e.id}' == id).firstOrNull;
          if (envio != null) mostrarDetalleEnvio(context, envio, widget.user);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ValueListenableBuilder<List<Envio>>(
      valueListenable: EnvioRepository.instance.envios,
      builder: (context, envios, _) {
        final activos = envios.where((e) => e.estado.esActivo).toList()
          ..sort(
            (a, b) => (a.programadoPara ?? DateTime(0)).compareTo(
              b.programadoPara ?? DateTime(0),
            ),
          );
        return Scaffold(
          body: Stack(
            children: [
              ValueListenableBuilder<EstiloMapa>(
                valueListenable: MapaBase.estilo,
                builder: (context, elegido, mapa) =>
                    elegido.es3d && MapaBase.hayMapbox
                    ? _mapaEn3d(activos, isDark)
                    : ColorFiltered(
                        // Mapbox tiene estilo nocturno propio; los demás se invierten.
                        colorFilter:
                            isDark && MapaBase.invertirEnOscuro(elegido)
                            ? const ColorFilter.matrix(<double>[
                                -0.85, 0, 0, 0, 255, //
                                0, -0.85, 0, 0, 255, //
                                0, 0, -0.85, 0, 255, //
                                0, 0, 0, 1, 0,
                              ])
                            : const ColorFilter.mode(
                                Colors.transparent,
                                BlendMode.dst,
                              ),
                        child: mapa,
                      ),
                child: FlutterMap(
                  mapController: _mapCtrl,
                  options: MapOptions(
                    initialCenter:
                        RastreoService.instance.posicion.value ??
                        activos
                            .map((e) => e.institucion.latLng)
                            .whereType<LatLng>()
                            .firstOrNull ??
                        _centroPorDefecto,
                    initialZoom: 13.5,
                  ),
                  children: [
                    ValueListenableBuilder<EstiloMapa>(
                      valueListenable: MapaBase.estilo,
                      builder: (context, estilo, _) => MapaBase.capa(
                        MapaBase.efectivo(estilo, oscuro: isDark),
                        retina: RetinaMode.isHighDensity(context),
                      ),
                    ),
                    if (_recorrido.length > 1)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _recorrido,
                            strokeWidth: 5,
                            color: PaeColors.accent,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        for (final e in activos)
                          if (e.institucion.latLng != null)
                            Marker(
                              point: e.institucion.latLng!,
                              width: 46,
                              height: 56,
                              child: GestureDetector(
                                onTap: () => mostrarDetalleEnvio(
                                  context,
                                  e,
                                  widget.user,
                                ),
                                child: _PinInstitucion(color: e.estado.color),
                              ),
                            ),
                        for (final c in _enVivo)
                          Marker(
                            point: c.posicion,
                            width: 120,
                            height: 60,
                            child: Tooltip(
                              message: [
                                c.nombre,
                                c.placa,
                              ].whereType<String>().join(' · '),
                              child: _PinVehiculo(
                                etiqueta: c.placa ?? c.nombre,
                              ),
                            ),
                          ),
                      ],
                    ),
                    ValueListenableBuilder<LatLng?>(
                      valueListenable: RastreoService.instance.posicion,
                      builder: (context, p, _) => MarkerLayer(
                        markers: [
                          if (p != null)
                            Marker(
                              point: p,
                              width: 48,
                              height: 48,
                              child: widget.user.role.canDriveRoute
                                  ? const _PinVehiculo()
                                  : const _PuntoAzul(),
                            ),
                        ],
                      ),
                    ),
                    ValueListenableBuilder<EstiloMapa>(
                      valueListenable: MapaBase.estilo,
                      builder: (context, estilo, _) => Padding(
                        // Encima del panel de envíos: el logo de Mapbox y la
                        // atribución deben quedar visibles (términos de uso).
                        padding: EdgeInsets.only(
                          bottom: activos.isEmpty ? 96 : 224,
                        ),
                        child: RichAttributionWidget(
                          // La clave fuerza a reconstruirla al cambiar de estilo.
                          key: ValueKey(estilo),
                          alignment: AttributionAlignment.bottomLeft,
                          attributions: MapaBase.atribuciones(estilo),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GradientHeader(
                  title: S.mapTitle,
                  subtitle: _esAdmin
                      ? S
                            .text(
                              'mapa.resumen_admin',
                              '{n} envíos activos · {c} conductores en vivo',
                              '{n} active deliveries · {c} live drivers',
                            )
                            .replaceAll('{n}', '${activos.length}')
                            .replaceAll('{c}', '${_enVivo.length}')
                      : S
                            .text(
                              'mapa.resumen',
                              '{n} envíos activos',
                              '{n} active deliveries',
                            )
                            .replaceAll('{n}', '${activos.length}'),
                  actions: [
                    if (MapaBase.disponibles.length > 1)
                      IconButton(
                        icon: const Icon(
                          Icons.layers_rounded,
                          color: Colors.white,
                        ),
                        onPressed: _elegirEstiloMapa,
                        tooltip: S.text(
                          'mapa.estilo',
                          'Estilo del mapa',
                          'Map style',
                        ),
                      ),
                    IconButton(
                      icon: const Icon(
                        Icons.my_location_rounded,
                        color: Colors.white,
                      ),
                      onPressed: _irAMiUbicacion,
                      tooltip: S.mapMyLocation,
                    ),
                    IconButton(
                      icon: _cargando
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.refresh_rounded,
                              color: Colors.white,
                            ),
                      onPressed: _cargando ? null : _refrescar,
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 100,
                left: 16,
                right: 16,
                child: Column(
                  children: [
                    ValueListenableBuilder<String?>(
                      valueListenable: RastreoService.instance.problema,
                      builder: (context, problema, _) => problema == null
                          ? const SizedBox.shrink()
                          : _Banner(
                              icono: Icons.gps_off_rounded,
                              texto: problema,
                              accion: S.text(
                                'gps.reintentar',
                                'Reintentar',
                                'Retry',
                              ),
                              onAccion: RastreoService.instance.reintentar,
                            ),
                    ),
                    if (widget.user.role.canDriveRoute)
                      const _EstadoTransmision(),
                    if (widget.user.role.canDriveRoute &&
                        activos.any(
                          (e) =>
                              e.estado == EstadoEnvio.enTransito &&
                              e.llegadaEn == null,
                        ))
                      const _AvisoSegundoPlano(),
                  ],
                ),
              ),
              Positioned(
                bottom: 16,
                left: 0,
                right: 0,
                child: _PanelEnvios(
                  envios: activos,
                  user: widget.user,
                  onIr: (e) {
                    final p = e.institucion.latLng;
                    if (p != null) _mover(p, 15);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Panel inferior ───────────────────────────────────────────────────────────

class _PanelEnvios extends StatefulWidget {
  const _PanelEnvios({
    required this.envios,
    required this.user,
    required this.onIr,
  });

  final List<Envio> envios;
  final AppUser user;
  final ValueChanged<Envio> onIr;

  @override
  State<_PanelEnvios> createState() => _PanelEnviosState();
}

class _PanelEnviosState extends State<_PanelEnvios> {
  // Se conserva entre reconstrucciones para no volver a la primera tarjeta
  // cada vez que llegan datos nuevos del servidor.
  final _paginas = PageController(viewportFraction: 0.92);

  @override
  void dispose() {
    _paginas.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final envios = widget.envios;
    final user = widget.user;
    if (envios.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _Tarjeta(
          child: Row(
            children: [
              const Icon(Icons.inbox_rounded, color: PaeColors.inactive),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  user.role.canDriveRoute
                      ? S.text(
                          'mapa.sin_envios_conductor',
                          'No tiene envíos asignados por ahora.',
                          'You have no assigned deliveries.',
                        )
                      : S.text(
                          'mapa.sin_envios',
                          'No hay envíos activos.',
                          'No active deliveries.',
                        ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      height: 200,
      child: PageView.builder(
        controller: _paginas,
        itemCount: envios.length,
        onPageChanged: (i) => widget.onIr(envios[i]),
        itemBuilder: (context, i) {
          final e = envios[i];
          final acciones = accionesEnvio(context, e, user);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: _Tarjeta(
              onTap: () => mostrarDetalleEnvio(context, e, user),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          e.codigo,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      StatusBadge(label: e.estado.label, color: e.estado.color),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    e.institucion.nombreCompleto,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    user.role.canDriveRoute
                        ? formatoFecha(e.programadoPara)
                        : '${formatoFecha(e.programadoPara)} · ${e.conductorNombre}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: PaeColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  if (user.role.canDriveRoute &&
                      e.llegadaEn != null &&
                      e.codigoVerificacion != null)
                    Text(
                      S
                          .text(
                            'mapa.esperando_confirmacion',
                            'Esperando confirmación · código {c}',
                            'Waiting for confirmation · code {c}',
                          )
                          .replaceAll('{c}', e.codigoVerificacion!),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: PaeColors.primary,
                      ),
                    )
                  else if (acciones.isNotEmpty)
                    acciones.first
                  else
                    Text(
                      S.text(
                        'mapa.ver_detalle',
                        'Toque para ver el detalle',
                        'Tap to see details',
                      ),
                      style: const TextStyle(
                        color: PaeColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Tarjeta extends StatelessWidget {
  const _Tarjeta({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark ? Colors.white12 : PaeColors.divider,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _EstadoTransmision extends StatelessWidget {
  const _EstadoTransmision();

  @override
  Widget build(BuildContext context) {
    final rastreo = RastreoService.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: rastreo.transmitiendo,
      builder: (context, activo, _) => ValueListenableBuilder<DateTime?>(
        valueListenable: rastreo.ultimoEnvio,
        builder: (context, ultimo, _) {
          final reciente =
              ultimo != null &&
              DateTime.now().difference(ultimo).inSeconds < 15;
          final texto = !activo
              ? S.text(
                  'vivo.pausado',
                  'Ubicación en vivo pausada',
                  'Live location paused',
                )
              : reciente
              ? S.text(
                  'vivo.activo',
                  'Compartiendo ubicación en vivo con la plataforma',
                  'Sharing live location with the platform',
                )
              : S.text(
                  'vivo.conectando',
                  'Conectando para compartir la ubicación…',
                  'Connecting to share location…',
                );
          return _Banner(
            icono: activo ? Icons.sensors_rounded : Icons.sensors_off_rounded,
            texto: texto,
            color: activo && reciente ? PaeColors.success : PaeColors.secondary,
            accion: activo
                ? S.text('vivo.pausar', 'Pausar', 'Pause')
                : S.text('vivo.reanudar', 'Reanudar', 'Resume'),
            onAccion: activo
                ? rastreo.pausarTransmision
                : rastreo.reanudarTransmision,
          );
        },
      ),
    );
  }
}

/// Durante un envío en tránsito, invita a seguir registrando el recorrido con
/// la pantalla bloqueada. Explica antes de pedir el permiso de Android.
class _AvisoSegundoPlano extends StatelessWidget {
  const _AvisoSegundoPlano();

  Future<void> _activar(BuildContext context) async {
    final aceptar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          S.text(
            'fondo.titulo',
            'Registrar el recorrido con la pantalla bloqueada',
            'Record the route with the screen locked',
          ),
        ),
        content: Text(
          S.text(
            'fondo.explicacion',
            'Mientras tengas un envío en camino, PAEGo seguirá enviando tu '
                'ubicación aunque bloquees el teléfono o uses otra app, y lo '
                'indicará con una notificación. En la siguiente pantalla elige '
                '"Permitir todo el tiempo". Se detiene al cerrar sesión.',
            'While a delivery is on its way, PAEGo will keep sending your '
                'location even if you lock the phone or use another app, and '
                'will show a notification. On the next screen choose "Allow '
                'all the time". It stops when you log out.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.text('fondo.ahora_no', 'Ahora no', 'Not now')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.text('fondo.continuar', 'Continuar', 'Continue')),
          ),
        ],
      ),
    );
    if (aceptar != true) return;
    final ok = await RastreoService.instance.activarSegundoPlano();
    if (ok || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          S.text(
            'fondo.negado',
            'Sin el permiso "Permitir todo el tiempo" el recorrido solo se '
                'registra con la app abierta. Puedes darlo en Ajustes > '
                'Aplicaciones > PAEGo > Ubicación.',
            'Without "Allow all the time" the route is only recorded while '
                'the app is open. You can grant it in Settings > Apps > PAEGo '
                '> Location.',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rastreo = RastreoService.instance;
    if (!rastreo.soportaSegundoPlano) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: rastreo.segundoPlano,
      builder: (context, activo, _) => ValueListenableBuilder<LatLng?>(
        valueListenable: rastreo.posicion,
        builder: (context, posicion, _) => activo || posicion == null
            ? const SizedBox.shrink()
            : _Banner(
                icono: Icons.lock_clock_rounded,
                texto: S.text(
                  'fondo.aviso',
                  'Con la pantalla bloqueada se deja de registrar el recorrido',
                  'The route stops recording when the screen is locked',
                ),
                accion: S.text('fondo.activar', 'Activar', 'Enable'),
                onAccion: () => _activar(context),
              ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icono,
    required this.texto,
    this.color = PaeColors.secondary,
    this.accion,
    this.onAccion,
  });

  final IconData icono;
  final String texto;
  final Color color;
  final String? accion;
  final VoidCallback? onAccion;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.only(left: 14, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icono, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                texto,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFamily: PaeTypography.fontBody,
                ),
              ),
            ),
          ),
          if (accion != null)
            TextButton(
              onPressed: onAccion,
              child: Text(
                accion!,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Marcadores ───────────────────────────────────────────────────────────────

class _PinInstitucion extends StatelessWidget {
  const _PinInstitucion({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.4),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: const Icon(
            Icons.school_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
        Icon(Icons.arrow_drop_down, color: color, size: 18),
      ],
    );
  }
}

class _PinVehiculo extends StatelessWidget {
  const _PinVehiculo({this.etiqueta});
  final String? etiqueta;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: PaeColors.primary,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: PaeColors.primary.withValues(alpha: 0.5),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(
            Icons.local_shipping_rounded,
            color: Colors.white,
            size: 18,
          ),
        ),
        if (etiqueta != null)
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              etiqueta!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

class _PuntoAzul extends StatelessWidget {
  const _PuntoAzul();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: PaeColors.secondary,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: PaeColors.secondary.withValues(alpha: 0.4),
              blurRadius: 10,
            ),
          ],
        ),
      ),
    );
  }
}

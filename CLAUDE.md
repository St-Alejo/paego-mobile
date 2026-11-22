# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es

App **móvil** Flutter de PAEGo (paquete `opaego`), la contraparte de la plataforma web Django que
vive en `../oPAEGo` (API REST + panel del administrador). Repo remoto:
`github.com/Dania2204/trabajo_Final_Flutter` (trabajo por PRs desde `feature/setup`).

Según el documento de tesis (`../oPAEGo/docs/`), la app la usan el **conductor** y la
**institución educativa**; además el **supervisor PAE** (rol nuevo, RF-39…42) registra qué
estudiantes reciben el PAE cada día. Está conectada a la API de `oPAEGo` (JWT); los usuarios se crean en la
web, la app solo inicia sesión. Contrato de la API: `/api/schema/` del backend.

## Comandos

```bash
flutter pub get
flutter run                      # requiere un archivo .env en la raíz (ver abajo)
flutter run -d chrome            # web: sqflite vía sqflite_common_ffi_web
flutter analyze                  # lints de flutter_lints
flutter test                     # modelos, cliente JWT y cola sin conexión
flutter test test/api_y_sincronizacion_test.dart --plain-name "sin red"
PAEGO_E2E_URL=http://127.0.0.1:8000 flutter test test/e2e   # punta a punta con backend real (seed_demo)
dart run flutter_launcher_icons  # regenerar íconos desde assets/images/pae_logo.png
```

- `.env` está declarado como asset en `pubspec.yaml`: si no existe, el build falla. Copiar
  `.env.example` → `.env` (está en `.gitignore`). `PAEGO_API_URL` = URL del backend
  (producción en Azure `https://azwafmsbgbksw4m22.azurewebsites.net`; Railway como alternativa; `http://10.0.2.2:8000` en emulador Android, `http://localhost:8000` en Chrome; para
  Chrome el backend necesita `CORS_ALLOWED_ORIGINS` con el origen de la app).
- Las pruebas de sqflite usan `sqflite_common_ffi` (dev dependency) y `http/testing.dart` MockClient.
  Cada archivo de pruebas que toca SQLite fija su propio `DatabaseHelper.nombreArchivo` (flutter test
  corre los archivos en paralelo). Las pruebas de widgets ponen `S.guardarTextosNuevos = false`
  (si no, `S.text` escribe en SQLite y quedan temporizadores pendientes). JSON real de un envío:
  `test/datos_prueba.dart`.

## Arquitectura

- `lib/main.dart`: sqflite (FFI en web), `.env`, `initializeDateFormatting('es')`, textos de Supabase.
- Rutas con nombre en `lib/core/router/app_router.dart` (`/`, `/login`, `/home` con `AppUser`).
  `HomeShell` arranca los servicios del usuario (`AuthService.iniciarServicios`), pide la
  aceptación de la Ley 1581 (RNF-11) y muestra `BarraSincronizacion`. Sin gestor de estado:
  singletons + `ValueNotifier`.

### Integración con oPAEGo (`lib/data/`)
- `remote/api_client.dart`: HTTP con JWT. Tokens en SharedPreferences; ante 401 renueva con el
  refresh (rota en cada uso, una renovación a la vez) y reintenta. Excepciones:
  `SinConexionException`, `SesionVencidaException` (refresh de 30 min vencido → volver a ingresar),
  `ApiException`.
- `repositories/auth_service.dart`: login `POST /api/auth/token/`, perfil guardado para abrir sin
  red, logout revoca el refresh (el backend saca al conductor del mapa en vivo).
- `sync/sync_service.dart`: **toda acción se encola** en la tabla SQLite `operaciones` con
  `uuid_cliente` + `ocurrido_en` y se envía a `POST /api/sincronizacion/lote/` (idempotente;
  RF-38). Reintenta al volver la red (connectivity_plus) y cada 30 s. Las rechazadas quedan con su
  motivo (pantalla Informes). Las fotos viajan en base64 dentro del JSON y se borran tras enviarse.
- `repositories/envio_repository.dart`: `GET /api/envios/` (30 días) con caché `envios_cache`, y
  acciones salida/llegada/ubicación/novedad/confirmar → cola. Aplica las operaciones pendientes
  sobre la caché (cambios optimistas) y recarga del servidor cuando el lote se aplica.
- `services/rastreo_service.dart`: GPS (`location`). Conductor: posición en vivo cada 3 s a
  `POST /api/monitoreo/mi-posicion/` (efímera, la ve el admin en "Hoy" de la web) + punto del
  recorrido (RF-21) cada `intervalo_ubicacion_seg` del servidor para envíos en tránsito (encolado).
  **Segundo plano** (conductor, durante un envío en tránsito): el mapa muestra un aviso → diálogo
  explicativo → `permission_handler` pide "Permitir todo el tiempo" *solo* (Android 11+ ignora la
  petición combinada que hace el plugin `location`) → `enableBackgroundMode` arranca el servicio en
  primer plano con notificación (`res/drawable/ic_stat_paego.xml`, protegido en `res/raw/keep.xml`).
  Se recuerda en `paego_segundo_plano` y se reactiva solo en cada sesión; `detener()` lo apaga.
  `permission_handler` fijado en ^12 (la 13 no compila con el Gradle del proyecto). En iOS, al
  generar el `Podfile`, definir `PERMISSION_LOCATION=1` y `PERMISSION_NOTIFICATIONS=1`.
  Si el GPS está apagado o sin permiso al
  iniciar, revisa cada 5 s y arranca solo (no repite "activar GPS"; el permiso lo pide una sola vez si nunca se pidió); `test/rastreo_test.dart` usa un
  `Location` falso (`usarLocation`).
- Modelos: `models/envio.dart` envuelve el JSON del `EnvioSerializer` (estados
  `ASIGNADO|EN_TRANSITO|ENTREGADO|CON_NOVEDAD|CANCELADO`). Roles: `CONDUCTOR→driver`,
  `INSTITUCION→rector`, `ADMINISTRADOR→admin`, `SUPERVISOR→supervisor` (`UserRoleX.fromBackend`); los getters de
  `user_role.dart` solo muestran/ocultan UI, los permisos reales los aplica la API.
- UI de envíos compartida en `lib/features/envios/envio_widgets.dart` (detalle, acciones por rol,
  novedad, confirmar recepción con código de 6 dígitos). Mapa, dashboard e informes leen de
  `EnvioRepository`/`SyncService`. Los usuarios se crean en la web (no hay pantalla de personal).
- SQLite `paego.db` versión 8: `app_texts`, `envios_cache`, `operaciones`, `estudiantes_cache`.
  La v6 borra las tablas del modo local anterior a la API (`users`, …); la v8 borra
  `plantillas_cache` y las operaciones `estudiante.autorizar|inscribir|revocar` de la cola.

### Supervisor PAE (`lib/features/supervisor/`, `repositories/estudiantes_repository.dart`)
- Entrega diaria por **código QR** único por estudiante (reemplazó al reconocimiento facial: no hay
  biometría, plantillas, cifrado ni autorización del acudiente). El QR impreso del carné contiene
  `PAEGO-E1:<codigo_qr>` (`prefijoQr`/`codigoDeQr` en `models/estudiante.dart`); `codigo_qr` es un
  token aleatorio del servidor y para el rol institución puede venir null.
- Pestañas propias en `HomeShell` (Cursos, Historial, Perfil); no maneja envíos. El rector ve la
  pestaña de solo lectura "Estudiantes" (`estudiantes_hoy_screen.dart`, `GET /api/estudiantes/cursos/`, en línea).
- Pantallas: `cursos_screen.dart` (avance del día por curso + "Escanear QR" de toda la institución),
  `curso_screen.dart` (búsqueda, filtros, botón principal "Escanear QR"), `estudiante_screen.dart`
  (ficha con el QR grande vía `qr_flutter`, estado de hoy y "Entrega manual" con motivo),
  `escaner_qr_screen.dart` (`mobile_scanner` continuo → hoja de confirmación → registra y sigue;
  avisa QR ajeno, no encontrado en la institución y "ya recibió hoy"; háptica),
  `historial_screen.dart`, piezas comunes en `supervisor_comun.dart`. Las pruebas inyectan el
  lector con `EscanerQrScreen(lector: …)` o `EscanerQrScreen.lectorDePrueba`.
- Descarga la institución (`GET /api/estudiantes/?page_size=500`) a `estudiantes_cache`; el avance
  por curso se calcula en el teléfono. `entrega_del_dia` de la caché solo cuenta si su fecha es hoy.
  `porCodigoQr` busca en la caché (sin red).
- Única acción: `estudiante.entregar` `{estudiante, metodo: QR|MANUAL, fecha, codigo | motivo}` →
  cola de `SyncService` (sin red), aplicada al instante sobre la lista; el servidor rechaza con
  `qr_invalido` o `duplicada`. Entregas antiguas con `metodo` `FACIAL` se muestran como
  "Reconocimiento facial". Historial = operaciones `estudiante.*` de la cola. Al cerrar sesión se
  borra `estudiantes_cache`.

### Mapa base (`lib/core/config/mapa_base.dart`)
- `flutter_map` (código abierto) con teselas del servicio **Static Basemap Tiles de ArcGIS
  Location Platform** si `ARCGIS_API_KEY` está en `.env`; sin clave, OpenStreetMap. Teselas de
  512 px → `tileSize: 512` + `zoomOffset: -1`; URL `.../v1/{familia}/{estilo}/static/tile/{z}/{y}/{x}?token=`
  (fila antes que columna). Capa gratuita: 2 M teselas/mes, sin tope automático → restringir la
  clave en location.arcgis.com. Atribución "Powered by Esri" obligatoria. El estilo elegido se
  guarda en SharedPreferences (`paego_estilo_mapa`). El SDK oficial `arcgis_maps` no se usa:
  es solo Android/iOS (no web) y exige licencia para producción.
- Debug Android permite HTTP sin TLS (`android/app/src/debug/AndroidManifest.xml`) para probar
  contra el backend local con `adb reverse tcp:8000 tcp:8000` y `PAEGO_API_URL=http://localhost:8000`.

### Otros
- Textos bilingües (`lib/core/l10n/app_strings.dart`, clase `S`): `S.text('clave', 'es', 'en')`
  o `_t('es','en')` (clave = hash FNV del texto: cambiar el texto cambia la clave). Se sincronizan
  con la tabla Supabase `app_texts`.
- Nutrición: el chat va a `POST /api/nutricion/asistente/` (`lib/data/remote/nutricion_api.dart`);
  el backend consulta Gemini con su propia clave (la app no tiene ninguna). Si falla (sin red,
  503 sin clave en el servidor, 502) se muestra un consejo local marcado como error.

## CI/CD (`.github/`)

- Secreto opcional `ARCGIS_API_KEY` (mapas de ArcGIS en los builds de CI y release).
- `ci.yml`: `flutter analyze` (cualquier aviso, incluso info, bloquea), `dart format
  --set-exit-if-changed lib test` (bloquea: formatear antes de commitear), `flutter test --coverage`
  con un archivo generado que importa todo `lib/` (cobertura real, con pantallas) y mínimo
  `COBERTURA_MINIMA` (25 %; subirlo al agregar pruebas), builds web y
  APK como artefactos. Crea `.env` con `PAEGO_API_URL` (variable de repo opcional).
  Job `e2e`: Postgres + backend de `Dania2204/oPAEGo` (rama `vars.OPAEGO_REF`, por defecto `main`)
  con `seed_demo`, y `flutter test test/e2e`: admin crea un envío por el lote, el conductor sale
  sin red (cola) y sincroniza, recorrido, llegada, mapa del admin y confirmación de la institución
  con el código. Sin `PAEGO_E2E_URL` esas pruebas se saltan (en `flutter test` normal).
- `release.yml`: con un tag `v*` compila el APK y lo publica en un GitHub Release. Firma con la
  keystore propia si existen los secretos `ANDROID_KEYSTORE_BASE64` (`base64 -w0 paego.jks`),
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` (crea
  `android/key.properties`, fuera de git); sin ellos, firma debug con aviso. `build.gradle.kts` usa
  `key.properties` si existe. applicationId / bundle id: `co.paego.app` (el namespace Kotlin sigue
  `com.example.opaego`). Perder la keystore impide actualizar la app instalada: guardarla aparte.
- Dependabot para pub y GitHub Actions.

## Pendientes conocidos

- La clave de Gemini que estuvo versionada en `.env.example` sigue en el historial de git: rotarla.

## Reglas del usuario

- Git: commits en ramas de feature (no en `main`), Conventional Commits en español, autor Steven,
  nunca atribución a Claude (hook `commit-msg`). Preguntar antes de `git push` o abrir PR: el
  remoto es de la compañera (Dania2204).
- Interfaz y mensajes en español (con traducción inglés vía `S`).

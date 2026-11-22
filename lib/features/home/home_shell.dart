import 'package:flutter/material.dart';
import '../../app/theme.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/router/app_router.dart';
import '../../data/repositories/auth_service.dart';
import '../../data/sync/sync_service.dart';
import '../../data/models/user_model.dart';
import '../../data/models/user_role.dart';
import '../dashboard/dashboard_screen.dart';
import '../map/map_screen.dart';
import '../nutrition/nutrition_screen.dart';
import '../reports/reports_screen.dart';
import '../profile/profile_screen.dart';
import '../supervisor/cursos_screen.dart';
import '../supervisor/estudiantes_hoy_screen.dart';
import '../supervisor/historial_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.user,
    required this.onToggleTheme,
    required this.themeMode,
    required this.onToggleLanguage,
    required this.locale,
  });

  final AppUser user;
  final VoidCallback onToggleTheme;
  final ThemeMode themeMode;
  final VoidCallback onToggleLanguage;
  final String locale;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    // Cola sin conexión, envíos y GPS (posición en vivo del conductor).
    AuthService.instance.iniciarServicios();
    if (!widget.user.aceptoTratamientoDatos) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _pedirAceptacionDatos(),
      );
    }
  }

  /// RNF-11: aceptación de la política de tratamiento de datos (Ley 1581).
  Future<void> _pedirAceptacionDatos() async {
    if (!mounted) return;
    final acepta = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(
          S.text(
            'datos.titulo',
            'Tratamiento de datos personales',
            'Personal data processing',
          ),
        ),
        content: Text(
          S.text(
            'datos.texto',
            'PAEGo registra su ubicación durante los recorridos, las novedades y las '
                'evidencias de entrega para el seguimiento del Programa de Alimentación '
                'Escolar, conforme a la Ley 1581 de 2012. ¿Acepta la política de '
                'tratamiento de datos?',
            'PAEGo records your location during routes, incidents and delivery '
                'evidence to monitor the School Feeding Programme, under Colombian '
                'Law 1581 of 2012. Do you accept the data processing policy?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(S.text('datos.rechazar', 'No acepto', 'Decline')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(S.text('datos.aceptar', 'Acepto', 'Accept')),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (acepta != true) {
      await AuthService.instance.logout();
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, AppRouter.login, (_) => false);
      return;
    }
    final r = await AuthService.instance.aceptarTratamientoDatos();
    if (!r.isSuccess && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(r.error!)));
    }
  }

  Widget _perfil(AppUser u) => ProfileScreen(
    user: u,
    onToggleTheme: widget.onToggleTheme,
    themeMode: widget.themeMode,
    onToggleLanguage: () {
      widget.onToggleLanguage();
      // force home shell rebuild too
      setState(() {});
    },
    locale: widget.locale,
  );

  List<_TabDef> _buildTabs() {
    final u = widget.user;
    // Supervisor PAE: solo la entrega por estudiante (no maneja envíos).
    if (u.role.canRegisterStudents) {
      return [
        _TabDef(
          icon: Icons.groups_rounded,
          label: S.text('nav.cursos', 'Cursos', 'Classes'),
          screen: const SupervisorCursosScreen(),
        ),
        _TabDef(
          icon: Icons.history_rounded,
          label: S.text('nav.historial', 'Historial', 'History'),
          screen: const HistorialSupervisorScreen(),
        ),
        _TabDef(
          icon: Icons.person_rounded,
          label: S.navProfile,
          screen: _perfil(u),
        ),
      ];
    }
    return [
      _TabDef(
        icon: Icons.dashboard_rounded,
        label: S.navHome,
        screen: DashboardScreen(user: u),
      ),
      _TabDef(
        icon: Icons.map_rounded,
        label: S.navMap,
        screen: MapScreen(user: u),
      ),
      _TabDef(
        icon: Icons.assignment_rounded,
        label: S.navReports,
        screen: ReportsScreen(user: u),
      ),
      _TabDef(
        icon: Icons.restaurant_menu_rounded,
        label: S.navNutrition,
        screen: NutritionScreen(user: u),
      ),
      // Institución: consulta quién recibió el PAE hoy (solo lectura).
      if (u.role.canViewStudents)
        _TabDef(
          icon: Icons.groups_rounded,
          label: S.text('nav.estudiantes', 'Estudiantes', 'Students'),
          screen: const EstudiantesHoyScreen(),
        ),
      _TabDef(
        icon: Icons.person_rounded,
        label: S.navProfile,
        screen: _perfil(u),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _buildTabs();

    // guard index if tabs shrink (shouldn't happen but defensive)
    if (_currentIndex >= tabs.length) _currentIndex = 0;

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: tabs.map((t) => t.screen).toList(),
            ),
          ),
          const BarraSincronizacion(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: PaeColors.primary.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          items: tabs
              .map(
                (t) =>
                    BottomNavigationBarItem(icon: Icon(t.icon), label: t.label),
              )
              .toList(),
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
      ),
    );
  }
}

class _TabDef {
  const _TabDef({
    required this.icon,
    required this.label,
    required this.screen,
  });

  final IconData icon;
  final String label;
  final Widget screen;
}

/// Franja inferior con el estado de la sincronización con la plataforma web:
/// sin conexión, operaciones pendientes, rechazadas o sesión vencida.
class BarraSincronizacion extends StatelessWidget {
  const BarraSincronizacion({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EstadoSync>(
      valueListenable: SyncService.instance.estado,
      builder: (context, e, _) {
        String? texto;
        Color color = PaeColors.secondary;
        IconData icono = Icons.cloud_upload_rounded;
        Widget? accion;

        if (e.sesionVencida) {
          texto = S.text(
            'sync.sesion_vencida',
            'La sesión venció. Ingrese de nuevo para enviar los datos.',
            'Session expired. Sign in again to upload your data.',
          );
          color = PaeColors.error;
          icono = Icons.lock_clock_rounded;
          accion = TextButton(
            onPressed: () => Navigator.pushNamedAndRemoveUntil(
              context,
              AppRouter.login,
              (_) => false,
            ),
            child: Text(
              S.text('sync.ingresar', 'Ingresar', 'Sign in'),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          );
        } else if (!e.enLinea) {
          texto = e.pendientes > 0
              ? S
                    .text(
                      'sync.offline_pendientes',
                      'Sin conexión · {n} cambios guardados en el teléfono',
                      'Offline · {n} changes saved on the phone',
                    )
                    .replaceAll('{n}', '${e.pendientes}')
              : S.text(
                  'sync.offline',
                  'Sin conexión · los cambios se guardan en el teléfono',
                  'Offline · changes are saved on the phone',
                );
          color = PaeColors.warning;
          icono = Icons.wifi_off_rounded;
        } else if (e.pendientes > 0) {
          texto = S
              .text(
                'sync.enviando',
                'Enviando {n} cambios a la plataforma…',
                'Sending {n} changes to the platform…',
              )
              .replaceAll('{n}', '${e.pendientes}');
        } else if (e.rechazadas > 0) {
          texto = S
              .text(
                'sync.rechazadas',
                '{n} cambios fueron rechazados por el servidor (ver Informes)',
                '{n} changes were rejected by the server (see Reports)',
              )
              .replaceAll('{n}', '${e.rechazadas}');
          color = PaeColors.error;
          icono = Icons.error_outline_rounded;
        }

        return AnimatedSize(
          duration: const Duration(milliseconds: 250),
          child: texto == null
              ? const SizedBox(width: double.infinity)
              : Material(
                  color: color,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Icon(icono, color: Colors.white, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            texto,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              fontFamily: PaeTypography.fontBody,
                            ),
                          ),
                        ),
                        ?accion,
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}

import '../../core/l10n/app_strings.dart';

enum UserRole { superAdmin, admin, rector, driver, supervisor }

extension UserRoleX on UserRole {
  String get label {
    switch (this) {
      case UserRole.superAdmin:
        return S.roleSuperAdmin;
      case UserRole.admin:
        return S.roleAdmin;
      case UserRole.rector:
        return S.roleRector;
      case UserRole.driver:
        return S.roleDriver;
      case UserRole.supervisor:
        return S.roleSupervisor;
    }
  }

  String get description {
    switch (this) {
      case UserRole.superAdmin:
        return S.roleDescSuperAdmin;
      case UserRole.admin:
        return S.roleDescAdmin;
      case UserRole.rector:
        return S.roleDescRector;
      case UserRole.driver:
        return S.roleDescDriver;
      case UserRole.supervisor:
        return S.roleDescSupervisor;
    }
  }

  // Los permisos reales los decide la API de oPAEGo (RF-06); estos getters
  // solo muestran u ocultan opciones en la app. La gestión de usuarios,
  // instituciones y envíos la hace el administrador en la plataforma web.

  bool get canViewAllReports =>
      this == UserRole.superAdmin || this == UserRole.admin;

  /// Conductor: salida, recorrido, llegada (RF-19 a RF-23).
  bool get canDriveRoute => this == UserRole.driver;

  /// Institución educativa: confirma la recepción (RF-24 a RF-28).
  bool get canConfirmReception => this == UserRole.rector;

  /// Supervisor PAE: registra la entrega diaria (QR del estudiante o manual).
  bool get canRegisterStudents => this == UserRole.supervisor;

  /// Quién consulta la entrega del PAE por estudiante (solo lectura el rector).
  bool get canViewStudents =>
      this == UserRole.supervisor || this == UserRole.rector;

  bool get canSubmitReport =>
      this == UserRole.rector || this == UserRole.driver;

  List<UserRole> get creatableRoles => const [];

  /// Rol del backend (`cuentas.Rol`) → rol de la app.
  static UserRole fromBackend(String? rol) {
    switch (rol) {
      case 'ADMINISTRADOR':
        return UserRole.admin;
      case 'INSTITUCION':
        return UserRole.rector;
      case 'SUPERVISOR':
        return UserRole.supervisor;
      case 'CONDUCTOR':
      default:
        return UserRole.driver;
    }
  }

  static UserRole fromString(String v) => UserRole.values.firstWhere(
    (e) => e.name == v,
    orElse: () => UserRole.driver,
  );
}

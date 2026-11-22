import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_model.dart';
import '../models/user_role.dart';
import '../remote/api_client.dart';
import '../services/rastreo_service.dart';
import '../sync/sync_service.dart';
import 'envio_repository.dart';
import 'estudiantes_repository.dart';

/// Sesión del usuario contra la API de la plataforma web PAEGo (RF-01, RF-02).
///
/// Los usuarios los crea el administrador en la web; la app solo inicia
/// sesión. El perfil y los tokens se guardan en el teléfono para que la app
/// abra sin conexión y siga registrando operaciones en la cola (RF-38).
class AuthService {
  AuthService._();
  static final instance = AuthService._();

  static const _kUsuario = 'paego_usuario';

  AppUser? _currentUser;

  AppUser? get currentUser => _currentUser;
  bool get isLoggedIn => _currentUser != null;

  /// Restaura la sesión guardada (sin red) y, si hay conexión, refresca el perfil.
  Future<void> init() async {
    await ApiClient.instance.cargarTokens();
    final prefs = await SharedPreferences.getInstance();
    final guardado = prefs.getString(_kUsuario);
    if (guardado == null) return;
    try {
      _currentUser = AppUser.fromPerfil(
        (jsonDecode(guardado) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      await prefs.remove(_kUsuario);
      return;
    }
    try {
      final perfil = await ApiClient.instance.get('/auth/yo/');
      await _guardarUsuario(
        AppUser.fromPerfil((perfil as Map).cast<String, dynamic>()),
      );
    } catch (_) {
      // Sin conexión o sesión vencida: se sigue con el perfil guardado.
    }
  }

  /// Arranca los servicios que dependen del usuario (cola, envíos, GPS).
  Future<void> iniciarServicios() async {
    final user = _currentUser;
    if (user == null) return;
    await SyncService.instance.iniciar(user.id!);
    if (user.role.canRegisterStudents) {
      // El supervisor no maneja envíos: solo estudiantes de su institución.
      await EstudiantesRepository.instance.iniciar(user.id!);
      return;
    }
    await EnvioRepository.instance.iniciar(user.id!);
    EnvioRepository.instance.refrescar().then((_) {}, onError: (_) {});
    await RastreoService.instance.iniciar(esConductor: user.role.canDriveRoute);
  }

  Future<AuthResult> register({
    required String fullName,
    required String email,
    required String phone,
    required String idNumber,
    required String password,
    required String role,
    String? institution,
    String? photoPath,
  }) async {
    return AuthResult.failure(
      'Los usuarios los crea el administrador en la plataforma web.',
    );
  }

  Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    try {
      final perfil = await ApiClient.instance.iniciarSesion(email, password);
      final user = AppUser.fromPerfil(perfil);
      if (_currentUser != null && _currentUser!.id != user.id) {
        await _detenerServicios();
      }
      await _guardarUsuario(user);
      return AuthResult.success(user);
    } on SinConexionException {
      return AuthResult.failure(
        'No hay conexión con el servidor. El primer ingreso necesita internet.',
      );
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        return AuthResult.failure('Correo o contraseña incorrectos.');
      }
      if (e.statusCode == 429) {
        // El servidor limita los intentos por conexión (fuerza bruta).
        return AuthResult.failure(
          'Demasiados intentos. Espere un minuto e intente de nuevo.',
        );
      }
      return AuthResult.failure(e.mensaje);
    } catch (_) {
      return AuthResult.failure('No se pudo iniciar sesión. Intente de nuevo.');
    }
  }

  /// RNF-11: registra en el servidor la aceptación de la política de datos.
  Future<AuthResult> aceptarTratamientoDatos() async {
    try {
      final perfil = await ApiClient.instance.post(
        '/auth/aceptar-tratamiento-datos/',
      );
      final user = AppUser.fromPerfil((perfil as Map).cast<String, dynamic>());
      await _guardarUsuario(user);
      return AuthResult.success(user);
    } on ApiException catch (e) {
      return AuthResult.failure(e.mensaje);
    } catch (e) {
      return AuthResult.failure(e.toString());
    }
  }

  Future<void> logout() async {
    // Antes de salir se intenta enviar lo pendiente; si no hay red, queda
    // guardado en el teléfono y se envía la próxima vez que este usuario ingrese.
    try {
      await SyncService.instance.sincronizar();
    } catch (_) {}
    await _detenerServicios();
    // Datos de menores: no quedan en el teléfono.
    await EstudiantesRepository.instance.borrarDatos();
    await ApiClient.instance.cerrarSesion();
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUsuario);
  }

  Future<void> _detenerServicios() async {
    await RastreoService.instance.detener();
    await EnvioRepository.instance.detener();
    await EstudiantesRepository.instance.detener();
    await SyncService.instance.detener();
  }

  Future<void> _guardarUsuario(AppUser user) async {
    _currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUsuario, jsonEncode(user.toSesion()));
  }
}

class AuthResult {
  AuthResult.success(this.user) : error = null;
  AuthResult.failure(this.error) : user = null;

  final AppUser? user;
  final String? error;

  bool get isSuccess => user != null;
}

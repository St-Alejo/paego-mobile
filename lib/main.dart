import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'app/app.dart';
import 'core/config/mapa_base.dart';
import 'core/l10n/app_strings.dart';
import 'data/repositories/app_text_sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kIsWeb) {
    databaseFactory = databaseFactoryFfiWebNoWebWorker;
  }

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // The app can still run with local defaults when .env is absent.
  }

  // Token de Mapbox para el mapa 3D (si está en .env).
  MapaBase.configurar();

  await initializeDateFormatting('es');

  // Textos de la interfaz desde Supabase (si no hay red, se usan los locales).
  try {
    await AppTextSyncService.instance.pullRemoteTexts();
  } catch (_) {}
  await S.loadFromDatabase();
  await S.seedDefaults();
  AppTextSyncService.instance.pushLocalTexts().catchError((_) {});

  // Force portrait orientation
  if (!kIsWeb) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  if (!kIsWeb) {
    // Transparent status bar
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );
  }

  runApp(const PaeGoApp());
}

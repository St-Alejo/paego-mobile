# Ramas y versiones de la app móvil

- `main`: siempre compila y pasa `flutter analyze` y `flutter test`.
- Ramas de trabajo desde `main`: `feat/`, `fix/`, `docs/`, `ci/`; se integran por pull request.
- Versiones: un tag `vX.Y.Z` en `main` dispara `release.yml`, que publica el APK.
- La app consume la API de oPAEGo; un cambio que dependa de un endpoint nuevo se
  fusiona después del PR correspondiente del backend.

Los pull requests se reflejan en el tablero "2. Sprints y tareas" de monday.

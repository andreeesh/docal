# Docal Desktop

Docal Desktop es la base técnica de una futura aplicación de escritorio multiplataforma para administrar instalaciones locales de WordPress. En esta fase ofrece una interfaz de solo lectura, un modo de demostración con fixtures ficticios y una consulta nativa de información del sistema. No ejecuta la CLI ni consulta Docker.

## Arquitectura

```text
React UI → Application Layer → DocalAdapter → Tauri IPC → Rust Backend
                                                        → Future Platform Adapter
                                                        → Existing Docal CLI
                                                        → Docker Engine
```

React presenta datos y estados; no conoce comandos de Bash ni rutas de Docker. La comunicación nativa se concentra en `TauriDocalAdapter`, y el backend Rust expone únicamente `get_runtime_info`. La CLI actual seguirá siendo la fuente de verdad y el único motor de operaciones.

### Decisiones arquitectónicas (ADR-001)

- **La CLI como motor único:** conservar reglas de negocio, configuración y ciclo de vida en una implementación ya existente evita duplicar el motor WordPress y reduce divergencias entre Desktop y terminal.
- **React no ejecuta comandos del sistema:** la UI no accede al filesystem del host, no usa APIs de Node ni crea procesos. Tauri IPC separa presentación y capacidades nativas, y permite validar los parámetros en un backend acotado.
- **Adaptadores separados por plataforma:** Windows/WSL2, Linux nativo y macOS tienen mecanismos y supuestos distintos. Un adaptador explícito por plataforma evita asumir rutas, distribuciones o servicios comunes.
- **Sin operaciones Docker en esta fase:** primero se define y valida el límite de seguridad. La versión actual informa el OS del proceso nativo y declara el motor Docal como desconectado; no invoca CLI, Docker, WSL ni procesos externos.

### Integración futura con la CLI

En Windows la aplicación correrá de forma nativa y el motor seguirá dentro de la distribución WSL2 que el usuario seleccione. No se supone Ubuntu ni se implementa esa comunicación en esta fase. Linux podrá tener un adaptador nativo. macOS tendrá un adaptador propio cuando exista soporte validado; no se instalará Docker Desktop ni otra virtualización automáticamente.

Los futuros contratos deberán usar comandos JSON estructurados, validar parámetros y devolver errores estables. No se construirán comandos por concatenación de strings de shell. Las operaciones destructivas exigirán validación y confirmación en el backend.

Antes de conectar el listado de sitios, hay que resolver una propiedad del CLI actual: algunas consultas, incluido `docal list --json`, pasan por un preflight que puede intentar inicializar Docker. Desktop necesitará una interfaz de lectura sin efectos secundarios. Esta fase no cambia la CLI para resolverlo.

## Requisitos de desarrollo

- Node.js 22 LTS y npm 10 o compatible con `package-lock.json`.
- Rust estable y Cargo; el manifiesto fija MSRV 1.90, acorde a las versiones de Tauri 2 bloqueadas en `Cargo.lock`.
- Linux: dependencias nativas de Tauri/WebKitGTK 4.1, entre ellas `build-essential`, `libwebkit2gtk-4.1-dev`, `libxdo-dev`, `libssl-dev`, `librsvg2-dev` y `libayatana-appindicator3-dev`.
- Windows: Microsoft C++ Build Tools y WebView2 Runtime para compilar/ejecutar Tauri.
- macOS: Xcode Command Line Tools y las dependencias nativas de Tauri para macOS.

No se requiere Docker Desktop. No se instala Docker, WSL2, WordPress ni dependencias del sistema automáticamente.

## Desarrollo

Desde esta carpeta (`desktop/`):

```sh
npm ci
npm run dev:mock
```

El modo mock sirve la interfaz en `http://127.0.0.1:1420`. Para iniciar la ventana nativa Tauri:

```sh
npm run tauri dev
```

La ventana usa Vite en modo normal, por lo que el backend nativo solo comunica el OS y la lista de sitios aparece como no implementada. Tauri toma sus comandos de `src-tauri/tauri.conf.json`.

## Adaptadores

- **MockDocalAdapter:** fixtures estáticos, deterministas y ficticios (`demo-wordpress`, `test-shop`, `local-blog`). Responde con `dataSource: "mock"`, runtime desconocido y Docal desconectado. La UI siempre lo anuncia como modo demostración. No hay conexión de red.
- **TauriDocalAdapter:** consulta únicamente `get_runtime_info` por el `invoke` oficial de Tauri y valida la respuesta externa en tiempo de ejecución. `listSites()` rechaza con `NOT_IMPLEMENTED`; no simula una consulta correcta.
- **UnavailableDocalAdapter:** se selecciona en un navegador normal; informa que el backend está desconectado y rechaza el listado con `BACKEND_UNAVAILABLE`.
- **Factory:** el modo Vite `mock` tiene prioridad; de otro modo utiliza `isTauri()` del API oficial; si no hay runtime, selecciona el adaptador no disponible. Un fallo del backend nunca cambia silenciosamente a datos simulados. El build de producción no selecciona mock automáticamente.

## Validación

```sh
npm run typecheck
npm run lint
npm run test:run
npm run build

cargo fmt --manifest-path src-tauri/Cargo.toml --check
cargo clippy --manifest-path src-tauri/Cargo.toml -- -D warnings
cargo test --manifest-path src-tauri/Cargo.toml
cargo check --manifest-path src-tauri/Cargo.toml
```

Los tests del frontend y Rust no requieren Docker ni una instalación de Docal. GitHub Actions ejecuta estas validaciones en Ubuntu 24.04; también compila y prueba Rust en Windows.

## Limitaciones actuales y compatibilidad

- **Windows/WSL2:** configurado para que el backend nativo reporte `windows`; no detecta WSL2 ni se comunica con distribuciones. La integración está pendiente y aún no está validada en este cambio.
- **Linux:** el código Rust identifica Linux y la CI compila/prueba en Ubuntu 24.04 con WebKitGTK 4.1. Esto no demuestra compatibilidad con todas las distribuciones.
- **macOS:** el mapeo de OS contempla macOS, pero no hay ejecución ni compilación de CI macOS en esta fase. Docal no tiene soporte macOS validado.
- No hay operaciones de sitios, conexión con Docker, backend HTTP, servicio residente ni base de datos.

## Política de seguridad

- Capacidad Tauri restringida a la ventana `main` y sin permisos de plugins.
- Sin plugins Shell, FS o HTTP, ejecución de procesos, sidecars ni APIs de escritura.
- CSP restrictiva para contenido local e IPC; no se cargan fuentes, imágenes o scripts externos.
- Sin navegación remota, auto-updates, telemetría, analytics ni llamadas a servicios externos.
- No hay credenciales, secretos ni datos de configuración de WordPress en el modelo de sitio.

## Próximos pasos

1. Definir una consulta de lectura en la CLI que garantice ausencia de efectos secundarios.
2. Acordar un contrato JSON estable y errores tipados con validación del lado Rust.
3. Diseñar y revisar el adaptador Windows/WSL2 con selección explícita de distribución.
4. Implementar adaptadores Linux y macOS por separado cuando el soporte esté validado.
5. Añadir operaciones explícitas una por una, con confirmación backend para cambios destructivos.

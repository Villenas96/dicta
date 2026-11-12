# Dicta — dictado por voz en español para Mac y Windows

Pulsas un atajo, hablas y el texto **corregido** aparece en la casilla donde estás
escribiendo, también en la terminal. La voz se transcribe **en tu ordenador** y la
corrección la hace **tu propia IA con tu suscripción** (Claude Code o Codex), sin
claves de API.

**👉 [Guía de instalación para alumnos](docs/INSTALACION.md)** ·
**[Descargas](https://github.com/Villenas96/dicta/releases/latest)**

## Instalación rápida

Mac (Terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/Villenas96/dicta/main/scripts/install-mac.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/Villenas96/dicta/main/scripts/install-windows.ps1 | iex
```

## Qué hace

| | |
|---|---|
| **Atajo** | Mantener para hablar · doble toque = manos libres · Esc cancela (⌥ derecha en Mac, Ctrl derecho en Windows) |
| **Indicador** | Píldora flotante con micro, onda y transcripción en vivo; se aparta de tu casilla |
| **Autocorrección** | «el viernes, bueno no, mejor el jueves» → «el jueves» |
| **Modo edición** | Selecciona texto + Mayús + atajo: sustitúyelo o da una instrucción («hazlo más formal») |
| **Continuidad** | Si sigues dictando en la misma casilla, continúa la frase tal cual |
| **Pegado universal** | Ctrl/⌘+V en apps; Mayús+Insert en terminales de Windows. Si no hay casilla, al portapapeles |
| **Historial y diccionario** | Todo lo dictado; palabras propias con «se oye como» (whisper → Wispr) |
| **Tu IA** | Claude Code (Claude Pro/Max) o Codex (ChatGPT), precalentados para responder en ~1,5–4 s |

## Cómo funciona

```
Atajo global ─► Micrófono ─► Voz → texto (local) ─► Diccionario ─► Tu IA corrige ─► Pegar
 CGEventTap /     AVAudioEngine /   SpeechAnalyzer (Mac)            Claude Code /     ⌘V · Ctrl+V ·
 WH_KEYBOARD_LL   NAudio            Whisper.cpp (Windows)           Codex             Mayús+Insert
```

El diseño sale del análisis con REA de Wispr Flow y Typeless:
[docs/ANALISIS-REA.md](docs/ANALISIS-REA.md).

## Estructura

| Carpeta | Contenido |
|---|---|
| `Sources/DictaCore`, `Sources/Dicta` | App de Mac (Swift, barra de menús) |
| `windows/src/Dicta.Core`, `windows/src/Dicta` | App de Windows (.NET 10, WPF, bandeja del sistema) |
| `Tests/`, `windows/tests/` | Tests del núcleo (atajo, diccionario, edición, colocación…) |
| `scripts/` | Compilar, empaquetar e instaladores de una línea |
| `.github/workflows/windows.yml` | Compila Windows y adjunta `Dicta-Setup.exe` a cada versión |

## Desarrollo

### Mac
Requiere macOS 26 y las Command Line Tools de Xcode.

```bash
./scripts/build-app.sh --install
```

```bash
swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Paquetes para repartir (`.dmg` y `.zip`, Intel + Apple Silicon):

```bash
./scripts/package-mac.sh
```

Prueba del motor sin micrófono:

```bash
say -v 'Eddy (Spanish (Spain))' -o /tmp/prueba.aiff "quiero algo para el viernes, bueno no, mejor para el jueves"
```

```bash
dist/Dicta.app/Contents/MacOS/Dicta --selftest /tmp/prueba.aiff
```

Firma estable (opcional; así macOS recuerda los permisos entre compilaciones):

```bash
./scripts/create-signing-cert.sh
```

### Windows
Se compila en GitHub Actions al publicar una versión. Para compilar desde Mac/Linux con
Docker (comprueba que compila; ejecutarla requiere Windows):

```bash
docker run --rm -v "$PWD/windows:/w" -w /w/src/Dicta mcr.microsoft.com/dotnet/sdk:10.0 dotnet build -c Release
```

# Análisis con REA: Wispr Flow y Typeless

Fecha: 2026-11-12 · Herramienta: REA 6.8.0 (MCP + CLI) · Apps analizadas en `/Applications`.

Todo lo que aparece aquí es **análisis estático** de los binarios instalados (no se ha
observado su ejecución ni su tráfico). Separo lo **observado** (está en el binario) de lo
**inferido** (deducción mía a partir de lo observado).

## 1. Qué son por dentro

| | Wispr Flow | Typeless |
|---|---|---|
| Tipo (REA `inspect_desktop_application`) | Electron (`app.asar`, 140 MB) + app Swift auxiliar (`swift-helper-app-dist/Wispr Flow.app`, v1.6.1446) | Electron (`app.asar`, 248 MB) + 6 dylibs Swift en `Resources/lib` |
| JS principal | `.webpack/main/index.js` (10,6 MB, minificado) | `dist/main/index.js` (647 KB, **ofuscado**: `_0x1edb3d(0x545)`) |
| Captura de audio | En el renderer de Electron (Web Audio + **AudioWorklet**) | En el renderer de Electron + `libopusenc`/`libopuschunk` |
| Transcripción | En la nube: `wss://api.wisprflow.ai/` (streaming por WebSocket, protobuf `flow_api.v1.Payload`) | En la nube: `https://api.typeless.com` |

Evidence REA: `ev_be62ae82…` (inventario Wispr), `ev_0ce42924…` (inventario Typeless),
`ev_adb88588…` (grafo JS de Typeless: 47 handlers IPC, 2 ventanas), `ev_d01df195…`
(Mach-O `libKeyboardHelper`), `ev_70052684…` (Mach-O helper Swift de Wispr).
Bundle principal de Wispr analizado con la CLI (`rea analyze-javascript-application
--detail summary`): 2.478 módulos webpack, 2,4 M nodos AST, 13.737 hallazgos, 9 canales IPC
literales; cobertura parcial (un worker no se pudo analizar).

## 2. Cómo capturan la voz y por qué son tan rápidos

**Observado (Wispr):**
- La captura usa `getUserMedia` + `AudioWorklet` (hay errores específicos `AudioWorkletLoadError`,
  `AudioContextRecovery`, métrica `audio_acquire_total`).
- El audio se trocea en **paquetes PCM Int16 a 16 kHz** (`new Int16Array(e)`, `…,16e3)`),
  con volumen por paquete (`packets`, `volumes`) para dibujar la onda.
- Hay workers de **Opus** (`opusEncoder.worker.js`, `incrementalOpusEncoder.worker.js`,
  `opusscript_native_wasm.wasm`) para comprimir el audio de forma incremental.
- La petición al servidor lleva `audio_packets` y un `pipeline` con pasos
  `TRANSCRIBE → ALIGN → FORMAT` (el paso FORMAT es un LLM; se ven errores
  "Baseten request" → modelo alojado en Baseten).

**Observado (Typeless):** `libopusenc.dylib` y `libopuschunk.dylib` (codifica Opus por
trozos) → envía audio comprimido a `api.typeless.com`.

**Inferido — la clave de la velocidad:** ninguno espera a que sueltes la tecla para
empezar. El audio se envía/procesa **mientras hablas**, de modo que al parar solo queda
el último trozo + el formateo del LLM. Comprimir en Opus reduce el tiempo de subida.

## 3. Atajo de teclado (mantener / doble pulsación)

**Observado:**
- Ambos usan `CGEventTapCreate` (tap de eventos global) y **IOHID** como alternativa
  (`IOHIDManager…`; Typeless: *"Software event tap unavailable; using HID event handling"*).
  Así detectan teclas sueltas como **Fn** o **⌥ derecho** (`LeftOption`, `RightOption`,
  `RightCmd`…).
- Wispr guarda por atajo `holdThresholdMs`, `doubleTapWindowMs` y `holdToTalk`; tiene
  modo *hands-free* (`wispr-flow://start-hands-free`).
- Typeless: clase `ShortcutDetector` con `allowedCounts` (número de pulsaciones permitidas).

**Inferido:** máquina de estados = "si mantienes más de X ms es pulsar-para-hablar; si
haces dos toques dentro de Y ms se queda bloqueado escuchando; otro toque lo para".

## 4. Pegar el texto en cualquier casilla

**Observado (Typeless `libInputHelper`):** importa `NSPasteboard`, `CGEventCreateKeyboardEvent`,
`CGEventPost`, `UCKeyTranslate`; cadenas `ArchivedPasteboardItem`, `insertText`,
`insertRichText`, `findKeyCodeForCharacter`.
**Observado (Wispr):** `pasteTextAndRelaunchHelperIfNeeded`, `getTextBoxInfo` →
`couldNotGetTextBoxInfo` / `isEditable`; si no hay casilla editable llama a
`sendVoidDictationNotification` (no pega, te avisa y conserva el texto).

**Inferido — técnica:** 1) guardar el portapapeles actual, 2) poner el texto, 3) simular
⌘V con `CGEventPost` (buscando el keycode de la "V" según la distribución de teclado),
4) restaurar el portapapeles. Funciona en cualquier app, incluida la Terminal.

## 5. Contexto, continuidad y diccionario

**Observado:**
- Ambos leen el campo enfocado con Accessibility (`AXFocusedUIElement`,
  `AXSelectedTextRange`, `AXTextMarkerRange`) y extraen `beforeText` / `afterText`
  (texto antes y después del cursor). Wispr lo envía como `textbox_contents`, junto con
  app, bundle id, URL, `prevAsrText`, `prevLlmText` y `conversation_id`.
- Wispr envía `dictionary_context` (palabras del diccionario personal) al servidor.
- **Aprendizaje automático (Wispr):** tras pegar registra `keystrokeTrace` y
  `editDistanceToDictated`, y llama a `updateHistoryAndDictionary`; hay eventos
  `dictionary_item_auto_added` y `dictionary_item_auto_learn_undone`.
  → observa lo que corriges después de pegar y añade la palabra al diccionario
  (deshacible).
- Wispr tiene **Command Mode** (`commandModeEnabled`, `CommandModeStatus`): seleccionas
  texto y dictas una instrucción para transformarlo.

## 6. Extras útiles detectados
- Typeless `libUtilHelper`: **silencia el audio del sistema** mientras dictas
  (`AudioObjectSetPropertyData` mute, "System audio muted successfully").
- Wispr: `MediaRemoteAdapter` (pausa la música) y sonidos de inicio/pegado
  (`PlayPasteSound`).
- Ambos leen el estado de tapa cerrada / dispositivos Bluetooth para escoger micrófono.

## 7. Límites de este análisis
- No había proveedor de descompilación (Ghidra/Hopper) instalado: no hay pseudocódigo;
  para cadenas de los dylib se complementó con `strings`.
- El JS de Typeless está ofuscado; el grafo REA es parcial (`coverage: partial`).
- Nada de esto prueba comportamiento en ejecución ni el contenido de los prompts de servidor.

## 8. Decisiones para nuestra app (Dicta)
| Funcionalidad | Qué copiamos | Cómo lo hacemos distinto |
|---|---|---|
| Captura | Captura continua, procesar mientras hablas | `AVAudioEngine` nativo (sin Electron) |
| Transcripción | Streaming durante la grabación | **SpeechAnalyzer/SpeechTranscriber de macOS (local, español)**: sin red, sin coste, modelo en memoria |
| Corrección | Paso FORMAT con LLM + contexto + diccionario | Claude (API) o Apple Foundation Models (local), con autocorrecciones ("no, mejor…") |
| Atajo | Event tap, mantener / doble toque / toque para parar | Igual; tecla configurable (⌥ derecho por defecto) |
| Pegado | Guardar portapapeles → ⌘V → restaurar | Igual; si no hay casilla editable → se queda en el portapapeles + historial |
| Contexto | `beforeText` / `afterText` | Igual, + modo "continuación" del último dictado |
| Diccionario | Auto-aprendizaje por edición posterior | Igual (diff palabra a palabra), deshacible |
| Command mode | Seleccionar + dictar instrucción | Mayús + atajo = modo edición sobre la selección |

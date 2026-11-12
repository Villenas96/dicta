# Guía de instalación de Dicta

Dicta es una app de dictado por voz **en español** para Mac y Windows. Pulsas un atajo,
hablas, y el texto aparece **corregido** en la casilla donde estés escribiendo: el
correo, WhatsApp Web, Word, Claude, ChatGPT… y también la **terminal**.

- La **voz se transcribe en tu ordenador** (no se envía audio a ningún sitio).
- La **corrección** (quitar muletillas, aplicar «no, mejor el jueves», puntuación…) la
  hace **tu propia IA con tu suscripción**: **Claude Code** (Claude Pro/Max) o
  **Codex** (ChatGPT Plus/Pro). No necesitas claves de API ni pagar nada extra.

Tiempo total: unos 10 minutos.

---

## 1. Requisitos

| | Mac | Windows |
|---|---|---|
| Sistema | macOS 26 (Tahoe) o superior | Windows 10 u 11 de 64 bits |
| Recomendado | Mac con chip Apple (M1 o posterior) | 8 GB de RAM, procesador de los últimos 5 años |
| Espacio | ~1 GB (modelo de voz de Apple) | ~500 MB (app + modelo de voz) |
| Tu IA | Claude Code **o** Codex con sesión iniciada | Claude Code **o** Codex con sesión iniciada |

---

## 2. Instalar Dicta

### 🍎 Mac

**Opción A — Una línea (recomendada).** Abre la app **Terminal** y pega:

```bash
curl -fsSL https://raw.githubusercontent.com/Villenas96/dicta/main/scripts/install-mac.sh | bash
```

Dicta se copia en Aplicaciones y se abre sola.

**Opción B — Con el .dmg.**
1. Descarga `Dicta-x.y.dmg` desde la página de
   [descargas](https://github.com/Villenas96/dicta/releases/latest).
2. Ábrelo y arrastra **Dicta** a **Aplicaciones**.
3. Abre Dicta. Si macOS dice *«no se puede comprobar el desarrollador»*:
   **Ajustes del Sistema › Privacidad y seguridad**, baja hasta el final y pulsa
   **«Abrir igualmente»**. (Dicta no tiene una firma de pago de Apple; es normal.)

### 🪟 Windows

**Opción A — Una línea (recomendada).** Abre **PowerShell** (menú Inicio › escribe
«PowerShell») y pega:

```powershell
irm https://raw.githubusercontent.com/Villenas96/dicta/main/scripts/install-windows.ps1 | iex
```

**Opción B — Con el instalador.**
1. Descarga `Dicta-Setup.exe` desde la página de
   [descargas](https://github.com/Villenas96/dicta/releases/latest).
2. Ábrelo. Si sale **«Windows protegió su PC»** (SmartScreen): pulsa
   **«Más información» › «Ejecutar de todas formas»**. (El instalador no está firmado
   con un certificado de pago; es normal.)
3. Sigue el asistente. No pide permisos de administrador.

Dicta aparece como un **icono de micrófono junto al reloj** (si no lo ves, pulsa la
flechita `^` de la barra de tareas).

---

## 3. Dar permisos

### 🍎 Mac
Dicta te abre una ventana con tres permisos. Pulsa **Conceder…** en cada uno y actívalo:

1. **Micrófono** — para oírte.
2. **Accesibilidad** — para pegar el texto en la casilla activa.
3. **Monitorización de entrada** — para detectar el atajo en cualquier app.

Si después de activarlos alguno sigue sin marcarse, pulsa **«Reiniciar Dicta»**.
La primera vez, macOS descarga el modelo de voz en español (unos minutos).

### 🪟 Windows
- **Micrófono**: Configuración › Privacidad y seguridad › Micrófono › activa
  **«Permitir que las aplicaciones de escritorio accedan al micrófono»**.
- La primera vez Dicta descarga su modelo de voz (~190 MB). Verás el progreso en el
  icono del reloj y en la ventana de bienvenida.

---

## 4. Conectar tu IA (usa tu suscripción)

Elige **una**. Si ya usas Claude Code o Codex en la terminal, **no tienes que hacer
nada**: Dicta lo detecta solo.

### Opción A — Claude Code (suscripción Claude Pro o Max)

**Mac** (Terminal):
```bash
curl -fsSL https://claude.ai/install.sh | bash
```
**Windows** (PowerShell):
```powershell
irm https://claude.ai/install.ps1 | iex
```
Después, en la misma terminal, escribe `claude`, elige **iniciar sesión con tu cuenta
de Claude** y sigue los pasos del navegador. Cuando veas el chat de Claude Code, ya
puedes cerrarlo (escribe `/exit`).

### Opción B — Codex (suscripción ChatGPT Plus o Pro)

Necesitas `pnpm`. Si no lo tienes:

**Mac:**
```bash
brew install pnpm
```
**Windows** (PowerShell):
```powershell
irm https://get.pnpm.io/install.ps1 | iex
```
Cierra y vuelve a abrir la terminal, y luego (Mac y Windows):
```bash
pnpm add -g @openai/codex
```
```bash
codex login
```
Inicia sesión con **tu cuenta de ChatGPT** en el navegador.

### Elegirla en Dicta
1. **Reinicia Dicta** (menú del icono › Salir, y vuelve a abrirla) para que encuentre
   el comando recién instalado.
2. Menú del icono › **Ajustes** › **Corrección con IA**: elige **Claude Code** o
   **Codex**. Debajo verás qué motor se está usando de verdad.
3. Modelo: en Claude Code puedes dejar `sonnet` (equilibrado), `haiku` (más rápido),
   `opus` (más listo) o escribir el ID exacto de un modelo concreto.

> Sin ninguna IA conectada Dicta sigue funcionando: en Mac usa Apple Intelligence (si
> está activado) y, si no, una limpieza básica sin IA.

---

## 5. Cómo se usa

| | Mac | Windows |
|---|---|---|
| **Dictar** | Mantén **⌥ derecha**, habla y suelta | Mantén **Ctrl derecho**, habla y suelta |
| **Manos libres** | Doble toque en ⌥ derecha; otro toque para | Doble toque en Ctrl derecho; otro toque para |
| **Corregir una parte** | Selecciona texto + **Mayús + ⌥ derecha** | Selecciona texto + **Mayús + Ctrl derecho** |
| **Cancelar** | Esc | Esc |

- **Autocorrecciones**: «quiero algo para el viernes, bueno no, mejor para el jueves»
  → *«Quiero algo para el jueves.»*
- **Modo edición**: selecciona un texto y di otro nuevo para sustituirlo, o una
  instrucción: «hazlo más formal», «cambia viernes por jueves», «ponlo en una lista».
- **Re-dictar**: tras pegar aparece una píldora con ↺ (re-dictar), ↩ (deshacer) y
  copiar.
- **Seguir dictando**: si haces una pausa y sigues en la misma casilla, continúa la
  frase tal cual, sin reescribir lo anterior.
- **Sin casilla de texto**: el dictado se queda en el portapapeles.
- **Historial** y **Diccionario** en el menú del icono. En el diccionario pon cómo se
  escribe una palabra y cómo la oye el reconocedor (p. ej. *Wispr ← whisper*).

En Windows puedes cambiar el atajo a **Alt Gr**, **F8** o **F9** en Ajustes. En Mac,
a ⌘ derecha, ⌃ derecha o fn.

---

## 6. Problemas frecuentes

| Problema | Solución |
|---|---|
| «No encuentro el comando claude/codex» | Reinicia Dicta. Comprueba en una terminal que `claude --version` o `codex --version` responden. |
| La corrección dice «Pegado sin IA» | Tu IA no respondió: abre una terminal y ejecuta `claude` (o `codex login`) para volver a iniciar sesión. |
| No pega en la terminal de Windows | Si la terminal está abierta **como administrador**, Windows impide que otras apps le escriban. Ábrela normal. |
| No hace nada al pulsar el atajo (Mac) | Revisa **Monitorización de entrada** y **Accesibilidad**; pulsa «Reiniciar Dicta». |
| Escribe mal un nombre propio | Añádelo al **Diccionario** con «se oye como». También aprende solo si lo corriges justo después de pegarlo (Mac). |
| Va lento en Windows | Ajustes › Voz › modelo **Base** (más rápido). Si tu PC es potente, **Large v3 Turbo** es el más preciso. |
| La primera vez no dicta | Está descargando el modelo de voz; espera a que termine (se ve en el menú del icono). |

## Privacidad
- El audio **no sale de tu ordenador**: se transcribe en local (Apple en Mac, Whisper en
  Windows).
- El **texto** transcrito se envía a tu IA (Anthropic u OpenAI) con **tu cuenta**, igual
  que cuando usas Claude Code o Codex.
- Historial, diccionario y ajustes se guardan solo en tu ordenador.

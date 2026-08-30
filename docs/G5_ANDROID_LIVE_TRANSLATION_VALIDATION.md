# Validación física de G5 — Live Translator Android

> **Estado actual:** `PREPARED`. Este procedimiento no constituye evidencia de una ejecución real. No cambie ningún truth label a `MEASURED` hasta completar, registrar y revisar una ejecución reproducible en un dispositivo Android físico.

## Propósito y límites

Este procedimiento valida la primera cadena de usuario real de PersalOne HORIZON en Android: micrófono físico `AudioRecord` → PCM canónico 16 kHz mono → reconocimiento `SpeechRecognizer` con entrada de descriptor de archivo → traducción local ML Kit EN↔ES → `TextToSpeech` Android → ruta de altavoz elegida por el sistema. La aplicación no almacena PCM, transcripciones, traducciones ni identificadores de usuario. Los textos visibles se mantienen sólo durante la sesión y deben desaparecer al detenerla.

La prueba **no valida Halo**, BLE, audio de las gafas, OTA ni iOS. Halo audio se mantiene `BLOCKED` hasta una validación física independiente de las gafas. La disponibilidad de reconocimiento con entrada PCM es una capacidad del dispositivo y del servicio instalado: si la aplicación muestra `recognitionUnavailable`, el resultado es **BLOCKED**, no un resultado degradado.

| Campo de evidencia | Registro obligatorio |
|---|---|
| Dispositivo | Fabricante, modelo y variante; sin número de serie ni identificador persistente |
| Software | Versión Android, parche de seguridad, versión de la aplicación y commit Git |
| Ruta | Dispositivo de salida seleccionado (altavoz, auricular o Bluetooth), sin identificadores de accesorios |
| Modelo | Dirección EN→ES o ES→EN, estado del modelo local antes y después de la preparación |
| Ensayo | Fecha/hora local, operador autorizado, frases de prueba no sensibles y resultados por gate |
| Métricas | Frames/drops G3, underruns G4, callbacks obsoletos descartados, observaciones de barge-in |

## Preparación controlada

Instale una compilación procedente del commit que se va a evaluar en un dispositivo Android físico. Confirme que `RECORD_AUDIO` no está bloqueado por una política MDM y que el dispositivo tiene un servicio de reconocimiento on-device compatible con entrada PCM. Compruebe que los idiomas inglés y español están disponibles para la voz TTS instalada. Conecte una red sólo si es necesaria para la descarga inicial del modelo ML Kit y documente ese hecho; no active ninguna ruta cloud de traducción.

Abra la aplicación y ejecute primero el procedimiento G3/G4 en [`G3_G4_ANDROID_HOST_AUDIO_VALIDATION.md`](G3_G4_ANDROID_HOST_AUDIO_VALIDATION.md). El resultado debe registrar la ruta de audio, pero no convierte G5 en `MEASURED`.

## Gates de la sesión G5

| Gate | Acción | Resultado aceptable | Resultado fail-closed |
|---|---|---|---|
| Consentimiento | Mantenga desmarcada una casilla de consentimiento e intente iniciar | Inicio bloqueado con mensaje explícito | Cualquier inicio de captura, modelo o TTS sin ambas autorizaciones |
| Modelo local | Marque ambos consentimientos y elija dirección | Estado `Modelo on-device preparado (PREPARED)` | Modelo no disponible o descarga sin consentimiento; registrar `BLOCKED` |
| STT por PCM | Inicie la sesión y pronuncie una frase de prueba | Hipótesis parcial/final visible de la frase real | `recognitionUnavailable`, error de pipe o ausencia de resultado; registrar `BLOCKED` |
| Traducción | Espere un segmento final | Traducción local visible en la dirección elegida | Salida vacía, idioma incorrecto o modelo no disponible; registrar fallo |
| TTS | Espere la salida del segmento final | Voz audible en el locale destino por la ruta registrada | Locale/voz no disponible o falta de audibilidad; registrar fallo |
| Barge-in | Durante la voz, pronuncie una nueva frase | La locución previa se interrumpe y el siguiente turno se procesa | La voz previa persiste o se reproduce un turno obsoleto |
| Stop/privacidad | Pulse detener y navegue fuera o reinicie | Texto visible vacío y ningún evento tardío audible | Texto persistente o salida de un turno posterior a stop |

## Frases de prueba

Use textos no sensibles y no personales. Para EN→ES, use “Where is the nearest station?” y “Please stop speaking now.” Para ES→EN, use “¿Dónde está la estación más cercana?” y “Por favor, deja de hablar ahora.” No grabe ni adjunte audio a la evidencia salvo que una política de privacidad independiente lo autorice explícitamente.

## Criterios de cierre

Sólo se puede proponer `MEASURED` para una subcapacidad concreta si se conserva un registro reproducible que demuestre el gate correspondiente, incluido el commit exacto y la configuración de dispositivo. El estado de modelo, STT, traducción y TTS debe anotarse por separado. Una ejecución satisfactoria de un dispositivo no generaliza a todos los dispositivos Android, ni autoriza ninguna afirmación sobre iOS o Halo.

| Subcapacidad | Estado antes del ensayo | Evidencia mínima para proponer `MEASURED` |
|---|---|---|
| G3 micrófono Android | `PREPARED` | Captura de audio real según G3, con métricas y dispositivo registrados |
| G4 salida AudioTrack | `PREPARED` | Reproducción audible humana y métricas G4 en el mismo entorno |
| G5 STT PFD | `PREPARED` | Resultado de habla real en el servicio Android compatible, con el gate STT superado |
| G5 ML Kit local | `PREPARED` | Modelo preparado con consentimiento y traducción correcta de una frase de prueba |
| G5 TTS Android | `PREPARED` | Voz en locale destino audible por la ruta documentada |
| G5 barge-in | `PREPARED` | Interrupción reproducible sin locución tardía tras una nueva frase o stop |
| Halo audio | `BLOCKED` | No aplicable hasta llegada y validación independiente del hardware Halo |

## Registro de ensayo

Copie esta tabla para cada ejecución. No incluya transcripciones ni textos de traducción en el registro final.

| Campo | Valor |
|---|---|
| Fecha/hora local | |
| Operador autorizado | |
| Commit Git | |
| Dispositivo y Android | |
| Ruta de salida | |
| Dirección | |
| Estado modelo inicial/final | |
| Consentimiento bloqueado correctamente | Sí / No |
| Gate STT | Superado / Bloqueado / Falló |
| Gate traducción | Superado / Bloqueado / Falló |
| Gate TTS | Superado / Bloqueado / Falló |
| Gate barge-in | Superado / Bloqueado / Falló |
| Frames/drops/underruns/callbacks obsoletos | |
| Observaciones no sensibles | |
| Revisor | |

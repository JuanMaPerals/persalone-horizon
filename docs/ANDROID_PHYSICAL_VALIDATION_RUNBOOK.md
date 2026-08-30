# Runbook reproducible — validación física Android G3/G4/G5

> **Estado de este runbook:** `PREPARED`. No ejecutar este documento en un emulador ni promocionar ningún componente a `MEASURED` hasta que un ensayo en un teléfono Android físico quede registrado y revisado. Este runbook no valida Halo, BLE, cámara, OTA, iOS ni G6.

## Alcance y evidencia

El objetivo es comprobar la cadena Android actualmente implementada: `AudioRecord` → PCM S16LE mono 16 kHz → `SpeechRecognizer` por `ParcelFileDescriptor` → ML Kit Translation on-device EN↔ES → `TextToSpeech` → ruta de salida Android. Las fuentes locales que se someten a prueba son `MainActivity.kt`, los adaptadores de `packages/audio_adapters`, `packages/translation_runtime` y la UI de `apps/mobile`. La evidencia sólo puede contener metadatos, contadores y observaciones humanas; no PCM, transcripciones, traducciones, identificadores de dispositivo, números de serie, voces ni capturas que revelen texto personal.

| Afirmación | Evidencia primaria | Estado | Límite |
|---|---|---|---|
| El APK debug se construye para una prueba de desarrollo en dispositivo físico. | Flutter documenta `flutter run` para probar y define debug como modo de desarrollo en dispositivo físico.[1] [2] | `PREPARED` | No se ha construido en este entorno sin SDK Android. |
| `RECORD_AUDIO` requiere consentimiento runtime en Android 6.0/API 23 o posterior. | Android documenta que los permisos peligrosos se solicitan en runtime y la app declara `RECORD_AUDIO`.[3] `apps/mobile/android/app/src/main/AndroidManifest.xml` | `PREPARED` | La concesión depende del dispositivo y del usuario. |
| La entrada STT por PFD está disponible desde Android 13/API 33 y puede no ser soportada por el reconocedor. | `EXTRA_AUDIO_SOURCE` se añadió en API 33; si no está configurado o no se soporta, el reconocedor puede abrir su propio micrófono.[4] | `PREPARED` | La compatibilidad debe observarse en cada dispositivo. |
| ML Kit traduce localmente una vez descargado el modelo bajo demanda. | ML Kit exige confirmar la descarga de modelo antes de traducir y recomienda Wi‑Fi; la traducción se ejecuta on-device.[5] [6] | `PREPARED` | La descarga inicial y la calidad dependen del dispositivo/modelo. |

## 1. Prerrequisitos exactos

Use un **teléfono Android físico** con Android **13/API 33 o superior**. G3/G4 pueden intentar la ruta de host audio con versiones anteriores compatibles con la APK, pero G5 STT por `EXTRA_AUDIO_SOURCE` se bloquea deliberadamente por debajo de API 33. No sustituya el teléfono por emulador: el resultado no es evidencia de micrófono, salida acústica, ruta ni latencia física.

| Requisito | Obligatorio para | Verificación humana antes de empezar |
|---|---|---|
| Teléfono físico Android API 33+ | G5 completo | Ajustes → Acerca del teléfono; registre versión/API sin número de serie. |
| Batería ≥50 %, sin llamada, grabador ni asistente de voz activo | G3/G4/G5 | Cierre aplicaciones que puedan poseer micrófono o ruta de audio. |
| Cable USB de datos y depuración USB autorizada | Instalación | `adb devices -l` debe mostrar `device`, no `unauthorized`. |
| Altavoz interno como ruta inicial | G4/G5 TTS | Desconecte Bluetooth/cable; registre la ruta que Android muestre. |
| Servicio de reconocimiento on-device compatible con EN y ES | G5 STT | Si la app devuelve `recognitionUnavailable`, registre `BLOCKED`; no active un fallback. |
| Voz TTS instalada para el locale de destino | G5 TTS | Compruebe que Android tiene voz para inglés y español. |
| Wi‑Fi permitido sólo durante descarga inicial de modelo | G5 MT | El consentimiento específico de descarga debe estar activo; registre conectividad, no SSID. |

### Permisos y visibilidad Android observados

| Elemento | Declaración actual | Solicitud al usuario | Uso en el ensayo |
|---|---|---|---|
| `android.permission.RECORD_AUDIO` | Manifest principal | Sí, diálogo runtime al pulsar la función de micrófono | Obligatorio para G3 y G5. |
| `android.permission.INTERNET` | Manifest `debug` de Flutter | No, permiso normal | Sólo APK debug: comunicación de desarrollo y descarga inicial del modelo si procede. |
| `RecognitionService` | `<queries>` | No es permiso | Permite descubrir servicios de reconocimiento en Android 11/API 30+.[7] |
| `TTS_SERVICE` | `<queries>` | No es permiso | Permite descubrir motores TTS en Android 11/API 30+.[7] |

No conceda permisos de cámara, ubicación, Bluetooth, almacenamiento o contactos: no forman parte de este ensayo.

## 2. Build reproducible y APK

Ejecute desde una copia limpia de la rama/commit candidato. Este es el comando exacto de build debug; no requiere crear keystore ni publicar nada.

```bash
cd /ruta/a/persalone-halo

git fetch origin --prune
git switch <rama-candidata>
git status --short
git rev-parse HEAD
/home/ubuntu/.tools/flutter/bin/flutter --version
/home/ubuntu/.tools/flutter/bin/flutter pub get
/home/ubuntu/.tools/flutter/bin/flutter analyze
(cd packages/contracts && /home/ubuntu/.tools/flutter/bin/dart test)
(cd packages/halo_adapter && /home/ubuntu/.tools/flutter/bin/flutter test)
(cd packages/audio_adapters && /home/ubuntu/.tools/flutter/bin/flutter test)
(cd packages/translation_runtime && /home/ubuntu/.tools/flutter/bin/dart test)
(cd apps/mobile && /home/ubuntu/.tools/flutter/bin/flutter test)
bash tooling/preflight.sh --all

cd apps/mobile
/home/ubuntu/.tools/flutter/bin/flutter build apk --debug
sha256sum build/app/outputs/flutter-apk/app-debug.apk
```

La salida esperada es exactamente:

```text
apps/mobile/build/app/outputs/flutter-apk/app-debug.apk
```

> No use `--release` para este gate. El modo debug sirve para desarrollo y observación; las cifras de rendimiento de debug no son latencia de producto. Flutter indica que la medición de rendimiento requiere profile en dispositivo físico.[2]

### Instalación mínima

Con el teléfono conectado y desbloqueado, ejecute:

```bash
adb devices -l
adb install -r apps/mobile/build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.example.persalone_mobile/.MainActivity
```

Si `adb devices -l` no muestra exactamente un dispositivo autorizado elegido para el ensayo, **deténgase**. Si la instalación falla por firma o paquete, registre el error; no desinstale ni borre datos sin la autorización del operador del dispositivo. Para un ensayo deliberadamente frío de descarga de modelo, la desinstalación es una acción humana explícita y debe documentarse por separado.

## 3. Flujo mínimo de validación

El operador puede completar un ciclo con los pasos siguientes. Las frases son de prueba y no deben guardarse ni incluirse en evidencia.

1. Abra la app y confirme que todas las capacidades siguen etiquetadas `PREPARED` o `BLOCKED`, nunca `MEASURED`.
2. En G3/G4, pulse **Solicitar micrófono**. Conceda sólo `RECORD_AUDIO`; anote concedido/denegado.
3. Pulse **Iniciar captura real**, diga una frase no sensible durante 5–10 segundos y pulse **Detener captura**. Repita tres veces.
4. Pulse **Reproducir muestra real** para cada ejecución G3. Una persona presente confirma si la muestra actual se oye y es reconocible. Repita tres veces.
5. En G5 elija dirección EN→ES o ES→EN. Deje desmarcado al menos un consentimiento e intente iniciar: debe bloquearse sin capturar, descargar ni sintetizar.
6. Marque consentimiento de procesamiento local y consentimiento de descarga de modelo para **esa sesión**. Mantenga Wi‑Fi sólo si el modelo aún no está disponible.
7. Pulse **Iniciar traducción en vivo**. Diga una frase de prueba, espere hipótesis parcial/final, traducción y voz TTS por la ruta declarada. Repita con la dirección inversa.
8. Durante TTS diga inmediatamente la segunda frase de prueba. El turno anterior debe interrumpirse; no puede oírse texto de una sesión o epoch anterior.
9. Pulse **Detener y descartar sesión**. Las tres áreas de texto de la UI deben quedar vacías y no debe aparecer voz tardía. Cierre y vuelva a abrir la app para comprobar que no se restauró texto.

## 4. Criterios explícitos de PASS / FAIL

| Gate | PASS sólo si | FAIL / BLOCKED si |
|---|---|---|
| G3 permiso | El usuario concede `RECORD_AUDIO` y la captura inicia sólo después. | La UI intenta capturar sin permiso, el permiso se deniega o hay error de `AudioRecord`. |
| G3 PCM | En cada una de tres repeticiones hay frames reales no vacíos con formato S16LE/16 kHz/mono y contador de drops registrado. | Frames vacíos, formato distinto, error o ausencia de contadores. |
| G4 playback | `AudioTrack` escribe la muestra del ensayo actual, sin error; se anotan writes/underruns. | No inicia, write falla, ruta no registrada o diagnostics ausentes. |
| G4 audibilidad | Una persona confirma la muestra correcta en las tres repeticiones y la ruta declarada. | ACK sin confirmación humana, silencio, distorsión no aceptada o ruta inesperada. |
| G5 consentimiento | Con un consentimiento ausente, inicio bloqueado antes de audio/modelo/TTS; con ambos, se permite preparar. | Cualquier actividad de cadena G5 antes de ambos consentimientos. |
| G5 STT PFD | El reconocedor produce texto parcial/final del habla real y no abre un segundo micrófono observable. | `recognitionUnavailable`, error PFD, sin resultado, locale no soportado o fallback silencioso. |
| G5 MT | El modelo local se prepara bajo consentimiento y produce resultado correcto en la dirección elegida. | Descarga sin consentimiento, modelo no disponible, texto vacío o idioma erróneo. |
| G5 TTS | La voz del locale destino se oye por la ruta anotada. | Voz/locale no disponible, falla TTS o no hay confirmación humana. |
| G5 barge-in / stop | Nueva frase detiene la síntesis anterior; stop elimina texto UI y bloquea callbacks/voz tardíos. | Continúa la voz anterior, aparece texto persistente o se reproduce callback obsoleto. |

Un gate fallido no se compensa con otro gate aprobado. Marque únicamente la subcapacidad afectada `FAILED` o `BLOCKED`; el resto sigue `PREPARED` hasta su propia evidencia.

## 5. Captura de evidencia y latencia

### Evidencia permitida

Capture una sola hoja por repetición con commit, hash SHA-256 de APK, fabricante/modelo, versión Android, ruta de salida, estado de permiso, dirección, estados de modelo, contadores y resultado humano. Puede adjuntar capturas de UI sólo si no contienen transcripción/traducción ni identificadores. No exporte PCM ni use grabación de pantalla/audio como prueba de contenido.

### Latencia: método y límites

| Medida | Fuente real permitida | Resultado que se puede registrar | No se puede afirmar |
|---|---|---|---|
| Captura G3 | `AudioRecord.getTimestamp()` emitido por la ruta nativa | Disponible/no disponible, posición de frame y timestamp monotónico cuando esté visible en diagnóstico. | Latencia de usuario a traducción. |
| Salida G4 | `AudioTrack.getTimestamp()` y `underrunCount` nativos | Disponible/no disponible, posición de frame y underruns. | Audibilidad o latencia acústica sin observador. |
| Backpressure G4 | Inicio/fin monotónicos de write y writes parciales | Duración de write si se obtiene por instrumentación del ensayo. | Latencia end-to-end. |
| Conversación G5 | No existe aún un instrumento end-to-end aceptado en la UI. | **No medir ni publicar número.** | Cualquier cifra de “latencia en vivo”. |
| Barge-in | Observación humana con marca temporal externa y evento de cancelación cuando sea visible. | Pass/fail de interrupción, no milisegundos de marketing. | Latencia de AEC/full duplex. |

Para medir una cifra física futura será necesario un protocolo de loopback independiente (fuente acústica, referencia temporal común y análisis reproducible) aprobado antes de usarlo. Hasta entonces, registrar timestamps no autoriza una métrica de latencia end-to-end.[8]

## 6. Plantilla de registro censurado

```text
commit_sha:
branch:
apk_sha256:
flutter_version:
android_manufacturer_model:
android_api_level:
audio_route:
run_number: 1|2|3
permission_record_audio: granted|denied
input_frames:
input_drops:
input_timestamp: available|unavailable
output_writes:
output_partial_writes:
output_underruns:
output_timestamp: available|unavailable
g5_consent_blocked_correctly: yes|no
g5_model_state: ready|blocked|failed
g5_stt_pfd: pass|blocked|failed
g5_translation: pass|blocked|failed
g5_tts_human_audible: yes|no
g5_barge_in: pass|blocked|failed
g5_stop_reset: pass|blocked|failed
anomalies_non_sensitive:
truth_label: PREPARED|MEASURED|FAILED|BLOCKED
reviewer:
```

Cambie a `MEASURED` únicamente si tres repeticiones verificables de la subcapacidad satisfacen el criterio correspondiente, con este registro completo y revisión humana. Nunca cambie Halo audio de `BLOCKED` por una validación de host Android.

## 7. Diagnóstico de fallos

| Síntoma | Clasificación segura | Acción permitida |
|---|---|---|
| `adb` no detecta dispositivo | `BLOCKED` | Revisar cable/depuración USB; no alterar el teléfono sin operador. |
| Permiso de micrófono denegado | `BLOCKED` | Registrar decisión del usuario; no insistir ni iniciar captura. |
| `recognitionUnavailable` | `BLOCKED` | Registrar versión/API/servicio; no usar segundo micrófono o proveedor alternativo silencioso. |
| Modelo no disponible | `BLOCKED` | Confirmar ambos consentimientos, conectividad documentada y espacio; no activar cloud. |
| TTS sin voz de locale | `BLOCKED` | Instalar voz como acción del operador o registrar bloqueo. |
| Underrun/drop/error | `FAILED` para la repetición | Conservar counters y repetir sólo tras anotar ruta/configuración. |
| Texto/voz tras stop | `FAILED` | Detener ensayo y abrir issue privado censurado; no declarar privacidad superada. |

## Referencias

[1]: https://docs.flutter.dev/deployment/android "Flutter — Build and release an Android app"
[2]: https://docs.flutter.dev/testing/build-modes "Flutter — Build modes"
[3]: https://developer.android.com/training/permissions/requesting "Android Developers — Request runtime permissions"
[4]: https://developer.android.com/reference/android/speech/RecognizerIntent "Android Developers — RecognizerIntent"
[5]: https://developers.google.com/ml-kit/language/translation/android "ML Kit — Translate text with ML Kit on Android"
[6]: https://developers.google.com/ml-kit/language/translation "ML Kit — Translation overview"
[7]: https://developer.android.com/training/package-visibility/use-cases "Android Developers — Package visibility use cases"
[8]: https://developer.android.com/reference/android/media/AudioTimestamp "Android Developers — AudioTimestamp"

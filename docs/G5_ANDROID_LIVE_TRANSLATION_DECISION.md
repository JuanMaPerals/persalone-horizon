# G5 — Decisión de traducción en vivo Android-first

**Estado:** `PREPARED`; no hay aún medición en dispositivo Android físico.
**Alcance:** inglés ↔ español, entrada y salida reales del host Android, con aislamiento de proveedores y consentimiento explícito.
**Fuera de alcance:** Halo audio, ruta cloud con secretos móviles, AEC, agentes instalables, OTA, uso en segundo plano y cualquier proveedor simulado.

> La primera ruta G5 no debe inventar transcripciones, traducciones, audio ni latencias. Si una capacidad de reconocimiento, modelo o voz no está disponible en el dispositivo, la sesión falla cerrada y muestra el motivo; no hay fallback de demostración.

## Decisión

La propuesta se basa en tres puertos de dominio independientes de Android: `StreamingSttProvider`, `TextTranslationProvider` y `SpeechSynthesisProvider`. La aplicación móvil conserva los canales Android como detalles de adaptadores concretos; el runtime de traducción sólo ve los contratos, epochs de sesión, resultados parciales/finales, errores tipados, consentimiento y etiquetas de evidencia.

| Etapa | Adaptador Android inicial | Ruta de datos | Etiqueta antes de prueba | Decisión |
|---|---|---|---|---|
| STT | `AndroidSpeechRecognizerProvider` | PCM G3 → pipe/PFD → `SpeechRecognizer` con resultados parciales | `PREPARED` | Requiere comprobar soporte de audio inyectado por dispositivo antes de activarse. |
| Traducción | `MlKitOnDeviceTranslatorProvider` | Texto final EN↔ES → modelo local descargado bajo consentimiento | `PREPARED` | Base local preferida; no se invoca hasta confirmar el modelo. |
| TTS | `AndroidTextToSpeechProvider` | Texto traducido → cola local del motor TTS → ruta Android seleccionada | `PREPARED` | Sólo se marca como funcional tras recibir callbacks y verificación humana audible. |
| Salida PCM directa | `AndroidSpeakerAdapter` | PCM de un proveedor futuro → `AudioTrack` | `PREPARED` | Conservado para proveedores que entreguen PCM y para diagnóstico G4. |
| Halo | `PreparedHaloMicrophoneAdapter` / `PreparedHaloSpeakerAdapter` | Ningún audio físico | `PREPARED/BLOCKED` | No se habilita sin gafas y prueba física independiente. |

## Fundamento de la selección

`SpeechRecognizer` acepta resultados parciales y finales, pero su implementación puede transmitir audio a servicios remotos; su disponibilidad, el soporte de extras y el comportamiento de parciales dependen del servicio del dispositivo.[1] [2] El reconocimiento on-device existe como opción del sistema y debe comprobarse antes de crear o iniciar una sesión; la API exige `destroy()` al finalizar.[1]

Para preservar el ownership de G3, la plataforma ofrece `RecognizerIntent.EXTRA_AUDIO_SOURCE`, un `ParcelFileDescriptor` de fuente de audio ya abierta, junto con extras de canales, codificación y sample rate. No obstante, la referencia advierte que el recognizer puede ignorar esa característica; por tanto, G5 debe consultar soporte y bloquear la sesión si no queda demostrado.[3]

ML Kit Translation ofrece traducción on-device entre más de 50 idiomas, pero requiere descargar y confirmar cada modelo antes de `translate()`. Los modelos rondan 30 MB y la documentación recomienda no descargarlos innecesariamente ni fuera de Wi-Fi sin una elección expresa de la persona usuaria.[4] Para EN↔ES, los modelos se tratan como un recurso local que el usuario puede aceptar, preparar, borrar y auditar.

Android `TextToSpeech` inicializa de forma asíncrona, debe liberar recursos con `shutdown()` y dispone de callbacks de progreso. La síntesis puede depender del motor/voz instalados, por lo que la disponibilidad EN/ES debe comprobarse y los errores de datos/voz no instalada no se degradan de forma silenciosa.[5]

## Contratos y límites de seguridad

| Puerto | Entrada | Salida | Prohibiciones |
|---|---|---|---|
| `StreamingSttProvider` | `Stream<AudioFrame>` G3, idioma esperado, consentimiento, epoch | Hipótesis parciales/finales, confianza opcional, diagnósticos sin PCM | No abrir un segundo micrófono, no persistir PCM, no enviar audio sin consentimiento. |
| `TextTranslationProvider` | Segmento final, idioma origen/destino, epoch | Segmento traducido, estado de modelo, latencia monotónica | No traducir sin modelo listo, no mezclar epochs, no registrar texto por defecto. |
| `SpeechSynthesisProvider` | Segmento traducido, locale/voz, epoch | Eventos start/done/error y ruta declarada | No asumir que el callback prueba audibilidad ni usar una voz no disponible. |
| `HorizonTranslationRuntime` | Eventos de los tres puertos | Estado visible y diagnóstico redactado | No invocar APIs Android, ML Kit o proveedores directamente. |

Los resultados parciales son revisables. Sólo un segmento final puede entrar en la traducción que se verbaliza por defecto; una futura política de latencia podrá habilitar parciales estables tras pruebas específicas. Con cada stop, error, barge-in o cambio de idioma, el runtime incrementa epoch y descarta callbacks tardíos.

## Consentimiento y privacidad

Antes de descargar un modelo, iniciar reconocimiento o producir voz, la UI debe presentar un consentimiento por sesión que incluya: proveedor seleccionado, si el reconocimiento puede ser remoto, idiomas, consumo de red/almacenamiento, controles de cancelación y regla de no persistencia. La selección por defecto será **local cuando el estado del dispositivo lo demuestre**; no se describe la ruta como offline si el recognizer o motor TTS no lo certifica.

El log operativo conserva sólo códigos, duración, estado de modelo, contadores y timebase monotónico. Quedan excluidos PCM, transcript, traducción, nombres de voz, identificadores del dispositivo y prompts. Todo diagnóstico de fallo se redacta antes de cruzar el límite de UI/telemetría.

## Gates de implementación

| Gate | Condición de apertura | Evidencia requerida | Acción si falla |
|---|---|---|---|
| G5.1 | Soporte de STT | API/servicio disponible y PFD soportado en el dispositivo real | Bloquear STT; no abrir el micrófono alternativo. |
| G5.2 | Modelo de traducción | Consentimiento y modelo EN↔ES descargado/verificado | Bloquear traducción y explicar estado de modelo. |
| G5.3 | Voz TTS | Motor inicializado y locale objetivo disponible | Bloquear speak; no sustituir por audio de fixture. |
| G5.4 | Recorrido completo | Tres ensayos EN→ES y tres ES→EN, con trazas redactadas | Mantener `PREPARED`; no declarar `MEASURED`. |
| G5.5 | Halo audio | Gafas conectadas y prueba independiente | Mantener los adaptadores Halo bloqueados. |

## Decisiones reversibles y no reversibles

| Decisión | Estado | Razón |
|---|---|---|
| Puertos canónicos STT/MT/TTS | Congelar | Evitan acoplar el runtime a Android y permiten cloud/Halo después. |
| ML Kit para MT EN↔ES | Reversible | Es una primera ruta local; otro proveedor implementa el mismo puerto. |
| `SpeechRecognizer` con PFD | Reversible y condicionado | El soporte depende de la implementación; la medición real decide. |
| TTS del sistema Android | Reversible | Es un adaptador local; otra voz/PCM puede reemplazarlo sin cambiar el runtime. |
| Privacidad fail-closed y no persistencia | Congelar | Son gates de seguridad, no optimizaciones. |

## Referencias

[1]: https://developer.android.com/reference/android/speech/SpeechRecognizer "Android Developers — SpeechRecognizer"
[2]: https://developer.android.com/reference/android/speech/RecognitionListener "Android Developers — RecognitionListener"
[3]: https://developer.android.com/reference/android/speech/RecognizerIntent "Android Developers — RecognizerIntent"
[4]: https://developers.google.com/ml-kit/language/translation/android "Google ML Kit — Translate text with ML Kit on Android"
[5]: https://developer.android.com/reference/android/speech/tts/TextToSpeech "Android Developers — TextToSpeech"

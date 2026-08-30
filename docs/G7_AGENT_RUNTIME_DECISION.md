# G7 — decisión de runtime de agentes y HORIZON Translate

> **Decisión:** `PREPARED`. Este documento define contratos y gates para implementar G7. No demuestra que un agente se ejecute en un dispositivo físico, que un permiso esté concedido ni que una capacidad Android/Halo esté `MEASURED`.

## Contexto y objetivo

HORIZON Translate debe ser el primer agente real de PersalOne HORIZON, pero el runtime de agentes no puede convertirse en una capa por paquete PCM, callback de reconocimiento o write de salida. El hot path existente de G5 ya conserva una única captura canónica y controla sus propios epochs: `AudioInputAdapter` → `StreamingSttProvider` → `TextTranslationProvider` → `SpeechSynthesisProvider`. G7 gobernará **registro, descubrimiento, permisos, lifecycle, límites de sesión, requisitos de proveedor, auditoría y diagnóstico**, no transporte de frames ni planificación de audio.

| Decisión | Resultado |
|---|---|
| Separar plano de control y plano de datos | El agente inicia/detiene una sesión de traducción por un puerto de alto nivel; los frames nunca atraviesan `AgentRuntime`. |
| Permiso explícito por sesión | Un manifiesto sólo solicita capacidades; un grant de sesión las autoriza de forma limitada o el runtime bloquea. |
| Memoria sin persistencia por defecto | HORIZON Translate declara `none`; no recibe almacenamiento de PCM, texto, identificadores ni historial entre sesiones. |
| Proveedores declarados | El manifiesto exige STT local, MT local y TTS local por sus puertos canónicos, no una API Android concreta. |
| Auditoría censurada | Los eventos contienen IDs de agente, session/epoch, código y timestamp; nunca texto, PCM, voz, dispositivo, claves o argumentos de proveedor. |
| Etiquetas de verdad independientes | Un permiso no eleva `PREPARED` a `MEASURED`. Las capacidades `BLOCKED` o `FAILED` se rechazan; una capacidad `PREPARED` puede ejecutarse para una validación explícita sin publicidad de evidencia física. |

## Frontera de rendimiento

```text
Control plane (G7)                         Data plane (G5)
──────────────────                         ───────────────
register / discover agent                  AudioInputAdapter.frames
check session grant                        → STT.push(frame)
create session context                     → MT.translate(final segment)
invoke start / stop                        → TTS.speak(translation)
emit redacted audit event                  epochs / barge-in / stale callbacks
```

> El runtime G7 no expone `AudioFrame`, `Uint8List`, `Stream<AudioFrame>`, texto de transcript ni texto de traducción a una interfaz genérica de agente. La única llamada de inicio prevista es de alto nivel y devuelve inmediatamente tras arrancar la sesión; no se usa para realizar trabajo de audio.

## Contratos canónicos propuestos

Los siguientes tipos residirán en `packages/contracts/lib/src/agent.dart` y serán exportados por `persalone_contracts.dart`.

| Tipo | Responsabilidad | Restricción principal |
|---|---|---|
| `AgentManifest` | Identidad/versionado, nombre visible, permisos solicitados, requisitos de proveedor y política de memoria. | Inmutable, validado antes del registro; no contiene secretos ni configuración de proveedor. |
| `AgentPermission` | Capacidad que un agente puede solicitar. | El conjunto inicial: `liveTranslationControl`, `microphoneCapture`, `speakerPlayback`, `localSpeechRecognition`, `localTextTranslation`, `modelDownload`, `localSpeechSynthesis`, `readDiagnostics`. |
| `AgentPermissionGrant` | Autorización explícita, por sesión/epoch, de un subconjunto del manifiesto. | Debe estar activa, pertenecer al agente/session correctos y no puede incluir permisos no solicitados. |
| `AgentProviderRequirement` | Requisito de proveedor abstracto, locality y revision mínima opcional. | No referencia clases Android ni credenciales. |
| `AgentMemoryPolicy` | `none`, `sessionEphemeral` o futuras políticas explícitas. | Ninguna política habilita persistencia implícita; HORIZON Translate usa `none`. |
| `AgentLifecycleState` | `discovered`, `registered`, `permissionRequired`, `ready`, `starting`, `active`, `stopping`, `stopped`, `failed`, `disposed`. | No permite llamadas de start/stop fuera de transición válida. |
| `AgentSessionContext` | Identidad de sesión, epoch, grants, modo de ejecución y acceso al puerto de control. | Sin payload de audio/texto y sin identificador de hardware. |
| `AgentAuditEvent` / `AgentDiagnostic` | Observabilidad censurada. | Códigos tipados, no campos de texto de usuario. |
| `AgentRegistration` | Resultado verificable de registro/descubrimiento. | No es prueba de que el agente se haya ejecutado ni de hardware conectado. |

### Manifiesto de HORIZON Translate

```dart
const AgentManifest horizonTranslateManifest = AgentManifest(
  schemaVersion: 'persalone.agent/1',
  agentId: 'persalone.horizon.translate',
  displayName: 'HORIZON Translate',
  version: '0.1.0',
  requestedPermissions: <AgentPermission>{
    AgentPermission.liveTranslationControl,
    AgentPermission.microphoneCapture,
    AgentPermission.speakerPlayback,
    AgentPermission.localSpeechRecognition,
    AgentPermission.localTextTranslation,
    AgentPermission.modelDownload,
    AgentPermission.localSpeechSynthesis,
  },
  providerRequirements: <AgentProviderRequirement>[
    AgentProviderRequirement.localSpeechRecognition,
    AgentProviderRequirement.localTextTranslation,
    AgentProviderRequirement.localSpeechSynthesis,
  ],
  memoryPolicy: AgentMemoryPolicy.none,
);
```

Este fragmento es una **forma contractual propuesta**, no un objeto ya compilado. La implementación final no otorgará permisos por existir el manifiesto.

## Puertos y enforcement fail-closed

```dart
abstract interface class AgentController {
  AgentManifest get manifest;
  Future<void> start(AgentSessionContext context);
  Future<void> stop(AgentSessionContext context);
  Future<void> dispose();
}

abstract interface class AgentRuntime {
  Stream<AgentRegistration> get registrations;
  Stream<AgentAuditEvent> get auditEvents;
  Stream<AgentDiagnostic> get diagnostics;

  Future<void> register(AgentController agent);
  Future<AgentRegistration> registrationFor(String agentId);
  Future<void> start(String agentId, AgentSessionContext context);
  Future<void> stop(String agentId, AgentSessionContext context);
  Future<void> dispose();
}
```

Antes de invocar `start`, `AgentRuntime` debe rechazar de forma tipada cualquiera de estas condiciones:

| Gate | Error tipado propuesto | Acción |
|---|---|---|
| Agente no registrado o manifiesto inválido | `agentUnavailable` / `invalidContract` | No se crea sesión. |
| Grant ausente, expirado, agentId/session/epoch incongruente | `consentRequired` / `policyDenied` / `staleStreamEpoch` | No se llama al agente. |
| Grant contiene permiso no solicitado | `policyDenied` | Registrar auditoría censurada y bloquear. |
| Requisito de proveedor explícitamente `unavailable` o `failed` | `providerUnavailable` | No se llama al controlador. |
| Capacidad declarada `BLOCKED` o `FAILED` | `capabilityUnavailable` | No se llama al controlador. |
| Lifecycle no válido | `sessionClosed` / `policyDenied` | No se ejecuta acción repetida o tardía. |
| Callback de otro epoch | `staleStreamEpoch` | Descartar y auditar sin texto. |

Los estados `unknown` y `preparing` sólo confirman que existe un puerto registrado; no son una afirmación de disponibilidad. G7 deja que el controlador inicie G5 y que G5 prepare STT, modelo y TTS bajo consentimiento. Si esa preparación falla, G5 bloquea la sesión y el runtime de agente registra el fallo censurado.

### Regla especial para `PREPARED`

La etiqueta de verdad no es un permiso. El runtime puede permitir que el operador ejecute una sesión con una capacidad `PREPARED` únicamente cuando el grant de esa sesión declare `AgentExecutionMode.validation`. La UI debe mostrar `PREPARED` durante toda la sesión y la auditoría nunca puede convertirlo a `MEASURED`. `AgentExecutionMode.standard` no desbloquea una capacidad `BLOCKED`, `FAILED` o no declarada.

## HORIZON Translate como controlador

`HorizonTranslateAgent` recibirá por inyección una fábrica de `HorizonTranslationRuntime`. En `start`, tras verificar contexto, creará una configuración `LiveTranslationConfig`, iniciará el runtime G5 y publicará auditoría censurada. En `stop`, cancelará dicha sesión. El controlador no podrá leer `frames`, ni suscribirse a transcripts, ni reenviar bytes. La UI de Live Translate se suscribirá directamente a los snapshots y diagnósticos de G5 autorizados por el controller/session, no a un bus genérico de audio.

| Responsabilidad | G7 | G5 |
|---|---|---|
| Decidir si un agente puede iniciar | Sí | No |
| Asociar consentimiento/grant con session + epoch | Sí | G5 exige `TranslationConsent` por sesión. |
| Crear y destruir lifecycle del agente | Sí | Maneja lifecycle de traducción activa. |
| Leer/escribir PCM | No | Sí, en adaptadores/proveedor STT. |
| Descartar callback tardío de frame/transcript | No | Sí, por epoch G5. |
| Interrumpir TTS ante nuevo turno | No | Sí, barge-in G5. |
| Emitir auditoría de inicio/denegación | Sí | Sólo diagnósticos de proveedor/runtime. |

## Auditabilidad y límites de memoria

| Evento propuesto | Campos permitidos | Campos prohibidos |
|---|---|---|
| `agentRegistered` | agentId, manifestVersion, observedAtMicros | ruta local, firma/clave, datos de usuario |
| `permissionDenied` | agentId, sessionId hash/redactado, epoch, permission code | razón textual del usuario, transcript |
| `agentStarted` / `agentStopped` | agentId, sessionId hash/redactado, epoch, mode | texto, audio, identificador de dispositivo |
| `providerRequirementFailed` | agentId, provider category, error code | response/provider token |
| `staleCallbackDiscarded` | agentId, epoch, component code | payload o diagnóstico no censurado |

`AgentMemoryPolicy.none` obliga a que el controlador no reciba un almacenamiento. `sessionEphemeral`, cuando se implemente, sólo será memoria borrada por `stop`/`dispose`, vinculada a session/epoch y con tipos explícitos; no incluirá PCM ni texto de conversación sin un permiso contractual posterior.

## Plan de implementación

1. Añadir contratos, códigos de error agent-specific y pruebas de validación de manifiestos/grants en `packages/contracts`.
2. Crear `packages/agent_runtime` Dart puro con registro, discovery, lifecycle y auditoría censurada.
3. Implementar `HorizonTranslateAgent` en el nuevo paquete, inyectando G5 por fábrica de alto nivel; no importará adaptadores Android.
4. Añadir pruebas de fail-closed: grant ausente, permiso extra, provider ausente, lifecycle inválido y epoch obsoleto.
5. Conectar la UI a snapshots reales de runtime/G5, visibles como `PREPARED` hasta evidencia física.
6. Mantener `Halo` como `BLOCKED`; no otorgar BLE, OTA, Lua, cámara o herramientas externas al manifiesto inicial.

## Criterios de aceptación G7

| Criterio | Evidencia requerida antes de llamar `PREPARED` |
|---|---|
| Contratos | Análisis y pruebas de serialización/validación de manifiesto y grant. |
| Runtime | Pruebas que demuestren bloqueo fail-closed antes de llamar un controller. |
| Translate agent | Prueba de que sólo invoca `start/stop` de G5 y no acepta `AudioFrame`. |
| Privacidad | Pruebas de que los audit events no aceptan ni exponen PCM/transcript/traducción. |
| UI | Estados registrados/requiere permiso/activo/fallido procedentes de snapshots reales. |
| Evidencia física | No requerida para G7 de control puro; las capacidades G3/G4/G5 mantienen sus truth labels propios. |

## Límites no negociables

- No agentes instalables desde red, carga de código remoto, plugins dinámicos o herramientas externas en G7 inicial.
- No persistencia de permisos ni consentimiento entre sesiones.
- No credenciales de proveedor en manifiestos, audit events, UI o repositorio.
- No fallback de audio/proveedor que el usuario no haya autorizado.
- No reinterpretar una capacidad `PREPARED` como `MEASURED`.
- No modificar upstreams `brilliantlabsAR/halo-firmware` ni `brilliantlabsAR/brilliant_sdk`.

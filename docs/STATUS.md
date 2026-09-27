# Estado verificable

**Regla:** el estado se calcula a partir de evidencia registrada, no se escribe a mano. La tabla de abajo se genera desde el catálogo de capacidades (`packages/contracts`, `ProductCapabilities`) y el registro de evidencias (`evidence/registry.v1.json`); los tests de `contracts` (y CI) fallan si alguien la edita o si queda desfasada. Código, flags, endpoints, UI o permisos concedidos nunca cuentan como verificación.

**Escalera de evidencia:** SIMULATED → EMULATED → PC_REAL → ANDROID_REAL → HALO_REAL. Una simulación nunca verifica nada; una ejecución en el emulador oficial de Brilliant solo verifica en EMULATED.

**Qué falta para el producto:** ANDROID_REAL se obtiene con el pack de validación física (`ANDROID_PHYSICAL_VALIDATION_PACK.md`, sección 8 para registrar la evidencia). HALO_REAL necesita un Halo físico y sigue `BLOCKED_HARDWARE`.

Estados de implementación: `unavailable` (sin código), `installed` (código sin componer en ninguna app), `dormant` (compuesto pero apagado salvo flag), `available` (compuesto y alcanzable por defecto), `verified` (medición registrada en ese entorno).

<!-- BEGIN GENERATED: dart run tool/capabilities.dart (packages/contracts) -->

| Capability | Implementation | EMULATED | ANDROID_REAL | HALO_REAL | Required for |
|---|---|---|---|---|---|
| `liveTranslation` | available | available | available | available | ANDROID_REAL |
| `speechLatency` | available | available | available | available | ANDROID_REAL |
| `echoControl` | available | available | available | available | ANDROID_REAL |
| `stopPanic` | available | **VERIFIED** | available | available | ANDROID_REAL, HALO_REAL |
| `captionRendering` | dormant | **VERIFIED** | dormant | dormant | HALO_REAL |
| `translationToDisplay` | dormant | **VERIFIED** | dormant | dormant | HALO_REAL |
| `haloConnection` | dormant | dormant | dormant | dormant | HALO_REAL |
| `haloButton` | installed | installed | installed | installed | — |
| `haloAudio` | installed | installed | installed | installed | — |
| `deviceTelemetry` | installed | installed | installed | installed | — |
| `runtimeStream` | dormant | dormant | dormant | dormant | — |
| `studioHelloHalo` | available | **VERIFIED** | available | available | — |

| Product target | Verified / required | Missing |
|---|---|---|
| ANDROID_REAL | 0 / 4 | `liveTranslation`, `speechLatency`, `echoControl`, `stopPanic` |
| HALO_REAL | 0 / 4 | `stopPanic`, `captionRendering`, `translationToDisplay`, `haloConnection` |

**PRODUCT_FINISHED:** 0 / 8 — not finished.

<!-- END GENERATED -->

Para regenerar tras añadir evidencia:

```bash
cd packages/contracts && dart run tool/capabilities.dart
```

## Acciones manuales pendientes

El propietario debe completar y verificar los ajustes indicados en [GITHUB_MANUAL_SETTINGS.md](GITHUB_MANUAL_SETTINGS.md). Hasta entonces, no se afirma que `main` esté protegida ni que exista un canal privado de vulnerabilidades.

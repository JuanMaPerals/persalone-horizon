# Ajustes manuales de GitHub pendientes

**Estado al 2026-08-20:** `JuanMaPerals/persalone-halo` es **público intencionalmente** para colaboración comunitaria. El propietario confirmó que una ruleset protege `main` y prohíbe pushes directos. La API clásica de protección de rama no refleja necesariamente una ruleset; no se debe usar su respuesta para declarar que la protección está ausente. Estos controles siguen requiriendo configuración y verificación del propietario en GitHub.

| Ajuste | Acción manual exacta | Resultado esperado | Evidencia a conservar |
|---|---|---|---|
| Protección de `main` | Mantener la ruleset ya confirmada para `main` con pull request obligatorio y sin bypass no revisado. | Bloquea push directo; exige pull request antes de merge. | Captura de la regla y enlace a la configuración. |
| Revisión de PR | **Hardening pendiente:** activar al menos una aprobación y desestimar aprobaciones obsoletas al recibir nuevos commits. | Ningún cambio llega a `main` sin revisión humana actual. | Ruleset con aprobación requerida y checks de una PR de prueba. |
| Checks requeridos | **Hardening pendiente:** exigir `verify`, `secret-scan` y `sbom` cuando los workflows hayan completado su primera ejecución. | No permite merge si falla análisis, tests o escaneo. | Ruleset con los tres checks seleccionados. |
| Bloqueo de force push y borrado | Mantener desactivados force pushes y eliminación de rama protegida. | Conserva historial y recuperación operativa. | Ruleset activa. |
| Reporte privado de vulnerabilidades | En **Settings → Code security and analysis**, activar **Private vulnerability reporting** si está disponible para el plan del repositorio. | Existe un canal privado de reporte; si la función no está disponible, publicar una dirección de contacto privada controlada por el propietario en `SECURITY.md`. | Pantalla de estado o prueba de flujo privado. |
| Dependabot alerts y secret scanning | Confirmar y mantener Dependabot alerts y GitHub secret scanning/push protection. En la comprobación de 2026-08-20 aparecen habilitados; sigue siendo necesaria evidencia del propietario al cambiar configuración. | Señales adicionales gestionadas por GitHub sobre dependencias y secretos. | Pantalla de estado; no sustituye los workflows del repositorio. |
| Acceso de GitHub Actions | Mantener el token predeterminado de Actions en lectura; no habilitar secretos de despliegue ni permisos de escritura para esta fase. | El CI solo lee el repositorio y ejecuta checks. | Configuración de Actions. |
| Propietarios y revisión | Validar que `@JuanMaPerals` mantiene ownership y añadir revisores adicionales solo cuando existan mantenedores identificados. | Accountability explícita de revisión. | `CODEOWNERS` y configuración de acceso. |

> No habilitar publicación en tiendas, despliegues, OTA, secretos de proveedores, credenciales de backend ni automatización de release como parte de G0/G1.
>
> No detener el proyecto por visibilidad pública intencional ni por una respuesta de la API clásica incompatible con rulesets. Sólo detener y escalar ante pérdida verificable de protección de rama, fallo de un control de seguridad, exposición de secretos o un push directo real a `main`.

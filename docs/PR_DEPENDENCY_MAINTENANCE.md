# Mantenimiento de pull requests dependientes

> **Propósito:** mantener una cadena de cambios revisable sin push directo a `main`, sin sobrescribir evidencia y sin ocultar conflictos que alteren comportamiento, privacidad o etiquetas de verdad.

## Principio operativo

Una rama puede depender de otra mientras la dependencia quede explícita en el campo **Base branch / PR** de la pull request. Una PR dependiente no se fusiona hasta que su base haya sido fusionada, retargeteada o rebasada contra la nueva base canónica y haya vuelto a pasar las comprobaciones requeridas.

| Regla | Obligación |
|---|---|
| Escritura | Crear commits únicamente en una rama de trabajo; nunca hacer push a `main`. |
| Base | Declarar si la PR depende de otra PR o es independiente. |
| Evidencia | Conservar commits, documentos de validación, scripts, fixtures y resultados reproducibles. No squashear o descartar evidencia por comodidad. |
| Conflictos | Detenerse y reportar un conflicto si la resolución cambia comportamiento, permisos, privacidad, contratos, pruebas o truth labels. |
| Verificación | Repetir análisis, tests, preflight y CI después de rebase/retarget. |

## Procedimiento después de fusionar una base

El mantenedor ejecuta estos pasos desde una copia limpia del repositorio. Sustituya los marcadores por ramas reales; no copie credenciales, material privado ni evidencia de usuarios en los mensajes o commits.

```bash
cd /ruta/a/persalone-halo
git fetch origin --prune
git switch <rama-dependiente>
git status --short
```

Si la PR dependiente debe pasar de una rama temporal a `main`, actualice primero su base en GitHub y luego rebásela localmente cuando sea necesario:

```bash
# Guarda una referencia local antes de reescribir commits.
git branch backup/<rama-dependiente>-before-rebase

# Rebase explícito; no usar --autosquash ni --force sin comparar el resultado.
git rebase --onto origin/main <antigua-base>
```

Si Git indica conflictos, no seleccione una resolución por defecto. Compare las alternativas y clasifique el impacto antes de continuar.

| Tipo de conflicto | Acción permitida |
|---|---|
| Sólo formato o contexto documental sin cambio de significado | Resolver, documentar el motivo y continuar. |
| Código, contrato, permiso, lifecycle, proveedor, privacidad o etiqueta de verdad | Detener rebase, registrar la diferencia y pedir/requerir revisión antes de resolver. |
| Evidencia física, logs censurados, procedimiento o resultados de ensayo | Conservar ambas versiones hasta que un revisor determine cuál es la evidencia válida. |
| Credencial, dato personal, PCM, transcripción o identificador | Detener el trabajo; eliminar el material del cambio y usar el canal privado de seguridad si corresponde. |

Después de un rebase limpio o una resolución aprobada, compare la historia y los parches antes de publicar la rama reescrita:

```bash
# Muestra la transformación de commits entre las dos bases.
git range-diff <antigua-base>...backup/<rama-dependiente>-before-rebase origin/main...HEAD

# Debe estar limpio antes de publicar.
git diff --check
bash tooling/preflight.sh --all
```

Ejecute la matriz de validación aplicable al alcance del cambio. Como mínimo, toda rama Dart/Flutter debe ejecutar `flutter pub get`, `flutter analyze` y las suites de sus paquetes modificados. Una rama que toque UI móvil debe ejecutar además `cd apps/mobile && flutter test`. Una rama que cambie un procedimiento físico no puede declarar `MEASURED` sin un ensayo reproducible en el hardware correspondiente.

## Publicación y retarget

Una vez que el estado local y la matriz sean correctos, actualice la rama remota con el método que preserve la revisión. Si la rama ya se había publicado y fue rebasada, solicite una revisión adicional de los cambios reescritos; no asuma que un check verde anterior cubre el nuevo commit.

No se automatiza el merge desde este procedimiento. Las protecciones de rama, aprobaciones, checks requeridos y configuraciones de seguridad siguen siendo acciones del propietario documentadas en [`GITHUB_MANUAL_SETTINGS.md`](GITHUB_MANUAL_SETTINGS.md).

## Registro mínimo en la PR

| Campo | Contenido requerido |
|---|---|
| Base anterior y nueva | Ramas/PRs y SHA antes/después del rebase. |
| Conflictos | `ninguno` o resumen censurado de cada conflicto y quién aprobó la resolución. |
| Cambio semántico | `ninguno` o descripción precisa de lo que cambió. |
| Evidencia preservada | Documentos, scripts, fixtures o resultados que siguen presentes. |
| Validación repetida | Comandos y resultado posterior al rebase. |
| Bloqueadores | Hardware, permisos, configuración manual GitHub o revisión humana pendiente. |

> Un rebase limpio no es evidencia de que una capacidad funcione físicamente. La verdad de hardware, audio, traducción, proveedores y agentes permanece limitada por sus propios gates reproducibles.

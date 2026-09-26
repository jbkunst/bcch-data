# bcch-data

`bcch-data` mantiene una selección de series públicas del Banco Central de Chile
como JSON estáticos actualizados automáticamente. Los datos alimentan el dashboard
**Indicadores Financieros** y pueden ser consumidos directamente por otras
aplicaciones.

El flujo es deliberadamente pequeño:

```text
BCCh → bcchr → JSON estáticos → dashboard y otros consumidores
```

## Estructura

- `config/series.yml`: catálogo declarativo de series.
- `scripts/update_data.R`: descarga, normaliza, conserva datos stale y valida.
- `api/v1/manifest.json`: índice descubrible del dataset.
- `api/v1/series/<series_id>.json`: historia completa disponible de cada serie.
- `dashboard/index.qmd`: dashboard que lee exclusivamente los JSON locales.

## Uso

Para agregar una serie, incorpora su código y grupo en `config/series.yml`. La
actualización requiere `BCCH_TOKEN` como variable de entorno y usa `bcchr`; el
token nunca se escribe en los datos.

```r
system("Rscript scripts/update_data.R")
system("Rscript scripts/update_data.R --validate-only")
system("quarto render dashboard/index.qmd --output-dir ../_site")
```

`manifest.json` permite descubrir IDs, frecuencias, cobertura y estado sin abrir
cada archivo. Una vez habilitado GitHub Pages, las rutas públicas serán:

```text
https://jbkunst.github.io/bcch-data/api/v1/manifest.json
https://jbkunst.github.io/bcch-data/api/v1/series/F073.TCO.PRE.Z.D.json
```

La actualización automática corre diariamente a las 06:17 UTC y también puede
ejecutarse manualmente. El HTML del dashboard se publica como artefacto de GitHub
Pages y no se versiona en `main`.

Se conserva la historia completa que devuelve `bcchr` para cada serie; la ventana
de cinco años es sólo una decisión de visualización del dashboard.

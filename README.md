# bcch-data

`bcch-data` mantiene una selección de series públicas del Banco Central de Chile
como JSON estáticos actualizados automáticamente. Los datos alimentan el dashboard
**Indicadores económicos** y pueden ser consumidos directamente por otras
aplicaciones.

El flujo es deliberadamente pequeño:

```text
BCCh → bcchr → JSON estáticos → dashboard y otros consumidores
```

## Estructura

- `config/series.yml`: catálogo declarativo `id` + `name`, inicialmente unificado
  desde los tres catálogos de análisis de `bcch-studio`.
- `config/indicators.yml`: selección, unidades y formato de los indicadores
  destacados.
- `scripts/update_data.R`: descarga la historia completa, normaliza y genera los
  JSON junto con el manifest.
- `api/v1/manifest.json`: índice descubrible del dataset.
- `api/v1/indicators.json`: últimos valores listos para portadas y cintas.
- `api/v1/series/<series_id>.json`: historia completa disponible de cada serie.
- `dashboard/index.qmd`: dashboard que lee exclusivamente los JSON locales.

## Uso

Para agregar una serie, incorpora su código y nombre en `config/series.yml`. La
actualización requiere `BCCH_TOKEN` como variable de entorno y usa `bcchr`; el
token nunca se escribe en los datos.

```r
system("Rscript scripts/update_data.R")
system("quarto render dashboard/index.qmd --output-dir ../_site")
```

## Revisar el API

El validador usa solamente la biblioteca estándar de Python. Comprueba el
manifest, las 94 series, el orden y unicidad de sus fechas, sus valores y la
coherencia de los indicadores destacados:

```shell
python scripts/check_api.py
python scripts/check_api.py https://jbkunst.github.io/bcch-data/api/v1
```

El primer comando revisa los archivos locales; el segundo revisa exactamente lo
publicado en GitHub Pages. Para consumir un endpoint desde Python tampoco se
requieren paquetes adicionales:

```python
import json
from urllib.request import urlopen

url = "https://jbkunst.github.io/bcch-data/api/v1/indicators.json"
with urlopen(url) as response:
    indicators = json.load(response)["indicators"]
```

`manifest.json` permite descubrir IDs, frecuencias, cobertura y estado sin abrir
cada archivo. Una vez habilitado GitHub Pages, las rutas públicas serán:

```text
https://jbkunst.github.io/bcch-data/api/v1/manifest.json
https://jbkunst.github.io/bcch-data/api/v1/indicators.json
https://jbkunst.github.io/bcch-data/api/v1/series/F073.TCO.PRE.Z.D.json
```

La actualización automática corre diariamente a las 06:17 UTC y también puede
ejecutarse manualmente. El HTML del dashboard se publica como artefacto de GitHub
Pages y no se versiona en `main`.

Se conserva la historia completa que devuelve `bcchr` para cada serie; la ventana
de cinco años es sólo una decisión de visualización del dashboard.

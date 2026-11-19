# bcch-data

`bcch-data` publica la metadata completa de las series públicas del Banco Central
de Chile y mantiene una selección de historias como JSON estáticos actualizados
automáticamente. Los datos alimentan el dashboard **Indicadores económicos** y
pueden ser consumidos directamente por otras aplicaciones.

## ¿Por qué existe?

La [Base de Datos Estadísticos (BDE)](https://si3.bcentral.cl/siete) del Banco Central de Chile sigue siendo la fuente oficial y completa. `bcch-data` no busca reemplazarla, sino complementarla con una capa pequeña para dos casos de uso frecuentes:

- consultar rápidamente una selección de indicadores económicos sin recorrer toda la BDE;
- reutilizar series desde otras aplicaciones sin repetir la misma descarga desde la API del Banco Central.

Un proceso automático descarga y valida los datos, los publica como JSON estáticos y los deja disponibles para el dashboard y otros consumidores. Esto separa la obtención de los datos de su consumo: aplicaciones como `bcch-studio` pueden usar directamente las historias publicadas y recurrir a la API del Banco Central sólo cuando una serie todavía no está disponible en `bcch-data`.

El flujo es deliberadamente pequeño. Las historias derivadas se calculan sólo
desde series oficiales ya descargadas y nunca disparan consultas adicionales:

```text
BCCh → bcchr → historias oficiales → derivadas declaradas → JSON estáticos
```

## Estructura

- `config/series.yml`: selección declarativa de historias oficiales y de las
  derivadas reproducibles que se calculan a partir de ellas.
- `config/indicators.yml`: selección, unidades y formato de los indicadores
  destacados.
- `scripts/update_data.R`: descarga la historia completa, normaliza y genera los
  JSON junto con el manifest.
- `api/v1/catalog.json`: catálogo versionado con metadata y enriquecimiento
  editorial de todas las series disponibles en BCCh.
- `api/v1/manifest.json`: descripción del dataset e índice exclusivo de las
  historias cacheadas.
- `api/v1/indicators.json`: últimos valores listos para portadas y cintas.
- `api/v1/series/<series_id>.json`: historia completa disponible de cada serie.
- `dashboard/index.qmd`: dashboard que lee exclusivamente los JSON locales.

`catalog.json` tiene un contrato independiente de las historias:

```json
{
  "schema_version": 1,
  "updated_at": "2026-09-27T04:55:25Z",
  "series_count": 25525,
  "series": []
}
```

Cada elemento de `series` incluye la metadata original y los campos editoriales
`display_name`, `measure`, `unit`, `adjustment`, `source` y
`enrichment_version`. `kind` y `official` distinguen las series oficiales de las
derivadas de `bcch-data`. La presencia de una serie en este catálogo no implica
que su historia esté cacheada; para eso se debe consultar `manifest.json`.

El catálogo se ordena por `series_id` y se escribe de forma compacta. Su
`updated_at` cambia solamente cuando cambian la metadata o el enriquecimiento;
si sus registros son idénticos, el archivo no se reescribe. En cambio,
`manifest.updated_at` registra la actualización de las historias y
`manifest.catalog_updated_at` identifica la versión efectiva de `catalog.json`.

## Uso

Para agregar una serie oficial, incorpora su código y nombre bajo `series` en
`config/series.yml`. Cuando la metadata original no identifica correctamente la
unidad, la entrada puede declarar `unit`; el generador aplica ese valor editorial
al registro correspondiente del catálogo. Una entrada bajo `derived_series` debe
usar un ID propio con prefijo `BCCHDATA.`, declarar dos fuentes oficiales
configuradas y una operación soportada. La primera operación disponible es
`subtract`; no admite cadenas de derivadas ni fechas distintas entre las fuentes.

La actualización requiere `BCCH_TOKEN` como variable de entorno y usa `bcchr`; el
token nunca se escribe en los datos.

La contribución de exportaciones netas se publica como
`BCCHDATA.CCNN.EXPORTACIONES_NETAS.V12.2018.T`. Se calcula mediante
`F033.XBS.V12.R.Z.2018.0.T - F033.IBS.V12.R.Z.2018.0.T` y conserva en su payload
los IDs de origen, la fórmula y el enlace del gráfico oficial usado para validar
la definición. Es un cálculo reproducible de `bcch-data`, no una serie oficial del
Banco Central.

```r
system("Rscript scripts/update_data.R")
system("quarto render dashboard/index.qmd --output-dir ../_site")
```

## Revisar el API

El validador usa solamente la biblioteca estándar de Python. Comprueba el
catálogo completo, el manifest, todas las historias publicadas, el orden y
unicidad de sus fechas, sus valores y la coherencia de los indicadores
destacados. Para las derivadas también verifica su procedencia y recalcula cada
observación desde las fuentes oficiales:

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
https://jbkunst.github.io/bcch-data/api/v1/catalog.json
https://jbkunst.github.io/bcch-data/api/v1/indicators.json
https://jbkunst.github.io/bcch-data/api/v1/series/F073.TCO.PRE.Z.D.json
https://jbkunst.github.io/bcch-data/api/v1/series/BCCHDATA.CCNN.EXPORTACIONES_NETAS.V12.2018.T.json
```

La actualización automática tiene dos oportunidades diarias programadas y también
puede ejecutarse manualmente. La segunda oportunidad actúa como respaldo si
GitHub Actions retrasa u omite la primera; una verificación de frescura evita más
de una descarga y un commit dentro de una ventana de 20 horas. El HTML del
dashboard se publica como artefacto de GitHub Pages y no se versiona en `main`.

Se conserva la historia completa que devuelve `bcchr` para cada serie; la ventana
de cinco años es sólo una decisión de visualización del dashboard.

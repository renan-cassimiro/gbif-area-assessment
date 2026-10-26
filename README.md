# gbif-area-assessment

Ferramenta exploratória em R para consultar, filtrar, resumir e visualizar registros de ocorrência do **GBIF** dentro de uma ou mais áreas de estudo e avaliar a **disponibilidade e distribuição espacial dos dados**. Sem modelagem ecológica, rarefação, correção de viés ou inferência estatística (ver CIDI, seção 24).

## Instalação (renv)

A infraestrutura do renv já está no projeto (`.Rprofile`, `renv/activate.R`, `renv/settings.json`, `.Rbuildignore`). **`renv.lock` não vem pronto**: gere-o na sua máquina, com acesso ao CRAN.

``` r
renv::install(c("rgbif", "sf", "dplyr", "tidyr", "ggplot2", "yaml", "logger", "rmarkdown", "knitr", "rlang"))
renv::install(c("mapedit", "leaflet", "shiny"))   # somente para input.area.mode: "draw"
renv::snapshot()                                   # grava renv.lock — versione renv.lock e renv/activate.R
```

O relatório PDF exige **pandoc** e um motor **LaTeX** (`tinytex::install_tinytex()` resolve).

## Ambiente sem root (conda) — recomendado se `sf` não carregar

`sf` precisa de PROJ/GDAL/GEOS do sistema; o renv não os fornece. O `environment.yml` instala tudo em espaço de usuário (micromamba é um binário único, sem root):

``` bash
micromamba env create -f environment.yml     # ou: mamba env create -f environment.yml
micromamba activate gbif-area-assessment
Rscript -e 'tinytex::install_tinytex()'      # LaTeX em ~/.TinyTeX, sem root (necessário para o PDF)
export RENV_CONFIG_AUTOLOADER_ENABLED=false  # usa os pacotes do conda, não a biblioteca do renv
Rscript scripts/run.R config/config.yaml
```

Neste modo o conda é a fonte da reprodutibilidade (versões no `environment.yml`; use `conda env export --no-builds > environment.lock.yml` para congelar). O renv continua válido onde as bibliotecas do sistema existem.

## Execução

``` bash
Rscript scripts/run.R config/config.yaml
```

Cada execução cria `results/run_YYYYMMDD_HHMMSS/` com `figures/`, `spatial/` (GPKG único com `areas`, `gbif_records`, `gbif_density`), `tables/` (CSV + `run_context.rds`), `logs/`, `report/gbif_area_assessment.pdf`, cópia da configuração original e efetiva e `run_status.yaml` (`completed`/`failed`). Em falha, nenhum PDF é gerado.

## Configuração

Ver comentários em `config/config.yaml`. Pontos principais:

- **Entrada**: `input.area.mode` = `gpkg` (um único arquivo; 1 polígono = análise individual, 2+ = individual + comparação) ou `draw` (um polígono desenhado no navegador, salvo em `spatial/drawn_area.gpkg`). Sem `id_column`, usa uma coluna identificadora adequada ou gera `area_01`, `area_02`, ... (registrado no log). Geometrias inválidas só são corrigidas com `fix_invalid: true`.
- **Filtros GBIF** (`gbif.filters`): só os declarados são aplicados. Aceita qualquer argumento de filtro de `rgbif::occ_data()`; os principais têm validação de tipo/valores (enums, intervalos `{min, max}`, países ISO, chaves taxonômicas). Argumentos com default não-nulo no rgbif (ex.: `occurrenceStatus = "PRESENT"`) são explicitamente anulados quando não configurados, para não haver filtro implícito.
- **Cache** (`gbif.cache`): chave = hash da geometria (WKT), filtros normalizados, defaults do rgbif anulados, API e versão do esquema de cache. Guarda `records.rds` (resposta bruta) + `meta.yaml`. Lê o cache se `enabled && use_cached && !refresh`; grava sempre que `enabled`; a versão anterior é arquivada em `archive/<timestamp>/`. Entrada inconsistente = erro, nunca reutilização silenciosa.

## Download em massa (`gbif.query.method: download`)

Para áreas com mais de \~100 mil registros (ex.: bacias da Amazônia), use `method: download`: o GBIF prepara o arquivo (`rgbif::occ_download`, formato SIMPLE_CSV) e a ferramenta espera, baixa, importa e guarda no mesmo cache bruto.

- Credenciais: copie `.Renviron.example` para `~/.Renviron` (ou para `.Renviron` na raiz do projeto, já ignorado pelo Git) e preencha `GBIF_USER`, `GBIF_PWD`, `GBIF_EMAIL`; reinicie a sessão do R.
- Um download por área. A chave do pedido fica em `download_pending.yaml` na pasta do cache: se a execução cair ou estourar `download_wait_minutes`, rodar de novo **retoma o mesmo pedido** (não cria outro). O DOI do download vai para o `meta.yaml` e o relatório.
- Filtros suportados: os tipados do registro (ver `docs/future_work.md` para o que ficou de fora).
- O mapa de pontos usa amostra sistemática acima de `analysis.max_map_points`; `output.write_records_layer: false` evita gravar milhões de pontos no GPKG.
- Status: testado com as chamadas ao GBIF simuladas; **ainda não validado contra a API real**.

## Independent filtering (`scripts/filter.R`)

Post-retrieval filtering of **existing** GBIF cache entries, with its own run directory and PDF report. It never calls `rgbif`, never submits or polls a GBIF download, never needs credentials, and never modifies the cache (MD5 of `records.rds` and `meta.yaml` is recorded at load and verified at the end).

``` bash
Rscript scripts/filter.R config/filter.yaml
```

- **Input** (`config/filter.yaml`): `input.cache_entries` lists explicit cache-entry directories (one per area; the cache root is never scanned). Each needs `records.rds` + `meta.yaml` with `cache_key`, supported `cache_schema` and `area_id`; the key must match the directory name, the row count must match `n_records`, and duplicate keys or `area_id`s are rejected. Area polygons are rebuilt from `geometry_wkt`; if absent or invalid, spatial metrics and maps are skipped for that area (WARN).
- **Filter v1 – `filters.spatial.raster`**: one raster, **EPSG:4326** (a raster in another CRS, or without CRS, is rejected; nothing is reprojected), exact matching of numeric **cell codes** in `accepted_values` (no ranges, thresholds, labels or combinations). Out-of-extent, NoData and non-accepted values are removed and counted separately from technical-validation removals. Categorical rasters are matched by raw codes, not labels. The raster is identified by path and MD5 (main file only for multi-file formats).
- **Extension point**: `filter_registry()` in `R/filtering.R` (id, category, `validate`/`apply`/`describe`). Only `spatial.raster` exists; no quality filters are implemented.
- **Output** (`results/filtering/run_YYYYMMDD_HHMMSS/`): `config_original.yaml`, `config_effective.yaml`, `run_status.yaml`, `logs/`, `tables/` (`input_entries`, `profile_raw`, `profile_before_filter`, `profile_after_filter`, `profile_by_year`, `profile_comparison`, `filter_summary`, `removed_records`, `run_context.rds`), `spatial/gbif_filtered_records.gpkg` (retained records + derived `raster_value`; `areas` when geometry is available), `figures/`, `report/filtering_report.pdf`. Exit status is non-zero on failure (`run_status.yaml` = `failed`, no PDF).
- **Profiles**: *raw* (as stored in the cache), *pre-filter* (after technical validation) and *post-filter* use the same per-area metrics. Stage denominators are the records passed into each stage; per-stage removals are not necessarily unique across criteria. A zero-record result completes with a warning.
- **Dependency**: `terra` (declared in `DESCRIPTION`). Run `renv::install("terra")` and `renv::snapshot()`.
- **Tests**: `Rscript tests/test_filtering.R` (45 checks on synthetic rasters and cache entries; needs pandoc + LaTeX for the report checks). Not covered: Windows, real GBIF caches at scale.

## Outputs: GeoParquet, Darwin Core and run association

- **GeoParquet** (`output.spatial_format: geoparquet`, default): one `.parquet` per layer in `spatial/` (`areas`, `gbif_records`, `gbif_density`; filtering: `gbif_filtered_records`, `areas`), written by this tool with `arrow` as GeoParquet **1.0.0** (WKB, `geo` metadata with bbox and geometry types, no `crs` key = OGC:CRS84, which equals WGS 84 lon/lat; all layers are EPSG:4326). List columns are dropped. Set `gpkg` to get a single `.gpkg` instead. Needs `arrow` (`r-arrow` on conda-forge). Validated by reading the files with `arrow` and `geopandas`.
- **Darwin Core Archive** (`output.darwin_core.enabled: true`, in either config): one zip per area in `darwincore/` with `occurrence.txt` (tab-delimited; `gbifID` is the core id), `meta.xml`, `eml.xml` and `provenance.yaml`. `output.darwin_core.creator` is required (EML needs a creator). Columns that are Darwin Core / Dublin Core / GBIF terms are mapped to term URIs; any other column (e.g. the derived `raster_value`) goes to `dynamicProperties` as JSON. EML carries title, creator, coverage, methods (query, filters, cache key, DOI, raster) and the GBIF citation when a download DOI exists. Records keep their own `license`. **Check before publishing:** GBIF-specific column URIs use `http://rs.gbif.org/terms/1.0/` and were not validated against the GBIF Data Validator; a filtered dataset derived from a GBIF download is not registered as a GBIF "derived dataset" by this tool.
- **Associating runs**: `output.run_label` prefixes the run folder and log (`<label>_run_<timestamp>`). In `filter.yaml`, `input.from_run` points to a completed assessment run and takes its cache entries from `tables/retrieval.csv` + `config_effective.yaml`; the filtering run inherits the parent's label unless it sets its own. Both runs write a `lineage` block (run type, id, label, parent run, cache keys per area) in `run_status.yaml`; the report shows run type, label and parent. A cache entry can be shared by several runs, so `from_run` records which run was used as the starting point, not a one-to-one relation.
- **Dependencies**: `arrow` and `zip` were added (`renv::install(c("arrow", "zip"))`, then `renv::snapshot()`).
- **Tests**: `Rscript tests/test_outputs.R` (34 checks) and `Rscript tests/test_filtering.R` (45 checks); last run on Linux (R 4.4, conda-forge `arrow`/`terra`): all passed.

## Decisões de implementação

- Cada área é consultada separadamente (um cache por área); registros em áreas sobrepostas contam em cada uma.
- Filtros com vários valores (ex.: dois `basisOfRecord`) viram uma requisição por combinação (OU dentro do filtro) e são unidos e deduplicados por `gbifID`.
- Registros removidos no processamento (coordenadas ausentes/inválidas, `gbifID` duplicado, fora do polígono) são contados por motivo; nenhum filtro científico é aplicado.
- Densidade: grade quadrada (`density_cell_km`) recortada pelo polígono, em CRS métrico (Lambert azimutal de áreas iguais centrado nas áreas, ou `analysis.metric_crs`). Cobertura = % de células com registros.
- Módulos são carregados por `sys.source()` em ambiente próprio (sem estado global); a documentação roxygen2 está nos arquivos de `R/` (`roxygen2::roxygenise()` gera `man/` se desejado).

## Limitações conhecidas

- No modo `search`, a API do GBIF limita a 100 000 registros por consulta; acima disso a execução para com erro (use `method: download`).
- Polígonos muito detalhados geram WKT longo demais para a URL (`gbif.query.max_wkt_chars`): simplifique o polígono antes; a ferramenta nunca simplifica sozinha.
- Esta versão não tem testes automatizados (CIDI, seção 2).

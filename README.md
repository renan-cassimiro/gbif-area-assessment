# gbif-area-assessment

Ferramenta exploratória em R para consultar, filtrar, resumir e visualizar registros de ocorrência do **GBIF** dentro de uma ou mais áreas de estudo e avaliar a **disponibilidade e distribuição espacial dos dados**. Sem modelagem ecológica, rarefação, correção de viés ou inferência estatística (ver CIDI, seção 24).

## Instalação (renv)

A infraestrutura do renv já está no projeto (`.Rprofile`, `renv/activate.R`, `renv/settings.json`, `.Rbuildignore`). **`renv.lock` não vem pronto**: gere-o na sua máquina, com acesso ao CRAN.

```r
renv::install(c("rgbif", "sf", "dplyr", "tidyr", "ggplot2", "yaml", "logger", "rmarkdown", "knitr", "rlang"))
renv::install(c("mapedit", "leaflet", "shiny"))   # somente para input.area.mode: "draw"
renv::snapshot()                                   # grava renv.lock — versione renv.lock e renv/activate.R
```

O relatório PDF exige **pandoc** e um motor **LaTeX** (`tinytex::install_tinytex()` resolve).

## Execução

```bash
Rscript scripts/run.R config/config.yaml
```

Cada execução cria `results/run_YYYYMMDD_HHMMSS/` com `figures/`, `spatial/` (GPKG único com `areas`, `gbif_records`, `gbif_density`), `tables/` (CSV + `run_context.rds`), `logs/`, `report/gbif_area_assessment.pdf`, cópia da configuração original e efetiva e `run_status.yaml` (`completed`/`failed`). Em falha, nenhum PDF é gerado.

## Configuração

Ver comentários em `config/config.yaml`. Pontos principais:

- **Entrada**: `input.area.mode` = `gpkg` (um único arquivo; 1 polígono = análise individual, 2+ = individual + comparação) ou `draw` (um polígono desenhado no navegador, salvo em `spatial/drawn_area.gpkg`). Sem `id_column`, usa uma coluna identificadora adequada ou gera `area_01`, `area_02`, ... (registrado no log). Geometrias inválidas só são corrigidas com `fix_invalid: true`.
- **Filtros GBIF** (`gbif.filters`): só os declarados são aplicados. Aceita qualquer argumento de filtro de `rgbif::occ_data()`; os principais têm validação de tipo/valores (enums, intervalos `{min, max}`, países ISO, chaves taxonômicas). Argumentos com default não-nulo no rgbif (ex.: `occurrenceStatus = "PRESENT"`) são explicitamente anulados quando não configurados, para não haver filtro implícito.
- **Cache** (`gbif.cache`): chave = hash da geometria (WKT), filtros normalizados, defaults do rgbif anulados, API e versão do esquema de cache. Guarda `records.rds` (resposta bruta) + `meta.yaml`. Lê o cache se `enabled && use_cached && !refresh`; grava sempre que `enabled`; a versão anterior é arquivada em `archive/<timestamp>/`. Entrada inconsistente = erro, nunca reutilização silenciosa.

## Decisões de implementação

- Cada área é consultada separadamente (um cache por área); registros em áreas sobrepostas contam em cada uma.
- Filtros com vários valores (ex.: dois `basisOfRecord`) viram uma requisição por combinação (OU dentro do filtro) e são unidos e deduplicados por `gbifID`.
- Registros removidos no processamento (coordenadas ausentes/inválidas, `gbifID` duplicado, fora do polígono) são contados por motivo; nenhum filtro científico é aplicado.
- Densidade: grade quadrada (`density_cell_km`) recortada pelo polígono, em CRS métrico (Lambert azimutal de áreas iguais centrado nas áreas, ou `analysis.metric_crs`). Cobertura = % de células com registros.
- Módulos são carregados por `sys.source()` em ambiente próprio (sem estado global); a documentação roxygen2 está nos arquivos de `R/` (`roxygen2::roxygenise()` gera `man/` se desejado).

## Limitações conhecidas

- A API de busca do GBIF limita a 100 000 registros por consulta; acima disso a execução para com erro (downloads em lote via `occ_download` estão fora desta versão).
- Polígonos muito detalhados geram WKT longo demais para a URL (`gbif.query.max_wkt_chars`): simplifique o polígono antes; a ferramenta nunca simplifica sozinha.
- Esta versão não tem testes automatizados (CIDI, seção 2).

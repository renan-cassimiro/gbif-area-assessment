# gbif-area-assessment

Ferramenta exploratória em R para consultar, filtrar, resumir e visualizar registros de ocorrência do **GBIF** dentro de uma ou mais áreas de estudo e avaliar a **disponibilidade e distribuição espacial dos dados**. Sem modelagem ecológica, rarefação, correção de viés ou inferência estatística (ver CIDI, seção 24).

## Instalação (renv)

A infraestrutura do renv já está no projeto (`.Rprofile`, `renv/activate.R`, `renv/settings.json`, `.Rbuildignore`). **`renv.lock` não vem pronto**: gere-o na sua máquina, com acesso ao CRAN.

``` r
renv::install(c("rgbif", "sf", "terra", "dplyr", "tidyr", "ggplot2", "yaml", "logger", "rmarkdown", "knitr", "rlang"))
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

## Filtragem posterior dos registros em cache

A filtragem posterior é um fluxo independente do download/avaliação. Ela lê apenas as entradas de cache explicitamente listadas em `config/filter.yaml`; não chama a API do GBIF, não exige credenciais e não altera `records.rds` ou `meta.yaml`. Antes de executar, substitua o caminho de cache de exemplo e o caminho do raster.

```bash
Rscript scripts/filter.R config/filter.yaml
```

Teste determinístico do núcleo do filtro (cria um raster sintético local; não acessa o GBIF):

```bash
Rscript tests/test_filtering.R .
```

A versão inicial aceita um único raster de valores discretos. O raster deve estar explicitamente em **EPSG:4326**; CRS ausente ou diferente interrompe a execução, sem reprojeção automática. `accepted_values` contém os códigos de célula a manter. Cada execução cria `results/filtering/run_*/` com perfis brutos/pré/pós-filtro, resumo das exclusões por etapa e motivo, registros retidos, metadados, log e relatório PDF independente. A filtragem não implementa regras de qualidade taxonômica ou outras regras futuras.

## Download em massa (`gbif.query.method: download`)

Para áreas com mais de \~100 mil registros (ex.: bacias da Amazônia), use `method: download`: o GBIF prepara o arquivo (`rgbif::occ_download`, formato SIMPLE_CSV) e a ferramenta espera, baixa, importa e guarda no mesmo cache bruto.

- Credenciais: copie `.Renviron.example` para `~/.Renviron` (ou para `.Renviron` na raiz do projeto, já ignorado pelo Git) e preencha `GBIF_USER`, `GBIF_PWD`, `GBIF_EMAIL`; reinicie a sessão do R.
- Um download por área. A chave do pedido fica em `download_pending.yaml` na pasta do cache: se a execução cair ou estourar `download_wait_minutes`, rodar de novo **retoma o mesmo pedido** (não cria outro). O DOI do download vai para o `meta.yaml` e o relatório.
- Filtros suportados: os tipados do registro (ver `docs/future_work.md` para o que ficou de fora).
- O mapa de pontos usa amostra sistemática acima de `analysis.max_map_points`; `output.write_records_layer: false` evita gravar milhões de pontos no GPKG.
- Status: testado com as chamadas ao GBIF simuladas; **ainda não validado contra a API real**.

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

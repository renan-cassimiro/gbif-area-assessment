# CIDI v2 — Diagnóstico exploratório de dados de biodiversidade do GBIF

> Documento derivado da implementação (engenharia reversa), versão da ferramenta **0.1.0**.
> Substitui o CIDI v1. Onde a implementação diverge do v1, a divergência está listada na seção 22.
> Itens ainda não validados estão na seção 21.

---

## 1. Objetivo

Ferramenta exploratória em **R** para consultar, filtrar, resumir e visualizar registros de ocorrência do **GBIF**
dentro de uma ou mais áreas de estudo, avaliando de forma rápida e reprodutível a **disponibilidade e distribuição
espacial dos dados** (inicialmente para áreas candidatas ao doutorado; uso previsto por bacias da Amazônia).

Permanece deliberadamente simples: sem modelagem ecológica, correção de viés amostral, rarefação, estimativa de
riqueza ou estatística inferencial.

---

## 2. Requisitos gerais

- R (>= 4.1), com `renv`; repositório Git existente; código modular com funções de responsabilidade única.
- Funções documentadas com roxygen2; configuração em YAML; logs estruturados (`logger`); execução não interativa.
- Cache local da resposta bruta do GBIF; resultados organizados por execução.
- Sem testes automatizados nesta versão.

Execução:

```bash
Rscript scripts/run.R config/config.yaml
```

Os módulos de `R/` são carregados por `sys.source()` em um ambiente privado (sem estado global); o `DESCRIPTION` serve
ao `renv` e à documentação (`roxygen2::roxygenise()` gera `man/` se desejado).

---

## 3. Entrada das áreas

Modo definido explicitamente em `input.area.mode` (`gpkg` ou `draw`, mutuamente exclusivos).

### 3.1 `gpkg`
- Um único arquivo `.gpkg` (`input.area.path`). Se tiver mais de uma camada, `input.area.layer` é obrigatório.
- 1 polígono = análise individual; 2+ = análise individual de cada área + comparação.
- Apenas `POLYGON`/`MULTIPOLYGON`, com CRS definido; Z/M removidos; saída padronizada em EPSG:4326 com coluna `area_id`.
- Identificadores: `input.area.id_column` (deve ser único e não vazio); sem ele, usa a primeira coluna candidata
  adequada (`area_id`, `id`, `name`, `nome`, `area`, `site`, `label`); sem coluna adequada, gera `area_01`, `area_02`, ...
  (registrado no log).
- Geometria inválida: erro, exceto com `input.area.fix_invalid: true` (usa `st_make_valid`, registrado em WARN; falha se o
  resultado não for polígono válido).
- Áreas sobrepostas geram WARN (registros nas sobreposições contam em cada área).

### 3.2 `draw`
- Um único polígono desenhado em mapa interativo (`mapedit`/`leaflet`/`shiny`, pacotes sugeridos).
- Viewer: painel do RStudio quando em sessão interativa do RStudio; navegador quando há display; caso contrário erro
  orientando a usar `scripts/draw_area.R`.
- Salvo em `results/run_*/spatial/drawn_area.gpkg`.
- `scripts/draw_area.R` (console interativo) desenha e grava `data/input/areas.gpkg` (não sobrescreve), para uso posterior
  em modo `gpkg`.

`mode: "draw"` não pode ser combinado com `path`/`layer`.

---

## 4. Arquivo de configuração (YAML)

Valores padrão são completados e validados em `validate_config()`; seções desconhecidas geram WARN.

```yaml
project:
  name: "gbif_area_assessment"

input:
  area:
    mode: "gpkg"                 # gpkg | draw
    path: "data/input/areas.gpkg"
    layer: null
    id_column: null
    fix_invalid: false

gbif:
  filters: {}                    # apenas filtros declarados são aplicados
  query:
    method: "download"           # download | search   (padrão do código: search)
    download_wait_minutes: 720
    download_poll_seconds: 30
    keep_download_zip: false
    max_records: 100000          # search (1..100000)
    page_size: 300               # search (1..300)
    max_retries: 3
    retry_wait_seconds: 5
    max_filter_combinations: 50  # search; sem entrada no config de exemplo
    max_wkt_chars: 8000          # search; sem entrada no config de exemplo
  cache:
    enabled: true
    directory: "data/cache/gbif"
    use_cached: true
    refresh: false

analysis:
  density_cell_km: 5
  top_n: 10
  low_coverage_pct: 20
  max_map_points: 50000
  metric_crs: "auto"             # auto = Lambert azimutal de áreas iguais centrado nas áreas, ou ex.: "EPSG:5880"

output:
  directory: "results"
  write_records_layer: true

logging:
  level: "INFO"                  # DEBUG | INFO | WARN | ERROR
```

Caminhos relativos são resolvidos a partir da raiz do projeto.

---

## 5. Filtros GBIF

- Opcionais, definidos em `gbif.filters`, aplicados somente se configurados, registrados no log e no relatório;
  valores `null` são ignorados.
- **Registro tipado** (`gbif_filter_registry()`):
  - enums: `basisOfRecord`, `occurrenceStatus`, `continent`, `mediaType`, `license`;
  - lógicos: `hasCoordinate`, `hasGeospatialIssue`, `repatriated`, `isInCluster`;
  - chaves inteiras: `taxonKey`, `acceptedTaxonKey`, `kingdomKey`, `phylumKey`, `classKey`, `orderKey`, `familyKey`,
    `genusKey`, `subgenusKey`, `speciesKey`;
  - países ISO-2: `country`, `publishingCountry`;
  - intervalos `{min, max}` ou `"a,b"` (ambos os limites obrigatórios): inteiros `year`, `month` (1–12); numéricos
    `decimalLatitude`, `decimalLongitude`, `elevation`, `depth`, `coordinateUncertaintyInMeters`; datas `eventDate`,
    `lastInterpreted`;
  - texto: `scientificName`, `datasetKey`, `typeStatus`, `recordNumber`, `recordedBy`, `institutionCode`,
    `collectionCode`, `catalogNumber`, `stateProvince`, `waterBody`, `locality`, `issue`, `establishmentMeans`,
    `protocol`, `publishingOrg`, `gadmGid`.
- **Genéricos:** qualquer outro argumento de `rgbif::occ_data()` é aceito (validação genérica) **apenas no modo `search`**.
  Argumentos técnicos (`geometry`, `limit`, `start`, `facet*`, ...) não podem ser definidos como filtro.
- **Validação:** existência (com sugestão de nome próximo), tipo, valores permitidos, intervalos e incompatibilidade
  (`hasCoordinate: false` é recusado, pois a consulta espacial só retorna registros georreferenciados). Erros interrompem
  a execução com mensagem clara.
- **Sem filtros implícitos:** argumentos do rgbif com default não nulo (ex.: `occurrenceStatus = "PRESENT"`) são anulados
  explicitamente (`NULL`) quando não configurados (modo `search`).
- **Modo `download`:** somente filtros do registro tipado são aceitos (`check_download_filters()`); os demais dão erro.

---

## 6. Consulta ao GBIF — dois métodos

Cada área é consultada **separadamente** (um cache por área).

### 6.1 `search` (paginado, `rgbif::occ_data`)
- Filtros multivalorados viram **uma requisição por combinação** (OU dentro do filtro), unidas e deduplicadas por `gbifID`.
- Paginação de `page_size` registros; retry com espera crescente (`max_retries`); erro se a contagem exceder `max_records`
  (teto da API: 100 000) ou se a paginação terminar incompleta.
- Geometria enviada como WKT com anéis reorientados (exterior anti-horário, buracos horários), 6 casas decimais, sem
  simplificação; erro se o WKT exceder `max_wkt_chars`.
- Chamada extra de contagem sem filtros → `n_total_without_filters` (NA em caso de falha, com WARN).

### 6.2 `download` (assíncrono, `rgbif::occ_download`, SIMPLE_CSV)
- Predicados: `pred_within(WKT)` + um predicado por filtro (`pred`, `pred_in`, `pred_gte`/`pred_lte` para intervalos),
  combinados por AND.
- Credenciais em variáveis de ambiente `GBIF_USER`, `GBIF_PWD`, `GBIF_EMAIL` (`~/.Renviron`; modelo em `.Renviron.example`);
  ausência dá erro antes do pedido.
- Fluxo: pedido → espera com *polling* (`download_poll_seconds`, até `download_wait_minutes`) → `occ_download_get` →
  `occ_download_import` → limpeza do zip (a menos que `keep_download_zip`).
- **Retomada:** a chave do pedido fica em `download_pending.yaml` na pasta do cache; nova execução retoma o mesmo pedido.
  Estados `CANCELLED`, `KILLED`, `FAILED`, `FILE_ERASED` descartam o pendente e interrompem com erro.
- Metadados guardados: `download_key`, `download_doi`, `download_format`, `download_total_records`.
- Aviso se o número importado diferir de `totalRecords`.

Falhas de API: ERROR e encerramento controlado; nenhum relatório é produzido.

---

## 7. Cache

- **Chave:** hash (`rlang::hash`) de um YAML canônico com: versão do esquema de cache, identificador da API, WKT da
  geometria, filtros normalizados e ordenados, nomes dos defaults do rgbif anulados e, apenas no modo `download`, o método
  (chaves do modo `search` permanecem estáveis).
- **Entrada de cache:** `<diretório>/<chave>/records.rds` (resposta bruta) + `meta.yaml` (chave, data/hora, área,
  versão da ferramenta, esquema, WKT, filtros, nº de registros, contagem sem filtros, versão do rgbif e, se download,
  chave/DOI).
- **Comportamento:** lê o cache se `enabled && use_cached && !refresh`; grava sempre que `enabled`. A versão anterior de
  uma entrada é arquivada em `archive/<timestamp>/` (nunca sobrescrita silenciosamente). Entrada inconsistente
  (chave/esquema diferente ou contagem divergente) é **erro**, nunca reutilizada.
- `enabled: false`: sem leitura nem escrita (o download usa diretório temporário).

---

## 8. Processamento dos registros

1. `combine_area_records()` — adiciona `area_id`, harmoniza tipos de colunas entre áreas.
2. `validate_records()` — apenas verificações técnicas: coordenadas ausentes/não numéricas, fora da faixa válida,
   `gbifID` duplicado dentro da área; coerção numérica de coordenadas, `year`, `month`, incerteza; colunas taxonômicas
   ausentes são criadas como `NA`.
3. `records_to_sf()` — EPSG:4326, preservando todas as colunas originais.
4. `assign_records_to_areas()` — remove pontos fora do polígono da área consultada. **Verificação pulada no modo
   `download`** (o GBIF já aplicou o polígono; a checagem é lenta em milhões de pontos).

Remoções são contadas por motivo e área (log WARN, tabela `removed_records`, relatório). Nenhum filtro científico é aplicado.

---

## 9. Métricas (descritivas)

CRS métrico: `metric_crs: "auto"` (Lambert azimutal de áreas iguais centrado nas áreas) ou CRS projetado informado.

- **Registros** (`area_summary`): área (km²), registros sem filtros, recuperados, processados, registros/km².
- **Taxonomia** (`taxonomic_*`): nº de espécies, gêneros e famílias distintos (campos `species`, `genus`, `family` do
  backbone; registros sem espécie contados à parte); `top_n` classes, famílias e espécies por área (com `%`).
- **Espacial** (`spatial_summary`, camada `gbif_density`): grade quadrada de `density_cell_km` recortada pelo polígono;
  cada registro conta em exatamente uma célula; cobertura = % de células com registro; concentração = % dos registros nas
  10% células mais povoadas. Erro se a grade passar de 200 000 células.
- **Temporal** (`temporal_*`): registros e espécies por ano, intervalo de anos, anos com registros, registros sem ano.

Áreas sem registros recebem zeros; execução com zero registros termina com WARN e resultados vazios (não é falha).

---

## 10. Comparação entre áreas

Somente com 2+ áreas, e apenas descritiva (sem testes): tabela por área (registros, registros/km², espécies, gêneros,
famílias, anos, cobertura, concentração) e espécies compartilhadas por par de áreas (compartilhadas, união, Jaccard).

---

## 11. Produtos espaciais

Um único GPKG: `spatial/gbif_area_assessment.gpkg` com as camadas `areas` (com `area_km2`), `gbif_records` e
`gbif_density`. Camadas vazias são omitidas (WARN); `output.write_records_layer: false` omite `gbif_records`. Colunas de
lista e duplicatas por caixa são removidas da camada de registros (registrado no log). Recusa-se a sobrescrever arquivo existente.

---

## 12. Visualizações (`ggplot2` + `sf`, PNG)

Mapas: áreas; registros por área (amostra sistemática acima de `max_map_points`, indicada no subtítulo); densidade por área.
Gráficos: registros e espécies por ano; registros por área; espécies por área; principais classes; comparação entre áreas
(quando aplicável).

---

## 13. Relatório PDF

Gerado por `report/report_template.Rmd` (idioma: **inglês**), a partir de `tables/run_context.rds`; o `.tex` é gerado pelo
`rmarkdown` e compilado pelo próprio código (`xelatex`/`pdflatex`/`lualatex`, duas passadas) em diretório temporário com
as figuras em caminhos relativos. Requer pandoc e motor LaTeX.

Seções: **Identificação** (projeto, execução, data/hora, versão da ferramenta, Git — commit/branch/alterações —, R,
plataforma, `renv` ativo, md5 do `renv.lock`, arquivo e configuração efetiva); **Áreas**; **Consulta GBIF** (filtros, origem
API/cache, método, data da consulta, chave de cache, DOI, contagens, registros removidos, avisos/erros);
**Caracterização**; **Comparação** (se aplicável); **Limitações** (geradas por `build_limitations()`: filtros usados,
exclusões, ausência de dados, baixa cobertura espacial, DOIs dos downloads e ressalvas metodológicas fixas). Sem
interpretação ecológica automática.

---

## 14. Logs

`logger`, níveis DEBUG/INFO/WARN/ERROR, console + arquivo `logs/run_YYYYMMDD_HHMMSS.log`; cada etapa registra início, fim e
duração; avisos do R são convertidos em WARN. Mensagens WARN/ERROR são coletadas e listadas no relatório.
Mensagens anteriores à criação do diretório da execução vão só ao console.

---

## 15. Estrutura do projeto

```text
gbif-area-assessment/
├── DESCRIPTION  README.md  .gitignore  .gitattributes  .Rbuildignore  .Rprofile  .Renviron.example
├── renv/ (activate.R, settings.json, .gitignore)      # renv.lock: gerar com renv::snapshot()
├── config/config.yaml
├── R/
│   ├── utils.R  logging.R  config.R  area_input.R
│   ├── gbif_filters.R  gbif_query.R  gbif_download.R  gbif_cache.R  gbif_processing.R
│   ├── metrics.R  spatial_outputs.R  plots.R  report.R  pipeline.R
├── report/report_template.Rmd
├── scripts/ (run.R, draw_area.R)
├── data/input/
├── docs/ (CIDI.md, future_work.md)
└── results/run_YYYYMMDD_HHMMSS/
    ├── config_original.yaml  config_effective.yaml  run_status.yaml
    ├── figures/  spatial/  tables/ (CSV + run_context.rds)  logs/  report/
```

`data/cache/` (cache GBIF), `results/` e `.Renviron` são ignorados pelo Git.

---

## 16. Funções principais

| Módulo | Funções |
|---|---|
| config | `read_config`, `validate_config` |
| logging | `setup_logging`, `set_log_level`, `add_log_file`, `lg_debug/info/warn/error` |
| area_input | `load_area`, `prepare_areas`, `draw_area` |
| gbif_filters | `normalize_gbif_filters`, `gbif_filter_registry`, `expand_filter_sets`, `rgbif_default_overrides` |
| gbif_query | `area_to_wkt`, `build_gbif_query`, `query_gbif`, `get_gbif_records`, `bind_records` |
| gbif_download | `check_download_filters`, `build_download_predicates`, `query_gbif_download` |
| gbif_cache | `build_cache_key`, `find_cached_query`, `save_gbif_cache`, `load_gbif_cache` |
| gbif_processing | `combine_area_records`, `validate_records`, `records_to_sf`, `assign_records_to_areas` |
| metrics | `get_metric_crs`, `area_km2`, `calculate_area_metrics`, `calculate_taxonomic_metrics`, `calculate_temporal_metrics`, `calculate_density`, `calculate_comparison` |
| spatial_outputs | `create_spatial_layers`, `write_spatial_layers`, `write_output_tables` |
| plots | `plot_areas`, `plot_records`, `plot_density`, `plot_temporal_distribution`, `plot_records_by_area`, `plot_species_by_area`, `plot_taxon_groups`, `plot_area_comparison`, `save_plot` |
| report | `build_limitations`, `render_report`, `compile_latex` |
| pipeline | `run_assessment` (retorna 0/1; grava `run_status.yaml`) |

---

## 17. Dependências

Imports: `rgbif`, `sf`, `dplyr`, `tidyr`, `ggplot2`, `yaml`, `logger`, `rmarkdown`, `knitr`, `rlang` (hash da chave de cache).
Suggests: `mapedit`, `leaflet`, `shiny` (modo `draw`), `roxygen2`. `rstudioapi` é usado opcionalmente (detecção do RStudio)
e deve constar em Suggests. Sistema: pandoc e motor LaTeX para o PDF.

---

## 18. Fluxo de execução

```text
iniciar logging → ler/validar configuração → criar results/run_* e log em arquivo
→ carregar/desenhar áreas → para cada área: construir consulta → chave de cache
    ├── cache encontrado (e permitido) → carregar
    └── ausente/refresh → search ou download → salvar cache
→ combinar, validar, converter para sf, (verificar polígono) → métricas (+ comparação)
→ camadas GPKG + tabelas CSV → figuras → contexto (.rds) → PDF → run_status.yaml
```

---

## 19. Casos especiais

- Nenhum registro: WARN, resultados vazios, relatório gerado.
- Uma área: só análise individual; múltiplas: individual + comparação.
- Cache inconsistente: erro (usar `refresh: true`).
- Falha de API/LaTeX: ERROR, `run_status.yaml` = `failed`, sem PDF.
- Geometria inválida: erro, salvo `fix_invalid: true`; WKT grande demais (`search`): erro, sem simplificação silenciosa.
- Pedido de download interrompido ou fora do prazo: retomado na próxima execução.

---

## 20. Fora do escopo

Testes automatizados; modelagem ecológica; rarefação; riqueza verdadeira; correção de viés; SDMs; conectividade;
integração com OBIA; hipótese ecológica; estatística inferencial; outras fontes além do GBIF. Melhorias planejadas:
`docs/future_work.md`.

---

## 21. Estado de validação

**Verificado** (Linux, R 4.3, GBIF simulado): validação de configuração e filtros; chave e ciclo do cache (incluindo
arquivamento); fluxo `download` com `occ_download`, `occ_download_meta` e `occ_download_get` simulados (predicados reais do
rgbif, retomada de pedido pendente, cache hit); pipeline completo com 2 áreas (GPKG, 13 tabelas, 10 figuras, PDF de 10
páginas); caso sem registros; erros de configuração; falha de rede com ERROR e `run_status.yaml`.

**Não validado:**
- consultas reais ao GBIF em ambos os métodos (paginação, `NULL` nos defaults do rgbif, colunas do SIMPLE_CSV, tamanho de
  WKT aceito no download, comportamento de `occurrenceStatus` ausente em downloads);
- erro `tipo de subscrito inválido 'list'` na 2ª página do modo `search` observado em campo (requer traceback);
- modo `draw` (`mapedit`) e compilação LaTeX no Windows com a correção atual;
- desempenho com milhões de registros (grade de densidade, GPKG de registros);
- `renv.lock` (precisa ser gerado com acesso ao CRAN).

---

## 22. Desvios em relação ao CIDI v1

| v1 | Implementação |
|---|---|
| `results/` fixo | pasta por execução `results/run_YYYYMMDD_HHMMSS/` (sem sobrescrita) |
| consulta GBIF única (`rgbif`) | dois métodos (`search` e `download`); consulta por área |
| filtros: qualquer filtro suportado pelo `rgbif` | idem no `search`; só filtros tipados no `download` |
| pacote R com carregamento padrão | módulos carregados por `sys.source()`; `DESCRIPTION` só para `renv`/docs |
| relatório sem idioma definido | relatório em inglês |
| `assign_records_to_areas` sempre | pulado no `download` |
| mapa com todos os registros | amostra sistemática acima de `max_map_points` |
| config sem parâmetros de escala | `max_map_points`, `write_records_layer`, `download_*`, `keep_download_zip` |
| — | `rlang` (hash), `scripts/draw_area.R`, `.Renviron.example`, `docs/future_work.md`, `run_status.yaml` |

---

## 23. Critério de conclusão

`Rscript scripts/run.R config/config.yaml` executa, a partir de área por GPKG (ou desenho salvo como GPKG): consulta ao
GBIF (`search` ou `download`) com os filtros configurados; cache bruto reutilizável e com `refresh`; registros espaciais;
métricas descritivas; mapas e gráficos; comparação com 2+ áreas; camadas em GPKG; PDF; logs detalhados; registro de
configuração, origem dos dados (API/cache, DOI) e ambiente (Git, R, `renv`) — de forma reprodutível com `renv`.
**Pendente para considerar o critério cumprido em produção:** os itens "não validados" da seção 21.

---

## Alterações posteriores ao v2 (ferramenta 0.1.0 + saídas)

- `scripts/filter.R` (módulo `R/filtering.R`): filtragem independente de entradas de cache por raster EPSG:4326 (ver README).
- `output.spatial_format: geoparquet | gpkg` (padrão geoparquet; GeoParquet 1.0.0 escrito com `arrow`); `write_spatial_layers(layers, dir, name, format)`.
- `output.darwin_core` (`R/darwincore.R`): Darwin Core Archive por área (zip: `occurrence.txt`, `meta.xml`, `eml.xml`, `provenance.yaml`).
- `output.run_label` (prefixo da pasta/log), `input.from_run` (filtragem a partir de uma run de assessment) e bloco `lineage` em `run_status.yaml`.
- Novas dependências: `terra`, `arrow`, `zip`.

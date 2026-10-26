# CIDI v3 — gbif-area-assessment: diagnóstico, filtragem e saídas de dados GBIF

> Documento derivado da implementação (engenharia reversa), ferramenta **0.1.0**. Substitui os CIDI v1 e v2 e
> incorpora o CIDI de filtragem. Divergências em relação aos documentos anteriores: seção 24. Itens não validados: seção 23.

---

## 1. Objetivo e escopo

Ferramenta exploratória em **R** com **dois fluxos independentes**:

1. **Assessment** (`scripts/run.R`): consulta o GBIF por área de estudo, guarda a resposta bruta em cache e produz métricas
   descritivas, mapas, camadas espaciais, relatório PDF e, opcionalmente, Darwin Core.
2. **Filtragem** (`scripts/filter.R`): lê entradas de cache **já existentes**, aplica filtros pós-recuperação (v1: raster de valores
   discretos), compara perfis antes/depois e gera tabelas, camadas, relatório PDF e, opcionalmente, Darwin Core. Nunca chama o GBIF e nunca altera o cache.

Uso previsto: diagnóstico da disponibilidade de dados por bacia (Amazônia), de forma reprodutível. Sem modelagem ecológica, correção
de viés, rarefação, riqueza verdadeira ou estatística inferencial.

---

## 2. Requisitos gerais e execução

- R (>= 4.1), `renv`, repositório Git existente, código modular, funções documentadas com roxygen2, config YAML, logs `logger`.
- Módulos de `R/` carregados por `sys.source()` em ambiente privado (sem estado global); `DESCRIPTION` serve ao `renv` e à documentação.

```bash
Rscript scripts/run.R    config/config.yaml      # assessment
Rscript scripts/filter.R config/filter.yaml      # filtragem de cache existente
Rscript tests/test_filtering.R                   # 45 checks (sem GBIF, sem rede)
Rscript tests/test_outputs.R                     # 34 checks (formatos, Darwin Core, label, lineage)
source("scripts/draw_area.R")                    # console interativo: desenha 1 polígono e grava data/input/areas.gpkg
```

Credenciais do GBIF (`GBIF_USER`, `GBIF_PWD`, `GBIF_EMAIL`, modelo em `.Renviron.example`) só são necessárias para `gbif.query.method: download`;
**a filtragem não precisa delas**. Ambiente sem root: `environment.yml` (conda-forge).

---

## 3. Entrada das áreas (assessment)

Modo explícito `input.area.mode` = `gpkg` | `draw` (exclusivos).

- **`gpkg`:** um único arquivo; `layer` obrigatório se houver mais de uma camada; apenas `POLYGON`/`MULTIPOLYGON` com CRS; saída padronizada em
  EPSG:4326 com `area_id`. Identificador: `id_column`, ou primeira coluna candidata adequada (`area_id`, `id`, `name`, `nome`, `area`, `site`, `label`),
  ou `area_01`, `area_02`, ... (registrado). Geometria inválida: erro, exceto `fix_invalid: true` (`st_make_valid`, registrado). Sobreposição gera WARN.
- **`draw`:** um polígono em mapa interativo (`mapedit`); painel do RStudio quando em sessão interativa, navegador se houver display, senão erro apontando
  `scripts/draw_area.R`. Salvo em `spatial/drawn_area.gpkg`. `draw` não pode ser combinado com `path`/`layer`.

---

## 4. Configuração do assessment (`config/config.yaml`)

Padrões completados e validados em `validate_config()`; seções desconhecidas geram WARN.

```yaml
project: {name: "gbif_area_assessment"}
input:
  area: {mode: "gpkg", path: "data/input/areas.gpkg", layer: null, id_column: null, fix_invalid: false}
gbif:
  filters: {}                      # só filtros declarados são aplicados
  query:
    method: "download"             # download | search (padrão do código: search)
    download_wait_minutes: 720
    download_poll_seconds: 30
    keep_download_zip: false
    max_records: 100000            # search (1..100000)
    page_size: 300                 # search (1..300)
    max_retries: 3
    retry_wait_seconds: 5
    max_filter_combinations: 50    # search; padrão do código, sem entrada no exemplo
    max_wkt_chars: 8000            # search; padrão do código, sem entrada no exemplo
  cache: {enabled: true, directory: "data/cache/gbif", use_cached: true, refresh: false}
analysis:
  density_cell_km: 5
  top_n: 10
  low_coverage_pct: 20
  max_map_points: 50000
  metric_crs: "auto"               # Lambert azimutal de áreas iguais centrado nas áreas, ou CRS projetado (ex.: "EPSG:5880")
output:
  directory: "results"
  write_records_layer: true
  spatial_format: "geoparquet"     # geoparquet | gpkg
  run_label: null                  # prefixo da pasta/log da run
  darwin_core: {enabled: false}    # ver seção 12
logging: {level: "INFO"}           # DEBUG | INFO | WARN | ERROR
```

Caminhos relativos são resolvidos a partir da raiz do projeto.

---

## 5. Filtros GBIF (consulta)

Opcionais, definidos em `gbif.filters`, aplicados só se configurados, registrados no log e no relatório; `null` é ignorado.

- **Registro tipado:** enums (`basisOfRecord`, `occurrenceStatus`, `continent`, `mediaType`, `license`); lógicos (`hasCoordinate`, `hasGeospatialIssue`,
  `repatriated`, `isInCluster`); chaves inteiras (`taxonKey`, `acceptedTaxonKey`, `kingdomKey` ... `speciesKey`); países ISO-2 (`country`, `publishingCountry`);
  intervalos `{min, max}` ou `"a,b"` com os dois limites (`year`, `month`, `decimalLatitude`, `decimalLongitude`, `elevation`, `depth`,
  `coordinateUncertaintyInMeters`, `eventDate`, `lastInterpreted`); texto (`scientificName`, `datasetKey`, `typeStatus`, `recordedBy`, `institutionCode`, ...).
- **Genéricos:** qualquer outro argumento de `rgbif::occ_data()` é aceito **apenas no modo `search`**; no `download`, só o registro tipado (erro caso contrário).
- **Validação:** existência (com sugestão), tipo, valores, intervalos e incompatibilidades (`hasCoordinate: false` é recusado).
- **Sem filtros implícitos:** defaults não nulos do rgbif (ex.: `occurrenceStatus = "PRESENT"`) são anulados explicitamente (`search`).

---

## 6. Consulta ao GBIF

Uma consulta por área (um cache por área).

- **`search`** (`rgbif::occ_data`): filtros multivalorados viram uma requisição por combinação (OU dentro do filtro), unidas e deduplicadas por `gbifID`;
  paginação, retry com espera crescente, erro se a contagem passar de `max_records` (teto 100 000) ou se a paginação terminar incompleta; WKT com anéis
  reorientados e 6 decimais, sem simplificação (erro acima de `max_wkt_chars`); contagem extra sem filtros (`n_total_without_filters`).
- **`download`** (`rgbif::occ_download`, SIMPLE_CSV): predicados `pred_within(WKT)` + um por filtro (AND); credenciais por variáveis de ambiente; espera com
  *polling* (`download_wait_minutes`); `occ_download_get` + `occ_download_import`; pedido pendente guardado em `download_pending.yaml` na pasta do cache
  (a próxima execução **retoma** o mesmo pedido); `CANCELLED/KILLED/FAILED/FILE_ERASED` descartam o pendente; guarda `download_key`, `download_doi`,
  `download_total_records`; aviso se a contagem importada divergir.

Falha de API: ERROR e encerramento controlado, sem relatório.

---

## 7. Cache

- **Chave:** hash (`rlang::hash`) de um YAML canônico: versão do esquema, identificador da API, WKT, filtros ordenados, defaults anulados do rgbif e, só no
  `download`, o método.
- **Entrada:** `<diretório>/<chave>/records.rds` (resposta bruta) + `meta.yaml` (chave, `area_id`, data/hora, versão, esquema, WKT, filtros, `n_records`,
  contagem sem filtros, versão do rgbif; no download, chave/DOI).
- **Comportamento:** lê se `enabled && use_cached && !refresh`; grava sempre que `enabled`; versão anterior arquivada em `archive/<timestamp>/`;
  entrada inconsistente é **erro**. `enabled: false` não lê nem grava.

---

## 8. Processamento (assessment)

`combine_area_records` → `validate_records` (só verificações técnicas: coordenadas ausentes/inválidas/fora da faixa e `gbifID` duplicado por área) →
`records_to_sf` (EPSG:4326, todas as colunas) → `assign_records_to_areas` (remove pontos fora do polígono; **pulado no `download`**). Remoções contadas por motivo
e área. Nenhum filtro científico é aplicado.

## 9. Métricas

CRS métrico `auto` ou informado. Registros (km², registros/km²); taxonomia (espécies/gêneros/famílias distintos, `top_n` classes/famílias/espécies);
espacial (grade quadrada recortada pelo polígono, cobertura = % de células com registro, concentração = % dos registros nas 10% células mais povoadas; erro acima de
200 000 células); temporal (registros e espécies por ano, intervalo, anos com registro, registros sem ano). Áreas sem registros recebem zeros; zero registros
total termina com WARN.

## 10. Comparação entre áreas

Só com 2+ áreas, descritiva: tabela por área e espécies compartilhadas por par (compartilhadas, união, Jaccard).

---

## 11. Saídas espaciais

`output.spatial_format`:

- **`geoparquet`** (padrão): um `.parquet` por camada, escrito por `write_geoparquet()` com `arrow` como **GeoParquet 1.0.0** (geometria WKB, metadado `geo`
  com `primary_column`, `geometry_types` e `bbox`; sem a chave `crs`, o que no padrão significa OGC:CRS84 = WGS 84 lon/lat). Só camadas EPSG:4326; colunas de
  lista descartadas. Assessment: `areas`, `gbif_records`, `gbif_density`. Filtragem: `gbif_filtered_records`, `areas`.
- **`gpkg`:** um único GPKG (`gbif_area_assessment.gpkg` / `gbif_filtered_records.gpkg`) com as mesmas camadas; colunas com nomes duplicados por caixa são descartadas (WARN).

Camadas vazias são omitidas (WARN); `write_records_layer: false` omite `gbif_records`; nunca sobrescreve arquivo existente. Exige `arrow` para GeoParquet
(verificado na validação da configuração).

## 12. Darwin Core Archive (`output.darwin_core`)

Opcional nos dois fluxos. **Um zip por área** em `darwincore/` (`<label>_<area>_dwca.zip`), com:

- `occurrence.txt` (UTF-8, tab, cabeçalho; `gbifID` é o id do core, deve ser único); `meta.xml` (core Occurrence, `ignoreHeaderLines=1`, um `<field>` por coluna);
  `eml.xml` (EML 2.1.1, perfil GBIF: título, criador, contato, data, idioma, resumo, direitos, cobertura geográfica e temporal, métodos, citação do GBIF quando há DOI);
  `provenance.yaml` (run, label, run pai, cache key, método, filtros, DOI, contagens por estágio, WKT, versão da ferramenta).
- **Mapeamento:** colunas DwC → `http://rs.tdwg.org/dwc/terms/`, Dublin Core → `http://purl.org/dc/terms/`, colunas específicas do GBIF → `http://rs.gbif.org/terms/1.0/`;
  qualquer outra coluna (ex.: `raster_value`) vai para `dynamicProperties` em JSON; `area_id` (constante) é omitido.
- Config: `enabled`, `creator` (**obrigatório se habilitado**), `institution`, `email`, `title`, `abstract`, `license_text`, `language`.
- Áreas sem registros não geram arquivo (WARN). Registros mantêm sua licença (`license`).

## 13. Visualizações

Assessment: mapa das áreas; registros e densidade por área (amostra sistemática acima de `max_map_points`); registros e espécies por ano e por área; principais classes;
comparação (2+ áreas). Filtragem: registros e densidade pré e pós-filtro por área; contagens observadas e registros por ano antes/depois.

## 14. Relatórios PDF (inglês)

Gerados a partir de um `run_context.rds`; o `.tex` sai do `rmarkdown` e é compilado pelo próprio código (`xelatex`/`pdflatex`/`lualatex`, duas passadas) em diretório
temporário com as figuras em caminhos relativos. Exige pandoc e LaTeX.

- **Assessment** (`report/gbif_area_assessment.pdf`): identificação (inclui tipo de run, label e run pai), áreas, consulta GBIF (filtros, origem API/cache, método, DOI, contagens,
  removidos, avisos), caracterização, comparação (se houver), limitações.
- **Filtragem** (`report/filtering_report.pdf`): identificação e configuração efetiva, entradas de cache (chaves, consultas de origem, MD5), filtros aplicados (raster: caminho, MD5, CRS,
  resolução, extensão, valores aceitos), contagens por estágio, remoções por estágio e motivo, perfis bruto/pré-filtro/pós-filtro, mapas, avisos, tempos, limitações.

## 15. Logs

`logger` (DEBUG/INFO/WARN/ERROR), console + `logs/<label_>run_<ts>.log` (criado no início); início/fim e duração de cada etapa; avisos do R viram WARN; WARN/ERROR são coletados para o relatório.

---

## 16. Módulo de filtragem (`R/filtering.R`, `config/filter.yaml`)

### 16.1 Configuração

```yaml
project: {name: "gbif_area_assessment"}
input:
  from_run: "results/<label>_run_<timestamp>"   # OU cache_entries (exclusivos; um dos dois é obrigatório)
  # cache_entries: ["data/cache/gbif/<cache_key>", ...]
filters:
  spatial:
    raster: {enabled: true, path: "data/input/mask.tif", accepted_values: [1, 3]}
analysis: {top_n: 10, density_cell_km: 5, metric_crs: "auto", max_map_points: 50000, low_coverage_pct: 20}
output: {directory: "results/filtering", spatial_format: "geoparquet", run_label: null, darwin_core: {enabled: false}}
logging: {level: "INFO"}
```

Categorias/filtros desconhecidos (ex.: `quality`) e opções não suportadas do raster são recusados; sem filtro habilitado é erro.

### 16.2 Entradas de cache (somente leitura)

`load_filter_inputs()` valida cada diretório: `records.rds` e `meta.yaml` presentes e legíveis; `cache_key`, `area_id` e `cache_schema` suportado; chave igual ao nome do
diretório (quando no padrão do cache); contagem de linhas igual a `n_records`; chaves e `area_id` duplicados e diretórios repetidos são recusados. O MD5 dos dois arquivos é gravado
ao carregar e **verificado no fim** (`inputs_unchanged` no status). Polígonos são reconstruídos de `geometry_wkt`; se ausente/inválido, métricas e mapas espaciais da área são
pulados (WARN).

**`input.from_run`:** `read_parent_run()` usa apenas `run_status.yaml` (deve ser `completed` e de assessment), `config_effective.yaml` (diretório do cache) e `tables/retrieval.csv`
(chave por área); a filtragem herda o label da run pai se não definir o próprio.

### 16.3 Registro de filtros e filtro `spatial.raster`

`filter_registry()` é o ponto de extensão: cada filtro tem `id`, `category`, nome na config e as funções `validate`, `apply` e `describe`; executam em ordem determinística. Implementado
apenas `spatial.raster` (sem filtros de qualidade).

- **Raster:** um arquivo, **EPSG:4326** (OGC:CRS84 equivalente; qualquer outro CRS ou ausência de CRS é erro — sem reprojeção de raster nem de pontos); primeira camada (WARN se houver mais);
  `accepted_values` numéricos exatos (rótulos de categoria, intervalos, limiares e combinações não são suportados); raster categórico comparado por código bruto; WARN para tipos de ponto
  flutuante; identificado por caminho e MD5 (arquivo principal).
- **Aplicação:** extração em blocos de 500 mil pontos; remoções classificadas em `outside_raster_extent`, `raster_nodata` e `raster_value_not_accepted`; campo derivado `raster_value`
  (sufixo `_derived` em colisão de nome); colunas originais preservadas.

### 16.4 Perfis e contabilidade

Três perfis por área, com as mesmas métricas: **bruto** (como no cache), **pré-filtro** (após validação técnica) e **pós-filtro** (registros, taxa distintos, cobertura temporal e, quando há
geometria, cobertura espacial; métricas espaciais não são calculadas no bruto). Cada estágio (validação técnica, cada filtro) registra entrada, retidos e removidos por área; o denominador é o
que entrou no estágio, então remoções por estágio **não são necessariamente únicas**. Resultado vazio não é falha (WARN e relatório).

### 16.5 Saídas (`results/filtering/[<label>_]run_<ts>/`)

`config_original.yaml`, `config_effective.yaml`, `run_status.yaml` (`status`, `lineage`, duração, `inputs_unchanged`, contagens), `logs/`,
`tables/` (`input_entries`, `profile_raw`, `profile_before_filter`, `profile_after_filter`, `profile_by_year`, `profile_comparison`, `filter_summary`, `removed_records` — CSV — e `run_context.rds`),
`spatial/`, `figures/`, `report/filtering_report.pdf` e `darwincore/` (se habilitado). Exit status não zero em falha (`run_status.yaml` = `failed`, sem PDF).

---

## 17. Associação entre runs

- `output.run_label` (1–40 caracteres: letras, dígitos, `_`, `-`) prefixa a pasta e o log: `<label>_run_<timestamp>`.
- `lineage` em `run_status.yaml`, no contexto do relatório e (na filtragem) no `provenance.yaml`: `run_type` (`assessment`/`filtering`), `run_id`, `run_label`, `parent_run`
  (tipo, id, label, pasta) e `cache_keys` por área. Run ids e labels são gravados entre aspas no YAML (evita leitura numérica de `20261024_055915`).
- Um cache pode ser compartilhado por várias runs: `from_run` registra o ponto de partida, não uma relação única. Não há índice central de runs.

---

## 18. Estrutura do projeto

```text
gbif-area-assessment/
├── DESCRIPTION  README.md  environment.yml  .gitignore  .gitattributes  .Rbuildignore  .Rprofile  .Renviron.example
├── renv/ (activate.R, settings.json, .gitignore)        # renv.lock: gerar com renv::snapshot()
├── config/ (config.yaml, filter.yaml)
├── R/ utils logging config area_input gbif_filters gbif_query gbif_download gbif_cache gbif_processing
│      metrics spatial_outputs darwincore plots report pipeline filtering
├── report/ (report_template.Rmd, filtering_report_template.Rmd)
├── scripts/ (run.R, filter.R, draw_area.R)
├── tests/ (test_filtering.R, test_outputs.R)
├── data/input/   docs/ (CIDI.md, future_work.md)
└── results/  results/filtering/        # uma pasta por execução
```

`data/cache/`, `results/` e `.Renviron` são ignorados pelo Git.

## 19. Funções principais (adições ao v2)

| Módulo | Funções |
|---|---|
| config | `validate_output_options` (label, formato, Darwin Core) |
| spatial_outputs | `write_geoparquet`, `write_spatial_layers(layers, dir, name, format)`, `create_spatial_layers` |
| darwincore | `write_dwca`, `dwc_term_uris` |
| filtering | `filter_registry`, `validate_filter_config`, `read_parent_run`, `validate_raster_filter`, `apply_raster_filter`, `describe_raster_filter`, `load_filter_inputs`, `verify_inputs_unchanged`, `area_from_wkt`, `calculate_profile`, `profile_comparison_table`, `apply_filters`, `plot_profile_comparison`, `plot_year_comparison`, `build_filtering_limitations`, `run_filtering` |
| utils | `.yq` (força aspas no YAML) |

As demais funções são as do v2 (config, logging, área, filtros GBIF, consulta, download, cache, processamento, métricas, gráficos, relatório, `run_assessment`).

## 20. Dependências

Imports: `rgbif`, `sf`, `dplyr`, `tidyr`, `ggplot2`, `yaml`, `logger`, `rmarkdown`, `knitr`, `rlang`, `terra`, `arrow`, `zip`. Suggests: `mapedit`, `leaflet`, `shiny`, `rstudioapi`, `roxygen2`.
Sistema: pandoc e LaTeX (PDF). `arrow` só é exigido com `spatial_format: geoparquet`, mas é o padrão.

## 21. Fluxos

```text
assessment:  config → áreas → (por área) consulta search|download ↔ cache → processamento → métricas → camadas + tabelas → figuras → [Darwin Core] → PDF → status
filtragem:   config → entradas de cache (from_run | cache_entries) → perfil bruto → validação técnica → perfil pré-filtro → filtros em sequência
             → perfil pós-filtro → tabelas → camadas → figuras → [Darwin Core] → PDF → verificação de MD5 do cache → status
```

## 22. Casos especiais

Nenhum registro: WARN e resultados vazios. Cache inconsistente: erro. Falha de API/LaTeX/validação: ERROR, `run_status.yaml` = `failed`, sem PDF. Download interrompido: retomado na próxima execução.
Raster em CRS diferente ou sem CRS, valores de texto, opções não suportadas, `from_run` inexistente/incompleto/falho/de filtragem, `from_run` junto com `cache_entries`: erro de configuração.
`darwin_core` sem `creator`, `run_label` inválido, formato desconhecido, `arrow` ausente com GeoParquet: erro de configuração.

## 23. Estado de validação

**Verificado** (Linux; testes sem GBIF e sem rede): `tests/test_filtering.R` — 45 checks (raster: aceitos, rejeitados, NoData, fora da extensão, correspondência exata, categórico, CRS diferente/ausente, colisão
de nome; 8 falhas de leitura de cache; erros de configuração; execução completa com duas áreas; resultado vazio; falha controlada; cache intacto; exit code; cliente do GBIF nunca carregado) e
`tests/test_outputs.R` — 34 checks (assessment com label, GeoParquet lido por `arrow` e `geopandas`, opção GPKG, Darwin Core: zip, `meta.xml`/`eml.xml` bem-formados, `dynamicProperties`,
filtragem via `from_run` com herança de label, lineage, validação de configuração). Fluxo `download` testado com `occ_download`, `occ_download_meta` e `occ_download_get` simulados (predicados reais).

**Não validado:**
- consultas reais ao GBIF nos dois métodos (paginação, `NULL` nos defaults do rgbif, colunas do SIMPLE_CSV, tamanho do WKT no download, `occurrenceStatus` em downloads) e o erro
  `tipo de subscrito inválido 'list'` na 2ª página do `search`;
- Darwin Core no GBIF Data Validator (URIs do namespace GBIF não conferidos) e leitura do GeoParquet em QGIS/GDAL;
- modo `draw`, compilação LaTeX no Windows e `renv.lock` (precisa de CRAN);
- desempenho com milhões de registros (grade de densidade, extração do raster, `write.table` do Darwin Core, GeoParquet).

## 24. Desvios em relação a v1 e v2

| Documento anterior | Implementação atual |
|---|---|
| v1: `results/` fixo | pasta por execução, com prefixo opcional `run_label` |
| v1: consulta única | `search` e `download`; consulta e cache por área |
| v1: saída espacial em GPKG | GeoParquet 1.0.0 por padrão; GPKG opcional |
| v1/v2: sem Darwin Core | Darwin Core Archive opcional, um zip por área |
| v2: um fluxo | dois fluxos independentes (assessment e filtragem) ligados por cache, `from_run` e `lineage` |
| CIDI de filtragem: raster "EPSG:4326 obrigatório" e "tratar CRS diferente" | contradição: seguiu-se a regra explícita (rejeita CRS diferente com erro claro); transformar os **pontos** exigiria decisão |
| CIDI de filtragem: um módulo, sem registro de saída | `R/filtering.R` mais `darwincore.R` e escritor GeoParquet em `spatial_outputs.R` |
| v2: relatório de um tipo | dois relatórios (assessment e filtragem), ambos em inglês |

## 25. Fora do escopo

Testes automatizados além dos scripts de `tests/`; modelagem ecológica; rarefação; riqueza verdadeira; correção de viés; SDMs; conectividade; integração com OBIA; estatística inferencial; outras fontes além do
GBIF; filtros de qualidade; rótulos de categoria, intervalos e vários rasters no filtro; índice central de runs. Melhorias planejadas: `docs/future_work.md`.

## 26. Critério de conclusão

`scripts/run.R` produz, a partir de uma área, consulta GBIF (`search` ou `download`), cache bruto reutilizável, métricas, mapas, camadas (GeoParquet ou GPKG), PDF, logs e, se habilitado, Darwin Core;
`scripts/filter.R` produz, a partir de entradas de cache existentes (explícitas ou via `from_run`), os registros filtrados, perfis antes/depois com contabilidade por estágio, PDF, camadas e Darwin Core,
sem acessar o GBIF e sem alterar o cache. Ambos registram configuração, origem dos dados (API/cache, DOI), ambiente (Git, R, `renv`) e a linhagem entre runs. **Pendente em produção:** os itens "não validados" da seção 23.

# Implementações futuras

Itens deliberadamente **fora** da versão atual. A versão atual cobre o essencial para baixar dados por bacia
(centenas de milhares a milhões de registros): `gbif.query.method: download`, polígono + filtros básicos de curadoria.

## Download (`occ_download`)

- **Validação com a API real.** O fluxo (pedido → espera → download → importação → retomada) foi testado apenas com as
  funções do rgbif simuladas; predicados reais (`pred_within`, `pred_in`, `pred_gte/lte`) foram construídos de fato.
  Falta rodar contra o GBIF e ajustar o que aparecer (colunas do SIMPLE_CSV, tipos, tamanho do WKT aceito).
- **Polígonos muito complexos.** Limite de vértices/tamanho do WKT no download é desconhecido. Se o GBIF recusar:
  simplificação explícita (registrada no log e no relatório) ou divisão do polígono em partes.
- **Filtros.** Hoje só os filtros tipados do registro (`basisOfRecord`, `occurrenceStatus`, `year`, `month`,
  `hasCoordinate`, `hasGeospatialIssue`, países, chaves taxonômicas, ...). Faltam: filtros genéricos do rgbif, `q`,
  predicados `OR`/`NOT`, e confirmar se downloads incluem registros `ABSENT` sem predicado explícito de `occurrenceStatus`.
- **Pré-checagem antes do pedido:** estimar nº de registros (`occ_count`) e espaço em disco necessário; abortar com aviso.
- **Formato:** só `SIMPLE_CSV`. Alternativas: `DWCA`/`SIMPLE_PARQUET` (menor e mais rápido de ler), seleção de colunas
  na importação para reduzir memória.
- **Várias áreas em um único pedido** (união dos polígonos) e posterior atribuição por área, em vez de um download por área.
- **Citação:** seção dedicada no relatório com DOI, data e citação formatada de cada download (hoje o DOI aparece na
  tabela de identificadores e nas limitações).
- **Limpeza de cache:** política para arquivar/remover `archive/` e zips antigos (disco limitado).

## Escala (milhões de registros)

- **Densidade:** atribuir células por aritmética de grade em vez de `st_intersects` ponto × grade; medir tempo real.
- **Verificação ponto-no-polígono:** hoje é pulada no modo download (o GBIF já aplicou o polígono); opção configurável
  para verificar em chunks, se necessário.
- **Camada `gbif_records`:** gravar em chunks, ou em Parquet/GeoParquet; hoje há só a opção `output.write_records_layer`.
- **Mapa de pontos:** hoje amostra sistemática (`analysis.max_map_points`); alternativa: hexbin/raster de contagem.
- **Métricas temporais/taxonômicas** com `data.table`/`dplyr` agrupado, caso `split()` fique lento.

## Modo `search`

- Diagnosticar o erro `tipo de subscrito inválido 'list'` na 2ª página (offset 300) observado na máquina do usuário;
  hipótese: registro com campo aninhado que o rgbif não formata. Requer o traceback.

## Geral

- Gerar e versionar `renv.lock` (precisa de CRAN).
- Testar o modo `draw` no RStudio Server e a compilação LaTeX no Windows com a correção atual.
- Testes automatizados (fora do escopo do CIDI atual).


## Filtragem posterior de ocorrências

Implementado em `scripts/filter.R`: um filtro espacial `spatial.raster` com valores discretos exatos, aplicado aos registros de entradas de cache selecionadas explicitamente. O raster precisa estar em EPSG:4326. Filtros de qualidade (por exemplo, regras taxonômicas ou flags de qualidade) permanecem fora do escopo e não são executados.

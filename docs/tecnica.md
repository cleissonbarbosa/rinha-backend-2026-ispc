# Documentação Técnica

Este documento concentra os detalhes de arquitetura, preprocessamento e hot path da busca vetorial.

## Topologia

```mermaid
flowchart LR
  client["cliente / k6"] --> lb["HAProxy<br/>porta 9999<br/>0.20 CPU / 50 MB"]
  lb --> api1["api1<br/>Zig<br/>0.40 CPU / 150 MB"]
  lb --> api2["api2<br/>Zig<br/>0.40 CPU / 150 MB"]
  api1 --> mm["mmap read-only<br/>page cache compartilhado"]
  api2 --> mm
  mm --> bins["vectors.bin<br/>labels.bin<br/>residuals.bin<br/>ivf.bin"]
```

Orçamento total da composição atual: `1.0 CPU` e `350 MB`.

## Fluxo da requisição

```mermaid
sequenceDiagram
  autonumber
  participant C as Cliente
  participant H as HAProxy
  participant A as API Zig
  participant J as json_fast
  participant V as vectorize
  participant X as vector_core
  participant I as ISPC
  participant D as mmap bins

  C->>H: POST /fraud-score
  H->>A: round-robin
  A->>J: parse do body
  J-->>A: Payload
  A->>V: vetor normalizado de 14 dimensões
  V-->>A: query[14]
  A->>X: vc_query(query)
  X->>D: centroides, listas e labels
  X->>I: centroid distance + q16 scan
  X-->>A: contagem de fraudes no top-K
  A-->>C: approved + fraud_score
```

O servidor expõe dois endpoints:

- `GET /ready` para readiness depois do carregamento dos binários.
- `POST /fraud-score` para classificar a transação.

## Componentes principais

| Arquivo | Responsabilidade |
| --- | --- |
| `src/main.zig` | servidor HTTP, roteamento, carregamento dos bins e montagem da resposta |
| `src/json_fast.zig` | parser JSON manual sem alocação no hot path |
| `src/vectorize.zig` | vetorização de 14 features e regra final `approved/fraud_score` |
| `src/vector_core.zig` | consulta ao índice IVF, shortlist coarse, expansão por raio e rerank refinado |
| `src/knn.ispc` | kernels SIMD para distância a centroides e scan q16 |
| `tools/preprocess.nim` | geração do índice binário no build da imagem |

## Pipeline de build e dados

```mermaid
flowchart LR
  refs["references.json.gz"] --> prep["tools/preprocess.nim"]
  prep --> v["vectors.bin<br/>SoA int16"]
  prep --> r["residuals.bin<br/>int8 por dimensão"]
  prep --> l["labels.bin<br/>1 byte por vetor"]
  prep --> i["ivf.bin<br/>centroides + raios + boundaries"]
  v --> image["imagem final"]
  r --> image
  l --> image
  i --> image
```

Comportamento atual do build:

- por padrão, o `Dockerfile` baixa `references.json.gz` do repositório oficial e regenera o índice;
- se `USE_LOCAL_DATA=1` e os arquivos em `data/*.bin` existirem, a imagem reutiliza os binários locais;
- a compilação usa `-Dcpu=haswell` e linka `knn_ispc.o` com `-Dispc-object`.

## Índice vetorial

O índice combina coarse search com refinamento curto:

1. a query é quantizada para `i16`;
2. o core mede a distância para todos os centroides IVF;
3. os `nprobe` clusters mais próximos são varridos primeiro;
4. a shortlist coarse é expandida quando o raio de um cluster ainda permite um candidato melhor;
5. os melhores candidatos passam por rerank com `residuals.bin`.

```mermaid
flowchart TD
  q["query 14D"] --> q16["quantização q16"]
  q16 --> cdist["distância aos centroides"]
  cdist --> probe["seleção dos clusters nprobe"]
  probe --> coarse["scan SoA quantizado"]
  coarse --> expand["expansão por raio"]
  expand --> topc["shortlist TOP_C"]
  topc --> refine["rerank com residual int8"]
  refine --> topk["K = 5"]
  topk --> resp["approved + fraud_score"]
```

Esse desenho reduz o número de vetores escaneados sem abrir mão do refinamento fino nos casos em que o coarse sozinho empata ou fica perto de empatar.

## Parâmetros atuais

| Parâmetro | Valor atual | Onde |
| --- | --- | --- |
| Dimensão do vetor | `14` | `src/vectorize.zig` |
| `K` final | `5` | `src/vector_core.zig` |
| Shortlist coarse | `TOP_C = 16` | `src/vector_core.zig` |
| Clusters IVF | `8192` | `Dockerfile` |
| `nprobe` | `8` | `Dockerfile` |
| Amostra do k-means | `65536` | `Dockerfile` |
| Iterações do k-means | `25` | `Dockerfile` |
| Worker threads na stack | `2` por API | `docker-compose.yml` |
| CPU target | `haswell` | `Dockerfile` / `build.zig` |

Detalhes relevantes da implementação:

- `vectors.bin` usa layout SoA quantizado em `i16`, organizado por cluster;
- `residuals.bin` guarda um ajuste `int8` por dimensão para o rerank refinado;
- `ivf.bin` contém magic, metadados, centroides, raios e limites das listas invertidas;
- o `mmap` faz pre-fault das páginas no startup para reduzir latência fria.

## Vetorização

As 14 features combinam sinal transacional, contexto temporal e perfil do merchant:

- valor, parcelas e relação entre `amount` e `avg_amount`;
- hora do dia e dia da semana;
- minutos desde a última transação e distância da última transação;
- distância de casa e volume nas últimas 24h;
- flags `is_online`, `card_present` e merchant conhecido;
- risco por MCC e ticket médio do merchant.

As saídas seguem a regra de maioria simples sobre o top-5:

```mermaid
flowchart LR
  f0["0 fraudes"] --> s0["approved = true<br/>fraud_score = 0.0"]
  f1["1 fraude"] --> s1["approved = true<br/>fraud_score = 0.2"]
  f2["2 fraudes"] --> s2["approved = true<br/>fraud_score = 0.4"]
  f3["3 fraudes"] --> s3["approved = false<br/>fraud_score = 0.6"]
  f4["4 fraudes"] --> s4["approved = false<br/>fraud_score = 0.8"]
  f5["5 fraudes"] --> s5["approved = false<br/>fraud_score = 1.0"]
```

## Trade-offs

- O parser manual evita DOM JSON e heap allocation por request, mas aumenta a rigidez do contrato de entrada.
- A expansão por raio custa mais do que uma ANN agressiva, mas melhora a chance de manter o top-K correto.
- O refinamento com residual adiciona memória ao dataset, porém reduz erro de ordenação nos casos de borda.
- O uso de `mmap` read-only simplifica o startup da aplicação e deixa o kernel compartilhar páginas entre `api1` e `api2`.
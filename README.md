# Rinha de Backend 2026

Implementação para a [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) com servidor HTTP em Zig, load balancer C sobre Unix sockets, índice vetorial IVF quantizado e kernels ISPC no hot path da busca.

## Stack

| Camada | Tecnologia | Por quê |
| --- | --- | --- |
| Load balancer | C + epoll | proxy round-robin mínimo |
| API ×2 | Zig | servidor HTTP enxuto com `io_uring`, parser zero-allocation |
| Busca vetorial | Zig + ISPC | kernels AVX2 para centroides, seleção de probes e scan top-k quantizado |
| Preprocessamento | Nim | build-time pipeline para gerar os binários do índice |
| Dataset runtime | mmap read-only | evita parsing do dataset em runtime e reaproveita page cache |

## Documentação

- [Documentação técnica](docs/tecnica.md)

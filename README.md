# Rinha de Backend 2026

Implementação para a [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) com servidor HTTP em Zig, índice vetorial IVF quantizado e kernels ISPC no hot path da busca.

## Stack

| Camada           | Tecnologia      | Por quê                                                                     |
| ---------------- | --------------- | --------------------------------------------------------------------------- |
| Load balancer    | HAProxy 2.9     | round-robin simples e barato dentro do orçamento                            |
| API ×2           | Zig 0.13        | servidor HTTP enxuto, parser zero-allocation e integração direta com o core |
| Busca vetorial   | Zig + ISPC 1.30 | scan SIMD AVX2/FMA sobre índice IVF quantizado                              |
| Preprocessamento | Nim 2.2         | build-time pipeline para gerar os binários do índice                        |
| Dataset runtime  | mmap read-only  | evita parsing do dataset em runtime e reaproveita page cache                |

## Testes

```bash
zig build test
```

## Documentação

- [Documentação técnica](docs/tecnica.md)

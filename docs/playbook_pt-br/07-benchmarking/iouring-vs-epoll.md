# io_uring vs epoll — Metodologia de Comparação

O Poseidon seleciona automaticamente o melhor back-end de I/O disponível na inicialização:

| Back-end | Condição | Observação |
|----------|----------|-----------|
| **io_uring** | Linux, kernel ≥ 5.1 | Preferido; menos syscalls por requisição |
| **epoll** | Linux, kernel < 5.1 ou io_uring bloqueado | Fallback automático |
| **IOCP** | Windows | Sempre usado no Windows |

Como a seleção é automática, comparar os dois back-ends exige duas execuções
separadas em ambientes distintos.

## Configuração

**Execução 1 — caminho io_uring** (kernel ≥ 5.1, io_uring não bloqueado por seccomp):

```bash
uname -r           # deve imprimir 5.1 ou superior
./Poseidon.Sample.Benchmark
```

**Execução 2 — fallback epoll** (uma das opções):

- Máquina com kernel < 5.1
- Container com política `seccomp` que bloqueia `io_uring_setup` (syscall 425)
- Bloquear temporariamente via `sysctl -w kernel.io_uring_disabled=1`
  (disponível no kernel ≥ 5.10)

## Diferença esperada

O io_uring agrupa submissões e conclusões em ring buffers compartilhados,
eliminando as syscalls `epoll_ctl` + `read`/`write` por operação. Em alta
concorrência (> 500 conexões simultâneas), a redução de syscalls normalmente
resulta em:

- 15–30% maior throughput
- 20–40% menor latência P99

O benefício é menor em workloads de baixa concorrência, onde o overhead de
syscall não é o gargalo.

## Confirmando o back-end ativo

Adicione um callback de log antes de `Listen`:

```pascal
LServer.OnLog :=
  procedure(ALevel: TLogLevel; const AMsg: string)
  begin
    if ALevel <= llInfo then Writeln(AMsg);
  end;
```

O servidor loga `[INFO] I/O back-end: io_uring` ou `[INFO] I/O back-end: epoll`
durante a inicialização.

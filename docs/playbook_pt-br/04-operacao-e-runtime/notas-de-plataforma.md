# Notas de Plataforma & Limitações Conhecidas

O Poseidon é dual-face: Windows (IOCP / RIO) e Linux (epoll / io_uring). O
backend é escolhido em tempo de compilação.

| Plataforma | Backend padrão | Fallback | Define para forçar |
|---|---|---|---|
| Windows 64-bit | RIO (Registered I/O) | IOCP | `FORCE_IOCP` |
| Linux 64-bit | io_uring | epoll | `FORCE_EPOLL` |

## Windows: I/O de extensão sobreposto do Winsock

Os backends Windows dependem das funções de extensão sobreposta carregadas via
`WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER, …)` (`AcceptEx`) e do Registered
I/O (RIO). Num Windows saudável isso está sempre disponível.

Alguns ambientes — certos builds Windows Insider, ou hosts com um produto de
segurança que faz hook do catálogo Winsock — **rejeitam essas chamadas com
`WSAEINVAL (10022)`** enquanto o `accept()` básico ainda funciona. Nesse host o
servidor aceita conexões TCP mas não consegue completar o recv sobreposto, então
fecha a conexão sem responder, e os testes de integração via socket falham.

Isso é uma **limitação ambiental, não um defeito de código** (reproduzível com
poucas linhas de Winsock puro, sem nenhum código Poseidon). Se você bater nisso:

- Rode os testes de integração / suítes de conformidade num host Windows limpo
  ou no **Linux** (ver [Testes & Conformidade](testes-e-conformidade.md)).
- Os testes puros/de lógica e de fuzz não são afetados e validam a lógica de
  parsing e protocolo sem sockets.

## Linux: TLS ainda não está production-ready

O build Linux (epoll / io_uring) serve HTTP puro corretamente e completa o
handshake TLS, mas **HTTPS e HTTP/2-over-TLS têm hoje um crash no Linux** no
caminho de recv/dispatch pós-handshake (uma corrida / use-after-free sensível a
timing na fronteira SSL + worker assíncrono). Reproduz nos dois backends e
bloqueia a rodada de conformidade HTTP/2.

**Recomendação:** até isso ser corrigido, faça a terminação TLS na frente do
Poseidon no Linux (ex.: um reverse proxy / load balancer fazendo TLS, com o
Poseidon servindo HTTP puro atrás dele). HTTP puro no Linux não é afetado.
Acompanhe a correção nas issues do projeto.

## OpenSSL

O TLS carrega o OpenSSL dinamicamente na primeira chamada de `ConfigureSSL` —
sem dependência em tempo de compilação:

- Windows: `libssl-3-x64.dll` / `libssl-1_1-x64.dll` (e `libcrypto`) no `PATH`.
- Linux: `libssl.so.3` / `libssl.so.1.1` (e `libcrypto`) — ex.:
  `apt install openssl` / `libssl3`.

# Poseidon

> *Deus dos mares — transporte bruto, a força das ondas.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  Servidor HTTP assíncrono de alta performance para Delphi — IOCP no Windows, epoll no Linux.<br/>
  Zero dependências externas. Um único WSASend por resposta. WebSocket, SSL/TLS e HTTP/2 nativos.
</p>

---

## Visão Geral

Poseidon é uma biblioteca Delphi standalone que fornece um servidor HTTP nativo com I/O assíncrono.
É usada como camada de transporte do [Pegasus](https://github.com/herlondf/pegasus) e do
[Horse](https://github.com/HashLoad/horse) quando o define `HORSE_ASYNCIO` está ativo.

| Funcionalidade | Status |
|----------------|--------|
| HTTP/1.1 keep-alive | ✅ |
| HTTPS (OpenSSL) | ✅ |
| SNI multi-certificado | ✅ |
| mTLS (certificados de cliente) | ✅ |
| WebSocket | ✅ |
| HTTP/2 (h2 via ALPN) | ✅ |
| HTTP/2 cleartext (upgrade h2c) | ✅ |
| Controle de fluxo HTTP/2 (RFC 7540 §6.9) | ✅ |
| Compressão gzip | ✅ |
| Rate limiting (por IP e global) | ✅ |
| Endpoint Prometheus de métricas | ✅ |
| Proxy Protocol v1/v2 | ✅ |
| Security headers (opt-in) | ✅ |
| Proteção contra path traversal e request smuggling | ✅ |
| Linux 64-bit (epoll) | ✅ |
| Windows 64-bit (IOCP) | ✅ |

## Requisitos

- Delphi 11 Alexandria ou superior
- Target Linux 64-bit ou Windows 64-bit
- OpenSSL (`libssl` / `libcrypto`) no PATH — apenas para HTTPS/HTTP2

## Instalação

Clone o repositório e adicione o diretório `src/` ao search path do seu projeto.
Sem necessidade de instalar pacote.

```
{search path}
<caminho-para-poseidon>\src\
```

## Início Rápido

```pascal
uses Poseidon.Net.HttpServer;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  LServer.Listen('0.0.0.0', 9000,
    procedure(const AReq: TPoseidonNativeRequest;
              out AStatus: Integer;
              out AContentType: string;
              out ABody: TBytes;
              out AExtraHeaders: TArray<TPair<string,string>>)
    begin
      AStatus      := 200;
      AContentType := 'text/plain';
      ABody        := TEncoding.UTF8.GetBytes('Olá, mundo!');
    end,
    procedure begin Writeln('Ouvindo em :9000'); end);
end;
```

Veja [`samples/`](samples/) para exemplos executáveis.

## Configuração Rápida

### Segurança

| Propriedade / Método | Padrão | Descrição |
|----------------------|--------|-----------|
| `AllowedMethods` | `[]` (todos) | Allowlist de verbos HTTP — verbos não listados retornam 405 |
| `MinTLSVersion` | `$0303` (TLS 1.2) | Versão mínima de TLS; `0` = padrão da biblioteca |
| `ConfigureMTLS(CAFile)` | — | Exige certificados de cliente assinados pelo CA bundle informado |
| `SecureHeadersEnabled` | `False` | Injeta `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` |
| `ServerBanner` | `'Poseidon/1.0'` | Valor do header `Server:`; `''` suprime o header |

### Limites e Confiabilidade

| Propriedade | Padrão | Descrição |
|-------------|--------|-----------|
| `MaxRequestSize` | 8 MB | Tamanho máximo da requisição — retorna 413 se excedido |
| `MaxHeaderSize` | 64 KB | Tamanho máximo da seção de headers — retorna 400 se excedido |
| `MaxWSFrameSize` | 0 (ilimitado) | Payload máximo de frame WebSocket — fecha com 1009 se excedido |
| `MaxQueueDepth` | 0 (ilimitado) | Máximo de requisições em-flight simultâneas — retorna 503 se excedido |
| `MaxConnections` | 0 (ilimitado) | Máximo de conexões simultâneas totais |
| `MaxConnectionsPerIP` | 0 (ilimitado) | Máximo de conexões por IP |
| `DrainTimeoutMs` | 30 000 ms | Tempo máximo de espera por requisições em-flight durante `Stop()` |
| `IdleTimeoutMs` | 10 000 ms | Timeout de conexão ociosa; `0` desabilita |

### Performance e HTTP/2

| Propriedade | Padrão | Descrição |
|-------------|--------|-----------|
| `WorkerCount` | 200 | Número de worker threads; `0` = auto (`CPU × 2`, mínimo 4) |
| `CompressionEnabled` | `False` | Habilita gzip inline para respostas de texto > 1 KB |
| `HTTP2Enabled` | `False` | Habilita HTTP/2 via ALPN (requer SSL) |
| `H2MaxConcurrentStreams` | 100 | `SETTINGS_MAX_CONCURRENT_STREAMS` enviado aos clientes |
| `H2InitialWindowSize` | 65535 | `SETTINGS_INITIAL_WINDOW_SIZE` enviado aos clientes |
| `TCPFastOpen` | `False` | Habilita TCP Fast Open (RFC 7413); ignorado silenciosamente se não suportado |

### Observabilidade

| Propriedade | Padrão | Descrição |
|-------------|--------|-----------|
| `MetricsEnabled` | `False` | Expõe métricas Prometheus em `MetricsPath` |
| `MetricsPath` | `'/metrics'` | Caminho do endpoint para scraping Prometheus |
| `MetricsAllowedCIDR` | `''` (todos) | Restringe scraping a este CIDR (ex: `'10.0.0.0/8'`) |
| `RateLimitPerIP` | 0 (off) | Máximo de req/s por IP — retorna 429 |
| `RateLimitGlobal` | 0 (off) | Máximo de req/s global — retorna 429 |
| `ProxyProtocol` | `ppDisabled` | Modo Proxy Protocol: `ppDisabled`, `ppV1`, `ppV2`, `ppAuto` |
| `OnLog` | `nil` | Callback de log de erros; `nil` escreve em `ErrOutput` |
| `OnRequestLog` | `nil` | Callback de access log (método, path, status, latência, bytes) |

### Injeção de Dependência (R-6)

O construtor aceita interfaces opcionais para testes unitários e customização:

```pascal
constructor Create(
  ABufferPool:  IBufferPool          = nil;   // nil → pool multi-tier embutido
  ASSLProvider: ISSLProvider         = nil;   // nil → OpenSSL real
  ACompression: ICompressionProvider = nil);  // nil → gzip via ZLib
```

Passe um spy ou stub em testes; passe `nil` em produção para usar os padrões reais.

## Documentação

- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Português)](docs/playbook_pt-br/README.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)
- [Contributing (English)](docs/CONTRIBUTING.md)

## Estrutura do código

```
src/
  Poseidon.Net.HttpServer.pas        ← servidor core (IOCP / epoll)
  Poseidon.Net.Connection.pas        ← objeto de conexão (ref-counted)
  Poseidon.Net.Dispatcher.pas        ← dispatcher de protocolo (HTTP/WS/H2)
  Poseidon.Net.HTTP1.Parser.pas      ← parser de requisição HTTP/1.1
  Poseidon.Net.HTTP2.pas             ← HTTP/2 (HPACK + controle de fluxo)
  Poseidon.Net.WebSocket.pas         ← frames WebSocket (zero-copy)
  Poseidon.Net.SSL.pas               ← bindings OpenSSL + SNI + mTLS
  Poseidon.Net.Security.pas          ← validação pura (IsPathSafe, StripCRLF …)
  Poseidon.Net.Pool.Buffer.pas       ← pool de buffers multi-tier (8 / 64 / 512 KB)
  Poseidon.Net.ResponseBuilder.pas   ← builder de resposta HTTP com pool
  Poseidon.Net.Interfaces.pas        ← IBufferPool, ISSLProvider, ICompressionProvider
  Poseidon.Net.Metrics.pas           ← formato Prometheus exposition
  Poseidon.Net.ProxyProtocol.pas     ← parser Proxy Protocol v1/v2
  Poseidon.Net.IO.pas                ← interface do backend de I/O
  Poseidon.Net.IO.IOCP.pas           ← backend IOCP (Windows)
  Poseidon.Net.IO.Epoll.pas          ← backend epoll (Linux)
```

## A Família Olímpica

> *Poseidon comanda os mares — transporte bruto, a força das ondas.*
> *Triton guarda as águas do pai — gerencia o que flui, retém o que não pode se perder.*
> *Pégaso voa pelos céus — nasceu do sangue de Medusa, pela espada que Hermes deu a Perseu.*
> *Hermes percorre todos os reinos — carrega mensagens entre deuses, mortais e monstros, mais rápido que qualquer onda.*

| Projeto | Mito | Papel |
|---------|------|-------|
| **Poseidon** (esta lib) | Deus dos mares | Camada de transporte assíncrono — IOCP/epoll, I/O bruto |
| [**Triton**](https://github.com/herlondf/triton) | Filho de Poseidon, guardião das profundezas | Pool de recursos genérico — conexões, clientes, SMTP |
| [**Pegasus**](https://github.com/herlondf/pegasus) | Nascido do sangue de Poseidon, cavalgado por heróis | Framework HTTP — roteamento, middleware, providers |
| **Hermes** *(Redis4D)* | Mensageiro dos deuses, guia entre os reinos | Cliente Redis — chave-valor rápido, pub/sub, mensageria |

---

## Licença

MIT

---

> 🇺🇸 Read this document in English: [README.md](./README.md)

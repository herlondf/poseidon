# Poseidon

> *Deus dos mares — transporte bruto, a força das ondas.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="180"/>
</p>

<p align="center">
  Servidor HTTP assíncrono de alta performance para Delphi — IOCP no Windows, epoll no Linux.<br/>
  Zero dependências externas. Um único WSASend por resposta. WebSocket, SSL/TLS e HTTP/2 nativos.
</p>

---

## Visão Geral

Poseidon (AsyncIO) é uma biblioteca Delphi standalone que fornece um servidor HTTP nativo com I/O assíncrono.
É usada como camada de transporte do [Pegasus](https://github.com/herlondf/pegasus) e do
[Horse](https://github.com/HashLoad/horse) quando o define `HORSE_ASYNCIO` está ativo.

| Funcionalidade | Status |
|----------------|--------|
| HTTP/1.1 keep-alive | ✅ |
| HTTPS (OpenSSL) | ✅ |
| SNI multi-certificado | ✅ |
| WebSocket | ✅ |
| HTTP/2 (h2 via ALPN) | ✅ |
| Compressão gzip | ✅ |
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
<caminho-para-asyncio>\src\
```

## Início Rápido

```pascal
uses AsyncIO.Net.HttpServer;

var
  LServer: TAsyncIONativeServer;
begin
  LServer := TAsyncIONativeServer.Create;
  LServer.Listen('0.0.0.0', 9000,
    procedure(const AReq: TAsyncIONativeRequest;
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

## Documentação

- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Português)](docs/playbook_pt-br/README.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)
- [Contributing (English)](docs/CONTRIBUTING.md)

## Estrutura do código

```
src/                                   ← core AsyncIO (zero dependências externas)
  AsyncIO.Net.HttpServer.pas           ← servidor core — syscalls epoll/IOCP
  AsyncIO.Net.Pool.Buffer.pas          ← pool de buffers lock-free
  AsyncIO.Net.Pool.Native.pas          ← pool de contexto por requisição
  AsyncIO.Net.WebAdapters.Native.pas   ← bridge para adaptadores WebBroker
  AsyncIO.Net.WebSocket.pas            ← manipulação de frames WebSocket
  AsyncIO.Net.SSL.pas                  ← bindings OpenSSL + SNI
  AsyncIO.Net.HTTP2.pas                ← HTTP/2 (h2 via ALPN)

providers/                             ← integrações com frameworks (opcionais)
  horse/
    Horse.Provider.AsyncIO.pas         ← provider Horse (requer Horse ≥ 3.1.9)
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

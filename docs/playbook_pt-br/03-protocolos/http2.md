# HTTP/2

O Poseidon implementa HTTP/2 (RFC 7540) com compressão de headers HPACK (RFC 7541).
HTTP/2 pode ser usado em dois modos:

| Modo | Como | Requisito |
|------|------|-----------|
| **h2** (cifrado) | Negociação ALPN durante o handshake TLS | Requer SSL |
| **h2c** (cleartext) | Mecanismo `Upgrade: h2c` do HTTP/1.1 | Sem SSL |

## Habilitando h2 (sobre TLS)

```pascal
LServer.HTTP2Enabled := True;   // deve ser definido antes de ConfigureSSL
LServer.ConfigureSSL('server.crt', 'server.key');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

Quando um cliente conecta e negocia `"h2"` via ALPN, o Poseidon cria uma instância
`TH2Conn` para a conexão. Clientes HTTP/1.1 na mesma porta continuam funcionando.

## Habilitando h2c (upgrade cleartext)

h2c não requer configuração. Qualquer conexão TCP simples que envie um header
`Upgrade: h2c` + `HTTP2-Settings` válido é automaticamente promovida:

```pascal
LServer.Listen('0.0.0.0', 8080, @HandleRequest, nil);
// cliente enviando Upgrade: h2c é transparentemente promovido para HTTP/2
```

## Negociação de SETTINGS

Configure os valores enviados ao cliente no frame SETTINGS inicial:

```pascal
LServer.H2MaxConcurrentStreams := 200;    // SETTINGS_MAX_CONCURRENT_STREAMS (padrão 100)
LServer.H2InitialWindowSize    := 65535;  // SETTINGS_INITIAL_WINDOW_SIZE (padrão 65535)
```

Ambas as propriedades devem ser definidas antes de `Listen`.

## Handler de aplicação

A assinatura do handler de requisição é a mesma para HTTP/1.1 e HTTP/2.
O Poseidon mapeia os pseudo-headers HTTP/2 (`:method`, `:path`, `:authority`) para
os campos de `TPoseidonNativeRequest` (`Method`, `Path`, `Host`).

## Limitações

- **Server Push** não está implementado (`ENABLE_PUSH = 0` no SETTINGS).
- HPACK: headers são enviados como literais sem indexação (correto, não ótimo).

## Veja também

- [Controle de Fluxo HTTP/2](http2-flow-control.md) — janelas por stream e de conexão
- [Upgrade HTTP/2 Cleartext (h2c)](h2c-upgrade.md) — fluxo detalhado do protocolo h2c

# Upgrade HTTP/2 Cleartext (h2c)

O Poseidon suporta o mecanismo de upgrade HTTP/1.1 → HTTP/2 definido no RFC 7540 §3.2,
permitindo que clientes alternem para HTTP/2 em conexões plain (sem TLS).

## Como funciona

1. O cliente envia uma requisição HTTP/1.1 com:
   ```
   Upgrade: h2c
   Connection: Upgrade, HTTP2-Settings
   HTTP2-Settings: <payload SETTINGS codificado em base64url>
   ```
2. O Poseidon detecta o header `Upgrade: h2c` em uma conexão plain.
3. O Poseidon responde:
   ```
   HTTP/1.1 101 Switching Protocols
   Connection: Upgrade
   Upgrade: h2c
   ```
4. A requisição original é reenviada como stream 1 do HTTP/2.
5. Todos os frames subsequentes na conexão usam o framing binário do HTTP/2.

## Habilitando h2c

O h2c é habilitado automaticamente quando:
- `TPoseidonNativeServer.H2Enabled` é `True` (padrão); e
- A conexão não tem TLS (`SSLHandle = nil`).

Nenhuma configuração adicional é necessária.

## Habilitando HTTP/2 no servidor

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.H2Enabled := True;   // habilita ALPN h2 (TLS) e upgrade h2c (plain)
LServer.Listen('0.0.0.0', 8080, HandleRequest);
```

## Diferença entre ALPN h2 e h2c

| | ALPN h2 | upgrade h2c |
|-|---------|-------------|
| Transporte | TLS apenas | TCP plain |
| Negociação | Extensão TLS | Header HTTP/1.1 Upgrade |
| Primeira requisição | Nova requisição HTTP/2 | Enviada como stream 1 |
| Suporte de browsers | Universal | Limitado (maioria exige TLS para h2) |

## Observações

- O header `HTTP2-Settings` é aceito, mas seu valor não é aplicado — o Poseidon
  usa seus próprios valores de SETTINGS configurados.
- O upgrade h2c só é acionado em conexões plain. Conexões TLS sempre usam negociação ALPN.
- Após o 101, a conexão é exclusivamente HTTP/2; HTTP/1.1 não é mais válido naquele socket.

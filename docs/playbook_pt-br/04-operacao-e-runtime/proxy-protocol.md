# Proxy Protocol

Quando o Poseidon executa atrás de um load-balancer (nginx, HAProxy, AWS NLB, …),
o `RemoteAddr` direto de cada conexão é o IP do load-balancer, não o IP real do cliente.
O Proxy Protocol (v1/v2) resolve isso fazendo o load-balancer prefixar o endereço real
do cliente em cada conexão TCP.

## Habilitando

```pascal
LServer.ProxyProtocol := ppAuto;   // aceita v1 ou v2 (auto-detecção pela assinatura)
// LServer.ProxyProtocol := ppV1;  // impõe apenas v1
// LServer.ProxyProtocol := ppV2;  // impõe apenas v2
// LServer.ProxyProtocol := ppDisabled;  // padrão — ignora qualquer header PP
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

`ProxyProtocol` deve ser definido antes de `Listen`.

## Modos

| Valor | Significado |
|-------|-------------|
| `ppDisabled` | Proxy Protocol não esperado (padrão) |
| `ppV1` | Espera Proxy Protocol v1 (formato texto) |
| `ppV2` | Espera Proxy Protocol v2 (formato binário) |
| `ppAuto` | Auto-detecta v1 vs v2 pela assinatura |

## Efeito

Quando o Proxy Protocol está ativo, `TPoseidonNativeRequest.RemoteAddr` contém
o **IP original do cliente** extraído do header PP — não o IP do load-balancer.
Rate limiting, limites de conexão por IP e métricas usam esse endereço resolvido.

## Aviso de segurança

**Habilite Proxy Protocol apenas em conexões de load-balancers confiáveis.**  
Aceitar PP de fontes não confiáveis permite que qualquer cliente falsifique seu IP.
Use regras de firewall ou `MaxConnectionsPerIP` para restringir quais hosts podem
conectar em uma porta com PP habilitado.

## Observações

- O header PP é parseado antes de qualquer dado HTTP ser processado; headers malformados
  fecham a conexão imediatamente.
- `ppAuto` adiciona um branch por conexão, mas tem overhead negligível.

# Métricas Prometheus

O Poseidon pode expor um endpoint HTTP que retorna métricas do servidor no
[formato exposition Prometheus](https://prometheus.io/docs/instrumenting/exposition_formats/) 0.0.4.

## Habilitando o endpoint

```pascal
LServer.MetricsEnabled     := True;
LServer.MetricsPath        := '/metrics';    // padrão
LServer.MetricsAllowedCIDR := '10.0.0.0/8'; // opcional — restringe scraping à rede interna
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

`MetricsEnabled` deve ser definido antes de `Listen`.

## Scraping

```
GET /metrics
```

Retorna uma resposta texto (`Content-Type: text/plain; version=0.0.4`) com todas
as métricas expostas. O intervalo padrão de scraping Prometheus é de 15–60 s.

## Restringindo o acesso

`MetricsAllowedCIDR` aceita um bloco CIDR IPv4. Requisições de scraping fora do
bloco recebem `403 Forbidden`. Defina como `''` (padrão) para permitir qualquer origem.

```pascal
LServer.MetricsAllowedCIDR := '172.16.0.0/12';  // somente redes Docker / VPC internas
```

## Acesso programático

A propriedade somente leitura `Metrics` expõe o objeto `TPoseidonMetrics` para
instrumentação customizada dentro do handler de requisição:

```pascal
LServer.Metrics.IncrementCounter('minhas_requisicoes_customizadas_total');
```

`Metrics` é `nil` quando `MetricsEnabled = False` — verifique antes de acessar.

## Observações

- As métricas são atualizadas atomicamente; o endpoint `/metrics` é seguro para scraping concorrente.
- O endpoint é servido pelo mesmo pool de workers que as requisições regulares.
- Não exponha `/metrics` em uma porta pública sem `MetricsAllowedCIDR` ou um proxy externo.

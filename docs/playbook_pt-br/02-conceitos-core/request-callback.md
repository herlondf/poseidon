# Contrato do callback de requisição

O único ponto de integração entre seu código e o Poseidon é o callback de requisição
passado para `TPoseidonNativeServer.Listen`:

```pascal
procedure(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>
)
```

## Regras

- O callback é chamado de uma thread worker. Deve ser **thread-safe**.
- `ABody` deve estar codificado em UTF-8 (ou binário). O Poseidon escreve verbatim — sem re-encoding.
- `AExtraHeaders` não deve incluir `Content-Type` nem `Content-Length` — o Poseidon define esses.
- Lançar exceção não tratada resulta em resposta 500. Prefira capturar e setar `AStatus := 500` explicitamente.
- O callback deve retornar antes da escrita na conexão ser concluída.
  **Não** guarde referência a `AReq` após o retorno do callback.

## Campos de TPoseidonNativeRequest

| Campo | Tipo | Descrição |
|-------|------|-----------|
| `Method` | `string` | Verbo HTTP (GET, POST, …) |
| `Path` | `string` | Caminho da URL sem query string |
| `QueryString` | `string` | Query string bruta |
| `Headers` | `TDictionary<string,string>` | Cabeçalhos da requisição (chaves em minúsculas) |
| `Body` | `TBytes` | Body bruto da requisição |
| `RemoteIP` | `string` | IP do cliente |

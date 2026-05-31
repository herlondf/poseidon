# Compressão

O Poseidon suporta compressão gzip inline para respostas HTTP/1.1.
A compressão está **desabilitada por padrão** (gasto de CPU — opt-in).

## Habilitando gzip

```pascal
LServer.CompressionEnabled := True;
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

Quando habilitado, respostas com `Content-Type` do tipo texto e body > 1 KB são
automaticamente comprimidas com gzip **se** o cliente enviou `Accept-Encoding: gzip`.

A resposta comprimida inclui o header `Content-Encoding: gzip`. O header
`Content-Length` reflete o tamanho comprimido.

## Elegibilidade

Uma resposta é comprimida quando todas as condições abaixo são verdadeiras:

| Condição | Detalhe |
|----------|---------|
| `CompressionEnabled = True` | Opt-in no servidor |
| Cliente enviou `Accept-Encoding: gzip` | Lido do header da requisição |
| Tamanho do body > 1 KB | Bodies menores não compensam comprimir |
| `Content-Type` começa com `text/` ou é `application/json` | Respostas binárias não são comprimidas |

## ICompressionProvider (injeção de dependência)

A compressão é respaldada por `ICompressionProvider`, que pode ser substituído:

```pascal
// nil → gzip ZLib embutido (TDefaultCompressionProvider)
LServer := TPoseidonNativeServer.Create(nil, nil, nil);

// Provider customizado (ex: Brotli ou mock em testes)
LServer := TPoseidonNativeServer.Create(nil, nil, TBrotliCompressionProvider.Create);
```

A interface `ICompressionProvider`:

```pascal
ICompressionProvider = interface
  function IsAvailable: Boolean;
  function TryCompress(const AInput: TBytes;
    const AAcceptEncoding: string;
    out AOutput:   TBytes;
    out AEncoding: string): Boolean;
end;
```

`TryCompress` recebe o valor completo do header `Accept-Encoding` e negocia o melhor
encoding disponível. Retorne `False` para indicar que nenhuma compressão foi aplicada.

## Observações

- A compressão é síncrona na worker thread — bodies grandes bloqueiam o worker.
- Respostas HTTP/2 não são comprimidas pelo servidor.
- Para máximo throughput, pré-comprima respostas estáticas offline e sirva-as diretamente.

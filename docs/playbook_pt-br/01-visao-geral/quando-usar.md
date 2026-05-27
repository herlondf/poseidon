# Quando usar o AsyncIO

## Bom encaixe

- APIs HTTP de alta concorrência no Linux ou Windows onde latência importa
- Substituir Indy ou Delphi-Cross-Socket como camada de transporte no Horse/Pegasus
- Cenários onde WebSocket e HTTP precisam coexistir na mesma porta
- Deploys sem dependências (sem VCL, sem Indy, sem DLL cross-socket)

## Não é adequado para

- Targets 32-bit (implementação epoll/IOCP é exclusivamente 64-bit)
- Targets macOS / ARM (não implementado)
- Aplicações que precisam do pipeline completo WebBroker sem Horse ou Pegasus

## Comparação

| | AsyncIO | Indy | Delphi-Cross-Socket |
|---|---|---|---|
| Dependências externas | nenhuma | nenhuma | CnPack (crypto) |
| epoll Linux | ✅ | ❌ | ✅ |
| IOCP Windows | ✅ | ❌ (blocking) | ✅ |
| HTTP/2 | ✅ | ❌ | ❌ |
| WebSocket | ✅ | parcial | ✅ |
| Envio único | ✅ | ❌ | ❌ |

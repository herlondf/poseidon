# O que é o AsyncIO

AsyncIO é uma biblioteca Delphi nativa de I/O assíncrono para servidores HTTP.
Ela ignora os stacks Delphi-Cross-Socket e Indy em favor de syscalls diretas do SO:

- **Windows**: I/O Completion Ports (IOCP) via `WSARecv` / `WSASend`
- **Linux**: epoll edge-triggered via `epoll_wait` / `sendfile`

Um único `WSASend` (ou `write`) entrega a resposta HTTP completa — sem travamento do Nagle,
sem double-write, sem necessidade de `TCP_NODELAY`.

## Propriedades principais

| Propriedade | Valor |
|-------------|-------|
| Dependências externas | **zero** |
| Plataformas | Linux 64-bit, Windows 64-bit |
| Threads worker padrão | 200 (`WorkerCount`) |
| Entrega de resposta | única syscall por resposta |
| Protocolos | HTTP/1.1, HTTPS, WebSocket, HTTP/2 |

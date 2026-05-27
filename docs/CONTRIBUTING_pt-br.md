# Contribuindo com o Poseidon

## Escopo

O Poseidon busca ser uma biblioteca Delphi de I/O assíncrono com zero dependências, focada em:

- **Apenas syscalls nativas** — epoll no Linux, IOCP no Windows; sem camada de transporte de terceiros
- **Um único WSASend por resposta** — elimina o stall de Nagle causado por padrões de dupla escrita
- **Hot path lock-free** — buffer pool e context pool com TMonitor; sem lock global no despacho de requisições
- **Separação de protocolos** — HttpServer cuida do I/O; adapters traduzem protocolos; pools gerenciam memória — nunca misturar

## Diretrizes técnicas

- `Poseidon.Net.HttpServer` é a **única** unit que faz syscalls diretas (epoll/IOCP). Todas as demais são adapters.
- Nunca adicionar `uses` de bibliotecas de terceiros em qualquer unit `Poseidon.Net.*` — zero dependências externas é uma restrição rígida.
- Novas units seguem a convenção de nomenclatura `Poseidon.Net.<Modulo>.pas`.
- Compatibilidade de plataforma: Linux 64-bit (epoll) **e** Windows 64-bit (IOCP). Qualquer bloco `{$IFDEF}` deve cobrir ambos.
- `class var` compartilhados entre threads → proteger com `TMonitor` ou `TCriticalSection`. Ver `Poseidon.Net.Pool.Buffer` como referência.
- `try/finally` obrigatório sempre que um objeto é alocado e precisa ser liberado.
- Sem blocos `except` vazios. Logar ou relançar.

## Fluxo sugerido

1. Abra uma issue descrevendo o bug, funcionalidade ou adição de protocolo.
2. Faça uma branch a partir de `main`.
3. Adicione ou ajuste testes em `tests/` quando a mudança afetar comportamento observável.
4. Se estiver adicionando um novo sample, coloque-o em `samples/NN-nome/` com seu próprio `.dpr` / `.dproj`.
5. Compile todos os samples afetados para confirmar que não há regressão.
6. Atualize o playbook em `docs/playbook/` quando a mudança afetar uso, opções ou comportamento observável.
7. Envie um pull request com descrição objetiva do problema e da solução.

## Validação mínima

Sempre valide:

- Build da suite de testes (`tests/Poseidon.Tests.dproj`)
- Build de todos os samples (`samples/0N-*/`)
- Smoke test quando a mudança tocar o caminho de despacho de requisições, buffer pool ou handshake SSL

## Adicionando uma nova funcionalidade de protocolo

1. Se requer novas syscalls, adicioná-las a `Poseidon.Net.HttpServer.pas` com guards `{$IFDEF MSWINDOWS}` / `{$IFDEF LINUX}`.
2. Criar uma unit dedicada `Poseidon.Net.<Funcionalidade>.pas` para a lógica do protocolo.
3. Expor via método em `TPoseidonNativeServer` — callers não devem precisar referenciar a nova unit diretamente.
4. Adicionar um sample em `samples/` e documentar em `docs/playbook/03-protocols/`.

## Convenções

- Documentação pública (`playbook/`) em inglês; `playbook_pt-br/` é a tradução direta — manter em sincronia.
- Código e identificadores seguem o estilo atual do projeto (prefixo `TPoseidon`, `IPoseidon`, `EPoseidon`).
- Mensagens de commit em pt-BR, formato `tipo(escopo): descrição curta` (Conventional Commits).

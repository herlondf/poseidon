# Poseidon v2 — Auditoria da máquina de estados TLS de runtime — 2026-07-15

Fecha o maior gap deixado em aberto pelo #209: a lógica TLS de **runtime** no
`Poseidon.Net.HttpServer` (`_ProcessRecvSSL`, `_EncryptAndSend`, `_CloseConn`,
`_OnNewSocket`, `Stop`), que estava fora dos 3 arquivos FFI auditados antes.
Método: rastrear WANT_READ/WRITE vs fatal, drain de BIO parcial, lifetime de
`SSL*`/BIO cross-thread (IO vs worker), renegociação e DoS de handshake.

## O que está CORRETO (confirmado por leitura, não por inspeção superficial)

- **Serialização SSL cross-thread (#213) — SÓLIDA.** Todo acesso a `SSL*`/BIO —
  `_ProcessRecvSSL` (SSL_Read/handshake) sob o `LConn.Lock` de `_ProcessRecv`, e
  `_EncryptAndSend` (SSL_Write) sob o `LConn.Lock` do worker (ou sync sob o mesmo
  lock) — e o **free** em `_CloseConn` ocorrem sob o MESMO lock por conexão.
  SSL_Read e SSL_Write nunca correm concorrentes no mesmo `SSL*`.
- **Lifetime / UAF — LIMPO.** `_CloseConn` faz `FConnManager.Remove` (idempotente,
  um único caller prossegue) ANTES do lock, libera `SSL*`+BIOs sob o lock e nila os
  campos; acessos posteriores checam `SSLHandle = nil`. Um worker retardatário que
  pegue o lock depois vê `nil` e vira no-op (socket já fechado). O ref do servidor
  mantém o objeto/lock vivos durante o teardown. No `Stop`, a liberação de SSL só
  ocorre se o pool drenou (senão vaza deliberadamente p/ evitar UAF com straggler —
  processo saindo). H2Conn é liberado só no `Destroy` (refcount 0), não em
  `_CloseConn` (#213).
- **WANT_READ de handshake e de SSL_Read — tratados** (flush do write BIO, re-arma
  recv, break do laço de drain). BIO de memória cresce → SSL_Write não retorna
  WANT_WRITE nesse setup.
- **Acúmulo em AccumBuf** é limitado por recv (o read BIO só tem os bytes
  alimentados naquele recv) e por `StepSizeCheck`/`MaxWSFrameSize` no dispatch.
- **Min TLS = TLS 1.2 ($0303) por padrão** — sem SSL/TLS legado.

## Achado A — [MEDIUM] Renegociação cliente-iniciada não desabilitada (CORRIGIDO)

O contexto TLS (`SSL.Manager.ConfigureSSL` / `AddSSLCert`) configurava min-version,
session cache, SNI e ALPN, mas **nunca chamava `SSL_CTX_set_options`** — logo a
renegociação cliente-iniciada em TLS 1.2 ficava **permitida**. É um vetor conhecido
de **DoS de amplificação de CPU**: o cliente força handshakes de renegociação
(crypto assimétrico caro) repetidamente numa única conexão.

**Fix:** novo `ISSLProvider.SetSecurityOptions` → `TPoseidonSSL.CTX_SetSecurityOptions`
chamado em ConfigureSSL e no setup per-host do AddSSLCert. Seta
`SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_COMPRESSION` (CRIME) `|
SSL_OP_CIPHER_SERVER_PREFERENCE`. `SSL_CTX_set_options` é bindado como **função
real** (`NativeUInt`) — na OpenSSL 1.1.0+ o ctrl `SSL_CTRL_OPTIONS` foi removido,
então o caminho `SSL_CTX_ctrl` viraria no-op silencioso; e `NativeUInt` (64-bit)
casa com `uint64_t` sem o smell de largura `long`. Regressão:
`ConfigureSSL_CallsSetSecurityOptions`. Gate 2-faces PASSED.

## Achados LOW (não corrigidos — robustez/correção, baixo risco)

- **[LOW] `SSL_Write <= 0` tratado como fatal sem distinguir WANT_*** em
  `_EncryptAndSend:304`. Com BIO de memória o WANT_WRITE não ocorre, mas um
  WANT_READ pós-handshake (ex.: KeyUpdate TLS 1.3) fecharia a conexão. Robustez.
- **[LOW] Sem `ERR_clear_error` antes de SSL_read/write/do_handshake.**
  `SSL_get_error` pode classificar com base em entradas antigas da fila de erro. Os
  caminhos tratam quase tudo não-WANT_READ como close (direção segura), então o
  impacto é baixo. Recomendação: limpar a fila antes de cada op.
- **[LOW/def-in-depth] Slowloris no nível TLS:** uma conexão que abre TCP+TLS e
  estola no meio do handshake segura `SSL*`+2 BIOs até o `IdleTimeout`. Mitigado por
  `MaxConnections` + `MaxConnectionsPerIP` + idle sweep (com esses configurados). Um
  timeout de handshake dedicado seria defesa adicional.

## Veredito

A máquina de estados TLS de runtime é **robusta**: a serialização por conexão do
#213 elimina de fato as corridas/UAF de `SSL*` cross-thread (confirmado por leitura
de todos os caminhos, não por inspeção), e o floor TLS 1.2 é são. O único gap de
segurança concreto — renegociação cliente-iniciada habilitada — foi **corrigido**
(+ compressão e ordem de cifra endurecidas), com regressão e gate 2-faces. Restam
LOWs de robustez (WANT_* no write, ERR_clear_error) e o slowloris-TLS mitigado por
limites de conexão. Isto fecha o gap de auditoria que o #209 explicitava.

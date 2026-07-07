# Receita — Graceful Reload (Restart sem Downtime)

Graceful reload permite substituir o processo do servidor por uma nova versão
sem rejeitar conexões ativas. O processo antigo continua servindo requisições
em andamento enquanto o novo processo já aceita novas conexões.

---

## Visao geral do fluxo

1. Deploy copia o novo binario para disco.
2. Script envia `SIGHUP` ao processo atual (Linux) ou escreve um marcador de
   reload (Windows).
3. O processo atual para de aceitar novas conexoes e aguarda as ativas drenarem
   (`DrainTimeoutMs`).
4. O novo processo sobe, le o PID file e registra o proprio PID.
5. O processo antigo encerra.

---

## Passo 1 — Configurar PIDFile

```pascal
LApp.PIDFile := '/var/run/poseidon-meuapp.pid';
```

O Poseidon grava o PID do processo ao chamar `Listen` e remove o arquivo ao
encerrar normalmente. Isso permite que scripts de deploy localizem o processo
sem precisar de `pgrep`.

---

## Passo 2 — Habilitar PerCoreAccept (SO_REUSEPORT)

```pascal
LApp.PerCoreAccept := True;
```

Com `SO_REUSEPORT`, dois processos podem escutar na mesma porta simultaneamente.
O kernel distribui novas conexoes entre eles. Durante o reload, o novo processo
sobe e começa a aceitar conexoes antes que o antigo encerre — sem downtime de
`accept`.

Disponivel em Linux kernel >= 3.9. No Windows, `PerCoreAccept` habilita
`SO_REUSEADDR` (comportamento equivalente parcial; nao ha garantia de
distribuicao pelo kernel).

---

## Passo 3 — Configurar DrainTimeoutMs

```pascal
LApp.DrainTimeoutMs := 10000;  // aguarda ate 10 s para conexoes ativas encerrarem
```

Quando `Stop` e chamado, o Poseidon:

1. Para de aceitar novas conexoes (fecha o socket de listen).
2. Aguarda conexoes ativas completarem, ate `DrainTimeoutMs` milissegundos.
3. Forcibly encerra conexoes restantes e libera recursos.

Ajuste conforme o tempo maximo esperado de suas requisicoes de maior latencia.

---

## Passo 4 — InstallSignalHandler (Linux)

```pascal
uses Poseidon.Net.Signal;

LApp.PIDFile := '/var/run/poseidon-meuapp.pid';
LApp.PerCoreAccept := True;
LApp.DrainTimeoutMs := 10000;
InstallSignalHandler(LApp);
LApp.Listen(9000);
```

`InstallSignalHandler` registra handlers POSIX para:

| Sinal | Acao |
|-------|------|
| `SIGTERM` | Chama `App.Stop` (graceful shutdown) |
| `SIGHUP` | Chama `App.Stop` (graceful reload — o script de deploy e responsavel por subir o novo processo) |
| `SIGINT` | Chama `App.Stop` (Ctrl+C no terminal) |

No Windows, `InstallSignalHandler` e um no-op. Use `SetConsoleCtrlHandler`
da WinAPI diretamente se precisar tratar Ctrl+C em producao no Windows.

---

## Passo 5 — Script de deploy

Script de referencia para Linux (bash):

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_BIN="/opt/meuapp/bin/meuapp"
NEW_BIN="/tmp/meuapp-novo"
PID_FILE="/var/run/poseidon-meuapp.pid"
DRAIN_WAIT=12   # segundos — deve ser > DrainTimeoutMs/1000

# 1. Copiar novo binario
cp "$NEW_BIN" "$APP_BIN.next"
chmod +x "$APP_BIN.next"

# 2. Subir novo processo (ja escuta na porta via SO_REUSEPORT)
"$APP_BIN.next" &
NEW_PID=$!
echo "Novo processo PID: $NEW_PID"

# 3. Aguardar o novo processo registrar o PID file dele
sleep 1

# 4. Enviar SIGHUP ao processo antigo
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  kill -HUP "$OLD_PID" && echo "SIGHUP enviado para PID $OLD_PID"
fi

# 5. Aguardar drenagem
sleep "$DRAIN_WAIT"

# 6. Substituir binario principal
mv "$APP_BIN.next" "$APP_BIN"
echo "Deploy concluido."
```

---

## Comportamento no Windows

| Recurso | Linux | Windows |
|---------|-------|---------|
| PIDFile | Suportado | Suportado |
| PerCoreAccept | SO_REUSEPORT (kernel distribui) | SO_REUSEADDR (sem distribuicao garantida) |
| InstallSignalHandler | SIGTERM / SIGHUP / SIGINT | No-op |
| DrainTimeoutMs | Suportado | Suportado |

No Windows, o reload pode ser orquestrado por um servico do Windows (NSSM,
WinSW) que envia uma solicitacao de parada ao servico antigo e inicia o novo,
aproveitando o `DrainTimeoutMs` para a janela de drenagem.

---

## Veja tambem

- [08 — API Nativa](../08-api-nativa/README.md) — propriedades `PIDFile`, `DrainTimeoutMs`, `PerCoreAccept`
- [04 — Operacao e Runtime](../04-operacao-e-runtime/README.md) — worker threads e ciclo de vida

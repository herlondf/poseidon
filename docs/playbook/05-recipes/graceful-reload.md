# Recipe: Zero-Downtime Restart (Graceful Reload)

This recipe shows how to replace a running Poseidon process with a new binary
without dropping in-flight requests or refusing new connections during the
transition.

The technique relies on `SO_REUSEPORT`: the new process binds the same port
while the old process finishes draining, then the old process exits. At no
point is the port unbound.

---

## Prerequisites

- Linux kernel >= 3.9 for `SO_REUSEPORT` (all modern distros qualify).
- The new binary must be in place before sending the reload signal.
- On Windows, `SO_REUSEPORT` is not available. Use the PID file + service
  manager restart instead (see the Windows note at the end).

---

## Server setup

```pascal
uses
  Poseidon.Net.Server,
  Poseidon.Net.Signal;

var
  LApp: TPoseidonServer;
begin
  LApp := TPoseidonServer.Create;
  try
    // 1. Write the PID file so the deploy script can find this process.
    LApp.PIDFile := '/var/run/myapp/poseidon.pid';

    // 2. Enable per-core accept so each worker thread owns its own listener
    //    socket via SO_REUSEPORT.  The new process can bind the same port
    //    while this one is still running.
    LApp.PerCoreAccept := True;

    // 3. How long to wait for in-flight requests to complete before
    //    forcibly closing connections.
    LApp.DrainTimeoutMs := 5000;

    // 4. Install the signal handler (Linux only).
    //    SIGUSR2 triggers a graceful reload:
    //      a) the new process starts and binds the port,
    //      b) this process stops accepting new connections,
    //      c) in-flight requests are drained up to DrainTimeoutMs,
    //      d) this process exits with code 0.
    InstallSignalHandler(LApp);

    LApp.Get('/ping', procedure(var ACtx: TNativeRequestContext)
    begin
      ACtx.Body := 'pong';
    end);

    LApp.Listen(9000);
  finally
    LApp.Free;
  end;
end;
```

---

## Deploy script (Linux)

```bash
#!/usr/bin/env bash
set -euo pipefail

PID_FILE=/var/run/myapp/poseidon.pid
NEW_BIN=/opt/myapp/bin/myapp_new
LIVE_BIN=/opt/myapp/bin/myapp

# 1. Copy the new binary into place.
cp "$NEW_BIN" "$LIVE_BIN"

# 2. Read the PID of the currently running process.
if [[ ! -f "$PID_FILE" ]]; then
  echo "PID file not found — starting fresh."
  "$LIVE_BIN" &
  exit 0
fi

OLD_PID=$(cat "$PID_FILE")

# 3. Start the new process.  It binds the port immediately via SO_REUSEPORT.
"$LIVE_BIN" &
NEW_PID=$!

# 4. Give the new process a moment to bind and begin accepting.
sleep 1

# 5. Send SIGUSR2 to the old process.  It stops accepting new connections
#    and begins draining in-flight requests.
kill -USR2 "$OLD_PID"

# 6. Wait for the old process to exit (drain + DrainTimeoutMs).
timeout 30 tail --pid="$OLD_PID" -f /dev/null || true

echo "Reload complete. New PID: $NEW_PID"
```

---

## How the drain phase works

1. `InstallSignalHandler` catches `SIGUSR2` on the main thread.
2. The server closes the listener socket (no new connections accepted).
3. Existing connections continue to be processed normally.
4. After `DrainTimeoutMs` milliseconds, any remaining connections are closed
   with a `Connection: close` header on the next response boundary.
5. The process exits with code 0.

The new process started in step 3 of the deploy script is already accepting
connections on the same port via `SO_REUSEPORT`. Clients and load balancers
see no gap in availability.

---

## Systemd integration

If you run Poseidon as a systemd service, you can trigger the reload with:

```bash
systemctl reload myapp
```

Configure the service unit to map `reload` to `SIGUSR2`:

```ini
[Service]
ExecStart=/opt/myapp/bin/myapp
ExecReload=/bin/kill -USR2 $MAINPID
KillMode=process
TimeoutStopSec=30
Restart=on-failure
```

---

## Windows note

`SO_REUSEPORT` and `SIGUSR2` are not available on Windows. The PID file is
still written, but `InstallSignalHandler` is a no-op on Windows.

For zero-downtime deploys on Windows:

1. Use a service manager (NSSM, WinSW, or Windows Service) with a
   configurable stop timeout that matches `DrainTimeoutMs`.
2. Deploy the new binary, then issue a service restart. The service manager
   will wait for the old process to drain before starting the new one.
3. Use a load balancer (IIS ARR, nginx on WSL, or a hardware LB) in front
   of two instances alternating on ports 9000 and 9001 for true zero-downtime.

---

## See also

- [08 — Native API — Lifecycle](../08-native-api/README.md#lifecycle)
- [08 — Native API — Configuration properties](../08-native-api/README.md#configuration-properties)
- [04 — Operations](../04-operations/README.md)

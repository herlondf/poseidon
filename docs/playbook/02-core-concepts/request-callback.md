# Request callback contract

The sole integration point between your code and AsyncIO is the request callback
passed to `TAsyncIONativeServer.Listen`:

```pascal
procedure(
  const AReq:          TAsyncIONativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>
)
```

## Rules

- The callback is called from a worker thread. It **must** be thread-safe.
- `ABody` must be UTF-8 encoded (or binary). AsyncIO writes it verbatim — no re-encoding.
- `AExtraHeaders` must not include `Content-Type` or `Content-Length` — AsyncIO sets those.
- Raising an unhandled exception from the callback results in a 500 response with the
  exception message in the body. Prefer catching and setting `AStatus := 500` explicitly.
- The callback must return before the connection write completes.
  Do **not** hold a reference to `AReq` after the callback returns.

## TAsyncIONativeRequest fields

| Field | Type | Description |
|-------|------|-------------|
| `Method` | `string` | HTTP verb (GET, POST, …) |
| `Path` | `string` | URL path without query string |
| `QueryString` | `string` | Raw query string |
| `Headers` | `TDictionary<string,string>` | Request headers (lowercase keys) |
| `Body` | `TBytes` | Raw request body |
| `RemoteIP` | `string` | Client IP address |

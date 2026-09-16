unit Poseidon.Net.Types;

// Shared public types for the Poseidon framework.
// Extracted from Poseidon.Net.HttpServer so that Dispatcher and other units
// can reference them without creating circular dependencies.

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Generics.Collections;
  {$ELSE}
  System.SysUtils,
  System.Generics.Collections;
  {$ENDIF}

type
  // Request / response types

  TPoseidonNativeRequest = record
    Method: string;
    Path: string;
    QueryString: string;
    RawBody: TBytes;
    RemoteAddr: string;
    KeepAlive: Boolean;
    Headers: TArray<TPair<string,string>>;
  end;

  TOnNativeRequest = reference to procedure(
    const AReq: TPoseidonNativeRequest;
    out AStatus: Integer;
    out AContentType: string;
    out ABody: TBytes;
    out AExtraHeaders: TArray<TPair<string,string>>);

  // HTTP/2 server push resource - used with TPoseidonNativeServer.OnH2Push.
  // The server sends a PUSH_PROMISE + synthetic GET response for each resource.
  TPoseidonPushResource = record
    Path: string;
    ContentType: string;
    Body: TBytes;
    Extra: TArray<TPair<string, string>>;
  end;

  // Called before the HTTP/2 response is sent.  Populate APushResources with
  // any resources to proactively push to the client.
  TOnH2Push = reference to procedure(
    const AReq: TPoseidonNativeRequest;
    var APushResources: TArray<TPoseidonPushResource>);

  // Logging types

  TLogLevel = (llDebug, llInfo, llWarning, llError);
  TOnPoseidonLog = reference to procedure(ALevel: TLogLevel; const AMessage: string);
  // Only affects the server's OWN default log sink (Writeln to ErrOutput
  // when no OnLog callback is assigned) - a consumer that sets OnLog already
  // controls formatting entirely and this has no effect on it. lfJSON wraps
  // the exact same pre-formatted message string (e.g. the whole "[health]
  // conns=..." line) as one JSON string field - it does not break individual
  // key=value pairs out into separate JSON fields, so a log aggregator gets
  // valid, parseable JSON, but "structured" here means "one JSON object per
  // line", not "one field per metric".
  TPoseidonLogFormat = (lfPlain, lfJSON);

  TPoseidonRequestLogEvent = record
    Method: string;
    Path: string;
    Status: Integer;
    DurationMs: Int64;
    RemoteAddr: string;
    RxBytes: Int64;
    TxBytes: Int64;
  end;
  TOnPoseidonRequestLog = reference to procedure(
    const AEvent: TPoseidonRequestLogEvent);

implementation

end.

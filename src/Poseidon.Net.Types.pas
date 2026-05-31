unit Poseidon.Net.Types;

// Shared public types for the Poseidon framework.
// Extracted from Poseidon.Net.HttpServer so that Dispatcher and other units
// can reference them without creating circular dependencies.

interface

uses
  System.SysUtils,
  System.Generics.Collections;

type
  // --------------------------------------------------------------------------
  // Request / response types
  // --------------------------------------------------------------------------

  TPoseidonNativeRequest = record
    Method:      string;
    Path:        string;
    QueryString: string;
    RawBody:     TBytes;
    RemoteAddr:  string;
    KeepAlive:   Boolean;
    Headers:     TArray<TPair<string,string>>;
  end;

  TOnNativeRequest = reference to procedure(
    const AReq:          TPoseidonNativeRequest;
    out   AStatus:       Integer;
    out   AContentType:  string;
    out   ABody:         TBytes;
    out   AExtraHeaders: TArray<TPair<string,string>>);

  // HTTP/2 server push resource — used with TPoseidonNativeServer.OnH2Push.
  // The server sends a PUSH_PROMISE + synthetic GET response for each resource.
  TPoseidonPushResource = record
    Path:        string;    // e.g. '/styles.css'
    ContentType: string;
    Body:        TBytes;
    Extra:       TArray<TPair<string, string>>;
  end;

  // Called before the HTTP/2 response is sent.  Populate APushResources with
  // any resources to proactively push to the client.
  TOnH2Push = reference to procedure(
    const AReq:           TPoseidonNativeRequest;
    var   APushResources: TArray<TPoseidonPushResource>);

  // --------------------------------------------------------------------------
  // Logging types
  // --------------------------------------------------------------------------

  TLogLevel = (llDebug, llInfo, llWarning, llError);
  TOnPoseidonLog = reference to procedure(ALevel: TLogLevel; const AMessage: string);

  TPoseidonRequestLogEvent = record
    Method:     string;
    Path:       string;
    Status:     Integer;
    DurationMs: Int64;
    RemoteAddr: string;
    RxBytes:    Int64;
    TxBytes:    Int64;
  end;
  TOnPoseidonRequestLog = reference to procedure(
    const AEvent: TPoseidonRequestLogEvent);

implementation

end.

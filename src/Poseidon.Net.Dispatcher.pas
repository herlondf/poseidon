unit Poseidon.Net.Dispatcher;

// TProtocolDispatcher — Pipeline pattern.
//
// Replaces the dual _DispatchFull/_DispatchLightweight paths with a composable
// array of TDispatchStep methods walked in a tight loop.  The pipeline is
// configured once at construction time based on the ALightweight flag:
//
//   Full:        [ProxyProtocol, SizeCheck, H2Branch, WSBranch,
//                 ParseFull, UpgradeDetect, InvokeAndRespond]
//   Lightweight: [SizeCheck, ParseLightweight, InvokeAndRespond]
//
// NOTE: the Lightweight pipeline (SyncDispatch) has no UpgradeDetection step and
// materializes no headers, so WebSocket / h2c upgrades are unavailable in that
// mode. Use the Full pipeline when upgrades must be supported (issue #165).
//
// Each step receives a stack-allocated TDispatchContext record and sets
// Ctx.Handled := True to short-circuit the pipeline.
//
// TDispatchStep = procedure(var ACtx: TDispatchContext) of object
//   → zero heap allocation (code + Self pointers only)
//   → direct call, no vtable lookup

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  Generics.Collections,
  syncobjs,
  Math,
  Poseidon.Compat,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.SyncObjs,
  System.Math,
  {$ENDIF}
  Poseidon.Net.Types,
  Poseidon.Net.Connection,
  Poseidon.Net.HTTP2,
  Poseidon.Net.ProxyProtocol,
  Poseidon.Net.ResponseBuilder,
  Poseidon.Net.Interfaces;

const
  CMaxDispatchSteps = 7;

type
  // --------------------------------------------------------------------------
  // Config snapshot — fields read on every request; copied from server fields.
  // --------------------------------------------------------------------------

  PDispatchConfig = ^TDispatchConfig;

  TDispatchConfig = record
    ProxyProtocol:        TProxyProtocolMode;
    TrustedProxies:       TArray<string>;   // CIDRs allowed to inject PROXY header
    MaxRequestSize:       Integer;
    MaxHeaderSize:        Integer;
    H2Enabled:            Boolean;
    SecureHeadersEnabled: Boolean;
    ServerBanner:         string;
    MaxQueueDepth:        Integer;
    InFlightCount:        PInt64;   // pointer to server's FInFlightCount (atomic)
  end;

  // --------------------------------------------------------------------------
  // Callback interface — implemented by TPoseidonNativeServer.
  // The dispatcher never calls server fields directly; only through here.
  // --------------------------------------------------------------------------

  IDispatchCallbacks = interface
    ['{D1E2F3A4-B5C6-7890-ABCD-EF1234567890}']
    // Transport
    procedure PostRecv(AConn: Pointer);
    procedure CloseConn(AConn: Pointer);
    procedure SendResponse(AConn: Pointer; const AData: TBytes; AActualLen: Integer);
    // Vectored send — headers + body separately, no concatenation
    procedure SendResponseV(AConn: Pointer;
      const AHeaders: TBytes; AHdrLen: Integer;
      const ABody: TBytes; ABodyLen: Integer);

    // Protocol upgrades
    procedure UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    procedure UpgradeToH2C(AConn: Pointer; const AReq: TPoseidonNativeRequest);

    // WebSocket
    function DispatchWSFrames(AConn: Pointer): Boolean;

    // Application handler (includes exception handling and inflight tracking).
    // AConn is passed so the callback can bind a deferred responder to the
    // connection currently being dispatched. ADeferred is set True when the
    // handler took ownership of the response (Ctx.Defer) — the caller then must
    // NOT send a response nor re-arm the connection.
    procedure InvokeRequest(AConn: Pointer; const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtra: TArray<TPair<string,string>>;
      out ADeferred: Boolean);

    // Access log
    procedure LogRequest(const AEvent: TPoseidonRequestLogEvent);
  end;

  // --------------------------------------------------------------------------
  // Pipeline context — stack-allocated, flows between steps
  // --------------------------------------------------------------------------

  TDispatchContext = record
    Conn:          Pointer;
    Config:        PDispatchConfig;
    Req:           TPoseidonNativeRequest;
    Status:        Integer;
    ContentType:   string;
    Body:          TBytes;
    Extra:         TArray<TPair<string,string>>;
    Resp:          TBytes;
    RespActualLen: Integer;
    Consumed:      Integer;
    ReqBad:        Boolean;
    StartTick:     Int64;
    Handled:       Boolean;   // True = stop pipeline
    HdrStart:      Integer;   // lightweight: lazy headers byte range
    HdrEnd:        Integer;
  end;

  // --------------------------------------------------------------------------
  // Pipeline step signature
  // --------------------------------------------------------------------------

  TDispatchStep = procedure(var ACtx: TDispatchContext) of object;

  // --------------------------------------------------------------------------
  // Pipeline dispatcher
  // --------------------------------------------------------------------------

  TProtocolDispatcher = class
  private
    FCallbacks: IDispatchCallbacks;
    FSteps: array[0..CMaxDispatchSteps] of TDispatchStep;
    FStepCount: Integer;
    FLightweight: Boolean;

    // Step methods — each ~20-40 lines, single responsibility
    procedure StepProxyProtocol(var ACtx: TDispatchContext);
    procedure StepSizeCheck(var ACtx: TDispatchContext);
    procedure StepH2Branch(var ACtx: TDispatchContext);
    procedure StepWSBranch(var ACtx: TDispatchContext);
    procedure StepParseHTTP1Full(var ACtx: TDispatchContext);
    procedure StepParseHTTP1Lightweight(var ACtx: TDispatchContext);
    procedure StepUpgradeDetection(var ACtx: TDispatchContext);
    procedure StepInvokeAndRespond(var ACtx: TDispatchContext);
    procedure StepInvokeAndRespondLightweight(var ACtx: TDispatchContext);
  public
    constructor Create(ACallbacks: IDispatchCallbacks; ALightweight: Boolean);

    // Walk the pipeline for AConn with the given config snapshot.
    procedure Dispatch(AConn: Pointer; const AConfig: TDispatchConfig); reintroduce;

    property Lightweight: Boolean read FLightweight;
  end;

implementation

uses
  Poseidon.Net.HTTP1.Parser;

// ---------------------------------------------------------------------------
// Constructor — assemble pipeline once
// ---------------------------------------------------------------------------

constructor TProtocolDispatcher.Create(ACallbacks: IDispatchCallbacks;
  ALightweight: Boolean);
begin
  inherited Create;
  FCallbacks := ACallbacks;
  FLightweight := ALightweight;
  FStepCount := 0;

  if ALightweight then
  begin
    FSteps[FStepCount] := StepSizeCheck;              Inc(FStepCount);
    FSteps[FStepCount] := StepParseHTTP1Lightweight;  Inc(FStepCount);
    FSteps[FStepCount] := StepInvokeAndRespondLightweight; Inc(FStepCount);
  end
  else
  begin
    FSteps[FStepCount] := StepProxyProtocol;     Inc(FStepCount);
    FSteps[FStepCount] := StepSizeCheck;         Inc(FStepCount);
    FSteps[FStepCount] := StepH2Branch;          Inc(FStepCount);
    FSteps[FStepCount] := StepWSBranch;          Inc(FStepCount);
    FSteps[FStepCount] := StepParseHTTP1Full;    Inc(FStepCount);
    FSteps[FStepCount] := StepUpgradeDetection;  Inc(FStepCount);
    FSteps[FStepCount] := StepInvokeAndRespond;  Inc(FStepCount);
  end;
end;

// ---------------------------------------------------------------------------
// Dispatch — tight loop over pre-configured steps
// ---------------------------------------------------------------------------

procedure TProtocolDispatcher.Dispatch(AConn: Pointer;
  const AConfig: TDispatchConfig);
var
  LCtx: TDispatchContext;
  I:    Integer;
begin
  LCtx := Default(TDispatchContext);
  LCtx.Conn := AConn;
  LCtx.Config := @AConfig;
  LCtx.Handled := False;

  for I := 0 to FStepCount - 1 do
  begin
    FSteps[I](LCtx);
    if LCtx.Handled then
      Exit;
  end;
end;

// ===========================================================================
// Pipeline steps
// ===========================================================================

// ---------------------------------------------------------------------------
// StepProxyProtocol — consume PP header once per new connection
// ---------------------------------------------------------------------------

procedure TProtocolDispatcher.StepProxyProtocol(var ACtx: TDispatchContext);
var
  LConn:         TNativeConn;
  LPPAddr:       string;
  LPPPort:       Word;
  LPPConsumed:   Integer;
  LPPIncomplete: Boolean;
  LPPInvalid:    Boolean;
  LPPNoSig:      Boolean;
begin
  LConn := TNativeConn(ACtx.Conn);

  if (ACtx.Config^.ProxyProtocol = ppDisabled) or LConn.PPParsed then
    Exit;

  if LConn.AccumLen = 0 then
  begin
    FCallbacks.PostRecv(ACtx.Conn);
    ACtx.Handled := True;
    Exit;
  end;

  LPPAddr       := '';
  LPPPort       := 0;
  LPPConsumed   := 0;
  LPPIncomplete := False;
  LPPInvalid    := False;
  LPPNoSig      := False;

  if TryParseProxyProtocolAuto(ACtx.Config^.ProxyProtocol,
       @LConn.AccumBuf[0], LConn.AccumLen,
       LPPAddr, LPPPort, LPPConsumed,
       LPPIncomplete, LPPInvalid, LPPNoSig,
       LConn.RemoteAddr, ACtx.Config^.TrustedProxies) then
  begin
    if LPPConsumed > 0 then
    begin
      Dec(LConn.AccumLen, LPPConsumed);
      if LConn.AccumLen > 0 then
        Move(LConn.AccumBuf[LPPConsumed], LConn.AccumBuf[0], LConn.AccumLen);
    end;
    if LPPAddr <> '' then
      LConn.RemoteAddr := LPPAddr + ':' + IntToStr(LPPPort);
    LConn.PPParsed := True;
  end
  else if LPPIncomplete then
  begin
    FCallbacks.PostRecv(ACtx.Conn);
    ACtx.Handled := True;
  end
  else if LPPInvalid then
  begin
    FCallbacks.CloseConn(ACtx.Conn);
    ACtx.Handled := True;
  end
  else
    LConn.PPParsed := True;  // ppAuto + no signature → treat as plain
end;

// ---------------------------------------------------------------------------
// StepSizeCheck — reject oversized payloads with 413
// ---------------------------------------------------------------------------

// True when the request headers already in AccumBuf declare a Content-Length
// greater than AMax. Lets StepSizeCheck answer 413 (Payload Too Large) from the
// headers alone, BEFORE the parser's own over-limit guard rejects the same body
// with a generic 400. Conservative: any ambiguity (headers incomplete, no CL,
// unparseable value) returns False and the normal pipeline continues.
function _DeclaredCLExceeds(const ABuf: TBytes; ALen, AMax: Integer): Boolean;
const
  CName: array[0..13] of Byte = (Ord('c'),Ord('o'),Ord('n'),Ord('t'),Ord('e'),
    Ord('n'),Ord('t'),Ord('-'),Ord('l'),Ord('e'),Ord('n'),Ord('g'),Ord('t'),Ord('h'));
var
  LHdrEnd, I, J, LStart: Integer;
  LMatch: Boolean;
  LVal: Int64;
begin
  Result := False;
  // Bound the scan to the header block (first CRLFCRLF); if absent, headers are
  // still arriving — defer.
  LHdrEnd := -1;
  I := 0;
  while I + 3 < ALen do
  begin
    if (ABuf[I] = 13) and (ABuf[I+1] = 10) and (ABuf[I+2] = 13) and (ABuf[I+3] = 10) then
    begin LHdrEnd := I; Break; end;
    Inc(I);
  end;
  if LHdrEnd < 0 then Exit;

  I := 0;
  while I < LHdrEnd do
  begin
    // At a line start, try to match "content-length" case-insensitively.
    LMatch := True;
    for J := 0 to High(CName) do
      if (I + J >= LHdrEnd) or ((ABuf[I + J] or $20) <> CName[J]) then
      begin LMatch := False; Break; end;
    if LMatch then
    begin
      J := I + Length(CName);
      while (J < LHdrEnd) and ((ABuf[J] = 32) or (ABuf[J] = 9)) do Inc(J);
      if (J < LHdrEnd) and (ABuf[J] = Ord(':')) then
      begin
        Inc(J);
        while (J < LHdrEnd) and ((ABuf[J] = 32) or (ABuf[J] = 9)) do Inc(J);
        LStart := J;
        LVal := 0;
        while (J < LHdrEnd) and (ABuf[J] >= Ord('0')) and (ABuf[J] <= Ord('9')) do
        begin
          LVal := LVal * 10 + (ABuf[J] - Ord('0'));
          if LVal > AMax then Exit(True);  // already over — short-circuit
          Inc(J);
        end;
        if J > LStart then
          Exit(LVal > AMax);
        Exit;  // present but empty/unparseable — defer to the parser
      end;
    end;
    // Advance to the next header line.
    while (I < LHdrEnd) and not ((ABuf[I] = 13) and (I + 1 < ALen) and (ABuf[I+1] = 10)) do
      Inc(I);
    Inc(I, 2);
  end;
end;

procedure TProtocolDispatcher.StepSizeCheck(var ACtx: TDispatchContext);
var
  LConn: TNativeConn;
  LResp: TBytes;
begin
  LConn := TNativeConn(ACtx.Conn);

  // #199: a WebSocket connection's AccumBuf holds WS frame bytes, NOT an HTTP
  // request — its size is bounded by MaxWSFrameSize in the WS manager. Applying
  // the HTTP MaxRequestSize here rejected any WS message larger than it with a
  // 413 (garbage in the WS stream) and closed the connection before StepWSBranch
  // could echo it — Autobahn 9.1.5/6, 9.2.5/6 (>4 MB messages).
  if LConn.WSMode = CCMWebSocket then
    Exit;

  // 413 when EITHER the accumulated bytes exceed the limit, OR the request
  // already declares a Content-Length over it (so an oversized POST gets a
  // proper 413 instead of the parser's generic 400 for the over-limit body).
  if (LConn.AccumLen <= ACtx.Config^.MaxRequestSize) and
     not _DeclaredCLExceeds(LConn.AccumBuf, LConn.AccumLen, ACtx.Config^.MaxRequestSize) then
    Exit;

  LResp := BuildHTTPResponse(413, 'text/plain',
    TEncoding.ASCII.GetBytes('Payload Too Large'), False, [],
    ACtx.Config^.SecureHeadersEnabled, ACtx.Config^.ServerBanner);
  FCallbacks.SendResponse(ACtx.Conn, LResp, 0);
  // #174: the 413 response advertises Connection: close — force the socket to
  // actually close and drop the offending bytes so OnSendComplete does not
  // re-dispatch the same oversized buffer in a keep-alive loop.
  LConn.KeepAlive := False;
  LConn.AccumLen  := 0;
  ACtx.Handled := True;
end;

// ---------------------------------------------------------------------------
// StepH2Branch — route to HTTP/2 handler if connection upgraded
// ---------------------------------------------------------------------------

procedure TProtocolDispatcher.StepH2Branch(var ACtx: TDispatchContext);
var
  LConn: TNativeConn;
  LLen:  Integer;
begin
  LConn := TNativeConn(ACtx.Conn);

  if LConn.H2Conn = nil then
    Exit;

  if LConn.AccumLen > 0 then
  begin
    // #213: zero AccumLen BEFORE ProcessData. On the epoll backend a response
    // send issued inside ProcessData completes inline and re-enters
    // OnSendComplete synchronously; if AccumLen were still > 0 there, the H2
    // conn (SSLHandshook, KeepAlive) path re-dispatches the SAME AccumBuf on a
    // second worker-pool thread — two concurrent TH2Conn.ProcessData calls
    // racing on FStreams/HPACK/flow-control → heap corruption / EAccessViolation.
    LLen := LConn.AccumLen;
    LConn.AccumLen := 0;
    LConn.H2Conn.ProcessData(@LConn.AccumBuf[0], LLen);
  end;
  // ProcessData may have closed the connection (GOAWAY / connection error on an
  // idle conn), which frees H2Conn (FreeAndNil). Guard against the nil-deref.
  if (LConn.H2Conn <> nil) and (not LConn.H2Conn.GoAwaySent) then
    FCallbacks.PostRecv(ACtx.Conn);
  ACtx.Handled := True;
end;

// ---------------------------------------------------------------------------
// StepWSBranch — route to WebSocket frame dispatch
// ---------------------------------------------------------------------------

procedure TProtocolDispatcher.StepWSBranch(var ACtx: TDispatchContext);
var
  LConn: TNativeConn;
begin
  LConn := TNativeConn(ACtx.Conn);

  if LConn.WSMode <> CCMWebSocket then
    Exit;

  if FCallbacks.DispatchWSFrames(ACtx.Conn) then
    FCallbacks.PostRecv(ACtx.Conn);
  ACtx.Handled := True;
end;

// ---------------------------------------------------------------------------
// StepParseHTTP1Full — full HTTP/1.1 parse with all headers materialized
// ---------------------------------------------------------------------------

procedure TProtocolDispatcher.StepParseHTTP1Full(var ACtx: TDispatchContext);
var
  LConn: TNativeConn;
  LResp: TBytes;
begin
  LConn := TNativeConn(ACtx.Conn);

  ACtx.ReqBad := False;
  if not ParseHTTP1Request(
       LConn.AccumBuf, LConn.AccumLen,
       ACtx.Config^.MaxHeaderSize, ACtx.Config^.MaxRequestSize,
       ACtx.Req.Method, ACtx.Req.Path, ACtx.Req.QueryString,
       ACtx.Req.Headers, ACtx.Req.RawBody, ACtx.Req.KeepAlive,
       ACtx.Consumed, ACtx.ReqBad) then
  begin
    if ACtx.ReqBad then
    begin
      LResp := BuildHTTPResponse(400, 'text/plain',
        TEncoding.ASCII.GetBytes('Bad Request'), False, [],
        ACtx.Config^.SecureHeadersEnabled, ACtx.Config^.ServerBanner);
      FCallbacks.SendResponse(ACtx.Conn, LResp, 0);
      // #174: 400 advertises Connection: close — force-close and drop the
      // malformed bytes so OnSendComplete does not re-parse them in a loop.
      LConn.KeepAlive := False;
      LConn.AccumLen  := 0;
    end
    else
      FCallbacks.PostRecv(ACtx.Conn);
    ACtx.Handled := True;
    Exit;
  end;

  ACtx.Req.RemoteAddr := LConn.RemoteAddr;
  if LConn.AccumLen > ACtx.Consumed then
    Move(LConn.AccumBuf[ACtx.Consumed], LConn.AccumBuf[0],
      LConn.AccumLen - ACtx.Consumed);
  LConn.AccumLen := LConn.AccumLen - ACtx.Consumed;
end;

// ---------------------------------------------------------------------------
// StepParseHTTP1Lightweight — minimal parse, zero header string allocations
// ---------------------------------------------------------------------------

procedure TProtocolDispatcher.StepParseHTTP1Lightweight(
  var ACtx: TDispatchContext);
var
  LConn: TNativeConn;
  LResp: TBytes;
begin
  LConn := TNativeConn(ACtx.Conn);

  ACtx.ReqBad := False;
  if not ParseHTTP1Lightweight(
       LConn.AccumBuf, LConn.AccumLen,
       ACtx.Config^.MaxHeaderSize, ACtx.Config^.MaxRequestSize,
       ACtx.Req.Method, ACtx.Req.Path, ACtx.Req.QueryString,
       ACtx.Req.RawBody, ACtx.Req.KeepAlive,
       ACtx.Consumed, ACtx.ReqBad,
       ACtx.HdrStart, ACtx.HdrEnd) then
  begin
    if ACtx.ReqBad then
    begin
      LResp := BuildHTTPResponse(400, 'text/plain',
        TEncoding.ASCII.GetBytes('Bad Request'), False, [], False, '');
      FCallbacks.SendResponse(ACtx.Conn, LResp, 0);
      // #174: force-close and drop malformed bytes to avoid the keep-alive loop.
      LConn.KeepAlive := False;
      LConn.AccumLen  := 0;
    end
    else
      FCallbacks.PostRecv(ACtx.Conn);
    ACtx.Handled := True;
    Exit;
  end;

  ACtx.Req.RemoteAddr := LConn.RemoteAddr;
  ACtx.Req.Headers := nil;  // lazy — materialized on demand

  if LConn.AccumLen > ACtx.Consumed then
    Move(LConn.AccumBuf[ACtx.Consumed], LConn.AccumBuf[0],
      LConn.AccumLen - ACtx.Consumed);
  LConn.AccumLen := LConn.AccumLen - ACtx.Consumed;
  LConn.KeepAlive := ACtx.Req.KeepAlive;
end;

// ---------------------------------------------------------------------------
// StepUpgradeDetection — check for WebSocket/H2C upgrades (GET only)
// ---------------------------------------------------------------------------

procedure TProtocolDispatcher.StepUpgradeDetection(var ACtx: TDispatchContext);
var
  LConn:       TNativeConn;
  LUpgrade:    string;
  LWsKey:      string;
  LConnection: string;
  LHasUpgrade: Boolean;
  I:           Integer;
begin
  LConn := TNativeConn(ACtx.Conn);

  // HTTP methods are case-sensitive (RFC 7230 §3.1.1); the WebSocket/h2c
  // handshake mandates an uppercase "GET" (issue #166).
  if ACtx.Req.Method <> 'GET' then
    Exit;

  LUpgrade    := '';
  LWsKey      := '';
  LConnection := '';
  for I := 0 to High(ACtx.Req.Headers) do
  begin
    if (Length(ACtx.Req.Headers[I].Key) = 7) and
       SameText(ACtx.Req.Headers[I].Key, 'Upgrade') then
      LUpgrade := ACtx.Req.Headers[I].Value
    else if (Length(ACtx.Req.Headers[I].Key) = 17) and
       SameText(ACtx.Req.Headers[I].Key, 'Sec-WebSocket-Key') then
      LWsKey := ACtx.Req.Headers[I].Value
    else if (Length(ACtx.Req.Headers[I].Key) = 10) and
       SameText(ACtx.Req.Headers[I].Key, 'Connection') then
      LConnection := ACtx.Req.Headers[I].Value;
  end;

  // RFC 6455 §4.2.1 / RFC 7230 §6.7 — the Connection header's token list MUST
  // include "Upgrade"; without it the request is not a valid upgrade.
  LHasUpgrade := Pos('upgrade', LowerCase(LConnection)) > 0;

  if SameText(LUpgrade, 'websocket') and (LWsKey <> '') and LHasUpgrade then
  begin
    FCallbacks.UpgradeToWS(ACtx.Conn, ACtx.Req);
    ACtx.Handled := True;
    Exit;
  end;

  if SameText(LUpgrade, 'h2c') and LHasUpgrade and ACtx.Config^.H2Enabled and
     (LConn.SSLHandle = nil) then
  begin
    FCallbacks.UpgradeToH2C(ACtx.Conn, ACtx.Req);
    ACtx.Handled := True;
  end;
end;

// ---------------------------------------------------------------------------
// StepInvokeAndRespond — full mode: invoke handler, log, send response
// ---------------------------------------------------------------------------

procedure TProtocolDispatcher.StepInvokeAndRespond(var ACtx: TDispatchContext);
var
  LConn:       TNativeConn;
  LDurationMs: Int64;
  LLogEvt:     TPoseidonRequestLogEvent;
  LHdrBuf:     TBytes;
  LHdrLen:     Integer;
  LDeferred:   Boolean;
begin
  LConn := TNativeConn(ACtx.Conn);
  LConn.KeepAlive := ACtx.Req.KeepAlive;

  ACtx.StartTick := Int64(TThread.GetTickCount64);
  FCallbacks.InvokeRequest(ACtx.Conn, ACtx.Req, ACtx.Status, ACtx.ContentType,
    ACtx.Body, ACtx.Extra, LDeferred);

  // Deferred: the handler owns the response (async). Do not send or re-arm —
  // the responder holds the connection alive and completes it later.
  if LDeferred then
  begin
    ACtx.Handled := True;
    Exit;
  end;

  // Vectored send — build headers separately, body sent as-is
  LHdrBuf := BuildHTTPResponseHeaders(ACtx.Status, ACtx.ContentType,
    Length(ACtx.Body), ACtx.Req.KeepAlive, ACtx.Extra,
    ACtx.Config^.SecureHeadersEnabled, ACtx.Config^.ServerBanner,
    LHdrLen);
  LDurationMs := Int64(TThread.GetTickCount64) - ACtx.StartTick;

  LLogEvt.Method     := ACtx.Req.Method;
  LLogEvt.Path       := ACtx.Req.Path;
  LLogEvt.Status     := ACtx.Status;
  LLogEvt.DurationMs := LDurationMs;
  LLogEvt.RemoteAddr := LConn.RemoteAddr;
  LLogEvt.RxBytes    := Length(ACtx.Req.RawBody);
  LLogEvt.TxBytes    := LHdrLen + Length(ACtx.Body);
  FCallbacks.LogRequest(LLogEvt);

  FCallbacks.SendResponseV(ACtx.Conn, LHdrBuf, LHdrLen,
    ACtx.Body, Length(ACtx.Body));
  ACtx.Handled := True;
end;

// ---------------------------------------------------------------------------
// StepInvokeAndRespondLightweight — no logging, no security headers
// ---------------------------------------------------------------------------

procedure TProtocolDispatcher.StepInvokeAndRespondLightweight(
  var ACtx: TDispatchContext);
var
  LHdrBuf: TBytes;
  LHdrLen: Integer;
  LDeferred: Boolean;
begin
  FCallbacks.InvokeRequest(ACtx.Conn, ACtx.Req, ACtx.Status, ACtx.ContentType,
    ACtx.Body, ACtx.Extra, LDeferred);

  if LDeferred then
  begin
    ACtx.Handled := True;
    Exit;
  end;

  // Vectored send — headers + body separately
  LHdrBuf := BuildHTTPResponseHeaders(ACtx.Status, ACtx.ContentType,
    Length(ACtx.Body), ACtx.Req.KeepAlive, ACtx.Extra, False, '',
    LHdrLen);

  FCallbacks.SendResponseV(ACtx.Conn, LHdrBuf, LHdrLen,
    ACtx.Body, Length(ACtx.Body));
  ACtx.Handled := True;
end;

end.

unit Poseidon.Middleware.Tracing;

// W3C Trace Context propagation (#236, item 2 - /metrics itself already
// existed via Poseidon.Middleware.Metrics before this).
//
// Reads an incoming `traceparent` header (https://www.w3.org/TR/trace-context/)
// if present and well-formed, reusing its trace-id and sampled flag; otherwise
// originates a new trace. Either way, issues a NEW parent-id (this hop's own
// span) and writes the resulting `traceparent` as a response header, so it is
// both visible to the caller (correlation) and readable by any later
// middleware in the same chain via ACtx.ExtraHeaders (the same mechanism
// Poseidon.Middleware.RequestID already uses, and Poseidon.Middleware.Logger's
// LoggerMiddlewareJSON already reads FindExtraHeader for X-Request-ID - see
// the small addition there that surfaces trace_id/span_id in the log line
// too).
//
// Scope: propagation and exposure only. Does NOT export spans to
// Tempo/Grafana/any OTLP backend - that is a separate, larger piece of work
// (an actual OTLP client, span timing/start-end, batching/export) that #236
// only asked for "se possivel" (a stretch goal, not the core ask). What this
// gives you is the trace-id/span-id correctly generated and propagated per
// the W3C spec, ready for whoever wires up a real exporter to consume from
// the traceparent response header or the JSON log line.
//
// Usage:
//   App.Use(TracingMiddleware);
//   ... later, in a handler or another middleware ...
//   LTraceParent := ACtx.Header('traceparent'); // still the ORIGINAL request
//                                                // header at that point if
//                                                // read before this ran, or
//                                                // read the response side:
//   LTraceParent := FindExtraHeader(ACtx, 'traceparent'); // this hop's value

interface

uses
  Poseidon.Native.Types;

function TracingMiddleware: TNativeMiddlewareFunc;

// Exposed for Poseidon.Middleware.Logger and any other middleware that wants
// the trace-id/span-id without re-parsing the traceparent header itself.
function ExtractTraceParentIds(const ATraceParent: string;
  out ATraceId, ASpanId: string): Boolean;

implementation

uses
  System.SysUtils,
  System.Generics.Collections;

function IsHex(const S: string): Boolean;
var
  I: Integer;
begin
  Result := S <> '';
  for I := 1 to Length(S) do
    if not CharInSet(S[I], ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
end;

function IsAllZero(const S: string): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to Length(S) do
    if S[I] <> '0' then
      Exit(False);
end;

// Per https://www.w3.org/TR/trace-context/#traceparent-header-field-values:
// version(2)-trace-id(32)-parent-id(16)-trace-flags(2), all lowercase hex.
// Only version "00" (the only one defined as of this writing) is accepted -
// a future version may append fields after trace-flags per the spec's own
// forward-compatibility rule, which this does not attempt to parse; an
// unrecognised version falls through to "invalid" below, and the caller
// originates a fresh trace instead of guessing at a wider format.
function TryParseTraceParent(const AHeader: string; out ATraceId, AParentId: string;
  out ASampled: Boolean): Boolean;
var
  LParts: TArray<string>;
  LFlagsByte: Integer;
begin
  Result := False;
  ATraceId := '';
  AParentId := '';
  ASampled := False;
  if AHeader = '' then Exit;

  LParts := AHeader.Split(['-']);
  if Length(LParts) <> 4 then Exit;
  if (Length(LParts[0]) <> 2) or (Length(LParts[1]) <> 32) or
     (Length(LParts[2]) <> 16) or (Length(LParts[3]) <> 2) then Exit;
  if not (IsHex(LParts[0]) and IsHex(LParts[1]) and IsHex(LParts[2]) and
    IsHex(LParts[3])) then Exit;
  if SameText(LParts[0], 'ff') then Exit;          // reserved, invalid
  if not SameText(LParts[0], '00') then Exit;      // only version 00 defined
  if IsAllZero(LParts[1]) or IsAllZero(LParts[2]) then Exit;

  ATraceId := LowerCase(LParts[1]);
  AParentId := LowerCase(LParts[2]);
  LFlagsByte := StrToIntDef('$' + LParts[3], 0);
  ASampled := (LFlagsByte and 1) <> 0;
  Result := True;
end;

function BytesToHexLower(const ABytes: array of Byte): string;
const
  CHexDigits: array[0..15] of Char = '0123456789abcdef';
var
  I: Integer;
begin
  SetLength(Result, Length(ABytes) * 2);
  for I := 0 to High(ABytes) do
  begin
    Result[2 * I + 1] := CHexDigits[ABytes[I] shr 4];
    Result[2 * I + 2] := CHexDigits[ABytes[I] and $0F];
  end;
end;

// 128-bit trace-id: one GUID's worth of OS-RNG-sourced bytes (the same
// source Poseidon.Diagnostics._EnsureInstanceId already uses for InstanceId,
// portable across Windows/Linux in this RTL).
function NewTraceId: string;
var
  LGuid: TGUID;
begin
  LGuid := TGUID.NewGuid;
  Result := BytesToHexLower([
    Byte(LGuid.D1 shr 24), Byte(LGuid.D1 shr 16), Byte(LGuid.D1 shr 8), Byte(LGuid.D1),
    Byte(LGuid.D2 shr 8), Byte(LGuid.D2),
    Byte(LGuid.D3 shr 8), Byte(LGuid.D3),
    LGuid.D4[0], LGuid.D4[1], LGuid.D4[2], LGuid.D4[3],
    LGuid.D4[4], LGuid.D4[5], LGuid.D4[6], LGuid.D4[7]]);
end;

// 64-bit span/parent-id: half a GUID's worth of bytes is still OS-RNG, no
// need for a second full GUID just to discard half of it.
function NewSpanId: string;
var
  LGuid: TGUID;
begin
  LGuid := TGUID.NewGuid;
  Result := BytesToHexLower([
    Byte(LGuid.D1 shr 24), Byte(LGuid.D1 shr 16), Byte(LGuid.D1 shr 8), Byte(LGuid.D1),
    Byte(LGuid.D2 shr 8), Byte(LGuid.D2),
    Byte(LGuid.D3 shr 8), Byte(LGuid.D3)]);
end;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string);
var
  LLen: Integer;
begin
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(AName, AValue);
end;

function ExtractTraceParentIds(const ATraceParent: string;
  out ATraceId, ASpanId: string): Boolean;
var
  LSampled: Boolean;
begin
  Result := TryParseTraceParent(ATraceParent, ATraceId, ASpanId, LSampled);
end;

function TracingMiddleware: TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LIncomingTraceId, LIncomingParentId: string;
      LSampled: Boolean;
      LTraceId, LSpanId, LFlags: string;
    begin
      // The incoming parent-id is deliberately discarded once validated - it
      // identified the CALLER's span, not ours. We mint our own span-id
      // (LSpanId) for this hop and keep only the trace-id, per the spec: a
      // traceparent identifies "the incoming request in a tracing system",
      // and each hop is a new span within the same trace.
      if TryParseTraceParent(ACtx.Header('traceparent'), LIncomingTraceId,
        LIncomingParentId, LSampled) then
        LTraceId := LIncomingTraceId
      else
      begin
        // No valid upstream trace-context: this hop originates the trace.
        // Sampled by default (flags "01") - there is no sampler/exporter
        // wired up yet to make that decision meaningfully (see unit header),
        // so defaulting to "would be sampled if something were listening"
        // is more useful than defaulting to "never sampled".
        LTraceId := NewTraceId;
        LSampled := True;
      end;

      LSpanId := NewSpanId;
      if LSampled then LFlags := '01' else LFlags := '00';

      AddHeader(ACtx, 'traceparent', '00-' + LTraceId + '-' + LSpanId + '-' + LFlags);
      ANext();
    end;
end;

end.

unit Poseidon.Tests.Fuzz;

// In-process fuzzing of the pure parsing surfaces (no network, no server).
//
// Invariant under test: ParseHTTP1Request and TH2HpackCodec.DecodeHeaders must
// NEVER crash (AV / range error / OOB read), NEVER hang (infinite loop = DoS),
// and NEVER leak an exception, for ANY input — regardless of how malformed.
// They must always terminate returning True / False / a *BadRequest flag.
//
// Determinism: a seeded xorshift64 PRNG drives every input, so a failure is
// reproducible from the reported seed. The current seed is published to a
// class var before each call; a watchdog thread reports it if the loop hangs.
//
// This covers issues #200 (HTTP/1 parser fuzzing) and #201 (HPACK fuzzing) at
// the in-process level (the corpus that a libFuzzer/AFL harness would explore),
// which is what CAN be validated without a live-socket environment.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TFuzzHTTP1ParserTests = class
  public
    [Test] procedure Fuzz_RandomBytes_NeverCrashesNeverHangs;
    [Test] procedure Fuzz_MutatedValidRequests_NeverCrashesNeverHangs;
    [Test] procedure Fuzz_ChunkedDecoder_NeverCrashesNeverHangs;
  end;

  [TestFixture]
  TFuzzHPACKTests = class
  public
    [Test] procedure Fuzz_RandomBytes_NeverCrashesNeverHangs;
    [Test] procedure Fuzz_StructuredAdversarial_NeverCrashesNeverHangs;
  end;

implementation

uses
  System.Generics.Defaults,
  Poseidon.Net.HTTP1.Parser,
  Poseidon.Net.HTTP2.HPACK;

const
  CHTTP1Iterations = 60000;
  CHPACKIterations = 60000;
  // Generous ceiling: 60k pure-parse iterations complete in well under this on
  // any dev box. Overrun ⇒ an input drove an infinite loop (a real DoS bug).
  CWatchdogTimeoutMs = 25000;

// ---------------------------------------------------------------------------
// Deterministic PRNG — xorshift64. Seeded per run; reproducible.
// ---------------------------------------------------------------------------

type
  TRng = record
    State: UInt64;
    procedure Seed(AValue: UInt64);
    function NextU64: UInt64;
    function NextByte: Byte;
    function InRange(ALo, AHi: Integer): Integer;  // inclusive
  end;

procedure TRng.Seed(AValue: UInt64);
begin
  if AValue = 0 then AValue := $9E3779B97F4A7C15;
  State := AValue;
end;

function TRng.NextU64: UInt64;
begin
  State := State xor (State shr 12);
  State := State xor (State shl 25);
  State := State xor (State shr 27);
  Result := State * UInt64($2545F4914F6CDD1D);
end;

function TRng.NextByte: Byte;
begin
  Result := Byte(NextU64 and $FF);
end;

function TRng.InRange(ALo, AHi: Integer): Integer;
begin
  if AHi <= ALo then Exit(ALo);
  Result := ALo + Integer(NextU64 mod UInt64(AHi - ALo + 1));
end;

// ---------------------------------------------------------------------------
// Watchdog — publishes progress; a background thread detects a stalled loop.
// ---------------------------------------------------------------------------

type
  TFuzzProgress = class
  strict private
    FIter:     Integer;
    FSeed:     UInt64;
    FDone:     Boolean;
    FLock:     TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Mark(AIter: Integer; ASeed: UInt64);
    procedure SetDone;
    procedure Snapshot(out AIter: Integer; out ASeed: UInt64; out ADone: Boolean);
  end;

constructor TFuzzProgress.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TFuzzProgress.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TFuzzProgress.Mark(AIter: Integer; ASeed: UInt64);
begin
  FLock.Enter;
  try
    FIter := AIter;
    FSeed := ASeed;
  finally
    FLock.Leave;
  end;
end;

procedure TFuzzProgress.SetDone;
begin
  FLock.Enter;
  try
    FDone := True;
  finally
    FLock.Leave;
  end;
end;

procedure TFuzzProgress.Snapshot(out AIter: Integer; out ASeed: UInt64;
  out ADone: Boolean);
begin
  FLock.Enter;
  try
    AIter := FIter;
    ASeed := FSeed;
    ADone := FDone;
  finally
    FLock.Leave;
  end;
end;

// Runs AProc (the fuzz loop) on a worker thread; the calling test thread waits
// up to CWatchdogTimeoutMs. If the worker does not finish, the loop hung on
// some input — we report the last published seed. The worker is left detached
// (a hung pure function cannot be safely killed) so the suite keeps running.
procedure RunWithWatchdog(AProgress: TFuzzProgress; AProc: TProc);
var
  LThread: TThread;
  LDeadline: UInt64;
  LIter: Integer;
  LSeed: UInt64;
  LDone: Boolean;
  LErr: string;
begin
  LErr := '';
  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      try
        AProc();
      except
        on E: Exception do
          LErr := E.ClassName + ': ' + E.Message;
      end;
      AProgress.SetDone;
    end);
  LThread.FreeOnTerminate := True;
  LThread.Start;

  LDeadline := TThread.GetTickCount64 + UInt64(CWatchdogTimeoutMs);
  repeat
    TThread.Sleep(20);
    AProgress.Snapshot(LIter, LSeed, LDone);
  until LDone or (TThread.GetTickCount64 >= LDeadline);

  if not LDone then
    Assert.Fail(Format('HANG detected — loop stalled at iteration %d, ' +
      'seed=0x%.16x (infinite loop / DoS on that input)', [LIter, LSeed]));
  if LErr <> '' then
    Assert.Fail('Parser raised on a fuzz input: ' + LErr +
      Format(' (last iteration %d, seed=0x%.16x)', [LIter, LSeed]));
end;

// ---------------------------------------------------------------------------
// Corpus builders
// ---------------------------------------------------------------------------

function RandomBuf(var ARng: TRng; AMaxLen: Integer): TBytes;
var
  LLen, I: Integer;
begin
  LLen := ARng.InRange(0, AMaxLen);
  SetLength(Result, LLen);
  for I := 0 to LLen - 1 do
    Result[I] := ARng.NextByte;
end;

function MutateTemplate(var ARng: TRng): TBytes;
const
  CTemplate: AnsiString =
    'POST /api/items?x=1 HTTP/1.1'#13#10 +
    'Host: example.com'#13#10 +
    'Content-Length: 5'#13#10 +
    'Transfer-Encoding: chunked'#13#10 +
    'Connection: keep-alive'#13#10 +
    'X-Custom: value'#13#10#13#10 +
    'hello';
var
  LMutations, M, LPos, LLen: Integer;
begin
  LLen := Length(CTemplate);
  SetLength(Result, LLen);
  if LLen > 0 then
    Move(CTemplate[1], Result[0], LLen);

  LMutations := ARng.InRange(1, 12);
  for M := 0 to LMutations - 1 do
  begin
    if Length(Result) = 0 then Break;
    case ARng.InRange(0, 4) of
      0: // flip a byte
        begin
          LPos := ARng.InRange(0, Length(Result) - 1);
          Result[LPos] := ARng.NextByte;
        end;
      1: // truncate
        SetLength(Result, ARng.InRange(0, Length(Result)));
      2: // insert a byte
        begin
          LPos := ARng.InRange(0, Length(Result));
          Insert([ARng.NextByte], Result, LPos);
        end;
      3: // delete a byte
        begin
          LPos := ARng.InRange(0, Length(Result) - 1);
          Delete(Result, LPos, 1);
        end;
      4: // inject CRLF (smuggling shapes)
        begin
          LPos := ARng.InRange(0, Length(Result));
          Insert([13, 10], Result, LPos);
        end;
    end;
  end;
end;

// Structured HPACK inputs targeting the known danger zones: oversized varints
// (≥2^31 length — issue this session flagged), out-of-range table indices,
// truncated Huffman, dynamic-table-size updates.
function StructuredHPACK(var ARng: TRng): TBytes;
var
  LKind: Integer;
begin
  LKind := ARng.InRange(0, 6);
  case LKind of
    0: // indexed header field, huge index (varint continuation bytes)
      Result := TBytes.Create($FF, $FF, $FF, $FF, $FF, $0F);
    1: // literal w/ incremental indexing, name len = huge varint
      Result := TBytes.Create($40, $7F, $FF, $FF, $FF, $FF, $0F, $61, $62);
    2: // literal, Huffman-coded name, length longer than buffer
      Result := TBytes.Create($40, $FF, $7F, $41, $42);
    3: // dynamic table size update beyond any limit
      Result := TBytes.Create($3F, $FF, $FF, $FF, $FF, $0F);
    4: // never-indexed literal, value len overflow
      Result := TBytes.Create($10, $00, $FF, $FF, $FF, $FF, $0F);
    5: // truncated Huffman string (high bit set, cut short)
      Result := TBytes.Create($82, $FF);
  else
    Result := RandomBuf(ARng, 32);
  end;
  // Append random trailing noise to keep the decoder honest.
  Result := Result + RandomBuf(ARng, ARng.InRange(0, 24));
end;

// ---------------------------------------------------------------------------
// HTTP/1 parser fuzz
// ---------------------------------------------------------------------------

procedure FuzzHTTP1(AProgress: TFuzzProgress; ARandom: Boolean);
var
  LRng: TRng;
  LSeed: UInt64;
  I: Integer;
  LBuf: TBytes;
  LMethod, LPath, LQuery: string;
  LHeaders: TArray<TPair<string, string>>;
  LBody: TBytes;
  LKeepAlive, LBad: Boolean;
  LConsumed: Integer;
begin
  LSeed := $DEADBEEF01234567;
  if not ARandom then LSeed := $0BADF00DCAFEBABE;
  LRng.Seed(LSeed);

  for I := 0 to CHTTP1Iterations - 1 do
  begin
    LSeed := LRng.NextU64;
    AProgress.Mark(I, LSeed);
    if ARandom then
      LBuf := RandomBuf(LRng, 4096)
    else
      LBuf := MutateTemplate(LRng);

    // Must return without raising; result value is irrelevant — only the
    // no-crash / no-hang invariant matters.
    ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
      LMethod, LPath, LQuery, LHeaders, LBody, LKeepAlive, LConsumed, LBad);
  end;
end;

procedure FuzzChunked(AProgress: TFuzzProgress);
var
  LRng: TRng;
  I, LConsumed: Integer;
  LBuf: TBytes;
  LBody: TBytes;
  LMalformed: Boolean;
begin
  LRng.Seed($C0FFEE0011223344);
  for I := 0 to CHTTP1Iterations - 1 do
  begin
    AProgress.Mark(I, LRng.State);
    LBuf := RandomBuf(LRng, 2048);
    if Length(LBuf) = 0 then Continue;
    DecodeHTTP1Chunked(@LBuf[0], Length(LBuf), 8388608,
      LBody, LConsumed, LMalformed);
  end;
end;

procedure TFuzzHTTP1ParserTests.Fuzz_RandomBytes_NeverCrashesNeverHangs;
var
  LProg: TFuzzProgress;
begin
  LProg := TFuzzProgress.Create;
  try
    RunWithWatchdog(LProg, procedure begin FuzzHTTP1(LProg, True); end);
  finally
    LProg.Free;
  end;
end;

procedure TFuzzHTTP1ParserTests.Fuzz_MutatedValidRequests_NeverCrashesNeverHangs;
var
  LProg: TFuzzProgress;
begin
  LProg := TFuzzProgress.Create;
  try
    RunWithWatchdog(LProg, procedure begin FuzzHTTP1(LProg, False); end);
  finally
    LProg.Free;
  end;
end;

procedure TFuzzHTTP1ParserTests.Fuzz_ChunkedDecoder_NeverCrashesNeverHangs;
var
  LProg: TFuzzProgress;
begin
  LProg := TFuzzProgress.Create;
  try
    RunWithWatchdog(LProg, procedure begin FuzzChunked(LProg); end);
  finally
    LProg.Free;
  end;
end;

// ---------------------------------------------------------------------------
// HPACK fuzz
// ---------------------------------------------------------------------------

procedure FuzzHPACK(AProgress: TFuzzProgress; AStructured: Boolean);
var
  LRng: TRng;
  I: Integer;
  LBuf: TBytes;
  LCodec: TH2HpackCodec;
  LMethod, LPath, LScheme, LAuthority: string;
  LHeaders: TArray<TPair<string, string>>;
  LTooBig, LProtoErr: Boolean;
begin
  if AStructured then LRng.Seed($1234ABCD5678EF01)
  else LRng.Seed($FEDCBA9876543210);

  LCodec := TH2HpackCodec.Create;
  try
    for I := 0 to CHPACKIterations - 1 do
    begin
      AProgress.Mark(I, LRng.State);
      if AStructured then
        LBuf := StructuredHPACK(LRng)
      else
        LBuf := RandomBuf(LRng, 1024);

      // Reuse the codec across iterations to exercise dynamic-table state
      // transitions; recreate periodically to also cover the fresh-table path.
      if (I mod 512) = 511 then
      begin
        LCodec.Free;
        LCodec := TH2HpackCodec.Create;
      end;

      if Length(LBuf) = 0 then Continue;
      LCodec.DecodeHeaders(@LBuf[0], Length(LBuf),
        LMethod, LPath, LScheme, LAuthority, LHeaders, LTooBig, LProtoErr,
        procedure begin end);
    end;
  finally
    LCodec.Free;
  end;
end;

procedure TFuzzHPACKTests.Fuzz_RandomBytes_NeverCrashesNeverHangs;
var
  LProg: TFuzzProgress;
begin
  LProg := TFuzzProgress.Create;
  try
    RunWithWatchdog(LProg, procedure begin FuzzHPACK(LProg, False); end);
  finally
    LProg.Free;
  end;
end;

procedure TFuzzHPACKTests.Fuzz_StructuredAdversarial_NeverCrashesNeverHangs;
var
  LProg: TFuzzProgress;
begin
  LProg := TFuzzProgress.Create;
  try
    RunWithWatchdog(LProg, procedure begin FuzzHPACK(LProg, True); end);
  finally
    LProg.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TFuzzHTTP1ParserTests);
  TDUnitX.RegisterTestFixture(TFuzzHPACKTests);

end.

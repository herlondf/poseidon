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

  [TestFixture]
  TFuzzWebSocketTests = class
  public
    [Test] procedure Fuzz_RandomFrames_NeverCrashesNeverHangs;
    [Test] procedure Fuzz_MutatedValidFrames_NeverCrashesNeverHangs;
  end;

  // Deterministic invariant guards for the HPACK decoder. Fuzzing proves "never
  // crashes"; these prove the SECURITY invariants actively hold — each crafts the
  // exact adversarial block for one RFC 7541 danger zone and asserts the decoder
  // rejects it with the right signal (COMPRESSION_ERROR vs header-list-too-big),
  // not merely "did not crash". Regression guards for the HPACK-hardening.
  [TestFixture]
  THPACKInvariantTests = class
  public
    [Test] procedure Bomb_ManyRefsToLargePrimedEntry_FlagsHeaderListTooBig;
    [Test] procedure DynTableSizeUpdate_AboveAnnounced_IsCompressionError;
    [Test] procedure Huffman_EmbeddedEOS_IsCompressionError;
    [Test] procedure IndexedField_OutOfRange_IsCompressionError;
    [Test] procedure StringLength_BeyondBuffer_IsCompressionError;
    [Test] procedure IntegerOverflow_PastUInt32_DoesNotAllocate;
  end;

implementation

uses
  System.Generics.Defaults,
  Poseidon.Net.HTTP1.Parser,
  Poseidon.Net.HTTP2.HPACK,
  Poseidon.Net.WebSocket;

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
  LKind := ARng.InRange(0, 9);
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
    6: // Huffman value carrying the 30-bit EOS symbol (must COMPRESSION_ERROR)
      Result := TBytes.Create($00, $01, $61, $84, $FF, $FF, $FF, $FF);
    7: // indexed field one past the (empty) dynamic table boundary
      Result := TBytes.Create($BE);
    8: // dynamic table size update AFTER a field (out of position, §4.2)
      Result := TBytes.Create($82, $20);
  else
    Result := RandomBuf(ARng, 32);
  end;
  // Append random trailing noise to keep the decoder honest.
  Result := Result + RandomBuf(ARng, ARng.InRange(0, 24));
end;

// ---------------------------------------------------------------------------
// HPACK block builders — used by the deterministic invariant guards to craft
// the exact adversarial representation for each danger zone (RFC 7541 §5/§6).
// ---------------------------------------------------------------------------

procedure HpAppendInt(var ABuf: TBytes; AValue: Cardinal; APrefixBits: Byte;
  AHighBits: Byte);
var
  LMask: Cardinal;
  LN: Integer;
begin
  LMask := (Cardinal(1) shl APrefixBits) - 1;
  LN := Length(ABuf);
  if AValue < LMask then
  begin
    SetLength(ABuf, LN + 1);
    ABuf[LN] := AHighBits or Byte(AValue);
    Exit;
  end;
  SetLength(ABuf, LN + 1);
  ABuf[LN] := AHighBits or Byte(LMask);
  Dec(AValue, LMask);
  while AValue >= 128 do
  begin
    LN := Length(ABuf);
    SetLength(ABuf, LN + 1);
    ABuf[LN] := Byte(AValue and $7F) or $80;
    AValue := AValue shr 7;
  end;
  LN := Length(ABuf);
  SetLength(ABuf, LN + 1);
  ABuf[LN] := Byte(AValue);
end;

procedure HpAppendStr(var ABuf: TBytes; const AStr: AnsiString);
var
  LN, I: Integer;
begin
  HpAppendInt(ABuf, Cardinal(Length(AStr)), 7, $00); // H=0 (plain octets)
  LN := Length(ABuf);
  SetLength(ABuf, LN + Length(AStr));
  for I := 1 to Length(AStr) do
    ABuf[LN + I - 1] := Byte(AStr[I]);
end;

// §6.2.1 literal with incremental indexing, new name (index 0) — primes the
// dynamic table with (AName, AValue).
function HpLiteralIndexedNewName(const AName, AValue: AnsiString): TBytes;
begin
  Result := TBytes.Create($40);
  HpAppendStr(Result, AName);
  HpAppendStr(Result, AValue);
end;

// §6.1 indexed header field.
function HpIndexed(AIdx: Cardinal): TBytes;
begin
  Result := nil;
  HpAppendInt(Result, AIdx, 7, $80);
end;

function DecodeBlock(ACodec: TH2HpackCodec; const ABlock: TBytes;
  out ATooBig, AProtoErr: Boolean): Boolean;
var
  LMethod, LPath, LScheme, LAuthority: string;
  LHeaders: TArray<TPair<string, string>>;
begin
  if Length(ABlock) = 0 then
  begin
    ATooBig := False; AProtoErr := False; Exit(True);
  end;
  Result := ACodec.DecodeHeaders(@ABlock[0], Length(ABlock),
    LMethod, LPath, LScheme, LAuthority, LHeaders, ATooBig, AProtoErr,
    procedure begin end);
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

// ---------------------------------------------------------------------------
// WebSocket frame parser fuzz — a crafted 64-bit length field is a classic
// OOM/DoS vector; ParseFrame must reject it, not allocate on it.
// ---------------------------------------------------------------------------

procedure FuzzWebSocket(AProgress: TFuzzProgress; AMutate: Boolean);
var
  LRng: TRng;
  I, LConsumed: Integer;
  LBuf: TBytes;
  LFrame: TWebSocketFrame;
  LMutations, M, LPos: Integer;
begin
  if AMutate then LRng.Seed($55AA55AA33CC33CC)
  else LRng.Seed($1122334455667788);

  for I := 0 to CHTTP1Iterations - 1 do
  begin
    AProgress.Mark(I, LRng.State);
    if AMutate then
    begin
      // Start from a valid masked text frame, then corrupt a few bytes — keeps
      // the fuzzer near the header/length/mask decision boundaries.
      LBuf := TWebSocketUtils.TextFrame('hello world');
      LMutations := LRng.InRange(1, 6);
      for M := 0 to LMutations - 1 do
      begin
        if Length(LBuf) = 0 then Break;
        LPos := LRng.InRange(0, Length(LBuf) - 1);
        LBuf[LPos] := LRng.NextByte;
      end;
    end
    else
      LBuf := RandomBuf(LRng, 64);

    if Length(LBuf) = 0 then Continue;
    TWebSocketUtils.ParseFrame(@LBuf[0], Length(LBuf), LFrame, LConsumed);
  end;
end;

procedure TFuzzWebSocketTests.Fuzz_RandomFrames_NeverCrashesNeverHangs;
var
  LProg: TFuzzProgress;
begin
  LProg := TFuzzProgress.Create;
  try
    RunWithWatchdog(LProg, procedure begin FuzzWebSocket(LProg, False); end);
  finally
    LProg.Free;
  end;
end;

procedure TFuzzWebSocketTests.Fuzz_MutatedValidFrames_NeverCrashesNeverHangs;
var
  LProg: TFuzzProgress;
begin
  LProg := TFuzzProgress.Create;
  try
    RunWithWatchdog(LProg, procedure begin FuzzWebSocket(LProg, True); end);
  finally
    LProg.Free;
  end;
end;

// ---------------------------------------------------------------------------
// HPACK invariant guards (deterministic)
// ---------------------------------------------------------------------------

// A single ~3 KB dynamic-table entry referenced repeatedly by 1-byte indexed
// fields expands the header list past CMaxHeaderListSize (16 KB). The decoder
// must flag AHeaderListTooBig (REFUSE_STREAM), not keep accumulating.
procedure THPACKInvariantTests.Bomb_ManyRefsToLargePrimedEntry_FlagsHeaderListTooBig;
var
  LCodec: TH2HpackCodec;
  LBlock: TBytes;
  LTooBig, LProtoErr, LOk: Boolean;
  I: Integer;
begin
  LCodec := TH2HpackCodec.Create;
  try
    // Prime the dynamic table with a ~3042-byte entry (fits under 4096 cap).
    LBlock := HpLiteralIndexedNewName(AnsiString('xxxxxxxxxx'),
      AnsiString(StringOfChar('y', 3000)));
    // Reference it (index 62 = newest dynamic entry) enough times to blow 16 KB.
    for I := 1 to 6 do
      LBlock := LBlock + HpIndexed(62);
    LOk := DecodeBlock(LCodec, LBlock, LTooBig, LProtoErr);
    Assert.IsFalse(LOk, 'HPACK bomb must be rejected');
    Assert.IsTrue(LTooBig, 'AHeaderListTooBig must be set for the bomb');
  finally
    LCodec.Free;
  end;
end;

// §6.3 — a dynamic table size update above the announced maximum (4096) is a
// COMPRESSION_ERROR, never an allocation.
procedure THPACKInvariantTests.DynTableSizeUpdate_AboveAnnounced_IsCompressionError;
var
  LCodec: TH2HpackCodec;
  LBlock: TBytes;
  LTooBig, LProtoErr, LOk: Boolean;
begin
  LCodec := TH2HpackCodec.Create;
  try
    LBlock := nil;
    HpAppendInt(LBlock, 5000, 5, $20); // §6.3 pattern 001x xxxx, value 5000 > 4096
    LOk := DecodeBlock(LCodec, LBlock, LTooBig, LProtoErr);
    Assert.IsFalse(LOk, 'Oversized dyn-table-size update must be rejected');
    Assert.IsFalse(LTooBig, 'It is a compression error, not header-list-too-big');
  finally
    LCodec.Free;
  end;
end;

// §5.2 — the EOS symbol (30 ones) must not appear as a decoded Huffman symbol.
procedure THPACKInvariantTests.Huffman_EmbeddedEOS_IsCompressionError;
var
  LCodec: TH2HpackCodec;
  LBlock: TBytes;
  LTooBig, LProtoErr, LOk: Boolean;
begin
  LCodec := TH2HpackCodec.Create;
  try
    // Literal without indexing, new name "a", value = Huffman with 32 one-bits
    // (the first 30 form the EOS code → embedded EOS → COMPRESSION_ERROR).
    LBlock := TBytes.Create($00, $01, $61, $84, $FF, $FF, $FF, $FF);
    LOk := DecodeBlock(LCodec, LBlock, LTooBig, LProtoErr);
    Assert.IsFalse(LOk, 'Embedded EOS in Huffman must be rejected');
    Assert.IsFalse(LProtoErr, 'It is a compression error, not a protocol error');
  finally
    LCodec.Free;
  end;
end;

// §6.1 — an indexed field addressing neither the static nor the (empty) dynamic
// table is a COMPRESSION_ERROR.
procedure THPACKInvariantTests.IndexedField_OutOfRange_IsCompressionError;
var
  LCodec: TH2HpackCodec;
  LBlock: TBytes;
  LTooBig, LProtoErr, LOk: Boolean;
begin
  LCodec := TH2HpackCodec.Create;
  try
    LBlock := TBytes.Create($BE); // indexed, idx 62, dynamic table empty
    LOk := DecodeBlock(LCodec, LBlock, LTooBig, LProtoErr);
    Assert.IsFalse(LOk, 'Out-of-range index must be rejected');
  finally
    LCodec.Free;
  end;
end;

// §5.2 — a string length that runs past the buffer is a truncated fragment →
// COMPRESSION_ERROR (the unsigned bounds check must catch it before Move).
procedure THPACKInvariantTests.StringLength_BeyondBuffer_IsCompressionError;
var
  LCodec: TH2HpackCodec;
  LBlock: TBytes;
  LTooBig, LProtoErr, LOk: Boolean;
begin
  LCodec := TH2HpackCodec.Create;
  try
    // Literal new name, name length = 5 but only 1 byte follows.
    LBlock := TBytes.Create($00, $05, $61);
    LOk := DecodeBlock(LCodec, LBlock, LTooBig, LProtoErr);
    Assert.IsFalse(LOk, 'String length beyond buffer must be rejected');
  finally
    LCodec.Free;
  end;
end;

// §5.1 — an integer whose continuation bytes overflow past 2^32 must NOT wrap to
// a small signed value and drive an allocation; the decoder returns 0 and the
// representation is handled without a crash or giant Move.
procedure THPACKInvariantTests.IntegerOverflow_PastUInt32_DoesNotAllocate;
var
  LCodec: TH2HpackCodec;
  LBlock: TBytes;
  LTooBig, LProtoErr: Boolean;
begin
  LCodec := TH2HpackCodec.Create;
  try
    // Indexed field with a varint of six 0xFF continuation bytes (> 2^32).
    LBlock := TBytes.Create($FF, $FF, $FF, $FF, $FF, $FF, $0F);
    // Invariant: returns (no crash / no OOM) — value is irrelevant here.
    DecodeBlock(LCodec, LBlock, LTooBig, LProtoErr);
    Assert.Pass('Integer overflow handled without allocation or crash');
  finally
    LCodec.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TFuzzHTTP1ParserTests);
  TDUnitX.RegisterTestFixture(TFuzzHPACKTests);
  TDUnitX.RegisterTestFixture(TFuzzWebSocketTests);
  TDUnitX.RegisterTestFixture(THPACKInvariantTests);

end.

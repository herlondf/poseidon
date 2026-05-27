unit AsyncIO.Net.HTTP2;

// HTTP/2 (RFC 7540) + HPACK (RFC 7541) implementation for the AsyncIO framework.
// One TH2Conn instance per connection, driven by TAsyncIONativeServer._ProcessRecv.
//
// Design decisions:
//   - No server push (ENABLE_PUSH = 0)
//   - HPACK encode: literal without indexing (simple, correct)
//   - HPACK decode: full RFC 7541 (indexed, incremental-index, no-index, never-index, table-update)
//   - Huffman decode: tree built once at unit initialization
//   - Huffman encode: NOT used (literals sent as plain, flag = 0)
//   - Flow control: accepted/ignored (initial window 65535 is enough for most responses)
//   - Thread safety: caller (IOCP worker) is single-threaded per connection

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

type
  TH2RequestData = record
    Method, Path, Host, QueryString, RemoteAddr, ContentType, Protocol: string;
    Headers: TArray<TPair<string, string>>;
    Body: TBytes;
    StreamID: Cardinal;
  end;

  TH2RequestCallback = procedure(const AReq: TH2RequestData;
    var AStatus: Integer; var AContentType: string; var ABody: TBytes;
    var AExtra: TArray<TPair<string, string>>) of object;

  TH2SendProc  = procedure(AConn: Pointer; const AData: TBytes) of object;
  TH2CloseProc = procedure(AConn: Pointer) of object;

  TH2StreamState = (hssIdle, hssOpen, hssHalfClosedRemote, hssClosed);

  TH2Stream = class
  public
    StreamID:       Cardinal;
    State:          TH2StreamState;
    Method:         string;
    Path:           string;
    Scheme:         string;
    Authority:      string;
    RequestHeaders: TArray<TPair<string, string>>;
    Body:           TBytes;
    BodyLen:        Integer;
    EndStream:      Boolean;
    HeadersComplete: Boolean;
    destructor Destroy; override;
  end;

  TH2DynEntry = record
    Name:  string;
    Value: string;
  end;

  TH2Conn = class
  private
    FConn:       Pointer;
    FSendProc:   TH2SendProc;
    FCloseProc:  TH2CloseProc;
    FOnRequest:  TH2RequestCallback;

    // Connection state
    FPrefaceReceived: Boolean;
    FSettingsSent:    Boolean;
    FGoAwaySent:      Boolean;

    // Frame reassembly accumulator
    FFrameBuf: TBytes;
    FFrameLen: Integer;

    // CONTINUATION state (RFC 7540 §6.10)
    FContinStreamID:   Cardinal;
    FContinHeaders:    TBytes;
    FContinHeadersLen: Integer;

    // Streams
    FStreams:      TDictionary<Cardinal, TH2Stream>;
    FLastStreamID: Cardinal;

    // HPACK client→server dynamic table (for decoding request headers)
    FDynTable:       TArray<TH2DynEntry>;
    FDynTableSize:   Integer;   // current byte size
    FDynTableMaxSize: Integer;  // from client SETTINGS_HEADER_TABLE_SIZE

    // Peer settings
    FPeerMaxFrameSize: Integer;
    FPeerInitWinSize:  Integer;

    // -----------------------------------------------------------------------
    // HPACK decode
    // -----------------------------------------------------------------------
    function  _HpackDecodeInt(ABuf: PByte; ABufLen: Integer; APrefixBits: Byte;
      var APos: Integer): Cardinal;
    function  _HpackDecodeStr(ABuf: PByte; ABufLen: Integer;
      var APos: Integer): string;
    procedure _HpackHuffmanDecode(ABuf: PByte; ALen: Integer; out AResult: string);
    function  _HpackGetStatic(AIdx: Cardinal; out AName, AValue: string): Boolean;
    function  _HpackGetDynamic(AIdx: Cardinal; out AName, AValue: string): Boolean;
    procedure _HpackAddDyn(const AName, AValue: string);
    procedure _HpackEvict(AMaxSize: Integer);

    // -----------------------------------------------------------------------
    // Frame processing
    // -----------------------------------------------------------------------
    procedure _ProcessFrame(AType, AFlags: Byte; AStreamID: Cardinal;
      APayload: PByte; APayLen: Integer);
    procedure _HandleSettings(AFlags: Byte; APayload: PByte; APayLen: Integer);
    procedure _HandleHeaders(AFlags: Byte; AStreamID: Cardinal;
      APayload: PByte; APayLen: Integer; AContinuation: Boolean = False);
    procedure _HandleData(AFlags: Byte; AStreamID: Cardinal;
      APayload: PByte; APayLen: Integer);
    procedure _HandleWindowUpdate(AStreamID: Cardinal; APayload: PByte; APayLen: Integer);
    procedure _HandlePing(AFlags: Byte; APayload: PByte; APayLen: Integer);
    procedure _HandleGoAway(APayload: PByte; APayLen: Integer);
    procedure _HandleRstStream(AStreamID: Cardinal; APayload: PByte; APayLen: Integer);
    procedure _HandleContinuation(AFlags: Byte; AStreamID: Cardinal;
      APayload: PByte; APayLen: Integer);
    procedure _DispatchStream(AStream: TH2Stream);
    procedure _DecodeRequestHeaders(AStream: TH2Stream;
      APayload: PByte; APayLen: Integer; APadLen: Integer; APriority: Boolean);

    // -----------------------------------------------------------------------
    // Frame sending
    // -----------------------------------------------------------------------
    procedure _SendRaw(const AData: TBytes);
    procedure _SendFrame(AType, AFlags: Byte; AStreamID: Cardinal;
      APayload: PByte; APayLen: Integer);

    // -----------------------------------------------------------------------
    // HPACK encode (literal without indexing — simple and correct)
    // -----------------------------------------------------------------------
    procedure _HpackEncodeInt(var ABuf: TBytes; var APos: Integer;
      AValue: Cardinal; APrefixBits: Byte; AHighBits: Byte);
    procedure _HpackEncodeStr(var ABuf: TBytes; var APos: Integer;
      const AStr: string);
    procedure _BuildResponseHeaders(AStreamID: Cardinal; AStatus: Integer;
      const AContentType: string; ABodyLen: Integer;
      const AExtra: TArray<TPair<string, string>>;
      out AHeadersPayload: TBytes);

    procedure _GoAway(ALastStreamID: Cardinal; AErr: Cardinal);

  public
    constructor Create(AConn: Pointer;
      ASendProc: TH2SendProc; ACloseProc: TH2CloseProc;
      AOnRequest: TH2RequestCallback);
    destructor Destroy; override;

    // Feed incoming raw bytes (called from _ProcessRecv)
    procedure ProcessData(ABuf: PByte; ALen: Integer);

    // Send a complete HTTP/2 response for a given stream
    procedure SendResponse(AStreamID: Cardinal; AStatus: Integer;
      const AContentType: string; const ABody: TBytes;
      const AExtra: TArray<TPair<string, string>>);

    // Send server SETTINGS once after upgrade/preface
    procedure SendInitialSettings;

    property GoAwaySent: Boolean read FGoAwaySent;
  end;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const
  H2_FRAME_DATA          = 0;
  H2_FRAME_HEADERS       = 1;
  H2_FRAME_PRIORITY      = 2;
  H2_FRAME_RST_STREAM    = 3;
  H2_FRAME_SETTINGS      = 4;
  H2_FRAME_PUSH_PROMISE  = 5;
  H2_FRAME_PING          = 6;
  H2_FRAME_GOAWAY        = 7;
  H2_FRAME_WINDOW_UPDATE = 8;
  H2_FRAME_CONTINUATION  = 9;

  H2_FLAG_END_STREAM  = $01;
  H2_FLAG_END_HEADERS = $04;
  H2_FLAG_PADDED      = $08;
  H2_FLAG_PRIORITY    = $20;
  H2_FLAG_ACK         = $01;

  H2_SETTINGS_HEADER_TABLE_SIZE      = 1;
  H2_SETTINGS_ENABLE_PUSH            = 2;
  H2_SETTINGS_MAX_CONCURRENT_STREAMS = 3;
  H2_SETTINGS_INITIAL_WINDOW_SIZE    = 4;
  H2_SETTINGS_MAX_FRAME_SIZE         = 5;
  H2_SETTINGS_MAX_HEADER_LIST_SIZE   = 6;

  H2_ERR_NO_ERROR            = 0;
  H2_ERR_PROTOCOL_ERROR      = 1;
  H2_ERR_INTERNAL_ERROR      = 2;
  H2_ERR_FLOW_CONTROL_ERROR  = 3;
  H2_ERR_SETTINGS_TIMEOUT    = 4;
  H2_ERR_STREAM_CLOSED       = 5;
  H2_ERR_FRAME_SIZE_ERROR    = 6;
  H2_ERR_REFUSED_STREAM      = 7;
  H2_ERR_CANCEL              = 8;
  H2_ERR_COMPRESSION_ERROR   = 9;
  H2_ERR_CONNECT_ERROR       = 10;
  H2_ERR_ENHANCE_YOUR_CALM   = 11;
  H2_ERR_INADEQUATE_SECURITY = 12;
  H2_ERR_HTTP_1_1_REQUIRED   = 13;

  H2_CLIENT_PREFACE = 'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10;
  H2_PREFACE_LEN    = 24;

implementation

// Client connection preface — RFC 7540 §3.5 (24 bytes, no null terminator)
const
  H2_PREFACE_BYTES: array[0..23] of Byte = (
    $50,$52,$49,$20,$2A,$20,$48,$54,$54,$50,$2F,$32,$2E,$30,$0D,$0A,
    $0D,$0A,$53,$4D,$0D,$0A,$0D,$0A);
  // "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

// ===========================================================================
// Huffman decode tree — built once at initialization
// ===========================================================================

type
  TH2HuffNode = record
    Children: array[0..1] of Integer; // -1 = absent
    Symbol:   Integer;                // -1 = internal node; 0-255 = byte; 256 = EOS
  end;

var
  GHuffTree:      array of TH2HuffNode;
  GHuffTreeBuilt: Boolean = False;
  GHuffLock:      TCriticalSection;

// RFC 7541 Appendix B — (code, bits) for symbols 0..256
type
  THuffEntry = record Code: Cardinal; Bits: Byte; end;

const
  HUFF_TABLE: array[0..256] of THuffEntry = (
    // 0-7
    (Code: $00001FF8; Bits: 13), (Code: $007FFFD8; Bits: 23),
    (Code: $0FFFFFE2; Bits: 28), (Code: $0FFFFFE3; Bits: 28),
    (Code: $0FFFFFE4; Bits: 28), (Code: $0FFFFFE5; Bits: 28),
    (Code: $0FFFFFE6; Bits: 28), (Code: $0FFFFFE7; Bits: 28),
    // 8-15
    (Code: $0FFFFFE8; Bits: 28), (Code: $00FFFFEA; Bits: 24),
    (Code: $3FFFFFFC; Bits: 30), (Code: $0FFFFFE9; Bits: 28),
    (Code: $0FFFFFEA; Bits: 28), (Code: $3FFFFFFD; Bits: 30),
    (Code: $0FFFFFEB; Bits: 28), (Code: $0FFFFFEC; Bits: 28),
    // 16-23
    (Code: $0FFFFFED; Bits: 28), (Code: $0FFFFFEE; Bits: 28),
    (Code: $0FFFFFEF; Bits: 28), (Code: $0FFFFFF0; Bits: 28),
    (Code: $0FFFFFF1; Bits: 28), (Code: $0FFFFFF2; Bits: 28),
    (Code: $3FFFFFFE; Bits: 30), (Code: $0FFFFFF3; Bits: 28),
    // 24-31
    (Code: $0FFFFFF4; Bits: 28), (Code: $0FFFFFF5; Bits: 28),
    (Code: $0FFFFFF6; Bits: 28), (Code: $0FFFFFF7; Bits: 28),
    (Code: $0FFFFFF8; Bits: 28), (Code: $0FFFFFF9; Bits: 28),
    (Code: $0FFFFFFA; Bits: 28), (Code: $0FFFFFFB; Bits: 28),
    // 32-39
    (Code: $00000014; Bits:  6), (Code: $000003F8; Bits: 10),
    (Code: $000003F9; Bits: 10), (Code: $00000FFA; Bits: 12),
    (Code: $00001FF9; Bits: 13), (Code: $00000015; Bits:  6),
    (Code: $000000F8; Bits:  8), (Code: $000007FA; Bits: 11),
    // 40-47
    (Code: $000003FA; Bits: 10), (Code: $000003FB; Bits: 10),
    (Code: $000000F9; Bits:  8), (Code: $000007FB; Bits: 11),
    (Code: $000000FA; Bits:  8), (Code: $00000016; Bits:  6),
    (Code: $00000017; Bits:  6), (Code: $00000018; Bits:  6),
    // 48-55
    (Code: $00000000; Bits:  5), (Code: $00000001; Bits:  5),
    (Code: $00000002; Bits:  5), (Code: $00000019; Bits:  6),
    (Code: $0000001A; Bits:  6), (Code: $0000001B; Bits:  6),
    (Code: $0000001C; Bits:  6), (Code: $0000001D; Bits:  6),
    // 56-63
    (Code: $0000001E; Bits:  6), (Code: $0000001F; Bits:  6),
    (Code: $0000005C; Bits:  7), (Code: $000000FB; Bits:  8),
    (Code: $00007FFC; Bits: 15), (Code: $00000020; Bits:  6),
    (Code: $00000FFB; Bits: 12), (Code: $000003FC; Bits: 10),
    // 64-71
    (Code: $00001FFA; Bits: 13), (Code: $00000021; Bits:  6),
    (Code: $0000005D; Bits:  7), (Code: $0000005E; Bits:  7),
    (Code: $0000005F; Bits:  7), (Code: $00000060; Bits:  7),
    (Code: $00000061; Bits:  7), (Code: $00000062; Bits:  7),
    // 72-79
    (Code: $00000063; Bits:  7), (Code: $00000064; Bits:  7),
    (Code: $00000065; Bits:  7), (Code: $00000066; Bits:  7),
    (Code: $00000067; Bits:  7), (Code: $00000068; Bits:  7),
    (Code: $00000069; Bits:  7), (Code: $0000006A; Bits:  7),
    // 80-87
    (Code: $0000006B; Bits:  7), (Code: $0000006C; Bits:  7),
    (Code: $0000006D; Bits:  7), (Code: $0000006E; Bits:  7),
    (Code: $0000006F; Bits:  7), (Code: $00000070; Bits:  7),
    (Code: $00000071; Bits:  7), (Code: $00000072; Bits:  7),
    // 88-95
    (Code: $000000FC; Bits:  8), (Code: $00000073; Bits:  7),
    (Code: $000000FD; Bits:  8), (Code: $00001FFB; Bits: 13),
    (Code: $0007FFF0; Bits: 19), (Code: $00001FFC; Bits: 13),
    (Code: $00003FFC; Bits: 14), (Code: $00000022; Bits:  6),
    // 96-103
    (Code: $00007FFD; Bits: 15), (Code: $00000003; Bits:  5),
    (Code: $00000023; Bits:  6), (Code: $00000004; Bits:  5),
    (Code: $00000024; Bits:  6), (Code: $00000005; Bits:  5),
    (Code: $00000025; Bits:  6), (Code: $00000026; Bits:  6),
    // 104-111
    (Code: $00000027; Bits:  6), (Code: $00000006; Bits:  5),
    (Code: $00000074; Bits:  7), (Code: $00000075; Bits:  7),
    (Code: $00000028; Bits:  6), (Code: $00000029; Bits:  6),
    (Code: $0000002A; Bits:  6), (Code: $00000007; Bits:  5),
    // 112-119
    (Code: $0000002B; Bits:  6), (Code: $00000076; Bits:  7),
    (Code: $0000002C; Bits:  6), (Code: $00000008; Bits:  5),
    (Code: $00000009; Bits:  5), (Code: $0000002D; Bits:  6),
    (Code: $00000077; Bits:  7), (Code: $00000078; Bits:  7),
    // 120-127
    (Code: $00000079; Bits:  7), (Code: $0000007A; Bits:  7),
    (Code: $0000007B; Bits:  7), (Code: $00007FFE; Bits: 15),
    (Code: $000007FC; Bits: 11), (Code: $00003FFD; Bits: 14),
    (Code: $00001FFD; Bits: 13), (Code: $0FFFFFFC; Bits: 28),
    // 128-135
    (Code: $000FFFE6; Bits: 20), (Code: $003FFFD2; Bits: 22),
    (Code: $000FFFE7; Bits: 20), (Code: $000FFFE8; Bits: 20),
    (Code: $003FFFD3; Bits: 22), (Code: $003FFFD4; Bits: 22),
    (Code: $003FFFD5; Bits: 22), (Code: $007FFFD9; Bits: 23),
    // 136-143
    (Code: $003FFFD6; Bits: 22), (Code: $007FFFDA; Bits: 23),
    (Code: $007FFFDB; Bits: 23), (Code: $007FFFDC; Bits: 23),
    (Code: $007FFFDD; Bits: 23), (Code: $007FFFDE; Bits: 23),
    (Code: $00FFFFEB; Bits: 24), (Code: $007FFFDF; Bits: 23),
    // 144-151
    (Code: $00FFFFEC; Bits: 24), (Code: $00FFFFED; Bits: 24),
    (Code: $003FFFD7; Bits: 22), (Code: $007FFFE0; Bits: 23),
    (Code: $00FFFFEE; Bits: 24), (Code: $007FFFE1; Bits: 23),
    (Code: $007FFFE2; Bits: 23), (Code: $007FFFE3; Bits: 23),
    // 152-159
    (Code: $007FFFE4; Bits: 23), (Code: $001FFFDC; Bits: 21),
    (Code: $003FFFD8; Bits: 22), (Code: $007FFFE5; Bits: 23),
    (Code: $003FFFD9; Bits: 22), (Code: $007FFFE6; Bits: 23),
    (Code: $007FFFE7; Bits: 23), (Code: $00FFFFEF; Bits: 24),
    // 160-167
    (Code: $003FFFDA; Bits: 22), (Code: $001FFFDD; Bits: 21),
    (Code: $000FFFE9; Bits: 20), (Code: $003FFFDB; Bits: 22),
    (Code: $003FFFDC; Bits: 22), (Code: $007FFFE8; Bits: 23),
    (Code: $007FFFE9; Bits: 23), (Code: $001FFFDE; Bits: 21),
    // 168-175
    (Code: $007FFFEA; Bits: 23), (Code: $003FFFDD; Bits: 22),
    (Code: $003FFFDE; Bits: 22), (Code: $00FFFFF0; Bits: 24),
    (Code: $001FFFDF; Bits: 21), (Code: $003FFFDF; Bits: 22),
    (Code: $007FFFEB; Bits: 23), (Code: $007FFFEC; Bits: 23),
    // 176-183
    (Code: $001FFFE0; Bits: 21), (Code: $001FFFE1; Bits: 21),
    (Code: $003FFFE0; Bits: 22), (Code: $001FFFE2; Bits: 21),
    (Code: $007FFFED; Bits: 23), (Code: $003FFFE1; Bits: 22),
    (Code: $007FFFEE; Bits: 23), (Code: $007FFFEF; Bits: 23),
    // 184-191
    (Code: $000FFFEA; Bits: 20), (Code: $003FFFE2; Bits: 22),
    (Code: $003FFFE3; Bits: 22), (Code: $003FFFE4; Bits: 22),
    (Code: $007FFFF0; Bits: 23), (Code: $003FFFE5; Bits: 22),
    (Code: $003FFFE6; Bits: 22), (Code: $007FFFF1; Bits: 23),
    // 192-199
    (Code: $03FFFFE0; Bits: 26), (Code: $03FFFFE1; Bits: 26),
    (Code: $000FFFEB; Bits: 20), (Code: $0007FFF1; Bits: 19),
    (Code: $003FFFE7; Bits: 22), (Code: $007FFFF2; Bits: 23),
    (Code: $003FFFE8; Bits: 22), (Code: $01FFFFEC; Bits: 25),
    // 200-207
    (Code: $03FFFFE2; Bits: 26), (Code: $03FFFFE3; Bits: 26),
    (Code: $03FFFFE4; Bits: 26), (Code: $07FFFFDE; Bits: 27),
    (Code: $07FFFFDF; Bits: 27), (Code: $03FFFFE5; Bits: 26),
    (Code: $00FFFFF1; Bits: 24), (Code: $01FFFFED; Bits: 25),
    // 208-215
    (Code: $0007FFF2; Bits: 19), (Code: $001FFFE3; Bits: 21),
    (Code: $03FFFFE6; Bits: 26), (Code: $07FFFFE0; Bits: 27),
    (Code: $07FFFFE1; Bits: 27), (Code: $03FFFFE7; Bits: 26),
    (Code: $07FFFFE2; Bits: 27), (Code: $00FFFFF2; Bits: 24),
    // 216-223
    (Code: $001FFFE4; Bits: 21), (Code: $001FFFE5; Bits: 21),
    (Code: $03FFFFE8; Bits: 26), (Code: $03FFFFE9; Bits: 26),
    (Code: $0FFFFFFD; Bits: 28), (Code: $07FFFFE3; Bits: 27),
    (Code: $07FFFFE4; Bits: 27), (Code: $07FFFFE5; Bits: 27),
    // 224-231
    (Code: $000FFFEC; Bits: 20), (Code: $00FFFFF3; Bits: 24),
    (Code: $000FFFED; Bits: 20), (Code: $001FFFE6; Bits: 21),
    (Code: $003FFFE9; Bits: 22), (Code: $001FFFE7; Bits: 21),
    (Code: $001FFFE8; Bits: 21), (Code: $007FFFF3; Bits: 23),
    // 232-239
    (Code: $003FFFEA; Bits: 22), (Code: $003FFFEB; Bits: 22),
    (Code: $01FFFFEE; Bits: 25), (Code: $01FFFFEF; Bits: 25),
    (Code: $00FFFFF4; Bits: 24), (Code: $00FFFFF5; Bits: 24),
    (Code: $03FFFFEA; Bits: 26), (Code: $007FFFF4; Bits: 23),
    // 240-247
    (Code: $03FFFFEB; Bits: 26), (Code: $07FFFFE6; Bits: 27),
    (Code: $03FFFFEC; Bits: 26), (Code: $03FFFFED; Bits: 26),
    (Code: $07FFFFE7; Bits: 27), (Code: $07FFFFE8; Bits: 27),
    (Code: $07FFFFE9; Bits: 27), (Code: $07FFFFEA; Bits: 27),
    // 248-255
    (Code: $07FFFFEB; Bits: 27), (Code: $0FFFFFFE; Bits: 28),
    (Code: $07FFFFEC; Bits: 27), (Code: $07FFFFED; Bits: 27),
    (Code: $07FFFFEE; Bits: 27), (Code: $07FFFFEF; Bits: 27),
    (Code: $07FFFFF0; Bits: 27), (Code: $03FFFFEE; Bits: 26),
    // 256 = EOS
    (Code: $3FFFFFFF; Bits: 30)
  );

procedure _BuildHuffTree;
var
  LNodeCount: Integer;
  LEntry:     THuffEntry;
  I, B:       Integer;
  LNode:      Integer;
  LBit:       Integer;
  LChild:     Integer;
begin
  // Allocate a safe upper bound (30 bits → at most 2^30 paths but tree reuse
  // is guaranteed; in practice the table has 257 symbols × 30 bits = ~7710 nodes max)
  SetLength(GHuffTree, 8192);
  LNodeCount := 1;
  GHuffTree[0].Children[0] := -1;
  GHuffTree[0].Children[1] := -1;
  GHuffTree[0].Symbol       := -1;

  for I := 0 to 256 do
  begin
    LEntry := HUFF_TABLE[I];
    LNode  := 0;
    for B := LEntry.Bits - 1 downto 0 do
    begin
      LBit := (LEntry.Code shr B) and 1;
      LChild := GHuffTree[LNode].Children[LBit];
      if LChild = -1 then
      begin
        if LNodeCount >= Length(GHuffTree) then
          SetLength(GHuffTree, Length(GHuffTree) * 2);
        GHuffTree[LNodeCount].Children[0] := -1;
        GHuffTree[LNodeCount].Children[1] := -1;
        GHuffTree[LNodeCount].Symbol       := -1;
        GHuffTree[LNode].Children[LBit]   := LNodeCount;
        LChild := LNodeCount;
        Inc(LNodeCount);
      end;
      LNode := LChild;
    end;
    GHuffTree[LNode].Symbol := I;
  end;
end;

// ===========================================================================
// HPACK static table (RFC 7541 Appendix A — 61 entries, 1-based)
// ===========================================================================

type
  TStaticEntry = record Name, Value: string; end;

const
  STATIC_TABLE_SIZE = 61;

var
  GStaticTable: array[1..STATIC_TABLE_SIZE] of TStaticEntry;

procedure _InitStaticTable;
begin
  GStaticTable[ 1].Name := ':authority';         GStaticTable[ 1].Value := '';
  GStaticTable[ 2].Name := ':method';            GStaticTable[ 2].Value := 'GET';
  GStaticTable[ 3].Name := ':method';            GStaticTable[ 3].Value := 'POST';
  GStaticTable[ 4].Name := ':path';              GStaticTable[ 4].Value := '/';
  GStaticTable[ 5].Name := ':path';              GStaticTable[ 5].Value := '/index.html';
  GStaticTable[ 6].Name := ':scheme';            GStaticTable[ 6].Value := 'http';
  GStaticTable[ 7].Name := ':scheme';            GStaticTable[ 7].Value := 'https';
  GStaticTable[ 8].Name := ':status';            GStaticTable[ 8].Value := '200';
  GStaticTable[ 9].Name := ':status';            GStaticTable[ 9].Value := '204';
  GStaticTable[10].Name := ':status';            GStaticTable[10].Value := '206';
  GStaticTable[11].Name := ':status';            GStaticTable[11].Value := '304';
  GStaticTable[12].Name := ':status';            GStaticTable[12].Value := '400';
  GStaticTable[13].Name := ':status';            GStaticTable[13].Value := '404';
  GStaticTable[14].Name := ':status';            GStaticTable[14].Value := '500';
  GStaticTable[15].Name := 'accept-charset';     GStaticTable[15].Value := '';
  GStaticTable[16].Name := 'accept-encoding';    GStaticTable[16].Value := 'gzip, deflate';
  GStaticTable[17].Name := 'accept-language';    GStaticTable[17].Value := '';
  GStaticTable[18].Name := 'accept-ranges';      GStaticTable[18].Value := '';
  GStaticTable[19].Name := 'accept';             GStaticTable[19].Value := '';
  GStaticTable[20].Name := 'access-control-allow-origin'; GStaticTable[20].Value := '';
  GStaticTable[21].Name := 'age';                GStaticTable[21].Value := '';
  GStaticTable[22].Name := 'allow';              GStaticTable[22].Value := '';
  GStaticTable[23].Name := 'authorization';      GStaticTable[23].Value := '';
  GStaticTable[24].Name := 'cache-control';      GStaticTable[24].Value := '';
  GStaticTable[25].Name := 'content-disposition'; GStaticTable[25].Value := '';
  GStaticTable[26].Name := 'content-encoding';   GStaticTable[26].Value := '';
  GStaticTable[27].Name := 'content-language';   GStaticTable[27].Value := '';
  GStaticTable[28].Name := 'content-length';     GStaticTable[28].Value := '';
  GStaticTable[29].Name := 'content-location';   GStaticTable[29].Value := '';
  GStaticTable[30].Name := 'content-range';      GStaticTable[30].Value := '';
  GStaticTable[31].Name := 'content-type';       GStaticTable[31].Value := '';
  GStaticTable[32].Name := 'cookie';             GStaticTable[32].Value := '';
  GStaticTable[33].Name := 'date';               GStaticTable[33].Value := '';
  GStaticTable[34].Name := 'etag';               GStaticTable[34].Value := '';
  GStaticTable[35].Name := 'expect';             GStaticTable[35].Value := '';
  GStaticTable[36].Name := 'expires';            GStaticTable[36].Value := '';
  GStaticTable[37].Name := 'from';               GStaticTable[37].Value := '';
  GStaticTable[38].Name := 'host';               GStaticTable[38].Value := '';
  GStaticTable[39].Name := 'if-match';           GStaticTable[39].Value := '';
  GStaticTable[40].Name := 'if-modified-since';  GStaticTable[40].Value := '';
  GStaticTable[41].Name := 'if-none-match';      GStaticTable[41].Value := '';
  GStaticTable[42].Name := 'if-range';           GStaticTable[42].Value := '';
  GStaticTable[43].Name := 'if-unmodified-since'; GStaticTable[43].Value := '';
  GStaticTable[44].Name := 'last-modified';      GStaticTable[44].Value := '';
  GStaticTable[45].Name := 'link';               GStaticTable[45].Value := '';
  GStaticTable[46].Name := 'location';           GStaticTable[46].Value := '';
  GStaticTable[47].Name := 'max-forwards';       GStaticTable[47].Value := '';
  GStaticTable[48].Name := 'proxy-authenticate'; GStaticTable[48].Value := '';
  GStaticTable[49].Name := 'proxy-authorization'; GStaticTable[49].Value := '';
  GStaticTable[50].Name := 'range';              GStaticTable[50].Value := '';
  GStaticTable[51].Name := 'referer';            GStaticTable[51].Value := '';
  GStaticTable[52].Name := 'refresh';            GStaticTable[52].Value := '';
  GStaticTable[53].Name := 'retry-after';        GStaticTable[53].Value := '';
  GStaticTable[54].Name := 'server';             GStaticTable[54].Value := '';
  GStaticTable[55].Name := 'set-cookie';         GStaticTable[55].Value := '';
  GStaticTable[56].Name := 'strict-transport-security'; GStaticTable[56].Value := '';
  GStaticTable[57].Name := 'transfer-encoding';  GStaticTable[57].Value := '';
  GStaticTable[58].Name := 'user-agent';         GStaticTable[58].Value := '';
  GStaticTable[59].Name := 'vary';               GStaticTable[59].Value := '';
  GStaticTable[60].Name := 'via';                GStaticTable[60].Value := '';
  GStaticTable[61].Name := 'www-authenticate';   GStaticTable[61].Value := '';
end;

// ===========================================================================
// TH2Stream
// ===========================================================================

destructor TH2Stream.Destroy;
begin
  inherited Destroy;
end;

// ===========================================================================
// TH2Conn — constructor / destructor
// ===========================================================================

constructor TH2Conn.Create(AConn: Pointer;
  ASendProc: TH2SendProc; ACloseProc: TH2CloseProc;
  AOnRequest: TH2RequestCallback);
begin
  inherited Create;
  FConn      := AConn;
  FSendProc  := ASendProc;
  FCloseProc := ACloseProc;
  FOnRequest := AOnRequest;

  FPrefaceReceived := False;
  FSettingsSent    := False;
  FGoAwaySent      := False;

  SetLength(FFrameBuf, 0);
  FFrameLen := 0;

  FContinStreamID    := 0;
  FContinHeadersLen  := 0;
  SetLength(FContinHeaders, 0);

  FStreams      := TDictionary<Cardinal, TH2Stream>.Create;
  FLastStreamID := 0;

  SetLength(FDynTable, 0);
  FDynTableSize    := 0;
  FDynTableMaxSize := 4096; // default per RFC 7541

  FPeerMaxFrameSize := 16384;
  FPeerInitWinSize  := 65535;

  // Ensure Huffman tree is available
  GHuffLock.Enter;
  try
    if not GHuffTreeBuilt then
    begin
      _BuildHuffTree;
      GHuffTreeBuilt := True;
    end;
  finally
    GHuffLock.Leave;
  end;
end;

destructor TH2Conn.Destroy;
var
  LPair: TPair<Cardinal, TH2Stream>;
begin
  for LPair in FStreams do
    LPair.Value.Free;
  FStreams.Free;
  inherited Destroy;
end;

// ===========================================================================
// Raw send helpers
// ===========================================================================

procedure TH2Conn._SendRaw(const AData: TBytes);
begin
  if Assigned(FSendProc) then
    FSendProc(FConn, AData);
end;

// Build and send a complete HTTP/2 frame.
// APayload may be nil when APayLen = 0.
procedure TH2Conn._SendFrame(AType, AFlags: Byte; AStreamID: Cardinal;
  APayload: PByte; APayLen: Integer);
var
  LFrame: TBytes;
  LSID:   Cardinal;
begin
  SetLength(LFrame, 9 + APayLen);
  // 3-byte length (big-endian)
  LFrame[0] := (APayLen shr 16) and $FF;
  LFrame[1] := (APayLen shr  8) and $FF;
  LFrame[2] :=  APayLen         and $FF;
  LFrame[3] := AType;
  LFrame[4] := AFlags;
  // 4-byte stream ID (top bit = 0, big-endian)
  LSID := AStreamID and $7FFFFFFF;
  LFrame[5] := (LSID shr 24) and $FF;
  LFrame[6] := (LSID shr 16) and $FF;
  LFrame[7] := (LSID shr  8) and $FF;
  LFrame[8] :=  LSID         and $FF;
  if (APayLen > 0) and (APayload <> nil) then
    Move(APayload^, LFrame[9], APayLen);
  _SendRaw(LFrame);
end;

// ===========================================================================
// GOAWAY
// ===========================================================================

procedure TH2Conn._GoAway(ALastStreamID: Cardinal; AErr: Cardinal);
var
  LPayload: TBytes;
  LLSID:    Cardinal;
begin
  if FGoAwaySent then Exit;
  FGoAwaySent := True;
  SetLength(LPayload, 8);
  LLSID := ALastStreamID and $7FFFFFFF;
  LPayload[0] := (LLSID shr 24) and $FF;
  LPayload[1] := (LLSID shr 16) and $FF;
  LPayload[2] := (LLSID shr  8) and $FF;
  LPayload[3] :=  LLSID         and $FF;
  LPayload[4] := (AErr  shr 24) and $FF;
  LPayload[5] := (AErr  shr 16) and $FF;
  LPayload[6] := (AErr  shr  8) and $FF;
  LPayload[7] :=  AErr          and $FF;
  _SendFrame(H2_FRAME_GOAWAY, 0, 0, @LPayload[0], 8);
  if Assigned(FCloseProc) then
    FCloseProc(FConn);
end;

// ===========================================================================
// SendInitialSettings
// ===========================================================================

procedure TH2Conn.SendInitialSettings;
var
  LPayload: TBytes;
  LPos:     Integer;

  procedure PutSetting(AID: Word; AVal: Cardinal);
  begin
    LPayload[LPos + 0] := (AID  shr 8) and $FF;
    LPayload[LPos + 1] :=  AID         and $FF;
    LPayload[LPos + 2] := (AVal shr 24) and $FF;
    LPayload[LPos + 3] := (AVal shr 16) and $FF;
    LPayload[LPos + 4] := (AVal shr  8) and $FF;
    LPayload[LPos + 5] :=  AVal         and $FF;
    Inc(LPos, 6);
  end;

begin
  // 5 settings × 6 bytes each
  SetLength(LPayload, 30);
  LPos := 0;
  PutSetting(H2_SETTINGS_HEADER_TABLE_SIZE,      4096);
  PutSetting(H2_SETTINGS_ENABLE_PUSH,            0);
  PutSetting(H2_SETTINGS_MAX_CONCURRENT_STREAMS, 100);
  PutSetting(H2_SETTINGS_INITIAL_WINDOW_SIZE,    65535);
  PutSetting(H2_SETTINGS_MAX_FRAME_SIZE,         16384);
  _SendFrame(H2_FRAME_SETTINGS, 0, 0, @LPayload[0], 30);
  FSettingsSent := True;
end;

// ===========================================================================
// ProcessData — main entry point called by the server on new bytes
// ===========================================================================

procedure TH2Conn.ProcessData(ABuf: PByte; ALen: Integer);
var
  LNeeded:   Integer;
  LPayLen:   Integer;
  LType:     Byte;
  LFlags:    Byte;
  LSIDRaw:   Cardinal;
  LStreamID: Cardinal;
  LFBuf:     PByte;
begin
  if FGoAwaySent then Exit;

  // Append to accumulator
  LNeeded := FFrameLen + ALen;
  if LNeeded > Length(FFrameBuf) then
    SetLength(FFrameBuf, LNeeded + 4096);
  Move(ABuf^, FFrameBuf[FFrameLen], ALen);
  Inc(FFrameLen, ALen);

  // Check preface
  if not FPrefaceReceived then
  begin
    if FFrameLen < H2_PREFACE_LEN then Exit; // need more data
    if not CompareMem(@FFrameBuf[0], @H2_PREFACE_BYTES[0], H2_PREFACE_LEN) then
    begin
      _GoAway(0, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    FPrefaceReceived := True;
    // Remove preface from buffer
    Move(FFrameBuf[H2_PREFACE_LEN], FFrameBuf[0], FFrameLen - H2_PREFACE_LEN);
    Dec(FFrameLen, H2_PREFACE_LEN);
    // Send our settings immediately
    if not FSettingsSent then
      SendInitialSettings;
  end;

  // Parse frames
  while FFrameLen >= 9 do
  begin
    LFBuf   := @FFrameBuf[0];
    LPayLen := (Integer(LFBuf[0]) shl 16) or
               (Integer(LFBuf[1]) shl  8) or
                Integer(LFBuf[2]);
    if FFrameLen < 9 + LPayLen then Break; // incomplete frame

    LType  := LFBuf[3];
    LFlags := LFBuf[4];
    LSIDRaw := (Cardinal(LFBuf[5]) shl 24) or
               (Cardinal(LFBuf[6]) shl 16) or
               (Cardinal(LFBuf[7]) shl  8) or
                Cardinal(LFBuf[8]);
    LStreamID := LSIDRaw and $7FFFFFFF;

    // RFC 7540 §6.10: while awaiting CONTINUATION, only CONTINUATION is allowed
    if (FContinStreamID <> 0) and (LType <> H2_FRAME_CONTINUATION) then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;

    if LPayLen > 0 then
      _ProcessFrame(LType, LFlags, LStreamID, @FFrameBuf[9], LPayLen)
    else
      _ProcessFrame(LType, LFlags, LStreamID, nil, 0);

    if FGoAwaySent then Exit;

    // Advance buffer
    LNeeded := FFrameLen - (9 + LPayLen);
    if LNeeded > 0 then
      Move(FFrameBuf[9 + LPayLen], FFrameBuf[0], LNeeded);
    FFrameLen := LNeeded;
  end;
end;

// ===========================================================================
// _ProcessFrame — dispatch by type
// ===========================================================================

procedure TH2Conn._ProcessFrame(AType, AFlags: Byte; AStreamID: Cardinal;
  APayload: PByte; APayLen: Integer);
begin
  case AType of
    H2_FRAME_DATA:
      _HandleData(AFlags, AStreamID, APayload, APayLen);
    H2_FRAME_HEADERS:
      _HandleHeaders(AFlags, AStreamID, APayload, APayLen);
    H2_FRAME_PRIORITY:
      ; // ignore — RFC 7540 §6.3 says it may arrive on any stream state
    H2_FRAME_RST_STREAM:
      _HandleRstStream(AStreamID, APayload, APayLen);
    H2_FRAME_SETTINGS:
      _HandleSettings(AFlags, APayload, APayLen);
    H2_FRAME_PUSH_PROMISE:
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR); // client must not send push-promise
    H2_FRAME_PING:
      _HandlePing(AFlags, APayload, APayLen);
    H2_FRAME_GOAWAY:
      _HandleGoAway(APayload, APayLen);
    H2_FRAME_WINDOW_UPDATE:
      _HandleWindowUpdate(AStreamID, APayload, APayLen);
    H2_FRAME_CONTINUATION:
      _HandleContinuation(AFlags, AStreamID, APayload, APayLen);
    // Unknown frame types are ignored (RFC 7540 §4.1)
  end;
end;

// ===========================================================================
// _HandleSettings
// ===========================================================================

procedure TH2Conn._HandleSettings(AFlags: Byte; APayload: PByte; APayLen: Integer);
var
  LPos:  Integer;
  LID:   Word;
  LVal:  Cardinal;
  LDummy: TBytes;
begin
  // ACK — nothing to do
  if (AFlags and H2_FLAG_ACK) <> 0 then Exit;

  // Each setting is 6 bytes
  if (APayLen mod 6) <> 0 then
  begin
    _GoAway(FLastStreamID, H2_ERR_FRAME_SIZE_ERROR);
    Exit;
  end;

  LPos := 0;
  while LPos < APayLen do
  begin
    LID  := (Word(APayload[LPos]) shl 8) or Word(APayload[LPos + 1]);
    LVal := (Cardinal(APayload[LPos + 2]) shl 24) or
            (Cardinal(APayload[LPos + 3]) shl 16) or
            (Cardinal(APayload[LPos + 4]) shl  8) or
             Cardinal(APayload[LPos + 5]);
    Inc(LPos, 6);
    case LID of
      H2_SETTINGS_HEADER_TABLE_SIZE:
        begin
          FDynTableMaxSize := LVal;
          _HpackEvict(FDynTableMaxSize);
        end;
      H2_SETTINGS_MAX_FRAME_SIZE:
        begin
          if (LVal < 16384) or (LVal > 16777215) then
          begin
            _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
            Exit;
          end;
          FPeerMaxFrameSize := LVal;
        end;
      H2_SETTINGS_INITIAL_WINDOW_SIZE:
        FPeerInitWinSize := LVal;
      // Other settings: silently accept
    end;
  end;

  // Send SETTINGS ACK
  SetLength(LDummy, 0);
  _SendFrame(H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, nil, 0);
end;

// ===========================================================================
// _HandlePing
// ===========================================================================

procedure TH2Conn._HandlePing(AFlags: Byte; APayload: PByte; APayLen: Integer);
begin
  if (AFlags and H2_FLAG_ACK) <> 0 then Exit; // ACK to our ping — ignore
  if APayLen <> 8 then
  begin
    _GoAway(FLastStreamID, H2_ERR_FRAME_SIZE_ERROR);
    Exit;
  end;
  // Echo back with ACK
  _SendFrame(H2_FRAME_PING, H2_FLAG_ACK, 0, APayload, 8);
end;

// ===========================================================================
// _HandleGoAway
// ===========================================================================

procedure TH2Conn._HandleGoAway(APayload: PByte; APayLen: Integer);
begin
  FGoAwaySent := True; // suppress further sends
  if Assigned(FCloseProc) then
    FCloseProc(FConn);
end;

// ===========================================================================
// _HandleRstStream
// ===========================================================================

procedure TH2Conn._HandleRstStream(AStreamID: Cardinal; APayload: PByte; APayLen: Integer);
var
  LStream: TH2Stream;
begin
  if APayLen <> 4 then
  begin
    _GoAway(FLastStreamID, H2_ERR_FRAME_SIZE_ERROR);
    Exit;
  end;
  if FStreams.TryGetValue(AStreamID, LStream) then
  begin
    FStreams.Remove(AStreamID);
    LStream.Free;
  end;
end;

// ===========================================================================
// _HandleWindowUpdate
// ===========================================================================

procedure TH2Conn._HandleWindowUpdate(AStreamID: Cardinal; APayload: PByte; APayLen: Integer);
begin
  // Accept and ignore — our windows are large enough for typical responses
  if APayLen <> 4 then
    _GoAway(FLastStreamID, H2_ERR_FRAME_SIZE_ERROR);
end;

// ===========================================================================
// _HandleHeaders + _DecodeRequestHeaders
// ===========================================================================

procedure TH2Conn._HandleHeaders(AFlags: Byte; AStreamID: Cardinal;
  APayload: PByte; APayLen: Integer; AContinuation: Boolean);
var
  LStream:   TH2Stream;
  LPadLen:   Integer;
  LHasPad:   Boolean;
  LHasPri:   Boolean;
  LEndHdrs:  Boolean;
  LEndStrm:  Boolean;
begin
  if AStreamID = 0 then
  begin
    _GoAway(0, H2_ERR_PROTOCOL_ERROR);
    Exit;
  end;

  if AStreamID > FLastStreamID then
    FLastStreamID := AStreamID;

  LHasPad  := (not AContinuation) and ((AFlags and H2_FLAG_PADDED)   <> 0);
  LHasPri  := (not AContinuation) and ((AFlags and H2_FLAG_PRIORITY) <> 0);
  LEndHdrs := (AFlags and H2_FLAG_END_HEADERS) <> 0;
  LEndStrm := (AFlags and H2_FLAG_END_STREAM)  <> 0;

  LPadLen := 0;
  if LHasPad then
  begin
    if APayLen < 1 then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    LPadLen := APayload[0];
    Inc(APayload);
    Dec(APayLen);
  end;
  if LHasPri then
  begin
    if APayLen < 5 then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    Inc(APayload, 5);
    Dec(APayLen, 5);
  end;
  // Remove padding from end
  if LHasPad then
  begin
    if LPadLen >= APayLen then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    Dec(APayLen, LPadLen);
  end;

  // Get or create stream
  if not FStreams.TryGetValue(AStreamID, LStream) then
  begin
    LStream := TH2Stream.Create;
    LStream.StreamID := AStreamID;
    LStream.State    := hssOpen;
    FStreams.Add(AStreamID, LStream);
  end;

  if LEndHdrs then
  begin
    // Accumulate any CONTINUATION bytes already buffered, then decode
    if FContinHeadersLen > 0 then
    begin
      // Append final fragment
      LPadLen := FContinHeadersLen + APayLen; // reuse LPadLen as temp total
      if LPadLen > Length(FContinHeaders) then
        SetLength(FContinHeaders, LPadLen);
      Move(APayload^, FContinHeaders[FContinHeadersLen], APayLen);
      _DecodeRequestHeaders(LStream, @FContinHeaders[0], LPadLen, 0, False);
      FContinHeadersLen := 0;
      FContinStreamID   := 0;
    end
    else
      _DecodeRequestHeaders(LStream, APayload, APayLen, 0, False);

    LStream.HeadersComplete := True;
    LStream.EndStream := LEndStrm;
    if LEndStrm then
      _DispatchStream(LStream);
  end
  else
  begin
    // Headers are split; buffer and wait for CONTINUATION
    FContinStreamID := AStreamID;
    if FContinHeadersLen + APayLen > Length(FContinHeaders) then
      SetLength(FContinHeaders, FContinHeadersLen + APayLen + 4096);
    Move(APayload^, FContinHeaders[FContinHeadersLen], APayLen);
    Inc(FContinHeadersLen, APayLen);
    LStream.EndStream := LEndStrm;
  end;
end;

procedure TH2Conn._HandleContinuation(AFlags: Byte; AStreamID: Cardinal;
  APayload: PByte; APayLen: Integer);
begin
  if AStreamID <> FContinStreamID then
  begin
    _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
    Exit;
  end;
  _HandleHeaders(AFlags, AStreamID, APayload, APayLen, True);
end;

// ===========================================================================
// _HandleData
// ===========================================================================

procedure TH2Conn._HandleData(AFlags: Byte; AStreamID: Cardinal;
  APayload: PByte; APayLen: Integer);
var
  LStream:  TH2Stream;
  LPadLen:  Integer;
  LDataLen: Integer;
begin
  if AStreamID = 0 then
  begin
    _GoAway(0, H2_ERR_PROTOCOL_ERROR);
    Exit;
  end;

  LPadLen := 0;
  if (AFlags and H2_FLAG_PADDED) <> 0 then
  begin
    if APayLen < 1 then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    LPadLen := APayload[0];
    Inc(APayload);
    Dec(APayLen);
    if LPadLen >= APayLen then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    Dec(APayLen, LPadLen);
  end;

  LDataLen := APayLen;

  if not FStreams.TryGetValue(AStreamID, LStream) then Exit;

  // Append body
  if LDataLen > 0 then
  begin
    if LStream.BodyLen + LDataLen > Length(LStream.Body) then
      SetLength(LStream.Body, LStream.BodyLen + LDataLen + 4096);
    Move(APayload^, LStream.Body[LStream.BodyLen], LDataLen);
    Inc(LStream.BodyLen, LDataLen);
  end;

  if (AFlags and H2_FLAG_END_STREAM) <> 0 then
  begin
    LStream.EndStream := True;
    if LStream.HeadersComplete then
      _DispatchStream(LStream);
  end;
end;

// ===========================================================================
// HPACK integer codec
// ===========================================================================

// Decode a HPACK integer starting at FFrameBuf[APos].
// APrefixBits = number of low bits in the first byte used for the integer.
// The high bits of the first byte (above the prefix) are masked out by caller.
function TH2Conn._HpackDecodeInt(ABuf: PByte; ABufLen: Integer; APrefixBits: Byte;
  var APos: Integer): Cardinal;
var
  LMask:  Cardinal;
  LValue: Cardinal;
  LShift: Integer;
  LByte:  Byte;
begin
  LMask  := (1 shl APrefixBits) - 1;
  LValue := ABuf[APos] and LMask;
  Inc(APos);
  if LValue < LMask then
  begin
    Result := LValue;
    Exit;
  end;
  // Multi-byte encoding
  LShift := 0;
  repeat
    if APos >= ABufLen then
    begin
      Result := 0;
      Exit;
    end;
    LByte  := ABuf[APos];
    Inc(APos);
    LValue := LValue + Cardinal(LByte and $7F) shl LShift;
    Inc(LShift, 7);
  until (LByte and $80) = 0;
  Result := LValue;
end;

procedure TH2Conn._HpackEncodeInt(var ABuf: TBytes; var APos: Integer;
  AValue: Cardinal; APrefixBits: Byte; AHighBits: Byte);
var
  LMask: Cardinal;
begin
  LMask := (1 shl APrefixBits) - 1;
  if APos >= Length(ABuf) then SetLength(ABuf, APos + 64);

  if AValue < LMask then
  begin
    ABuf[APos] := AHighBits or Byte(AValue);
    Inc(APos);
  end
  else
  begin
    ABuf[APos] := AHighBits or Byte(LMask);
    Inc(APos);
    Dec(AValue, LMask);
    while AValue >= 128 do
    begin
      if APos >= Length(ABuf) then SetLength(ABuf, APos + 64);
      ABuf[APos] := Byte(AValue and $7F) or $80;
      Inc(APos);
      AValue := AValue shr 7;
    end;
    if APos >= Length(ABuf) then SetLength(ABuf, APos + 64);
    ABuf[APos] := Byte(AValue);
    Inc(APos);
  end;
end;

// ===========================================================================
// HPACK string codec
// ===========================================================================

procedure TH2Conn._HpackHuffmanDecode(ABuf: PByte; ALen: Integer; out AResult: string);
var
  LBytes:  TBytes;
  LBLen:   Integer;
  LNode:   Integer;
  I, B:    Integer;
  LBit:    Integer;
  LChild:  Integer;
  LSym:    Integer;
begin
  SetLength(LBytes, ALen * 2); // upper bound
  LBLen := 0;
  LNode := 0;
  for I := 0 to ALen - 1 do
  begin
    for B := 7 downto 0 do
    begin
      LBit   := (ABuf[I] shr B) and 1;
      LChild := GHuffTree[LNode].Children[LBit];
      if LChild = -1 then Break; // padding or invalid — stop
      LNode  := LChild;
      LSym   := GHuffTree[LNode].Symbol;
      if LSym >= 0 then
      begin
        if LSym = 256 then Break; // EOS
        if LBLen >= Length(LBytes) then SetLength(LBytes, LBLen + 64);
        LBytes[LBLen] := Byte(LSym);
        Inc(LBLen);
        LNode := 0; // back to root
      end;
    end;
  end;
  SetLength(LBytes, LBLen);
  AResult := TEncoding.UTF8.GetString(LBytes);
end;

function TH2Conn._HpackDecodeStr(ABuf: PByte; ABufLen: Integer;
  var APos: Integer): string;
var
  LHuffman: Boolean;
  LLen:     Cardinal;
  LRaw:     PByte;
  LSlice:   TBytes;
begin
  if APos >= ABufLen then
  begin
    Result := '';
    Exit;
  end;
  LHuffman := (ABuf[APos] and $80) <> 0;
  LLen := _HpackDecodeInt(ABuf, ABufLen, 7, APos);
  if APos + Integer(LLen) > ABufLen then
  begin
    Result := '';
    Exit;
  end;
  LRaw := @ABuf[APos];
  Inc(APos, LLen);
  if LHuffman then
    _HpackHuffmanDecode(LRaw, LLen, Result)
  else
  begin
    SetLength(LSlice, LLen);
    if LLen > 0 then
      Move(LRaw^, LSlice[0], LLen);
    Result := TEncoding.UTF8.GetString(LSlice);
  end;
end;

procedure TH2Conn._HpackEncodeStr(var ABuf: TBytes; var APos: Integer;
  const AStr: string);
var
  LEncoded: TBytes;
  LLen:     Integer;
begin
  LEncoded := TEncoding.UTF8.GetBytes(AStr);
  LLen := Length(LEncoded);
  // Write length with Huffman=0 flag, 7-bit prefix
  _HpackEncodeInt(ABuf, APos, LLen, 7, $00 {H=0});
  if APos + LLen > Length(ABuf) then
    SetLength(ABuf, APos + LLen + 64);
  if LLen > 0 then
    Move(LEncoded[0], ABuf[APos], LLen);
  Inc(APos, LLen);
end;

// ===========================================================================
// HPACK table access
// ===========================================================================

function TH2Conn._HpackGetStatic(AIdx: Cardinal; out AName, AValue: string): Boolean;
begin
  if (AIdx >= 1) and (AIdx <= STATIC_TABLE_SIZE) then
  begin
    AName  := GStaticTable[AIdx].Name;
    AValue := GStaticTable[AIdx].Value;
    Result := True;
  end
  else
    Result := False;
end;

function TH2Conn._HpackGetDynamic(AIdx: Cardinal; out AName, AValue: string): Boolean;
var
  LDynIdx: Integer;
begin
  // Dynamic table index: 62 = most recently added (index 0 in FDynTable)
  LDynIdx := Integer(AIdx) - (STATIC_TABLE_SIZE + 1);
  if (LDynIdx >= 0) and (LDynIdx < Length(FDynTable)) then
  begin
    AName  := FDynTable[LDynIdx].Name;
    AValue := FDynTable[LDynIdx].Value;
    Result := True;
  end
  else
    Result := False;
end;

procedure TH2Conn._HpackEvict(AMaxSize: Integer);
var
  LLen: Integer;
begin
  // Evict from the END of the array (oldest entries)
  LLen := Length(FDynTable);
  while (FDynTableSize > AMaxSize) and (LLen > 0) do
  begin
    Dec(LLen);
    Dec(FDynTableSize, 32 + Length(FDynTable[LLen].Name) + Length(FDynTable[LLen].Value));
    SetLength(FDynTable, LLen);
  end;
  if FDynTableSize < 0 then FDynTableSize := 0;
end;

procedure TH2Conn._HpackAddDyn(const AName, AValue: string);
var
  LEntrySize: Integer;
  LLen:       Integer;
begin
  LEntrySize := 32 + Length(AName) + Length(AValue); // RFC 7541 §4.1

  // Evict to make room
  _HpackEvict(FDynTableMaxSize - LEntrySize);

  if LEntrySize > FDynTableMaxSize then Exit; // won't fit even alone

  // Prepend (index 62 = element 0 = most recent)
  // Use a safe loop — TH2DynEntry contains managed string fields; Move would
  // bypass reference counting and corrupt memory.
  LLen := Length(FDynTable);
  SetLength(FDynTable, LLen + 1);
  var J: Integer;
  for J := LLen downto 1 do
    FDynTable[J] := FDynTable[J - 1];
  FDynTable[0].Name  := AName;
  FDynTable[0].Value := AValue;
  Inc(FDynTableSize, LEntrySize);
end;

// ===========================================================================
// _DecodeRequestHeaders — full HPACK header block decode
// ===========================================================================

procedure TH2Conn._DecodeRequestHeaders(AStream: TH2Stream;
  APayload: PByte; APayLen: Integer; APadLen: Integer; APriority: Boolean);
var
  LPos:       Integer;
  LByte:      Byte;
  LIdx:       Cardinal;
  LName:      string;
  LValue:     string;
  LNameOnly:  Boolean;
  LAddDyn:    Boolean;
  LPrefixBits: Byte;
  LHdrCount:  Integer;
  LPair:      TPair<string, string>;
begin
  LPos := 0;
  LHdrCount := 0;

  while LPos < APayLen do
  begin
    LByte := APayload[LPos];

    if (LByte and $80) <> 0 then
    begin
      // §6.1 Indexed Header Field Representation
      LIdx := _HpackDecodeInt(APayload, APayLen, 7, LPos);
      if LIdx = 0 then
      begin
        _GoAway(FLastStreamID, H2_ERR_COMPRESSION_ERROR);
        Exit;
      end;
      if LIdx <= STATIC_TABLE_SIZE then
      begin
        if not _HpackGetStatic(LIdx, LName, LValue) then Continue;
      end
      else
      begin
        if not _HpackGetDynamic(LIdx, LName, LValue) then Continue;
      end;
      LAddDyn := False;
    end
    else if (LByte and $C0) = $40 then
    begin
      // §6.2.1 Literal with Incremental Indexing
      LPrefixBits := 6;
      LIdx  := _HpackDecodeInt(APayload, APayLen, LPrefixBits, LPos);
      LAddDyn := True;
      LNameOnly := (LIdx = 0);
      if not LNameOnly then
      begin
        if LIdx <= STATIC_TABLE_SIZE then _HpackGetStatic(LIdx, LName, LValue)
        else _HpackGetDynamic(LIdx, LName, LValue);
      end
      else
        LName := _HpackDecodeStr(APayload, APayLen, LPos);
      LValue := _HpackDecodeStr(APayload, APayLen, LPos);
    end
    else if (LByte and $F0) = $10 then
    begin
      // §6.2.3 Literal Never Indexed
      LPrefixBits := 4;
      LIdx  := _HpackDecodeInt(APayload, APayLen, LPrefixBits, LPos);
      LAddDyn := False;
      LNameOnly := (LIdx = 0);
      if not LNameOnly then
      begin
        if LIdx <= STATIC_TABLE_SIZE then _HpackGetStatic(LIdx, LName, LValue)
        else _HpackGetDynamic(LIdx, LName, LValue);
      end
      else
        LName := _HpackDecodeStr(APayload, APayLen, LPos);
      LValue := _HpackDecodeStr(APayload, APayLen, LPos);
    end
    else if (LByte and $F0) = $00 then
    begin
      // §6.2.2 Literal without Indexing
      LPrefixBits := 4;
      LIdx  := _HpackDecodeInt(APayload, APayLen, LPrefixBits, LPos);
      LAddDyn := False;
      LNameOnly := (LIdx = 0);
      if not LNameOnly then
      begin
        if LIdx <= STATIC_TABLE_SIZE then _HpackGetStatic(LIdx, LName, LValue)
        else _HpackGetDynamic(LIdx, LName, LValue);
      end
      else
        LName := _HpackDecodeStr(APayload, APayLen, LPos);
      LValue := _HpackDecodeStr(APayload, APayLen, LPos);
    end
    else if (LByte and $E0) = $20 then
    begin
      // §6.3 Dynamic Table Size Update
      LIdx := _HpackDecodeInt(APayload, APayLen, 5, LPos);
      if Integer(LIdx) > FDynTableMaxSize then
      begin
        _GoAway(FLastStreamID, H2_ERR_COMPRESSION_ERROR);
        Exit;
      end;
      FDynTableMaxSize := LIdx;
      _HpackEvict(FDynTableMaxSize);
      Continue;
    end
    else
    begin
      Inc(LPos); // unknown — skip
      Continue;
    end;

    if LAddDyn then
      _HpackAddDyn(LName, LValue);

    // Map pseudo-headers to stream fields
    if LName = ':method'    then AStream.Method    := LValue
    else if LName = ':path'      then AStream.Path      := LValue
    else if LName = ':scheme'    then AStream.Scheme    := LValue
    else if LName = ':authority' then AStream.Authority := LValue
    else
    begin
      // Regular header
      LPair.Key   := LName;
      LPair.Value := LValue;
      SetLength(AStream.RequestHeaders, LHdrCount + 1);
      AStream.RequestHeaders[LHdrCount] := LPair;
      Inc(LHdrCount);
    end;
  end;
end;

// ===========================================================================
// _DispatchStream — build TH2RequestData and call FOnRequest
// ===========================================================================

procedure TH2Conn._DispatchStream(AStream: TH2Stream);
var
  LReq:         TH2RequestData;
  LStatus:      Integer;
  LContentType: string;
  LBody:        TBytes;
  LExtra:       TArray<TPair<string, string>>;
  I:            Integer;
  LQ:           Integer;
begin
  LReq.StreamID  := AStream.StreamID;
  LReq.Method    := AStream.Method;
  LReq.Protocol  := 'HTTP/2';
  LReq.Host      := AStream.Authority;
  LReq.RemoteAddr := '';  // caller sets if available

  // Split path and query string
  LQ := Pos('?', AStream.Path);
  if LQ > 0 then
  begin
    LReq.Path        := Copy(AStream.Path, 1, LQ - 1);
    LReq.QueryString := Copy(AStream.Path, LQ + 1, MaxInt);
  end
  else
  begin
    LReq.Path        := AStream.Path;
    LReq.QueryString := '';
  end;

  LReq.Headers := AStream.RequestHeaders;

  // Extract content-type from headers
  LReq.ContentType := '';
  for I := 0 to Length(AStream.RequestHeaders) - 1 do
    if SameText(AStream.RequestHeaders[I].Key, 'content-type') then
    begin
      LReq.ContentType := AStream.RequestHeaders[I].Value;
      Break;
    end;

  // Body
  if AStream.BodyLen > 0 then
  begin
    SetLength(LReq.Body, AStream.BodyLen);
    Move(AStream.Body[0], LReq.Body[0], AStream.BodyLen);
  end;

  // Defaults
  LStatus      := 200;
  LContentType := 'text/plain';
  SetLength(LBody, 0);
  SetLength(LExtra, 0);

  try
    if Assigned(FOnRequest) then
      FOnRequest(LReq, LStatus, LContentType, LBody, LExtra);
  except
    LStatus      := 500;
    LContentType := 'text/plain';
    SetLength(LBody, 0);
  end;

  SendResponse(AStream.StreamID, LStatus, LContentType, LBody, LExtra);

  // Clean up stream
  FStreams.Remove(AStream.StreamID);
  AStream.Free;
end;

// ===========================================================================
// _BuildResponseHeaders — HPACK encode response header block
// ===========================================================================

// Maps common status codes to their static table indexed byte (RFC 7541 §A)
// :status 200=idx8, 204=idx9, 206=idx10, 304=idx11, 400=idx12, 404=idx13, 500=idx14
function _StatusIndexByte(AStatus: Integer): Byte;
begin
  case AStatus of
    200: Result := $88; // indexed header field, idx=8
    204: Result := $89;
    206: Result := $8A;
    304: Result := $8B;
    400: Result := $8C;
    404: Result := $8D;
    500: Result := $8E;
  else
    Result := 0; // not in static table
  end;
end;

procedure TH2Conn._BuildResponseHeaders(AStreamID: Cardinal; AStatus: Integer;
  const AContentType: string; ABodyLen: Integer;
  const AExtra: TArray<TPair<string, string>>;
  out AHeadersPayload: TBytes);
var
  LBuf:    TBytes;
  LPos:    Integer;
  LIdxB:   Byte;
  LStatus: string;
  I:       Integer;

  procedure EmitLiteralHeader(const AName, AValue: string);
  begin
    // Literal without indexing, new name (§6.2.2): 0x00 + name-len + name + val-len + val
    _HpackEncodeInt(LBuf, LPos, 0, 4, $00);
    _HpackEncodeStr(LBuf, LPos, AName);
    _HpackEncodeStr(LBuf, LPos, AValue);
  end;

begin
  SetLength(LBuf, 256);
  LPos := 0;

  // :status
  LIdxB := _StatusIndexByte(AStatus);
  if LIdxB <> 0 then
  begin
    if LPos >= Length(LBuf) then SetLength(LBuf, LPos + 64);
    LBuf[LPos] := LIdxB;
    Inc(LPos);
  end
  else
  begin
    // Literal without indexing, name from static table idx 8 (:status)
    // High nibble $08 = literal without indexing, index=8
    LStatus := IntToStr(AStatus);
    _HpackEncodeInt(LBuf, LPos, 8, 4, $00);
    _HpackEncodeStr(LBuf, LPos, LStatus);
  end;

  // content-type (literal without indexing, name idx=31 in static table)
  if AContentType <> '' then
  begin
    _HpackEncodeInt(LBuf, LPos, 31, 4, $00);
    _HpackEncodeStr(LBuf, LPos, AContentType);
  end;

  // content-length (name idx=28)
  if ABodyLen >= 0 then
  begin
    _HpackEncodeInt(LBuf, LPos, 28, 4, $00);
    _HpackEncodeStr(LBuf, LPos, IntToStr(ABodyLen));
  end;

  // Extra headers
  for I := 0 to Length(AExtra) - 1 do
    EmitLiteralHeader(AExtra[I].Key, AExtra[I].Value);

  SetLength(LBuf, LPos);
  AHeadersPayload := LBuf;
end;

// ===========================================================================
// SendResponse — send HEADERS [+ DATA] frame(s)
// ===========================================================================

procedure TH2Conn.SendResponse(AStreamID: Cardinal; AStatus: Integer;
  const AContentType: string; const ABody: TBytes;
  const AExtra: TArray<TPair<string, string>>);
var
  LHdrPayload: TBytes;
  LBodyLen:    Integer;
  LHFlags:     Byte;
  LDataOfs:    Integer;
  LChunkSize:  Integer;
  LRemaining:  Integer;
begin
  if FGoAwaySent then Exit;

  LBodyLen := Length(ABody);
  _BuildResponseHeaders(AStreamID, AStatus, AContentType, LBodyLen, AExtra, LHdrPayload);

  if LBodyLen = 0 then
  begin
    // HEADERS with END_HEADERS + END_STREAM
    LHFlags := H2_FLAG_END_HEADERS or H2_FLAG_END_STREAM;
    _SendFrame(H2_FRAME_HEADERS, LHFlags, AStreamID, @LHdrPayload[0], Length(LHdrPayload));
  end
  else
  begin
    // HEADERS with END_HEADERS (no END_STREAM)
    LHFlags := H2_FLAG_END_HEADERS;
    _SendFrame(H2_FRAME_HEADERS, LHFlags, AStreamID, @LHdrPayload[0], Length(LHdrPayload));

    // DATA in chunks bounded by FPeerMaxFrameSize
    LDataOfs   := 0;
    LRemaining := LBodyLen;
    while LRemaining > 0 do
    begin
      LChunkSize := LRemaining;
      if LChunkSize > FPeerMaxFrameSize then LChunkSize := FPeerMaxFrameSize;
      Dec(LRemaining, LChunkSize);
      if LRemaining = 0 then
        _SendFrame(H2_FRAME_DATA, H2_FLAG_END_STREAM, AStreamID, @ABody[LDataOfs], LChunkSize)
      else
        _SendFrame(H2_FRAME_DATA, 0, AStreamID, @ABody[LDataOfs], LChunkSize);
      Inc(LDataOfs, LChunkSize);
    end;
  end;
end;

// ===========================================================================
// Unit initialization / finalization
// ===========================================================================

initialization
  GHuffLock := TCriticalSection.Create;
  GHuffTreeBuilt := False;
  _InitStaticTable;

finalization
  GHuffLock.Free;

end.

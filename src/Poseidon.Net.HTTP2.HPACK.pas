unit Poseidon.Net.HTTP2.HPACK;

// HPACK (RFC 7541) codec extracted from Poseidon.Net.HTTP2.
// Owns the dynamic table, static table and Huffman tree for one HTTP/2 connection.
//
// Design decisions:
//   - Huffman decode: tree built once at unit initialization (shared via globals)
//   - Huffman encode: NOT used (literals sent as plain, flag = 0)
//   - Dynamic table: owned per TH2HpackCodec instance (one per connection)

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections;

// ---------------------------------------------------------------------------
// Types shared with HTTP2.pas
// ---------------------------------------------------------------------------

type
  TH2DynEntry = record
    Name:  string;
    Value: string;
  end;

  TH2HpackCodec = class
  private
    FDynTable: TArray<TH2DynEntry>;
    FDynTableSize: Integer;
    FDynTableMaxSize: Integer;

    // -----------------------------------------------------------------------
    // HPACK integer codec
    // -----------------------------------------------------------------------
    function  _HpackDecodeInt(ABuf: PByte; ABufLen: Integer; APrefixBits: Byte;
      var APos: Integer): Cardinal;
    procedure _HpackEncodeInt(var ABuf: TBytes; var APos: Integer;
      AValue: Cardinal; APrefixBits: Byte; AHighBits: Byte);

    // -----------------------------------------------------------------------
    // HPACK string codec
    // -----------------------------------------------------------------------
    procedure _HpackHuffmanDecode(ABuf: PByte; ALen: Integer; out AResult: string);
    function  _HpackDecodeStr(ABuf: PByte; ABufLen: Integer;
      var APos: Integer): string;
    procedure _HpackEncodeStr(var ABuf: TBytes; var APos: Integer;
      const AStr: string);

    // -----------------------------------------------------------------------
    // HPACK table access
    // -----------------------------------------------------------------------
    function  _HpackGetStatic(AIdx: Cardinal; out AName, AValue: string): Boolean;
    function  _HpackGetDynamic(AIdx: Cardinal; out AName, AValue: string): Boolean;
    procedure _HpackAddDyn(const AName, AValue: string);

    // -----------------------------------------------------------------------
    // Property setter
    // -----------------------------------------------------------------------
    procedure SetMaxDynTableSize(AValue: Integer);

  public
    constructor Create;
    destructor  Destroy; override;

    // Evict oldest dynamic table entries until table fits AMaxSize bytes.
    procedure _HpackEvict(AMaxSize: Integer);

    // Decode a complete HPACK header block from a HEADERS / CONTINUATION payload.
    // Returns False and calls AOnError if a compression error is detected.
    // On success, fills AMethod/APath/AScheme/AAuthority and AHeaders.
    function DecodeHeaders(ABuf: PByte; ALen: Integer;
      out AMethod, APath, AScheme, AAuthority: string;
      out AHeaders: TArray<TPair<string, string>>;
      AOnGoAway: TProc): Boolean;

    // Encode a response header block into a raw HPACK byte sequence.
    function EncodeResponseHeaders(AStatus: Integer;
      const AContentType: string; ABodyLen: Integer;
      const AExtra: TArray<TPair<string, string>>): TBytes;

    // Encode pseudo-headers for an HTTP/2 PUSH_PROMISE request block.
    // Uses static table indexed entries where possible, literals otherwise.
    function EncodeRequestHeaders(const AMethod, APath, AScheme,
      AAuthority: string): TBytes;

    property MaxDynTableSize: Integer read FDynTableMaxSize write SetMaxDynTableSize;
  end;

// ---------------------------------------------------------------------------
// Constants (also used by HTTP2.pas through the uses clause)
// ---------------------------------------------------------------------------

const
  STATIC_TABLE_SIZE = 61;

implementation

const
  CDefaultDynTableMaxSize = 4096;   // RFC 7541 default
  CHuffTreeInitSize = 8192;

// ===========================================================================
// Huffman decode tree — built once at unit initialization
// ===========================================================================

type
  TH2HuffNode = record
    Children: array[0..1] of Integer; // -1 = absent
    Symbol: Integer;                  // -1 = internal; 0-255 = byte; 256 = EOS
  end;

  THuffEntry = record Code: Cardinal; Bits: Byte; end;

  TStaticEntry = record Name, Value: string; end;

var
  GHuffTree: array of TH2HuffNode;
  GHuffTreeBuilt: Boolean = False;
  GHuffLock: TCriticalSection;
  GStaticTable: array[1..STATIC_TABLE_SIZE] of TStaticEntry;

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

// ---------------------------------------------------------------------------
// Internal: build Huffman decode tree
// ---------------------------------------------------------------------------

procedure _BuildHuffTree;
var
  LNodeCount: Integer;
  LEntry: THuffEntry;
  I, B: Integer;
  LNode: Integer;
  LBit: Integer;
  LChild: Integer;
begin
  SetLength(GHuffTree, CHuffTreeInitSize);
  LNodeCount := 1;
  GHuffTree[0].Children[0] := -1;
  GHuffTree[0].Children[1] := -1;
  GHuffTree[0].Symbol       := -1;

  for I := 0 to 256 do
  begin
    LEntry := HUFF_TABLE[I];
    LNode := 0;
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

// ---------------------------------------------------------------------------
// Internal: populate RFC 7541 Appendix A static table
// ---------------------------------------------------------------------------

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
// Helper: map common status codes to static-table indexed byte
// ===========================================================================

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

// ===========================================================================
// TH2HpackCodec
// ===========================================================================

constructor TH2HpackCodec.Create;
begin
  inherited Create;
  SetLength(FDynTable, 0);
  FDynTableSize := 0;
  FDynTableMaxSize := CDefaultDynTableMaxSize;

  // Ensure shared Huffman tree is built
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

destructor TH2HpackCodec.Destroy;
begin
  SetLength(FDynTable, 0);
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// Property setter
// ---------------------------------------------------------------------------

procedure TH2HpackCodec.SetMaxDynTableSize(AValue: Integer);
begin
  FDynTableMaxSize := AValue;
  _HpackEvict(FDynTableMaxSize);
end;

// ===========================================================================
// HPACK integer codec
// ===========================================================================

function TH2HpackCodec._HpackDecodeInt(ABuf: PByte; ABufLen: Integer;
  APrefixBits: Byte; var APos: Integer): Cardinal;
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

procedure TH2HpackCodec._HpackEncodeInt(var ABuf: TBytes; var APos: Integer;
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

procedure TH2HpackCodec._HpackHuffmanDecode(ABuf: PByte; ALen: Integer;
  out AResult: string);
var
  LBytes: TBytes;
  LBLen: Integer;
  LNode: Integer;
  I, B: Integer;
  LBit: Integer;
  LChild: Integer;
  LSym: Integer;
begin
  SetLength(LBytes, ALen * 2); // upper bound
  LBLen := 0;
  LNode := 0;
  for I := 0 to ALen - 1 do
  begin
    for B := 7 downto 0 do
    begin
      LBit := (ABuf[I] shr B) and 1;
      LChild := GHuffTree[LNode].Children[LBit];
      if LChild = -1 then Break; // padding or invalid — stop
      LNode := LChild;
      LSym := GHuffTree[LNode].Symbol;
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

function TH2HpackCodec._HpackDecodeStr(ABuf: PByte; ABufLen: Integer;
  var APos: Integer): string;
var
  LHuffman: Boolean;
  LLen: Cardinal;
  LRaw: PByte;
  LSlice: TBytes;
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

procedure TH2HpackCodec._HpackEncodeStr(var ABuf: TBytes; var APos: Integer;
  const AStr: string);
var
  LEncoded: TBytes;
  LLen: Integer;
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

function TH2HpackCodec._HpackGetStatic(AIdx: Cardinal;
  out AName, AValue: string): Boolean;
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

function TH2HpackCodec._HpackGetDynamic(AIdx: Cardinal;
  out AName, AValue: string): Boolean;
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

procedure TH2HpackCodec._HpackEvict(AMaxSize: Integer);
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

procedure TH2HpackCodec._HpackAddDyn(const AName, AValue: string);
var
  LEntrySize: Integer;
  LLen: Integer;
  J: Integer;
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
  for J := LLen downto 1 do
    FDynTable[J] := FDynTable[J - 1];
  FDynTable[0].Name  := AName;
  FDynTable[0].Value := AValue;
  Inc(FDynTableSize, LEntrySize);
end;

// ===========================================================================
// DecodeHeaders — full HPACK header block decode
// ===========================================================================

function TH2HpackCodec.DecodeHeaders(ABuf: PByte; ALen: Integer;
  out AMethod, APath, AScheme, AAuthority: string;
  out AHeaders: TArray<TPair<string, string>>;
  AOnGoAway: TProc): Boolean;
var
  LPos: Integer;
  LByte: Byte;
  LIdx: Cardinal;
  LName: string;
  LValue: string;
  LNameOnly: Boolean;
  LAddDyn: Boolean;
  LPrefixBits: Byte;
  LHdrCount: Integer;
  LPair: TPair<string, string>;
begin
  Result := True;
  LPos := 0;
  LHdrCount := 0;
  AMethod := '';
  APath := '';
  AScheme := '';
  AAuthority := '';
  SetLength(AHeaders, 0);

  while LPos < ALen do
  begin
    LByte := ABuf[LPos];

    if (LByte and $80) <> 0 then
    begin
      // §6.1 Indexed Header Field Representation
      LIdx := _HpackDecodeInt(ABuf, ALen, 7, LPos);
      if LIdx = 0 then
      begin
        if Assigned(AOnGoAway) then AOnGoAway;
        Result := False;
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
      LIdx := _HpackDecodeInt(ABuf, ALen, LPrefixBits, LPos);
      LAddDyn := True;
      LNameOnly := (LIdx = 0);
      if not LNameOnly then
      begin
        if LIdx <= STATIC_TABLE_SIZE then _HpackGetStatic(LIdx, LName, LValue)
        else _HpackGetDynamic(LIdx, LName, LValue);
      end
      else
        LName := _HpackDecodeStr(ABuf, ALen, LPos);
      LValue := _HpackDecodeStr(ABuf, ALen, LPos);
    end
    else if (LByte and $F0) = $10 then
    begin
      // §6.2.3 Literal Never Indexed
      LPrefixBits := 4;
      LIdx := _HpackDecodeInt(ABuf, ALen, LPrefixBits, LPos);
      LAddDyn := False;
      LNameOnly := (LIdx = 0);
      if not LNameOnly then
      begin
        if LIdx <= STATIC_TABLE_SIZE then _HpackGetStatic(LIdx, LName, LValue)
        else _HpackGetDynamic(LIdx, LName, LValue);
      end
      else
        LName := _HpackDecodeStr(ABuf, ALen, LPos);
      LValue := _HpackDecodeStr(ABuf, ALen, LPos);
    end
    else if (LByte and $F0) = $00 then
    begin
      // §6.2.2 Literal without Indexing
      LPrefixBits := 4;
      LIdx := _HpackDecodeInt(ABuf, ALen, LPrefixBits, LPos);
      LAddDyn := False;
      LNameOnly := (LIdx = 0);
      if not LNameOnly then
      begin
        if LIdx <= STATIC_TABLE_SIZE then _HpackGetStatic(LIdx, LName, LValue)
        else _HpackGetDynamic(LIdx, LName, LValue);
      end
      else
        LName := _HpackDecodeStr(ABuf, ALen, LPos);
      LValue := _HpackDecodeStr(ABuf, ALen, LPos);
    end
    else if (LByte and $E0) = $20 then
    begin
      // §6.3 Dynamic Table Size Update
      LIdx := _HpackDecodeInt(ABuf, ALen, 5, LPos);
      if Integer(LIdx) > FDynTableMaxSize then
      begin
        if Assigned(AOnGoAway) then AOnGoAway;
        Result := False;
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

    // Map pseudo-headers
    if LName = ':method'    then AMethod    := LValue
    else if LName = ':path'      then APath      := LValue
    else if LName = ':scheme'    then AScheme    := LValue
    else if LName = ':authority' then AAuthority := LValue
    else
    begin
      LPair.Key := LName;
      LPair.Value := LValue;
      SetLength(AHeaders, LHdrCount + 1);
      AHeaders[LHdrCount] := LPair;
      Inc(LHdrCount);
    end;
  end;
end;

// ===========================================================================
// EncodeResponseHeaders — HPACK encode response header block
// ===========================================================================

function TH2HpackCodec.EncodeResponseHeaders(AStatus: Integer;
  const AContentType: string; ABodyLen: Integer;
  const AExtra: TArray<TPair<string, string>>): TBytes;
var
  LBuf: TBytes;
  LPos: Integer;
  LIdxB: Byte;
  LStatus: string;
  I: Integer;

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
  Result := LBuf;
end;

// ===========================================================================
// EncodeRequestHeaders — HPACK block for PUSH_PROMISE frames
// ===========================================================================

function TH2HpackCodec.EncodeRequestHeaders(const AMethod, APath, AScheme,
  AAuthority: string): TBytes;
// Encodes :method, :path, :scheme, :authority using static-table indices where
// possible and literal-without-indexing otherwise.
// Static table entries used:
//   2  = :method: GET    3  = :method: POST
//   4  = :path: /        6  = :scheme: http    7  = :scheme: https
//   1  = :authority (name only)
var
  LBuf: TBytes;
  LPos: Integer;
begin
  SetLength(LBuf, 128);
  LPos := 0;

  // :method
  if AMethod = 'GET' then
  begin
    LBuf[LPos] := $82;  // indexed: index 2 = :method: GET
    Inc(LPos);
  end
  else if AMethod = 'POST' then
  begin
    LBuf[LPos] := $83;  // indexed: index 3 = :method: POST
    Inc(LPos);
  end
  else
  begin
    // Literal without indexing, new name
    _HpackEncodeInt(LBuf, LPos, 0, 4, $00);
    _HpackEncodeStr(LBuf, LPos, ':method');
    _HpackEncodeStr(LBuf, LPos, AMethod);
  end;

  // :path
  if APath = '/' then
  begin
    LBuf[LPos] := $84;  // indexed: index 4 = :path: /
    Inc(LPos);
  end
  else
  begin
    // Literal without indexing, name from static table index 4 (:path)
    _HpackEncodeInt(LBuf, LPos, 4, 4, $00);
    _HpackEncodeStr(LBuf, LPos, APath);
  end;

  // :scheme
  if AScheme = 'http' then
  begin
    LBuf[LPos] := $86;  // indexed: index 6 = :scheme: http
    Inc(LPos);
  end
  else
  begin
    // Literal without indexing, name from static table index 6 (:scheme) + value
    // (covers 'https' and other schemes)
    _HpackEncodeInt(LBuf, LPos, 6, 4, $00);
    _HpackEncodeStr(LBuf, LPos, AScheme);
  end;

  // :authority — literal without indexing, name from static table index 1
  if AAuthority <> '' then
  begin
    _HpackEncodeInt(LBuf, LPos, 1, 4, $00);
    _HpackEncodeStr(LBuf, LPos, AAuthority);
  end;

  SetLength(LBuf, LPos);
  Result := LBuf;
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

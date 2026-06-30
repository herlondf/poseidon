unit Poseidon.Multipart;

// Multipart/form-data parser (RFC 7578).
// Operates on the assembled request body (after chunked/Content-Length decoding).
//
// Usage:
//   var LBoundary := TMultipartParser.ExtractBoundary(Req.ContentType);
//   var LParts    := TMultipartParser.Parse(Req.RawBody, LBoundary);
//   for var LPart in LParts do
//     if LPart.FileName <> '' then ... else ...;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections;

type
  TMultipartPart = record
    Name:        string;
    FileName:    string;
    ContentType: string;
    Data:        TBytes;
    Headers:     TArray<TPair<string,string>>;
  end;

  TMultipartParser = class
  private
    class function BytesIndexOf(const AHaystack: TBytes; AFrom: Integer;
      const ANeedle: TBytes): Integer;
    class procedure ParseHeaders(const AHdr: TBytes; var APart: TMultipartPart);
    class function StripQuotes(const AValue: string): string;
  public
    class function ExtractBoundary(const AContentType: string): string;
    class function Parse(const ABody: TBytes;
      const ABoundary: string): TArray<TMultipartPart>;
  end;

implementation

class function TMultipartParser.BytesIndexOf(const AHaystack: TBytes;
  AFrom: Integer; const ANeedle: TBytes): Integer;
var
  I, J, LHL, LNL: Integer;
begin
  Result := -1;
  LHL := Length(AHaystack);
  LNL := Length(ANeedle);
  if LNL = 0 then begin Result := AFrom; Exit; end;
  if AFrom < 0 then AFrom := 0;
  for I := AFrom to LHL - LNL do
  begin
    J := 0;
    while (J < LNL) and (AHaystack[I + J] = ANeedle[J]) do
      Inc(J);
    if J = LNL then begin Result := I; Exit; end;
  end;
end;

class function TMultipartParser.StripQuotes(const AValue: string): string;
begin
  Result := Trim(AValue);
  if (Length(Result) >= 2) and (Result[1] = '"') and (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

class procedure TMultipartParser.ParseHeaders(const AHdr: TBytes;
  var APart: TMultipartPart);
var
  LData:   string;
  LLines:  TArray<string>;
  LLine:   string;
  LColon:  Integer;
  LName:   string;
  LValue:  string;
  LSemi:   Integer;
  LParams: TArray<string>;
  LParam:  string;
  LTrim:   string;
  LCount:  Integer;
begin
  APart.Name        := '';
  APart.FileName    := '';
  APart.ContentType := 'text/plain';
  SetLength(APart.Headers, 0);
  LCount := 0;

  LData  := TEncoding.UTF8.GetString(AHdr);
  LLines := LData.Split([#13#10]);

  for LLine in LLines do
  begin
    if LLine.IsEmpty then Continue;
    LColon := Pos(':', LLine);
    if LColon <= 0 then Continue;
    LName  := Trim(Copy(LLine, 1, LColon - 1));
    LValue := Trim(Copy(LLine, LColon + 1, MaxInt));

    SetLength(APart.Headers, LCount + 1);
    APart.Headers[LCount].Key   := LName;
    APart.Headers[LCount].Value := LValue;
    Inc(LCount);

    if SameText(LName, 'Content-Type') then
    begin
      LSemi := Pos(';', LValue);
      if LSemi > 0 then
        APart.ContentType := Trim(Copy(LValue, 1, LSemi - 1))
      else
        APart.ContentType := Trim(LValue);
    end
    else if SameText(LName, 'Content-Disposition') then
    begin
      LParams := LValue.Split([';']);
      for LParam in LParams do
      begin
        LTrim := Trim(LParam);
        if LTrim.ToLower.StartsWith('name=') then
          APart.Name := StripQuotes(Copy(LTrim, 6, MaxInt))
        else if LTrim.ToLower.StartsWith('filename=') then
          APart.FileName := StripQuotes(Copy(LTrim, 10, MaxInt));
      end;
    end;
  end;
end;

class function TMultipartParser.ExtractBoundary(const AContentType: string): string;
const
  PREFIX = 'boundary=';
var
  LParts: TArray<string>;
  LP:     string;
  LT:     string;
begin
  Result := '';
  if AContentType.IsEmpty then Exit;
  LParts := AContentType.Split([';']);
  for LP in LParts do
  begin
    LT := Trim(LP);
    if LT.ToLower.StartsWith(PREFIX) then
    begin
      Result := StripQuotes(Copy(LT, Length(PREFIX) + 1, MaxInt));
      Exit;
    end;
  end;
end;

class function TMultipartParser.Parse(const ABody: TBytes;
  const ABoundary: string): TArray<TMultipartPart>;
var
  LFirst:  TBytes;  // --boundary
  LDelim:  TBytes;  // \r\n--boundary
  LPos, LNext: Integer;
  LHdrEnd: Integer;
  LPart:   TMultipartPart;
  LCount:  Integer;
  LHdr:    TBytes;
  LHdrLen: Integer;
  LDataStart, LDataLen: Integer;
  LBodyLen: Integer;
  I: Integer;
begin
  SetLength(Result, 0);
  LCount   := 0;
  LBodyLen := Length(ABody);
  if ABoundary.IsEmpty or (LBodyLen = 0) then Exit;

  LFirst := TEncoding.ASCII.GetBytes('--' + ABoundary);
  LDelim := TEncoding.ASCII.GetBytes(#13#10 + '--' + ABoundary);

  LPos := BytesIndexOf(ABody, 0, LFirst);
  if LPos < 0 then Exit;
  Inc(LPos, Length(LFirst));

  // Expect terminator or CRLF after first boundary
  if (LPos + 1 < LBodyLen) and (ABody[LPos] = $2D) and (ABody[LPos + 1] = $2D) then
    Exit;  // immediately terminated, no parts
  if (LPos + 1 < LBodyLen) and (ABody[LPos] = $0D) and (ABody[LPos + 1] = $0A) then
    Inc(LPos, 2)
  else
    Exit;  // malformed

  while LPos < LBodyLen do
  begin
    LHdrEnd := -1;
    I := LPos;
    while I <= LBodyLen - 4 do
    begin
      if (ABody[I] = $0D) and (ABody[I + 1] = $0A) and
         (ABody[I + 2] = $0D) and (ABody[I + 3] = $0A) then
      begin
        LHdrEnd := I;
        Break;
      end;
      Inc(I);
    end;
    if LHdrEnd < 0 then Break;

    LHdrLen := LHdrEnd - LPos;
    SetLength(LHdr, LHdrLen);
    if LHdrLen > 0 then Move(ABody[LPos], LHdr[0], LHdrLen);
    ParseHeaders(LHdr, LPart);

    LDataStart := LHdrEnd + 4;
    LNext := BytesIndexOf(ABody, LDataStart, LDelim);
    if LNext < 0 then Break;

    LDataLen := LNext - LDataStart;
    SetLength(LPart.Data, LDataLen);
    if LDataLen > 0 then Move(ABody[LDataStart], LPart.Data[0], LDataLen);

    SetLength(Result, LCount + 1);
    Result[LCount] := LPart;
    Inc(LCount);

    LPos := LNext + Length(LDelim);

    if LPos + 1 < LBodyLen then
    begin
      if (ABody[LPos] = $2D) and (ABody[LPos + 1] = $2D) then
        Break;  // terminator --boundary--
      if (ABody[LPos] = $0D) and (ABody[LPos + 1] = $0A) then
        Inc(LPos, 2)
      else
        Break;
    end
    else
      Break;
  end;
end;

end.

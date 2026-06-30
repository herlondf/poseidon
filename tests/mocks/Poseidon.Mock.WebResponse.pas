unit Poseidon.Mock.WebResponse;

// Minimal concrete TWebResponse for unit testing.
// TWebResponse (Delphi 11) exposes indexed properties via GetStringVariable/
// SetStringVariable (virtual abstract). ContentType=index 8, Location=index 6.
// SetCustomHeader, SetCookieField are concrete (NOT virtual) — base handles them.
// FreeContentStream and ContentLength are plain field/indexed properties — no
// separate virtual getters exist for them in TWebResponse.

interface

uses
  System.SysUtils,
  System.Classes,
  Web.HTTPApp;

type
  TMockWebResponse = class(TWebResponse)
  private
    FContent: string;
    FStatusCode: Integer;
    FLogMessage: string;
    FStrings: array[0..15] of string;
    FIntegers: array[0..5] of Int64;
    FDates: array[0..5] of TDateTime;
    FResponseSent: Boolean;
  protected
    function GetStringVariable(Index: Integer): string; override;
    procedure SetStringVariable(Index: Integer; const Value: string); override;
    function GetDateVariable(Index: Integer): TDateTime; override;
    procedure SetDateVariable(Index: Integer; const Value: TDateTime); override;
    function GetIntegerVariable(Index: Integer): Int64; override;
    procedure SetIntegerVariable(Index: Integer; Value: Int64); override;
    function GetContent: string; override;
    procedure SetContent(const Value: string); override;
    function GetStatusCode: Integer; override;
    procedure SetStatusCode(Value: Integer); override;
    function GetLogMessage: string; override;
    procedure SetLogMessage(const Value: string); override;
  public
    constructor Create(ARequest: TWebRequest); reintroduce;
    procedure SendResponse; override;
    procedure SendRedirect(const URI: string); override;

    // Test assertions — read these in test fixtures
    property SentContent: string read FContent;
    property SentStatusCode: Integer read FStatusCode;
    property SentContentType: string index 8 read GetStringVariable;
    property SentHeaders: TStrings read FCustomHeaders; // inherited protected field
    property ResponseSent: Boolean read FResponseSent;
  end;

implementation

constructor TMockWebResponse.Create(ARequest: TWebRequest);
begin
  inherited Create(ARequest); // initializes FCustomHeaders, FCookies
  FStatusCode := 200;
  FStrings[8] := 'application/json'; // ContentType default
end;

function TMockWebResponse.GetStringVariable(Index: Integer): string;
begin
  if (Index >= Low(FStrings)) and (Index <= High(FStrings)) then
    Result := FStrings[Index]
  else
    Result := '';
end;

procedure TMockWebResponse.SetStringVariable(Index: Integer; const Value: string);
begin
  if (Index >= Low(FStrings)) and (Index <= High(FStrings)) then
    FStrings[Index] := Value;
end;

function TMockWebResponse.GetDateVariable(Index: Integer): TDateTime;
begin
  if (Index >= Low(FDates)) and (Index <= High(FDates)) then
    Result := FDates[Index]
  else
    Result := 0;
end;

procedure TMockWebResponse.SetDateVariable(Index: Integer; const Value: TDateTime);
begin
  if (Index >= Low(FDates)) and (Index <= High(FDates)) then
    FDates[Index] := Value;
end;

function TMockWebResponse.GetIntegerVariable(Index: Integer): Int64;
begin
  if (Index >= Low(FIntegers)) and (Index <= High(FIntegers)) then
    Result := FIntegers[Index]
  else
    Result := 0;
end;

procedure TMockWebResponse.SetIntegerVariable(Index: Integer; Value: Int64);
begin
  if (Index >= Low(FIntegers)) and (Index <= High(FIntegers)) then
    FIntegers[Index] := Value;
end;

function TMockWebResponse.GetContent: string;
begin Result := FContent; end;

procedure TMockWebResponse.SetContent(const Value: string);
begin FContent := Value; end;

function TMockWebResponse.GetStatusCode: Integer;
begin Result := FStatusCode; end;

procedure TMockWebResponse.SetStatusCode(Value: Integer);
begin FStatusCode := Value; end;

function TMockWebResponse.GetLogMessage: string;
begin Result := FLogMessage; end;

procedure TMockWebResponse.SetLogMessage(const Value: string);
begin FLogMessage := Value; end;

procedure TMockWebResponse.SendResponse;
begin FResponseSent := True; end;

procedure TMockWebResponse.SendRedirect(const URI: string);
begin
  FStatusCode := 303;
  FCustomHeaders.Values['Location'] := URI;
  FResponseSent := True;
end;

end.

unit Poseidon.Validation;

interface

uses
  System.SysUtils,
  System.RTTI,
  System.TypInfo,
  System.RegularExpressions;

type
  // Base attribute — all validation attributes extend this
  PoseidonValidationAttribute = class(TCustomAttribute)
  public
    function Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean; virtual; abstract;
  end;

  // Field is mandatory — string non-empty, object non-nil
  RequiredAttribute = class(PoseidonValidationAttribute)
  public
    function Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean; override;
  end;

  // String must have at least N characters
  MinLengthAttribute = class(PoseidonValidationAttribute)
  private
    FMin: Integer;
  public
    constructor Create(AMin: Integer);
    function Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean; override;
  end;

  // String must have at most N characters
  MaxLengthAttribute = class(PoseidonValidationAttribute)
  private
    FMax: Integer;
  public
    constructor Create(AMax: Integer);
    function Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean; override;
  end;

  // String must match a basic email pattern
  EmailAttribute = class(PoseidonValidationAttribute)
  public
    function Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean; override;
  end;

  // Numeric value must be between Min and Max (inclusive)
  RangeAttribute = class(PoseidonValidationAttribute)
  private
    FMin, FMax: Double;
  public
    constructor Create(AMin, AMax: Double);
    function Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean; override;
  end;

  // String must match a custom regular expression
  PatternAttribute = class(PoseidonValidationAttribute)
  private
    FPattern: string;
    FMessage: string;
  public
    constructor Create(const APattern: string; const AMessage: string = '');
    function Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean; override;
  end;

  TPoseidonValidationError = record
    Field: string;
    Message: string;
  end;

  TPoseidonValidator = class
  public
    // Validates all fields with PoseidonValidationAttribute on AObject.
    // Returns True if valid. On failure, AErrors contains all violations.
    class function Validate(AObject: TObject; out AErrors: TArray<TPoseidonValidationError>): Boolean;

    // Same as Validate but raises EPoseidonValidation on first error
    class procedure ValidateOrRaise(AObject: TObject);
  end;

implementation

uses
  Poseidon.Exception;

{ RequiredAttribute }

function RequiredAttribute.Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean;
begin
  Result := True;
  case AValue.Kind of
    tkUString, tkString, tkLString, tkWString:
      Result := not AValue.AsString.IsEmpty;
    tkClass:
      Result := not AValue.IsEmpty and (AValue.AsObject <> nil);
    tkInteger, tkInt64, tkFloat:
      Result := True; // numeric 0 is valid
  end;
  if not Result then
    AError := Format('"%s" is required', [AFieldName]);
end;

{ MinLengthAttribute }

constructor MinLengthAttribute.Create(AMin: Integer);
begin
  inherited Create;
  FMin := AMin;
end;

function MinLengthAttribute.Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean;
var
  LStr: string;
begin
  LStr := AValue.ToString;
  Result := Length(LStr) >= FMin;
  if not Result then
    AError := Format('"%s" must be at least %d characters', [AFieldName, FMin]);
end;

{ MaxLengthAttribute }

constructor MaxLengthAttribute.Create(AMax: Integer);
begin
  inherited Create;
  FMax := AMax;
end;

function MaxLengthAttribute.Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean;
var
  LStr: string;
begin
  LStr := AValue.ToString;
  Result := Length(LStr) <= FMax;
  if not Result then
    AError := Format('"%s" must be at most %d characters', [AFieldName, FMax]);
end;

{ EmailAttribute }

function EmailAttribute.Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean;
const
  EMAIL_PATTERN = '^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$';
begin
  Result := TRegEx.IsMatch(AValue.ToString, EMAIL_PATTERN);
  if not Result then
    AError := Format('"%s" must be a valid email address', [AFieldName]);
end;

{ RangeAttribute }

constructor RangeAttribute.Create(AMin, AMax: Double);
begin
  inherited Create;
  FMin := AMin;
  FMax := AMax;
end;

function RangeAttribute.Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean;
var
  LNum: Double;
begin
  LNum := AValue.AsExtended;
  Result := (LNum >= FMin) and (LNum <= FMax);
  if not Result then
    AError := Format('"%s" must be between %g and %g', [AFieldName, FMin, FMax]);
end;

{ PatternAttribute }

constructor PatternAttribute.Create(const APattern, AMessage: string);
begin
  inherited Create;
  FPattern := APattern;
  FMessage := AMessage;
end;

function PatternAttribute.Validate(const AValue: TValue; const AFieldName: string; out AError: string): Boolean;
begin
  Result := TRegEx.IsMatch(AValue.ToString, FPattern);
  if not Result then
  begin
    if FMessage.IsEmpty then
      AError := Format('"%s" does not match the required pattern', [AFieldName])
    else
      AError := FMessage;
  end;
end;

{ TPoseidonValidator }

class function TPoseidonValidator.Validate(AObject: TObject; out AErrors: TArray<TPoseidonValidationError>): Boolean;
var
  LCtx: TRttiContext;
  LType: TRttiType;
  LField: TRttiField;
  LAttr: TCustomAttribute;
  LValue: TValue;
  LError: string;
  LErrors: TArray<TPoseidonValidationError>;
  LEntry: TPoseidonValidationError;
begin
  LCtx := TRttiContext.Create;
  try
    LType := LCtx.GetType(AObject.ClassType);
    LErrors := [];

    for LField in LType.GetFields do
    begin
      LValue := LField.GetValue(AObject);
      for LAttr in LField.GetAttributes do
      begin
        if LAttr is PoseidonValidationAttribute then
        begin
          LError := '';
          if not PoseidonValidationAttribute(LAttr).Validate(LValue, LField.Name, LError) then
          begin
            LEntry.Field := LField.Name;
            LEntry.Message := LError;
            LErrors := LErrors + [LEntry];
          end;
        end;
      end;
    end;

    AErrors := LErrors;
    Result := Length(LErrors) = 0;
  finally
    LCtx.Free;
  end;
end;

class procedure TPoseidonValidator.ValidateOrRaise(AObject: TObject);
var
  LErrors: TArray<TPoseidonValidationError>;
  LMessages: TArray<string>;
  LErr: TPoseidonValidationError;
begin
  if not Validate(AObject, LErrors) then
  begin
    LMessages := [];
    for LErr in LErrors do
      LMessages := LMessages + [LErr.Message];
    raise EPoseidonValidation.Create(string.Join('; ', LMessages));
  end;
end;

end.

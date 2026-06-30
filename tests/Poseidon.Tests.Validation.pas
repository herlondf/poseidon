unit Poseidon.Tests.Validation;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Validation,
  Poseidon.Exception;

type
  TValidationDTO = class
    [Required]
    Name: string;
    [MinLength(5)]
    Username: string;
    [MaxLength(10)]
    Code: string;
    [Email]
    Email: string;
    [Range(1, 100)]
    Age: Integer;
    [Pattern('^[A-Z]{3}$', 'Must be 3 uppercase letters')]
    Country: string;
  end;

  [TestFixture]
  TPoseidonValidationTests = class
  private
    FDTO: TValidationDTO;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Required_MissingField_ReturnsError;
    [Test]
    procedure Required_FilledField_NoError;
    [Test]
    procedure MinLength_TooShort_ReturnsError;
    [Test]
    procedure MinLength_ExactLength_NoError;
    [Test]
    procedure MaxLength_TooLong_ReturnsError;
    [Test]
    procedure MaxLength_ExactLength_NoError;
    [Test]
    procedure Email_Invalid_ReturnsError;
    [Test]
    procedure Email_Valid_NoError;
    [Test]
    procedure Range_BelowMin_ReturnsError;
    [Test]
    procedure Range_AboveMax_ReturnsError;
    [Test]
    procedure Range_InRange_NoError;
    [Test]
    procedure Pattern_NoMatch_ReturnsError;
    [Test]
    procedure Pattern_Match_NoError;
    [Test]
    procedure MultipleErrors_AllReturned;
    [Test]
    procedure ValidateOrRaise_Invalid_RaisesEPoseidonValidation;
    [Test]
    procedure ValidateOrRaise_Valid_DoesNotRaise;
  end;

implementation

procedure TPoseidonValidationTests.Setup;
begin
  FDTO := TValidationDTO.Create;
end;

procedure TPoseidonValidationTests.TearDown;
begin
  FDTO.Free;
end;

procedure TPoseidonValidationTests.Required_MissingField_ReturnsError;
var
  LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := '';
  Assert.IsFalse(TPoseidonValidator.Validate(FDTO, LErrors));
  Assert.IsTrue(Length(LErrors) > 0);
  Assert.AreEqual('Name', LErrors[0].Field);
end;

procedure TPoseidonValidationTests.Required_FilledField_NoError;
var
  LErrors: TArray<TPoseidonValidationError>;
  LOrigErrors: Integer;
begin
  FDTO.Name := 'Alice';
  FDTO.Username := 'alice1';
  FDTO.Email := 'alice@example.com';
  FDTO.Age := 30;
  FDTO.Country := 'BRA';
  TPoseidonValidator.Validate(FDTO, LErrors);
  // No Required error for Name when filled
  var LHasNameError := False;
  for var E in LErrors do
    if E.Field = 'Name' then
      LHasNameError := True;
  Assert.IsFalse(LHasNameError);
end;

procedure TPoseidonValidationTests.MinLength_TooShort_ReturnsError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Username := 'ab';  // min 5
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Username' then LHasError := True;
  Assert.IsTrue(LHasError);
end;

procedure TPoseidonValidationTests.MinLength_ExactLength_NoError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Username := 'abcde';  // exactly 5
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Username' then LHasError := True;
  Assert.IsFalse(LHasError);
end;

procedure TPoseidonValidationTests.MaxLength_TooLong_ReturnsError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Code := '12345678901';  // 11 chars, max 10
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Code' then LHasError := True;
  Assert.IsTrue(LHasError);
end;

procedure TPoseidonValidationTests.MaxLength_ExactLength_NoError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Code := '1234567890';  // exactly 10
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Code' then LHasError := True;
  Assert.IsFalse(LHasError);
end;

procedure TPoseidonValidationTests.Email_Invalid_ReturnsError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Email := 'not-an-email';
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Email' then LHasError := True;
  Assert.IsTrue(LHasError);
end;

procedure TPoseidonValidationTests.Email_Valid_NoError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Email := 'test@domain.com';
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Email' then LHasError := True;
  Assert.IsFalse(LHasError);
end;

procedure TPoseidonValidationTests.Range_BelowMin_ReturnsError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Age := 0;  // min 1
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Age' then LHasError := True;
  Assert.IsTrue(LHasError);
end;

procedure TPoseidonValidationTests.Range_AboveMax_ReturnsError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Age := 101;  // max 100
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Age' then LHasError := True;
  Assert.IsTrue(LHasError);
end;

procedure TPoseidonValidationTests.Range_InRange_NoError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Age := 50;
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Age' then LHasError := True;
  Assert.IsFalse(LHasError);
end;

procedure TPoseidonValidationTests.Pattern_NoMatch_ReturnsError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Country := 'br';  // must be ^[A-Z]{3}$
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Country' then LHasError := True;
  Assert.IsTrue(LHasError);
end;

procedure TPoseidonValidationTests.Pattern_Match_NoError;
var LErrors: TArray<TPoseidonValidationError>;
begin
  FDTO.Name := 'x';
  FDTO.Country := 'BRA';
  TPoseidonValidator.Validate(FDTO, LErrors);
  var LHasError := False;
  for var E in LErrors do
    if E.Field = 'Country' then LHasError := True;
  Assert.IsFalse(LHasError);
end;

procedure TPoseidonValidationTests.MultipleErrors_AllReturned;
var LErrors: TArray<TPoseidonValidationError>;
begin
  // Name empty (Required), Email invalid
  FDTO.Name  := '';
  FDTO.Email := 'invalid';
  TPoseidonValidator.Validate(FDTO, LErrors);
  Assert.IsTrue(Length(LErrors) >= 2);
end;

procedure TPoseidonValidationTests.ValidateOrRaise_Invalid_RaisesEPoseidonValidation;
begin
  FDTO.Name := '';
  Assert.WillRaise(
    procedure begin TPoseidonValidator.ValidateOrRaise(FDTO); end,
    EPoseidonValidation);
end;

procedure TPoseidonValidationTests.ValidateOrRaise_Valid_DoesNotRaise;
begin
  FDTO.Name    := 'Alice';
  FDTO.Username := 'alice1';
  FDTO.Code    := 'ABC';
  FDTO.Email   := 'alice@example.com';
  FDTO.Age     := 30;
  FDTO.Country := 'BRA';
  Assert.WillNotRaiseAny(
    procedure begin TPoseidonValidator.ValidateOrRaise(FDTO); end);
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonValidationTests);

end.

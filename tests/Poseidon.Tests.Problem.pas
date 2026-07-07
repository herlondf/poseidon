unit Poseidon.Tests.Problem;

interface

uses
  DUnitX.TestFramework,
  System.JSON,
  Poseidon.Problem,
  Poseidon.Exception,
  Poseidon.Status;

type
  [TestFixture]
  TPoseidonProblemTests = class
  public
    [Test]
    procedure FromException_MapsStatusCode;
    [Test]
    procedure FromException_404_TitleIsNotFound;
    [Test]
    procedure ToJSON_HasAllRequiredFields;
    [Test]
    procedure FromException_500_TitleIsInternalServerError;
  end;

implementation

{ TPoseidonProblemTests }

procedure TPoseidonProblemTests.FromException_MapsStatusCode;
var
  LEx: EPoseidonException;
  LProblem: TProblemDetail;
begin
  LEx := EPoseidonException.Create('Resource not found', THTTPStatus.NotFound);
  try
    LProblem := TProblemDetail.FromException(LEx, '/items/42');
    Assert.AreEqual(404, LProblem.Status);
  finally
    LEx.Free;
  end;
end;

procedure TPoseidonProblemTests.FromException_404_TitleIsNotFound;
var
  LEx: EPoseidonException;
  LProblem: TProblemDetail;
begin
  LEx := EPoseidonException.Create('Resource not found', THTTPStatus.NotFound);
  try
    LProblem := TProblemDetail.FromException(LEx, '/items/42');
    Assert.AreEqual('Not Found', LProblem.Title);
  finally
    LEx.Free;
  end;
end;

procedure TPoseidonProblemTests.ToJSON_HasAllRequiredFields;
var
  LEx: EPoseidonException;
  LProblem: TProblemDetail;
  LJSON: TJSONObject;
begin
  LEx := EPoseidonException.Create('Resource not found', THTTPStatus.NotFound);
  try
    LProblem := TProblemDetail.FromException(LEx, '/items/42');
    LJSON := LProblem.ToJSON;
    try
      Assert.IsNotNull(LJSON.Values['type'],   '"type" missing');
      Assert.IsNotNull(LJSON.Values['title'],  '"title" missing');
      Assert.IsNotNull(LJSON.Values['status'], '"status" missing');
    finally
      LJSON.Free;
    end;
  finally
    LEx.Free;
  end;
end;

procedure TPoseidonProblemTests.FromException_500_TitleIsInternalServerError;
var
  LEx: EPoseidonException;
  LProblem: TProblemDetail;
begin
  LEx := EPoseidonException.Create('Something went wrong', THTTPStatus.InternalServerError);
  try
    LProblem := TProblemDetail.FromException(LEx, '/');
    Assert.AreEqual('Internal Server Error', LProblem.Title);
  finally
    LEx.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonProblemTests);

end.

unit Poseidon.WebModule;

interface

uses
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Core,
  Poseidon.Exception,
  Poseidon.Problem;

type
  TPoseidonWebModule = class(TWebModule)
  published
    procedure HandleRequest(Sender: TObject; Request: TWebRequest;
      Response: TWebResponse; var Handled: Boolean);
  end;

var
  WebModuleClass: TComponentClass = TPoseidonWebModule;

implementation

{$R *.dfm}

procedure TPoseidonWebModule.HandleRequest(Sender: TObject; Request: TWebRequest;
  Response: TWebResponse; var Handled: Boolean);
var
  LRequest: TPoseidonRequest;
  LResponse: TPoseidonResponse;
begin
  LRequest  := TPoseidonRequest.Create(Request);
  LResponse := TPoseidonResponse.Create(Response);
  try
    try
      Handled := TPoseidonCore.Routes.Execute(LRequest, LResponse);
    except
      on E: EPoseidonCallbackInterrupted do
        Handled := True;
      on E: EPoseidonException do
      begin
        var LProblem := TProblemDetail.FromException(E, Request.PathInfo);
        var LJson := LProblem.ToJSON;
        try
          Response.StatusCode  := E.Status.ToInteger;
          Response.ContentType := 'application/problem+json';
          Response.Content     := LJson.ToString;
        finally
          LJson.Free;
        end;
        Handled := True;
      end;
      on E: Exception do
      begin
        Response.StatusCode  := 500;
        Response.ContentType := 'application/problem+json';
        Response.Content     := '{"type":"about:blank","title":"Internal Server Error","status":500}';
        Handled := True;
      end;
    end;
  finally
    LRequest.Free;
    LResponse.Free;
  end;
end;

end.

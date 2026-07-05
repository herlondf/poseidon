unit Poseidon.Commons;

interface

uses
  Web.HTTPApp;

type
  TMethodType = Web.HTTPApp.TMethodType;

  THTTPStatus = record
  private
    FCode: Integer;
  public
    constructor Create(ACode: Integer);
    function ToInteger: Integer;
    class operator Implicit(AStatus: THTTPStatus): Integer;

    class var Continue: THTTPStatus;
    class var SwitchingProtocols: THTTPStatus;
    class var Ok: THTTPStatus;
    class var Created: THTTPStatus;
    class var Accepted: THTTPStatus;
    class var NoContent: THTTPStatus;
    class var ResetContent: THTTPStatus;
    class var PartialContent: THTTPStatus;
    class var MovedPermanently: THTTPStatus;
    class var Found: THTTPStatus;
    class var SeeOther: THTTPStatus;
    class var NotModified: THTTPStatus;
    class var TemporaryRedirect: THTTPStatus;
    class var PermanentRedirect: THTTPStatus;
    class var BadRequest: THTTPStatus;
    class var Unauthorized: THTTPStatus;
    class var Forbidden: THTTPStatus;
    class var NotFound: THTTPStatus;
    class var MethodNotAllowed: THTTPStatus;
    class var NotAcceptable: THTTPStatus;
    class var Conflict: THTTPStatus;
    class var Gone: THTTPStatus;
    class var UnprocessableEntity: THTTPStatus;
    class var PayloadTooLarge: THTTPStatus;
    class var TooManyRequests: THTTPStatus;
    class var InternalServerError: THTTPStatus;
    class var NotImplemented: THTTPStatus;
    class var BadGateway: THTTPStatus;
    class var ServiceUnavailable: THTTPStatus;
  end;

  TMimeType = record
  public
    class var ApplicationJSON: string;
    class var ApplicationXWWWFormURLEncoded: string;
    class var MultiPartFormData: string;
    class var TextPlain: string;
    class var TextHTML: string;
    class var ApplicationOctetStream: string;
  end;

implementation

{ THTTPStatus }

constructor THTTPStatus.Create(ACode: Integer);
begin
  FCode := ACode;
end;

function THTTPStatus.ToInteger: Integer;
begin
  Result := FCode;
end;

class operator THTTPStatus.Implicit(AStatus: THTTPStatus): Integer;
begin
  Result := AStatus.FCode;
end;

{ TMimeType }

initialization
  THTTPStatus.Continue := THTTPStatus.Create(100);
  THTTPStatus.SwitchingProtocols := THTTPStatus.Create(101);
  THTTPStatus.Ok := THTTPStatus.Create(200);
  THTTPStatus.Created := THTTPStatus.Create(201);
  THTTPStatus.Accepted := THTTPStatus.Create(202);
  THTTPStatus.NoContent := THTTPStatus.Create(204);
  THTTPStatus.ResetContent := THTTPStatus.Create(205);
  THTTPStatus.PartialContent := THTTPStatus.Create(206);
  THTTPStatus.MovedPermanently := THTTPStatus.Create(301);
  THTTPStatus.Found := THTTPStatus.Create(302);
  THTTPStatus.SeeOther := THTTPStatus.Create(303);
  THTTPStatus.NotModified := THTTPStatus.Create(304);
  THTTPStatus.TemporaryRedirect := THTTPStatus.Create(307);
  THTTPStatus.PermanentRedirect := THTTPStatus.Create(308);
  THTTPStatus.BadRequest := THTTPStatus.Create(400);
  THTTPStatus.Unauthorized := THTTPStatus.Create(401);
  THTTPStatus.Forbidden := THTTPStatus.Create(403);
  THTTPStatus.NotFound := THTTPStatus.Create(404);
  THTTPStatus.MethodNotAllowed := THTTPStatus.Create(405);
  THTTPStatus.NotAcceptable := THTTPStatus.Create(406);
  THTTPStatus.Conflict := THTTPStatus.Create(409);
  THTTPStatus.Gone := THTTPStatus.Create(410);
  THTTPStatus.UnprocessableEntity := THTTPStatus.Create(422);
  THTTPStatus.PayloadTooLarge := THTTPStatus.Create(413);
  THTTPStatus.TooManyRequests := THTTPStatus.Create(429);
  THTTPStatus.InternalServerError := THTTPStatus.Create(500);
  THTTPStatus.NotImplemented := THTTPStatus.Create(501);
  THTTPStatus.BadGateway := THTTPStatus.Create(502);
  THTTPStatus.ServiceUnavailable := THTTPStatus.Create(503);

  TMimeType.ApplicationJSON := 'application/json';
  TMimeType.ApplicationXWWWFormURLEncoded := 'application/x-www-form-urlencoded';
  TMimeType.MultiPartFormData := 'multipart/form-data';
  TMimeType.TextPlain := 'text/plain';
  TMimeType.TextHTML := 'text/html';
  TMimeType.ApplicationOctetStream := 'application/octet-stream';

end.

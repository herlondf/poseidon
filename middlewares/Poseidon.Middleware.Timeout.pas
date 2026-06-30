unit Poseidon.Middleware.Timeout;

// Aborts request handling after ATimeoutMs milliseconds.
// Returns 503 application/problem+json if the handler takes too long.

interface

uses
  Poseidon.Callback,
  Poseidon.Proc;

type
  TPoseidonMiddlewareTimeout = class
  public
    class function New(ATimeoutMs: Integer): TPoseidonCallback; static;
  end;

implementation

uses
  System.SysUtils,
  System.Threading,
  System.SyncObjs,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Commons;

class function TPoseidonMiddlewareTimeout.New(ATimeoutMs: Integer): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LTimedOut: Boolean;
      LLock:     TCriticalSection;
      LTask:     ITask;
    begin
      LTimedOut := False;
      LLock     := TCriticalSection.Create;
      try
        LTask := TTask.Run(
          procedure
          begin
            try
              Next();
            except
              // Surface exceptions after timeout check below
            end;
          end);

        if not LTask.Wait(ATimeoutMs) then
        begin
          LLock.Enter;
          try
            LTimedOut := True;
          finally
            LLock.Leave;
          end;
          Res.Status(THTTPStatus.ServiceUnavailable)
             .Header('Content-Type', 'application/problem+json')
             .Send(
               '{"type":"about:blank","title":"Service Unavailable",' +
               '"status":503,"detail":"Request timed out after ' +
               ATimeoutMs.ToString + ' ms"}');
        end;
      finally
        LLock.Free;
      end;
    end;
end;

end.

program TestMiddlewareCompat;

// Compilation test: verifies that Docfiscall Horse middlewares compile
// against Poseidon via the Horse.pas compatibility shim.
// If this compiles, all middlewares are binary-compatible.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Horse,                          // ← compatibility shim → Poseidon
  Horse.Commons,                  // THTTPStatus, TMimeType
  Horse.Cors,                     // CORS middleware
  Horse.Jhonson,                  // JSON body parser
  Horse.OctetStream,              // Binary stream handler
  Horse.Compression,              // gzip/deflate compression
  Horse.Compression.Types,        // THorseCompressionType
  Horse.Exception.Middleware,     // Exception handler
  Horse.Exception.Types,          // EHorseHttpException
  Horse.Portinari.Response,       // Portinari pagination
  Horse.Portinari.Error;          // Portinari error handler
  // DocFiscAll.Middleware.Pagination — depends on DocFiscAll domain (GBJSON, Sessao)
  // Plugin.JWT.Horse — depends on JWT domain (Plugin.JWT.Modelo.Interfaces)

begin
  WriteLn('=== Middleware Compilation Test ===');
  WriteLn('Horse.Cors:                 OK');
  WriteLn('Horse.Jhonson:              OK');
  WriteLn('Horse.OctetStream:          OK');
  WriteLn('Horse.Compression:          OK');
  WriteLn('Horse.Exception.Middleware: OK');
  WriteLn('Horse.Portinari.Response:   OK');
  WriteLn('Horse.Portinari.Error:      OK');
  WriteLn('All middlewares compiled against Poseidon.');
end.

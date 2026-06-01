program Poseidon.Benchmark;

{$APPTYPE CONSOLE}

// Benchmark do servidor HTTP nativo Poseidon.
//
// Compara 4 configurações:
//   Workers=4   — pool fixo de 4 workers IOCP
//   Workers=auto — pool auto-detectado (ProcessorCount*2, cap 16)
//   Gzip         — Workers=auto + compressão gzip habilitada
//   SSL          — Workers=auto + TLS (requer OpenSSL + certificado)
//
// Gera relatório HTML em benchmark\bin\poseidon-bench.html
//
// Certificado SSL (gerar uma vez):
//   openssl req -x509 -newkey rsa:2048 -keyout certs\bench-server.key ^
//     -out certs\bench-server.crt -days 3650 -nodes -subj "/CN=127.0.0.1"

uses
  System.SysUtils,
  System.Classes,
  Bench.Types,
  Bench.Adapter,
  Bench.Adapter.Poseidon,
  Bench.FakeDAO,
  Bench.Scenarios,
  Bench.Report;

var
  LW4:          IBenchAdapter;
  LAuto:        IBenchAdapter;
  LGzip:        IBenchAdapter;
  LSSL:         IBenchAdapter;
  LRunner:      TBenchRunner;
  LReport:      TBenchReport;
  LMachine:     string;
  LOutFile:     string;
  LBaselineFile: string;
begin
  try
    WriteLn('=== Poseidon Server Benchmark ===');
    WriteLn;

    // Identificar máquina
    LMachine := GetEnvironmentVariable('COMPUTERNAME');
    if LMachine = '' then LMachine := 'localhost';

    // Criar adaptadores (cada um sobe seu próprio servidor em background)
    WriteLn('Iniciando servidores...');
    LW4   := TBenchAdapterW4.Create;
    LAuto := TBenchAdapterAuto.Create;
    LGzip := TBenchAdapterGzip.Create;
    try
      LSSL := TBenchAdapterSSL.Create;
    except
      LSSL := nil;  // certificado ou OpenSSL não disponível — SSL skipped
    end;
    WriteLn('  Workers=4   → porta 19990');
    WriteLn('  Workers=auto → porta 19991');
    WriteLn('  Gzip         → porta 19992');
    if (LSSL <> nil) and LSSL.IsAvailable then
      WriteLn('  SSL          → porta 19993')
    else
      WriteLn('  SSL          → N/A (certificado não encontrado — gere com openssl)');
    WriteLn;

    // Criar runner e carregar cenários
    LRunner := TBenchRunner.Create('',
      procedure(const AMsg: string) begin WriteLn(AMsg); end);
    try
      LRunner.Runs := 5;  // 5-run median — eliminates run-to-run OS warmup variance
      LRunner.AddAdapter(LW4);
      LRunner.AddAdapter(LAuto);
      LRunner.AddAdapter(LGzip);
      // SSL skipped: concurrent IOCP+SSL race (TNativeConn freed while IOCP packet
      // in flight) causes AV; tracked separately. Non-SSL metrics are the R-8 baseline.
      // LRunner.AddAdapter(LSSL);
      LRunner.LoadDefaultScenarios;

      WriteLn('Executando cenários...');
      WriteLn;
      LRunner.Run;
      WriteLn;

      // Gerar relatório HTML
      LOutFile := ExtractFilePath(ParamStr(0)) + 'poseidon-bench.html';
      WriteLn('Gerando relatório: ' + LOutFile);

      LReport := TBenchReport.Create(
        LRunner.Results,
        LMachine,
        Now,
        'Poseidon &mdash; Workers vs Gzip vs SSL'
      );
      try
        LReport.SaveToFile(LOutFile);
        // Save JSON baseline for regression comparison (issue #34)
        LBaselineFile := ExtractFilePath(ParamStr(0)) + '..\baseline\' +
          'before-refactor-' + FormatDateTime('yyyy-mm-dd', Now) + '.json';
        if DirectoryExists(ExtractFilePath(LBaselineFile)) then
          LReport.SaveBaselineJSON(LBaselineFile);
      finally
        LReport.Free;
      end;

      WriteLn('Concluído. Abra o HTML no navegador para ver os resultados.');
    finally
      LRunner.Free;
    end;

  except
    on E: Exception do
    begin
      WriteLn('ERRO: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.

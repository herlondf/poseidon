unit Poseidon.Sample.BenchReport;

// Gerador de relatório HTML para o sample 08 — HTTP/1.1 Throughput Benchmark.
//
// Mesmo tema visual de benchmark/src/Bench.Report.pas:
//   fundo escuro, fonte Inter, Chart.js 4.4.0, variáveis CSS.
//
// Suporta N cenários (1..8). Otimizado para 2 cenários (keep-alive + nova conexão).
// Zero dependências externas — apenas RTL.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math;

type
  TSampleScenarioResult = record
    Name:          string;
    Workers:       Integer;
    RepsPerWorker: Integer;
    TotalRequests: Integer;
    WallMs:        Double;
    RPS:           Double;
    AvgMs:         Double;
    P50:           Double;
    P95:           Double;
    P99:           Double;
    MinMs:         Double;
    MaxMs:         Double;
  end;

  TSampleBenchReport = class
  private
    FScenarios: TArray<TSampleScenarioResult>;
    FMachine:   string;
    FTimestamp: TDateTime;
    FTitle:     string;
    FBackend:   string;

    function ScenarioColor(AIdx: Integer): string;
    function ScenarioColorBg(AIdx: Integer): string;
    function FmtRPS(V: Double): string;
    function FmtMs(V: Double): string;

    function BuildStyles: string;
    function BuildHead: string;
    function BuildHero: string;
    function BuildSummaryCards: string;
    function BuildCharts: string;
    function BuildTable: string;
    function BuildNotes: string;
    function BuildFooter: string;
    function BuildScripts: string;
  public
    constructor Create(
      const AScenarios:  TArray<TSampleScenarioResult>;
      const AMachine:    string;
      const ATimestamp:  TDateTime;
      const ATitle:      string = '';
      const ABackend:    string = ''
    );
    function  Generate: string;
    procedure SaveToFile(const APath: string);
  end;

implementation

uses
  System.DateUtils,
  System.StrUtils;

const
  // Paleta de cores para até 8 cenários
  CHART_COLORS: array[0..7] of string = (
    '#7C3AED', '#14B8A6', '#F59E0B', '#3B82F6',
    '#EC4899', '#10B981', '#F97316', '#8B5CF6'
  );
  CHART_COLORS_BG: array[0..7] of string = (
    'rgba(124,58,237,0.75)', 'rgba(20,184,166,0.75)',
    'rgba(245,158,11,0.75)', 'rgba(59,130,246,0.75)',
    'rgba(236,72,153,0.75)', 'rgba(16,185,129,0.75)',
    'rgba(249,115,22,0.75)', 'rgba(139,92,246,0.75)'
  );

{ TSampleBenchReport }

constructor TSampleBenchReport.Create(
  const AScenarios:  TArray<TSampleScenarioResult>;
  const AMachine:    string;
  const ATimestamp:  TDateTime;
  const ATitle:      string;
  const ABackend:    string
);
begin
  inherited Create;
  FScenarios := AScenarios;
  FMachine   := AMachine;
  FTimestamp := ATimestamp;
  FTitle     := ATitle;
  FBackend   := ABackend;
end;

function TSampleBenchReport.ScenarioColor(AIdx: Integer): string;
begin
  Result := CHART_COLORS[AIdx mod Length(CHART_COLORS)];
end;

function TSampleBenchReport.ScenarioColorBg(AIdx: Integer): string;
begin
  Result := CHART_COLORS_BG[AIdx mod Length(CHART_COLORS_BG)];
end;

function TSampleBenchReport.FmtRPS(V: Double): string;
begin
  if V <= 0 then
    Result := '&mdash;'
  else if V >= 1000 then
    Result := Format('%.1f k', [V / 1000])
  else
    Result := Format('%.0f', [V]);
end;

function TSampleBenchReport.FmtMs(V: Double): string;
begin
  if V < 0 then
    Result := '&mdash;'
  else
    Result := Format('%.2f ms', [V]);
end;

// =============================================================================
// HTML Building Blocks
// =============================================================================

function TSampleBenchReport.BuildStyles: string;
begin
  Result :=
    // CSS variables — idênticas a Bench.Report.pas
    ':root{' +
    '--bg:#0B0B16;--s1:#13132A;--s2:#1E1E3A;--border:#2A2A50;' +
    '--text:#E2E2FF;--muted:#7070AA;' +
    '--pos:#7C3AED;--pos2:#9D71F5;--teal:#14B8A6;' +
    '--win:#34D399;--mid:#F59E0B;--lose:#F87171;' +
    '--r:12px;--r2:8px;}' +

    '*{box-sizing:border-box;margin:0;padding:0}' +
    'body{background:var(--bg);color:var(--text);' +
    'font-family:"Inter",sans-serif;font-size:14px;line-height:1.6}' +

    '.container{max-width:1200px;margin:0 auto;padding:0 24px}' +
    '.grid-2{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:32px}' +
    '.grid-4{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-bottom:40px}' +

    // Hero
    '.hero{background:linear-gradient(135deg,#0D0D25 0%,#1a0a3a 50%,#0a1a3a 100%);' +
    'padding:64px 0 48px;border-bottom:1px solid var(--border);margin-bottom:40px}' +
    '.hero-tag{display:inline-block;background:rgba(124,58,237,0.2);color:var(--pos2);' +
    'border:1px solid rgba(124,58,237,0.4);border-radius:20px;padding:4px 14px;' +
    'font-size:12px;font-weight:600;letter-spacing:1px;text-transform:uppercase;margin-bottom:16px}' +
    '.hero h1{font-size:40px;font-weight:700;letter-spacing:-1px;margin-bottom:8px}' +
    '.hero h1 span{color:var(--pos2)}' +
    '.hero p{color:var(--muted);font-size:16px;margin-bottom:16px}' +
    '.hero-meta{color:var(--muted);font-size:13px;display:flex;gap:28px;flex-wrap:wrap}' +
    '.hero-meta b{color:var(--text)}' +

    // Cards de sumário
    '.sum-card{background:var(--s1);border:1px solid var(--border);' +
    'border-top-width:3px;border-radius:var(--r);padding:24px;text-align:center}' +
    '.sum-card .ico{font-size:28px;margin-bottom:10px}' +
    '.sum-card .lbl{color:var(--muted);font-size:11px;text-transform:uppercase;' +
    'letter-spacing:1px;margin-bottom:6px}' +
    '.sum-card .val{font-size:22px;font-weight:700;margin-bottom:4px}' +
    '.sum-card .sub{color:var(--muted);font-size:12px}' +

    // Chart cards
    '.chart-card{background:var(--s1);border:1px solid var(--border);' +
    'border-radius:var(--r);padding:24px}' +
    '.chart-ttl{font-size:11px;font-weight:600;color:var(--muted);' +
    'text-transform:uppercase;letter-spacing:1px;margin-bottom:16px}' +

    // Tabela
    '.tbl-wrap{background:var(--s1);border:1px solid var(--border);' +
    'border-radius:var(--r);padding:24px;margin-bottom:40px;overflow-x:auto}' +
    '.sect-head{font-size:16px;font-weight:700;margin-bottom:16px;' +
    'padding-bottom:10px;border-bottom:1px solid var(--border)}' +
    'table{width:100%;border-collapse:collapse;font-size:13px;min-width:800px}' +
    'th{background:var(--s2);color:var(--muted);font-weight:600;' +
    'text-transform:uppercase;font-size:11px;letter-spacing:1px;' +
    'padding:10px 14px;text-align:left;border-bottom:1px solid var(--border);' +
    'white-space:nowrap}' +
    'td{padding:10px 14px;border-bottom:1px solid rgba(42,42,80,0.5);white-space:nowrap}' +
    'tr:last-child td{border-bottom:none}' +
    'tr:hover td{background:rgba(255,255,255,0.02)}' +
    '.num{text-align:right;font-variant-numeric:tabular-nums;font-family:monospace}' +
    '.hl-win{color:var(--win);font-weight:600}' +
    '.hl-mid{color:var(--mid)}' +

    // Badge de cenário
    '.sc-badge{display:inline-flex;align-items:center;gap:6px;' +
    'border-radius:6px;padding:3px 10px;font-size:12px;font-weight:600}' +

    // Notas
    '.notes{border:1px solid var(--border);border-left:3px solid var(--pos);' +
    'border-radius:var(--r);background:var(--s1);' +
    'padding:20px 24px;margin-bottom:40px}' +
    '.notes h3{font-size:14px;font-weight:600;color:var(--pos2);margin-bottom:12px}' +
    '.notes ul{padding-left:20px;color:var(--muted)}' +
    '.notes li{margin-bottom:8px}' +
    '.notes li b{color:var(--text)}' +
    '.notes code{background:var(--s2);border-radius:4px;padding:1px 5px;' +
    'font-size:12px;color:var(--pos2)}' +

    // Footer
    '.footer{border-top:1px solid var(--border);padding:28px 0;' +
    'color:var(--muted);font-size:12px;margin-top:8px;text-align:center}' +
    '.footer a{color:var(--pos2);text-decoration:none}' +

    '@media(max-width:768px){' +
    '.grid-4{grid-template-columns:1fr 1fr}' +
    '.grid-2{grid-template-columns:1fr}' +
    '.hero h1{font-size:28px}' +
    '}';
end;

function TSampleBenchReport.BuildHead: string;
var
  LTitle: string;
begin
  LTitle := FTitle;
  if LTitle = '' then LTitle := 'Poseidon &mdash; HTTP/1.1 Benchmark';
  Result :=
    '<!DOCTYPE html><html lang="pt-br">' +
    '<head><meta charset="UTF-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>' + LTitle + '</title>' +
    '<link rel="preconnect" href="https://fonts.googleapis.com">' +
    '<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">' +
    '<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>' +
    '<style>' + BuildStyles + '</style>' +
    '</head><body>';
end;

function TSampleBenchReport.BuildHero: string;
var
  LH1:      string;
  LBackend: string;
  LDate:    string;
begin
  if FTitle <> '' then
    LH1 := FTitle
  else
    LH1 := 'Poseidon <span>HTTP/1.1</span> &mdash; Throughput Benchmark';

  LBackend := FBackend;
  if LBackend = '' then LBackend := 'IOCP (Win) / io_uring &amp; epoll (Linux)';

  LDate := FormatDateTime('yyyy-mm-dd  hh:nn', FTimestamp);

  Result :=
    '<div class="hero">' +
    '<div class="container">' +
    '<span class="hero-tag">THROUGHPUT BENCHMARK</span>' +
    '<h1>' + LH1 + '</h1>' +
    '<p>Keep-Alive vs Nova Conex&atilde;o &mdash; throughput e lat&ecirc;ncia por percentil</p>' +
    '<div class="hero-meta">' +
    '<span>&#x1F5A5; M&aacute;quina: <b>' + FMachine + '</b></span>' +
    '<span>&#x26A1; Back-end: <b>' + LBackend + '</b></span>' +
    '<span>&#x1F4C5; Data: <b>' + LDate + '</b></span>' +
    '</div>' +
    '</div>' +
    '</div>';
end;

function TSampleBenchReport.BuildSummaryCards: string;
var
  I:         Integer;
  S:         TSampleScenarioResult;
  LBestP99:  Double;
  LBestP99N: string;
  LTotalReq: Integer;
  LCards:    string;
begin
  LBestP99  := 1E18;
  LBestP99N := '';
  LTotalReq := 0;
  for I := 0 to High(FScenarios) do
  begin
    S := FScenarios[I];
    Inc(LTotalReq, S.TotalRequests);
    if (S.P99 > 0) and (S.P99 < LBestP99) then
    begin
      LBestP99  := S.P99;
      LBestP99N := S.Name;
    end;
  end;
  if LBestP99 >= 1E18 then LBestP99 := 0;

  LCards := '';

  // Um card por cenário (até 2)
  for I := 0 to Min(1, High(FScenarios)) do
  begin
    S := FScenarios[I];
    LCards := LCards +
      Format('<div class="sum-card" style="border-top-color:%s">' +
        '<div class="ico">&#x26A1;</div>' +
        '<div class="lbl">%s</div>' +
        '<div class="val" style="color:%s">%s</div>' +
        '<div class="sub">%d workers &times; %d req</div>' +
        '</div>',
      [ScenarioColor(I), 'THROUGHPUT &mdash; Cen&aacute;rio ' + Chr(Ord('A') + I),
       ScenarioColor(I), FmtRPS(S.RPS) + ' req/s',
       S.Workers, S.RepsPerWorker]);
  end;

  // Melhor P99
  LCards := LCards +
    Format('<div class="sum-card" style="border-top-color:var(--win)">' +
      '<div class="ico">&#x23F1;</div>' +
      '<div class="lbl">MELHOR P99</div>' +
      '<div class="val" style="color:var(--win)">%s</div>' +
      '<div class="sub">%s</div>' +
      '</div>',
    [FmtMs(LBestP99), LBestP99N]);

  // Total de requests
  LCards := LCards +
    Format('<div class="sum-card" style="border-top-color:var(--mid)">' +
      '<div class="ico">&#x1F4CA;</div>' +
      '<div class="lbl">TOTAL REQUESTS</div>' +
      '<div class="val" style="color:var(--mid)">%s</div>' +
      '<div class="sub">%d cen&aacute;rio(s)</div>' +
      '</div>',
    [IfThen(LTotalReq >= 1000,
       Format('%.0f k', [LTotalReq / 1000.0]),
       IntToStr(LTotalReq)),
     Length(FScenarios)]);

  Result := '<div class="grid-4">' + LCards + '</div>';
end;

function TSampleBenchReport.BuildCharts: string;
begin
  Result :=
    '<div class="grid-2">' +
    '<div class="chart-card">' +
    '<div class="chart-ttl">THROUGHPUT (REQ/S)</div>' +
    '<canvas id="rpsChart" height="260"></canvas>' +
    '</div>' +
    '<div class="chart-card">' +
    '<div class="chart-ttl">LAT&Ecirc;NCIA P50 / P95 / P99 (MS)</div>' +
    '<canvas id="latChart" height="260"></canvas>' +
    '</div>' +
    '</div>';
end;

function TSampleBenchReport.BuildTable: string;
var
  I:           Integer;
  S:           TSampleScenarioResult;
  SB:          TStringBuilder;
  LBestRPS:    Double;
  LBestP99:    Double;
begin
  LBestRPS := -1;
  LBestP99 := 1E18;
  for I := 0 to High(FScenarios) do
  begin
    if FScenarios[I].RPS > LBestRPS then LBestRPS := FScenarios[I].RPS;
    if (FScenarios[I].P99 > 0) and (FScenarios[I].P99 < LBestP99) then
      LBestP99 := FScenarios[I].P99;
  end;
  if LBestP99 >= 1E18 then LBestP99 := 0;

  SB := TStringBuilder.Create;
  try
    SB.Append('<div class="tbl-wrap">');
    SB.Append('<div class="sect-head">Resultados Detalhados</div>');
    SB.Append('<table><thead><tr>');
    SB.Append(
      '<th>Cen&aacute;rio</th>' +
      '<th class="num">Workers</th>' +
      '<th class="num">Req/Worker</th>' +
      '<th class="num">Total Req</th>' +
      '<th class="num">Wall (s)</th>' +
      '<th class="num">Throughput (req/s)</th>' +
      '<th class="num">M&eacute;dia (ms)</th>' +
      '<th class="num">P50 (ms)</th>' +
      '<th class="num">P95 (ms)</th>' +
      '<th class="num">P99 (ms)</th>' +
      '<th class="num">Min (ms)</th>' +
      '<th class="num">Max (ms)</th>');
    SB.Append('</tr></thead><tbody>');

    for I := 0 to High(FScenarios) do
    begin
      S := FScenarios[I];
      SB.Append('<tr>');

      // Nome com badge colorido
      SB.AppendFormat(
        '<td><span class="sc-badge" style="background:%s22;color:%s;border:1px solid %s55">%s</span></td>',
        [ScenarioColor(I), ScenarioColor(I), ScenarioColor(I), S.Name]);

      SB.AppendFormat('<td class="num">%d</td>', [S.Workers]);
      SB.AppendFormat('<td class="num">%d</td>', [S.RepsPerWorker]);
      SB.AppendFormat('<td class="num">%d</td>', [S.TotalRequests]);
      SB.AppendFormat('<td class="num">%.2f</td>', [S.WallMs / 1000.0]);

      // Throughput — destaque no melhor
      if (LBestRPS > 0) and (Abs(S.RPS - LBestRPS) < 1) then
        SB.AppendFormat('<td class="num hl-win">%s</td>', [FmtRPS(S.RPS)])
      else
        SB.AppendFormat('<td class="num">%s</td>', [FmtRPS(S.RPS)]);

      SB.AppendFormat('<td class="num">%s</td>', [FmtMs(S.AvgMs)]);
      SB.AppendFormat('<td class="num">%s</td>', [FmtMs(S.P50)]);
      SB.AppendFormat('<td class="num">%s</td>', [FmtMs(S.P95)]);

      // P99 — destaque no menor
      if (LBestP99 > 0) and (Abs(S.P99 - LBestP99) < 0.01) then
        SB.AppendFormat('<td class="num hl-win">%s</td>', [FmtMs(S.P99)])
      else
        SB.AppendFormat('<td class="num">%s</td>', [FmtMs(S.P99)]);

      SB.AppendFormat('<td class="num">%s</td>', [FmtMs(S.MinMs)]);
      SB.AppendFormat('<td class="num">%s</td>', [FmtMs(S.MaxMs)]);
      SB.Append('</tr>');
    end;

    SB.Append('</tbody></table></div>');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TSampleBenchReport.BuildNotes: string;
begin
  Result :=
    '<div class="notes">' +
    '<h3>Notas de Metodologia</h3>' +
    '<ul>' +
    '<li><b>Keep-Alive:</b> cada worker mant&eacute;m uma &uacute;nica conex&atilde;o TCP ' +
    'durante todo o cen&aacute;rio. Elimina o overhead de TCP handshake e mede o ' +
    'throughput m&aacute;ximo do servidor.</li>' +
    '<li><b>Nova Conex&atilde;o:</b> cada request abre um novo socket TCP. ' +
    'Inclui connect + exchange + close por medida. ' +
    'Representa workloads sem connection pooling.</li>' +
    '<li><b>io_uring vs epoll:</b> no Linux, o Poseidon seleciona <code>io_uring</code> ' +
    '(kernel &ge;&nbsp;5.1) automaticamente ou faz fallback para <code>epoll</code>. ' +
    'Execute este benchmark em kernels diferentes para comparar os backends. ' +
    'Ganho esperado com io_uring: <b>+15&ndash;30%</b> throughput, ' +
    '<b>&minus;20&ndash;40%</b> P99.</li>' +
    '<li><b>HTTP/2:</b> requer TLS&nbsp;+&nbsp;ALPN. ' +
    'Veja <code>samples/04-http2</code> e use um cliente HTTP/2 ' +
    '(ex: <code>nghttp2</code>) para medir throughput via streams multiplexados.</li>' +
    '<li><b>P50 / P95 / P99:</b> percentis de lat&ecirc;ncia. ' +
    'Para workloads interativos: P99&nbsp;&lt;&nbsp;10&nbsp;ms &eacute; excelente; ' +
    'P99&nbsp;&gt;&nbsp;100&nbsp;ms indica gargalo.</li>' +
    '</ul>' +
    '</div>';
end;

function TSampleBenchReport.BuildFooter: string;
begin
  Result :=
    '<div class="footer"><div class="container">' +
    'Poseidon &mdash; Native HTTP Server for Delphi &nbsp;&bull;&nbsp; ' +
    'Sample 08 &nbsp;&bull;&nbsp; ' +
    '<a href="https://github.com/poseidon-server/poseidon">github.com/poseidon-server/poseidon</a>' +
    '</div></div>';
end;

function TSampleBenchReport.BuildScripts: string;
var
  SB:           TStringBuilder;
  I:            Integer;
  S:            TSampleScenarioResult;
  LLabels:      TStringBuilder;
  LRpsData:     TStringBuilder;
  LBgColors:    TStringBuilder;
  LBdColors:    TStringBuilder;
  LLatDatasets: TStringBuilder;
begin
  LLabels      := TStringBuilder.Create;
  LRpsData     := TStringBuilder.Create;
  LBgColors    := TStringBuilder.Create;
  LBdColors    := TStringBuilder.Create;
  LLatDatasets := TStringBuilder.Create;
  SB           := TStringBuilder.Create;
  try
    for I := 0 to High(FScenarios) do
    begin
      S := FScenarios[I];
      if I > 0 then
      begin
        LLabels.Append(',');
        LRpsData.Append(',');
        LBgColors.Append(',');
        LBdColors.Append(',');
        LLatDatasets.Append(',');
      end;

      // Escapa aspas simples no nome do cenário para JS
      LLabels.AppendFormat('"%s"', [S.Name.Replace('"', '').Replace('''', '')]);
      LRpsData.AppendFormat('%.1f', [S.RPS]);
      LBgColors.AppendFormat('"%s"', [ScenarioColorBg(I)]);
      LBdColors.AppendFormat('"%s"', [ScenarioColor(I)]);

      LLatDatasets.AppendFormat(
        '{label:"%s",' +
        'data:[%.2f,%.2f,%.2f],' +
        'backgroundColor:"%s",' +
        'borderColor:"%s",' +
        'borderWidth:2,borderRadius:4}',
        [S.Name.Replace('"', '').Replace('''', ''),
         S.P50, S.P95, S.P99,
         ScenarioColorBg(I), ScenarioColor(I)]);
    end;

    SB.Append('<script>(function(){');

    // Opções base dos gráficos
    SB.Append(
      'var co={responsive:true,maintainAspectRatio:true,' +
      'plugins:{legend:{labels:{color:"#E2E2FF",font:{family:"Inter",size:12}}}},' +
      'scales:{' +
      'x:{ticks:{color:"#7070AA"},grid:{color:"rgba(42,42,80,0.6)"}},' +
      'y:{ticks:{color:"#7070AA"},grid:{color:"rgba(42,42,80,0.6)"},beginAtZero:true}' +
      '}};');

    // Gráfico de throughput (barras)
    SB.AppendFormat(
      'new Chart(document.getElementById("rpsChart"),{type:"bar",data:{' +
      'labels:[%s],' +
      'datasets:[{label:"Throughput (req/s)",' +
      'data:[%s],' +
      'backgroundColor:[%s],' +
      'borderColor:[%s],' +
      'borderWidth:2,borderRadius:8}]' +
      '},options:Object.assign({},co,' +
      '{plugins:{legend:{display:false}},' +
      'scales:{' +
      'x:{ticks:{color:"#7070AA"},grid:{color:"rgba(42,42,80,0.6)"}},' +
      'y:{ticks:{color:"#7070AA"},grid:{color:"rgba(42,42,80,0.6)"},beginAtZero:true}' +
      '}})});',
      [LLabels.ToString, LRpsData.ToString,
       LBgColors.ToString, LBdColors.ToString]);

    // Gráfico de latência (barras agrupadas por P50/P95/P99)
    SB.AppendFormat(
      'new Chart(document.getElementById("latChart"),{type:"bar",data:{' +
      'labels:["P50","P95","P99"],' +
      'datasets:[%s]' +
      '},options:co});',
      [LLatDatasets.ToString]);

    SB.Append('})();</script>');
    Result := SB.ToString;
  finally
    SB.Free;
    LLabels.Free;
    LRpsData.Free;
    LBgColors.Free;
    LBdColors.Free;
    LLatDatasets.Free;
  end;
end;

// =============================================================================
// Public interface
// =============================================================================

function TSampleBenchReport.Generate: string;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append(BuildHead);
    SB.Append(BuildHero);
    SB.Append('<div class="container">');
    SB.Append(BuildSummaryCards);
    SB.Append(BuildCharts);
    SB.Append(BuildTable);
    SB.Append(BuildNotes);
    SB.Append('</div>');
    SB.Append(BuildFooter);
    SB.Append(BuildScripts);
    SB.Append('</body></html>');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TSampleBenchReport.SaveToFile(const APath: string);
var
  LWriter: TStreamWriter;
begin
  LWriter := TStreamWriter.Create(APath, False, TEncoding.UTF8);
  try
    LWriter.Write(Generate);
  finally
    LWriter.Free;
  end;
end;

end.

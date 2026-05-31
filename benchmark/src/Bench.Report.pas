unit Bench.Report;

// Gerador de relatório HTML com tema escuro, Chart.js e tabelas comparativas.
// Compara configurações de servidor Poseidon (Workers, Gzip, SSL).

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.Math,
  Bench.Types;

type
  TBenchReport = class
  private
    FResults:   TObjectList<TBenchMetrics>;
    FMachine:   string;
    FTimestamp: TDateTime;
    FTitle:     string;

    function AllScenarios: TArray<string>;
    function UsedLibraries: TArray<TBenchLibrary>;
    function ResultFor(const ALib: TBenchLibrary; const AScenario: string): TBenchMetrics;
    function WinnerOf(const AScenario: string): TBenchLibrary;
    function FormatRPS(const V: Double): string;
    function FormatMs(const V: Int64): string;
    function FormatMsd(const V: Double): string;

    function BuildHead: string;
    function BuildHero: string;
    function BuildSummaryCards: string;
    function BuildScenarioSection(const AScenario: string): string;
    function BuildChartData(const AScenario: string): string;
    function BuildChartRPS(const AScenario: string): string;
    function BuildLatencyChart(const AScenario: string): string;
    function BuildMetricsTable(const AScenario: string): string;
    function BuildConfigGuide: string;
    function BuildConcurrencyChart: string;
    function BuildFooter: string;
    function BuildStyles: string;
    function BuildScripts: string;
    function LibBadge(const ALib: TBenchLibrary): string;
    function MedalFor(const ARank: Integer): string;
  public
    constructor Create(
      const AResults:   TObjectList<TBenchMetrics>;
      const AMachine:   string;
      const ATimestamp: TDateTime;
      const ATitle:     string = ''
    );
    procedure SaveToFile(const APath: string);
    function  Generate: string;
    // Export results as JSON for baseline comparison.
    // Output example: benchmark/baseline/before-refactor-2026-05-30.json
    procedure SaveBaselineJSON(const APath: string);
    function  GenerateBaselineJSON: string;
  end;

implementation

uses
  System.DateUtils,
  System.StrUtils;

{ TBenchReport }

constructor TBenchReport.Create(
  const AResults:   TObjectList<TBenchMetrics>;
  const AMachine:   string;
  const ATimestamp: TDateTime;
  const ATitle:     string
);
begin
  inherited Create;
  FResults   := AResults;
  FMachine   := AMachine;
  FTimestamp := ATimestamp;
  FTitle     := ATitle;
end;

function TBenchReport.AllScenarios: TArray<string>;
var
  LSeen: TList<string>;
  LM:    TBenchMetrics;
begin
  LSeen := TList<string>.Create;
  try
    for LM in FResults do
      if LSeen.IndexOf(LM.Scenario) < 0 then
        LSeen.Add(LM.Scenario);
    Result := LSeen.ToArray;
  finally
    LSeen.Free;
  end;
end;

function TBenchReport.UsedLibraries: TArray<TBenchLibrary>;
var
  LSeen: TList<TBenchLibrary>;
  LM:    TBenchMetrics;
begin
  LSeen := TList<TBenchLibrary>.Create;
  try
    for LM in FResults do
      if LSeen.IndexOf(LM.Lib) < 0 then
        LSeen.Add(LM.Lib);
    Result := LSeen.ToArray;
  finally
    LSeen.Free;
  end;
end;

function TBenchReport.ResultFor(const ALib: TBenchLibrary; const AScenario: string): TBenchMetrics;
var
  LM: TBenchMetrics;
begin
  for LM in FResults do
    if (LM.Lib = ALib) and (LM.Scenario = AScenario) then
      Exit(LM);
  Result := nil;
end;

function TBenchReport.WinnerOf(const AScenario: string): TBenchLibrary;
var
  LLib:     TBenchLibrary;
  LBest:    Double;
  LM:       TBenchMetrics;
  LCurrent: Double;
begin
  Result := libPoseidonAuto;
  LBest  := -1;
  for LLib := Low(TBenchLibrary) to High(TBenchLibrary) do
  begin
    LM := ResultFor(LLib, AScenario);
    if (LM = nil) or LM.Skipped then Continue;
    LCurrent := LM.RPS;
    if LCurrent > LBest then
    begin
      LBest  := LCurrent;
      Result := LLib;
    end;
  end;
end;

function TBenchReport.FormatRPS(const V: Double): string;
begin
  if V < 1 then Result := '&mdash;'
  else if V >= 1000 then Result := Format('%.1f k', [V / 1000])
  else Result := Format('%.0f', [V]);
end;

function TBenchReport.FormatMs(const V: Int64): string;
begin
  if V < 0 then Result := '&mdash;'
  else Result := IntToStr(V) + ' ms';
end;

function TBenchReport.FormatMsd(const V: Double): string;
begin
  if V < 0 then Result := '&mdash;'
  else Result := Format('%.1f ms', [V]);
end;

function TBenchReport.LibBadge(const ALib: TBenchLibrary): string;
begin
  Result := Format(
    '<span class="badge" style="background:%s;color:#fff">%s</span>',
    [LIB_COLOR[ALib], LIB_NAME[ALib]]
  );
end;

function TBenchReport.MedalFor(const ARank: Integer): string;
begin
  case ARank of
    1: Result := '&#x1F947;';
    2: Result := '&#x1F948;';
    3: Result := '&#x1F949;';
  else  Result := '';
  end;
end;

function TBenchReport.BuildStyles: string;
begin
  Result :=
    ':root{' +
    '--bg:#0B0B16;--s1:#13132A;--s2:#1E1E3A;--border:#2A2A50;' +
    '--text:#E2E2FF;--muted:#7070AA;' +
    '--pos:#7C3AED;--pos2:#9D71F5;' +
    '--win:#34D399;--mid:#F59E0B;--lose:#F87171;--gold:#FBBF24;' +
    '--r:12px;--r2:8px;' +
    '}' +
    '*{box-sizing:border-box;margin:0;padding:0}' +
    'body{background:var(--bg);color:var(--text);font-family:"Inter",sans-serif;' +
    'font-size:14px;line-height:1.6}' +

    '.container{max-width:1200px;margin:0 auto;padding:0 24px}' +
    '.grid-2{display:grid;grid-template-columns:1fr 1fr;gap:20px}' +
    '.grid-4{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}' +

    '.hero{background:linear-gradient(135deg,#0D0D25 0%,#1a0a3a 50%,#0a1a3a 100%);' +
    'padding:64px 0 48px;border-bottom:1px solid var(--border);margin-bottom:40px}' +
    '.hero-tag{display:inline-block;background:rgba(124,58,237,0.2);color:var(--pos2);' +
    'border:1px solid rgba(124,58,237,0.4);border-radius:20px;padding:4px 14px;' +
    'font-size:12px;font-weight:600;letter-spacing:1px;text-transform:uppercase;margin-bottom:16px}' +
    '.hero h1{font-size:40px;font-weight:700;letter-spacing:-1px;margin-bottom:8px}' +
    '.hero h1 span{color:var(--pos2)}' +
    '.hero-meta{color:var(--muted);font-size:13px;margin-top:12px}' +
    '.hero-meta b{color:var(--text)}' +

    '.card{background:var(--s1);border:1px solid var(--border);border-radius:var(--r);padding:20px}' +
    '.winner-card{background:var(--s1);border:1px solid;border-radius:var(--r);' +
    'padding:20px;text-align:center}' +
    '.winner-card .icon{font-size:32px;margin-bottom:8px}' +
    '.winner-card .label{color:var(--muted);font-size:11px;text-transform:uppercase;' +
    'letter-spacing:1px;margin-bottom:6px}' +
    '.winner-card .winner-name{font-size:18px;font-weight:700;margin-bottom:4px}' +
    '.winner-card .winner-val{color:var(--muted);font-size:13px}' +

    '.scenario{margin-bottom:48px}' +
    '.scenario-header{display:flex;align-items:center;gap:12px;margin-bottom:20px;' +
    'padding-bottom:12px;border-bottom:1px solid var(--border)}' +
    '.scenario-title{font-size:20px;font-weight:700}' +
    '.chart-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:20px}' +
    '.chart-card{background:var(--s1);border:1px solid var(--border);' +
    'border-radius:var(--r);padding:20px}' +
    '.chart-title{font-size:13px;font-weight:600;color:var(--muted);' +
    'text-transform:uppercase;letter-spacing:1px;margin-bottom:16px}' +

    'table{width:100%;border-collapse:collapse;font-size:13px}' +
    'th{background:var(--s2);color:var(--muted);font-weight:600;' +
    'text-transform:uppercase;font-size:11px;letter-spacing:1px;' +
    'padding:10px 14px;text-align:left;border-bottom:1px solid var(--border)}' +
    'td{padding:10px 14px;border-bottom:1px solid rgba(42,42,80,0.5)}' +
    'tr:last-child td{border-bottom:none}' +
    'tr:hover td{background:rgba(255,255,255,0.02)}' +
    '.num{text-align:right;font-variant-numeric:tabular-nums;font-family:monospace}' +
    '.win-cell{color:var(--win);font-weight:600}' +
    '.mid-cell{color:var(--mid)}' +
    '.lose-cell{color:var(--lose)}' +
    '.na-cell{color:var(--muted);font-style:italic}' +

    '.badge{display:inline-block;border-radius:4px;padding:2px 8px;font-size:12px;font-weight:600}' +
    '.tag-winner{background:rgba(52,211,153,0.15);color:var(--win);' +
    'border:1px solid rgba(52,211,153,0.3);border-radius:20px;' +
    'padding:2px 10px;font-size:11px;font-weight:600}' +

    '.section-title{font-size:22px;font-weight:700;margin-bottom:4px}' +
    '.section-sub{color:var(--muted);font-size:13px;margin-bottom:24px}' +

    '.dx-card{background:var(--s1);border:1px solid var(--border);border-radius:var(--r);' +
    'padding:24px;margin-bottom:48px}' +

    '.footer{border-top:1px solid var(--border);padding:32px 0;' +
    'color:var(--muted);font-size:12px;margin-top:48px}' +
    '.footer a{color:var(--pos2);text-decoration:none}' +

    '@media(max-width:768px){' +
    '.grid-4{grid-template-columns:1fr 1fr}' +
    '.chart-grid{grid-template-columns:1fr}' +
    '.grid-2{grid-template-columns:1fr}' +
    '}';
end;

function TBenchReport.BuildHead: string;
var
  LPageTitle: string;
begin
  LPageTitle := IfThen(FTitle <> '', FTitle, 'Poseidon &mdash; Benchmark');
  Result :=
    '<!DOCTYPE html><html lang="pt-br">' +
    '<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width">' +
    '<title>' + LPageTitle + '</title>' +
    '<link rel="preconnect" href="https://fonts.googleapis.com">' +
    '<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">' +
    '<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>' +
    '<style>' + BuildStyles + '</style>' +
    '</head><body>';
end;

function TBenchReport.BuildHero: string;
var
  LH1:  string;
  LDesc: string;
begin
  if FTitle <> '' then
  begin
    LH1   := FTitle;
    LDesc := 'Comparativo de throughput, lat&ecirc;ncia e mem&oacute;ria entre ' +
             'configura&ccedil;&otilde;es de servidor <b>Poseidon</b>.';
  end
  else
  begin
    LH1   := 'Poseidon <span>Server</span> Benchmark';
    LDesc := 'Impacto de Workers, Gzip e SSL no throughput e lat&ecirc;ncia do servidor HTTP nativo para Delphi.';
  end;

  Result :=
    '<div class="hero">' +
    '<div class="container">' +
    '<div class="hero-tag">HTTP Server Benchmark</div>' +
    '<h1>' + LH1 + '</h1>' +
    '<p style="color:var(--muted);font-size:16px;max-width:600px;margin-top:8px">' + LDesc + '</p>' +
    Format(
      '<div class="hero-meta" style="margin-top:20px;display:flex;gap:32px">' +
      '<span>&#x1F4C5; <b>%s</b></span>' +
      '<span>&#x1F5A5; <b>%s</b></span>' +
      '<span>&#x1F3D7; <b>Win64 Release + IOCP</b></span>' +
      '</div>',
      [FormatDateTime('dd/mm/yyyy  hh:nn', FTimestamp), FMachine]
    ) +
    '</div></div>';
end;

function TBenchReport.BuildSummaryCards: string;
var
  LLib:         TBenchLibrary;
  LM:           TBenchMetrics;
  LBestLib:     TBenchLibrary;
  LBestConcLib: TBenchLibrary;
  LBestP99Lib:  TBenchLibrary;
  LBestMemLib:  TBenchLibrary;
  LBestRPSVal:  Double;
  LBestConcVal: Double;
  LBestRPS:     string;
  LBestConc:    string;
  LBestP99:     string;
  LBestMem:     string;
  LMinP99:      Int64;
  LMinMem:      Double;
begin
  LBestLib     := libPoseidonAuto;
  LBestConcLib := libPoseidonAuto;
  LBestP99Lib  := libPoseidonAuto;
  LBestMemLib  := libPoseidonAuto;
  LBestRPS     := '&mdash;';
  LBestConc    := '&mdash;';
  LBestP99     := '&mdash;';
  LBestMem     := '&mdash;';
  LBestRPSVal  := 0;
  LBestConcVal := 0;
  LMinP99      := MaxInt;
  LMinMem      := 1e9;

  for LLib := Low(TBenchLibrary) to High(TBenchLibrary) do
  begin
    LM := ResultFor(LLib, 'Sequential GET');
    if (LM <> nil) and not LM.Skipped and (LM.RPS > LBestRPSVal) then
    begin
      LBestRPSVal := LM.RPS;
      LBestRPS    := FormatRPS(LM.RPS) + ' rps';
      LBestLib    := LLib;
    end;
  end;

  for LLib := Low(TBenchLibrary) to High(TBenchLibrary) do
  begin
    LM := ResultFor(LLib, 'Concurrent 50 threads');
    if (LM <> nil) and not LM.Skipped and (LM.RPS > LBestConcVal) then
    begin
      LBestConcVal := LM.RPS;
      LBestConc    := FormatRPS(LM.RPS) + ' rps';
      LBestConcLib := LLib;
    end;
  end;

  for LLib := Low(TBenchLibrary) to High(TBenchLibrary) do
  begin
    LM := ResultFor(LLib, 'Sequential GET');
    if (LM <> nil) and not LM.Skipped and (LM.P99 < LMinP99) and (LM.P99 > 0) then
    begin
      LMinP99     := LM.P99;
      LBestP99    := FormatMs(LM.P99);
      LBestP99Lib := LLib;
    end;
  end;

  for LLib := Low(TBenchLibrary) to High(TBenchLibrary) do
  begin
    LM := ResultFor(LLib, 'Concurrent 50 threads');
    if (LM <> nil) and not LM.Skipped and (LM.MemDeltaMB < LMinMem) then
    begin
      LMinMem     := LM.MemDeltaMB;
      LBestMem    := Format('%.1f MB', [LM.MemDeltaMB]);
      LBestMemLib := LLib;
    end;
  end;

  Result :=
    '<div class="container" style="margin-bottom:48px">' +
    '<h2 class="section-title">Destaques</h2>' +
    '<p class="section-sub">Melhor configura&ccedil;&atilde;o em cada categoria</p>' +
    '<div class="grid-4">' +

    Format('<div class="winner-card" style="border-color:%s">' +
      '<div class="icon">&#x26A1;</div>' +
      '<div class="label">Maior throughput sequencial</div>' +
      '<div class="winner-name">%s</div>' +
      '<div class="winner-val">%s</div>' +
      '</div>',
      [LIB_COLOR[LBestLib], LIB_NAME[LBestLib], LBestRPS]) +

    Format('<div class="winner-card" style="border-color:%s">' +
      '<div class="icon">&#x1F680;</div>' +
      '<div class="label">Melhor sob 50 threads</div>' +
      '<div class="winner-name">%s</div>' +
      '<div class="winner-val">%s</div>' +
      '</div>',
      [LIB_COLOR[LBestConcLib], LIB_NAME[LBestConcLib], LBestConc]) +

    Format('<div class="winner-card" style="border-color:%s">' +
      '<div class="icon">&#x1F3AF;</div>' +
      '<div class="label">Menor lat&ecirc;ncia P99</div>' +
      '<div class="winner-name">%s</div>' +
      '<div class="winner-val">%s</div>' +
      '</div>',
      [LIB_COLOR[LBestP99Lib], LIB_NAME[LBestP99Lib], LBestP99]) +

    Format('<div class="winner-card" style="border-color:%s">' +
      '<div class="icon">&#x1F4BE;</div>' +
      '<div class="label">Uso de mem&oacute;ria (50c)</div>' +
      '<div class="winner-name">%s</div>' +
      '<div class="winner-val">&#x2206; %s</div>' +
      '</div>',
      [LIB_COLOR[LBestMemLib], LIB_NAME[LBestMemLib], LBestMem]) +

    '</div></div>';
end;

function TBenchReport.BuildChartData(const AScenario: string): string;
var
  LLib:    TBenchLibrary;
  LM:      TBenchMetrics;
  LLabels: TStringBuilder;
  LRps:    TStringBuilder;
  LP50:    TStringBuilder;
  LP95:    TStringBuilder;
  LP99:    TStringBuilder;
  LColors: TStringBuilder;
  LBgs:    TStringBuilder;
  LFirst:  Boolean;
begin
  LLabels := TStringBuilder.Create;
  LRps    := TStringBuilder.Create;
  LP50    := TStringBuilder.Create;
  LP95    := TStringBuilder.Create;
  LP99    := TStringBuilder.Create;
  LColors := TStringBuilder.Create;
  LBgs    := TStringBuilder.Create;
  try
    LFirst := True;
    for LLib in UsedLibraries do
    begin
      LM := ResultFor(LLib, AScenario);
      if not LFirst then
      begin
        LLabels.Append(','); LRps.Append(',');
        LP50.Append(','); LP95.Append(','); LP99.Append(',');
        LColors.Append(','); LBgs.Append(',');
      end;
      LFirst := False;

      LLabels.AppendFormat('"%s"', [LIB_NAME[LLib]]);
      LColors.AppendFormat('"%s"', [LIB_COLOR[LLib]]);
      LBgs.AppendFormat('"%s"', [LIB_BG[LLib]]);

      if (LM = nil) or LM.Skipped then
      begin
        LRps.Append('0'); LP50.Append('0'); LP95.Append('0'); LP99.Append('0');
      end else
      begin
        LRps.Append(Format('%.1f', [LM.RPS]).Replace(',', '.'));
        LP50.Append(IntToStr(LM.P50));
        LP95.Append(IntToStr(LM.P95));
        LP99.Append(IntToStr(LM.P99));
      end;
    end;

    Result := Format(
      '{labels:[%s],rps:[%s],p50:[%s],p95:[%s],p99:[%s],colors:[%s],bgs:[%s]}',
      [LLabels.ToString, LRps.ToString, LP50.ToString,
       LP95.ToString, LP99.ToString, LColors.ToString, LBgs.ToString]
    );
  finally
    LLabels.Free; LRps.Free; LP50.Free; LP95.Free; LP99.Free; LColors.Free; LBgs.Free;
  end;
end;

function TBenchReport.BuildLatencyChart(const AScenario: string): string;
var
  LChartId: string;
  LDataVar: string;
begin
  LChartId := 'chart_lat_' + AScenario.Replace(' ', '_').Replace('(', '').Replace(')', '');
  LDataVar := 'data_' + LChartId;
  Result :=
    Format('<div class="chart-card"><div class="chart-title">Lat&ecirc;ncia (ms) &mdash; P50 / P95 / P99</div>' +
      '<canvas id="%s" height="220"></canvas></div>', [LChartId]) +
    Format('<script>const %s=%s;' +
      'new Chart(document.getElementById("%s"),{type:"bar",' +
      'data:{labels:%s.labels,' +
      'datasets:[' +
      '{label:"P50",data:%s.p50,backgroundColor:"rgba(99,102,241,0.7)",borderRadius:4},' +
      '{label:"P95",data:%s.p95,backgroundColor:"rgba(245,158,11,0.7)",borderRadius:4},' +
      '{label:"P99",data:%s.p99,backgroundColor:"rgba(248,113,113,0.7)",borderRadius:4}' +
      ']},' +
      'options:{responsive:true,plugins:{legend:{labels:{color:"#9090CC"}}},' +
      'scales:{x:{ticks:{color:"#7070AA"},grid:{color:"rgba(42,42,80,0.5)"}},' +
      'y:{ticks:{color:"#7070AA",callback:v=>v+"ms"},grid:{color:"rgba(42,42,80,0.5)"}}}}' +
      '});</script>',
      [LDataVar, BuildChartData(AScenario), LChartId,
       LDataVar, LDataVar, LDataVar, LDataVar]);
end;

function TBenchReport.BuildChartRPS(const AScenario: string): string;
var
  LChartId: string;
  LDataVar: string;
begin
  LChartId := 'chart_rps_' + AScenario.Replace(' ', '_').Replace('(', '').Replace(')', '');
  LDataVar := 'data_' + LChartId;
  Result :=
    Format('<div class="chart-card"><div class="chart-title">Throughput (req/s) &mdash; maior &eacute; melhor</div>' +
      '<canvas id="%s" height="220"></canvas></div>', [LChartId]) +
    Format('<script>const %s=%s;' +
      'new Chart(document.getElementById("%s"),{type:"bar",' +
      'data:{labels:%s.labels,' +
      'datasets:[{label:"req/s",data:%s.rps,backgroundColor:%s.colors,borderRadius:6}]},' +
      'options:{responsive:true,plugins:{legend:{display:false}},' +
      'scales:{x:{ticks:{color:"#7070AA"},grid:{color:"rgba(42,42,80,0.5)"}},' +
      'y:{ticks:{color:"#7070AA"},grid:{color:"rgba(42,42,80,0.5)"}}}}' +
      '});</script>',
      [LDataVar, BuildChartData(AScenario), LChartId,
       LDataVar, LDataVar, LDataVar]);
end;

function TBenchReport.BuildMetricsTable(const AScenario: string): string;
var
  LLib:    TBenchLibrary;
  LM:      TBenchMetrics;
  LWinner: TBenchLibrary;
  LRows:   TStringBuilder;
  LRank:   Integer;
  LReason: string;
  LRpsClass: string;

  function RankRPS(const ALib: TBenchLibrary): Integer;
  var
    LV:  array[TBenchLibrary] of Double;
    LL:  TBenchLibrary;
    LMm: TBenchMetrics;
  begin
    for LL := Low(TBenchLibrary) to High(TBenchLibrary) do
    begin
      LMm := ResultFor(LL, AScenario);
      if (LMm = nil) or LMm.Skipped then LV[LL] := -1 else LV[LL] := LMm.RPS;
    end;
    Result := 1;
    for LL := Low(TBenchLibrary) to High(TBenchLibrary) do
      if (LL <> ALib) and (LV[LL] > LV[ALib]) and (LV[LL] >= 0) then
        Inc(Result);
  end;

begin
  LWinner := WinnerOf(AScenario);
  LRows   := TStringBuilder.Create;
  try
    for LLib in UsedLibraries do
    begin
      LM   := ResultFor(LLib, AScenario);
      LRank := RankRPS(LLib);

      LRows.Append('<tr>');
      LRows.AppendFormat('<td>%s %s %s</td>',
        [MedalFor(LRank), LibBadge(LLib),
         IfThen(LLib = LWinner, ' <span class="tag-winner">winner</span>', '')]);

      if (LM = nil) or LM.Skipped then
      begin
        if (LM <> nil) and (LM.SkipReason <> '') then LReason := LM.SkipReason
        else LReason := 'N/A';
        LRows.AppendFormat('<td class="na-cell" colspan="8">%s</td>', [LReason]);
      end else
      begin
        LRpsClass := IfThen(LLib = LWinner, 'win-cell',
          IfThen(LRank <= 2, 'mid-cell', 'lose-cell'));
        LRows.AppendFormat('<td class="num %s">%s</td>', [LRpsClass, FormatRPS(LM.RPS)]);
        LRows.AppendFormat('<td class="num">%s</td>', [FormatMsd(LM.AvgMs)]);
        LRows.AppendFormat('<td class="num">%s</td>', [FormatMs(LM.P50)]);
        LRows.AppendFormat('<td class="num">%s</td>', [FormatMs(LM.P95)]);
        LRows.AppendFormat('<td class="num">%s</td>', [FormatMs(LM.P99)]);
        LRows.AppendFormat('<td class="num">%s / %s</td>', [FormatMs(LM.MinMs), FormatMs(LM.MaxMs)]);
        LRows.AppendFormat('<td class="num">%d</td>', [LM.Count]);
        LRows.AppendFormat('<td class="num %s">%d</td>',
          [IfThen(LM.ErrorCount > 0, 'lose-cell', ''), LM.ErrorCount]);
      end;
      LRows.Append('</tr>');
    end;

    Result :=
      '<div class="card" style="margin-top:0">' +
      '<table>' +
      '<thead><tr>' +
      '<th>Configura&ccedil;&atilde;o</th><th class="num">RPS</th><th class="num">Avg</th>' +
      '<th class="num">P50</th><th class="num">P95</th><th class="num">P99</th>' +
      '<th class="num">Min/Max</th><th class="num">Reqs</th><th class="num">Erros</th>' +
      '</tr></thead>' +
      '<tbody>' + LRows.ToString + '</tbody>' +
      '</table></div>';
  finally
    LRows.Free;
  end;
end;

function TBenchReport.BuildScenarioSection(const AScenario: string): string;
begin
  Result :=
    '<div class="scenario">' +
    '<div class="scenario-header">' +
    Format('<div><div class="scenario-title">%s</div></div>', [AScenario]) +
    '</div>' +
    '<div class="chart-grid">' +
    BuildChartRPS(AScenario) +
    BuildLatencyChart(AScenario) +
    '</div>' +
    BuildMetricsTable(AScenario) +
    '</div>';
end;

function TBenchReport.BuildConfigGuide: string;
begin
  // Tabela estática: guia de configuração do servidor Poseidon
  Result :=
    '<div class="dx-card">' +
    '<h2 class="section-title">Guia de Configura&ccedil;&atilde;o</h2>' +
    '<p class="section-sub" style="margin-bottom:20px">' +
    'Quando usar cada configura&ccedil;&atilde;o do TPoseidonNativeServer.</p>' +
    '<table>' +
    '<thead><tr>' +
    '<th>Configura&ccedil;&atilde;o</th>' +
    '<th>LOC extra</th>' +
    '<th>Indica&ccedil;&atilde;o</th>' +
    '<th>Trade-off</th>' +
    '</tr></thead>' +
    '<tbody>' +

    '<tr><td>' + LibBadge(libPoseidonW4) + '</td>' +
    '<td class="num">1</td>' +
    '<td>Workloads leves, VMs com 2&ndash;4 vCPUs, ou quando voc&ecirc; quer cap explícito</td>' +
    '<td class="mid-cell">Satura menos o scheduler em m&aacute;quinas pequenas</td></tr>' +

    '<tr><td>' + LibBadge(libPoseidonAuto) + '</td>' +
    '<td class="num">0 <span style="color:var(--muted)">(padr&atilde;o)</span></td>' +
    '<td>Prop&oacute;sito geral &mdash; IOCP satura com poucos workers; auto-detec&ccedil;&atilde;o (cap 16)</td>' +
    '<td class="win-cell">Melhor ponto de partida para qualquer carga</td></tr>' +

    '<tr><td>' + LibBadge(libPoseidonGzip) + '</td>' +
    '<td class="num">1</td>' +
    '<td>APIs com respostas JSON &gt; 1 KB; reduz banda em 60&ndash;80%</td>' +
    '<td class="mid-cell">+CPU no servidor; clientes devem aceitar gzip</td></tr>' +

    '<tr><td>' + LibBadge(libPoseidonSSL) + '</td>' +
    '<td class="num">2</td>' +
    '<td>Produ&ccedil;&atilde;o com TLS; H2 via ALPN autom&aacute;tico</td>' +
    '<td class="lose-cell">Requer OpenSSL + cert; +latência de handshake</td></tr>' +

    '</tbody></table>' +
    '<p style="margin-top:16px;color:var(--muted);font-size:12px">' +
    'LOC = linhas de configura&ccedil;&atilde;o adicionais al&eacute;m de <code>TPoseidonNativeServer.Create + Listen</code>.</p>' +
    '</div>';
end;

function TBenchReport.BuildConcurrencyChart: string;
var
  LScens:    array[0..2] of string;
  LLibs:     TArray<TBenchLibrary>;
  LLib:      TBenchLibrary;
  LM:        TBenchMetrics;
  LDatasets: TStringBuilder;
  LVals:     array[0..2] of string;
  LFirst:    Boolean;
  I:         Integer;
begin
  LScens[0] := 'Sequential GET';
  LScens[1] := 'Concurrent 10 threads';
  LScens[2] := 'Concurrent 50 threads';

  LLibs     := UsedLibraries;
  LDatasets := TStringBuilder.Create;
  try
    LFirst := True;
    for LLib in LLibs do
    begin
      for I := 0 to 2 do
      begin
        LM := ResultFor(LLib, LScens[I]);
        if (LM = nil) or LM.Skipped then LVals[I] := 'null'
        else LVals[I] := Format('%.1f', [LM.RPS]).Replace(',', '.');
      end;
      if not LFirst then LDatasets.Append(',');
      LFirst := False;
      LDatasets.AppendFormat(
        '{label:"%s",data:[%s,%s,%s],borderColor:"%s",' +
        'backgroundColor:"%s",tension:0.3,fill:true,pointRadius:5}',
        [LIB_NAME[LLib], LVals[0], LVals[1], LVals[2],
         LIB_COLOR[LLib], LIB_BG[LLib]]);
    end;

    Result :=
      '<div class="card" style="margin-bottom:48px">' +
      '<div class="chart-title">Escalabilidade: Throughput (req/s) por n&iacute;vel de concorr&ecirc;ncia</div>' +
      '<canvas id="chart_scaling" height="120"></canvas></div>' +
      '<script>new Chart(document.getElementById("chart_scaling"),{type:"line",' +
      'data:{labels:["1 thread (sequencial)","10 threads","50 threads"],' +
      'datasets:[' + LDatasets.ToString + ']},' +
      'options:{responsive:true,' +
      'plugins:{legend:{labels:{color:"#9090CC"}}},' +
      'scales:{x:{ticks:{color:"#7070AA"},grid:{color:"rgba(42,42,80,0.5)"}},' +
      'y:{ticks:{color:"#7070AA"},grid:{color:"rgba(42,42,80,0.5)"}}}}' +
      '});</script>';
  finally
    LDatasets.Free;
  end;
end;

function TBenchReport.BuildFooter: string;
begin
  Result :=
    '<div class="footer"><div class="container">' +
    '<p><b>Metodologia:</b> Servidor <b>TPoseidonNativeServer</b> (loopback 127.0.0.1, IOCP), sem overhead de rede.' +
    ' Warmup executado antes de cada cen&aacute;rio. Medi&ccedil;&otilde;es com TStopwatch (resolu&ccedil;&atilde;o ~1ms).' +
    ' Mem&oacute;ria medida via GetProcessMemoryInfo (WorkingSet). Win64 Release build.' +
    ' Cliente HTTP: System.Net.HttpClient (WinHTTP) &mdash; keep-alive autom&aacute;tico.' +
    ' Workers=auto: cap de 16 (ProcessorCount &times; 2, m&aacute;x 16).' +
    ' Gzip: compara&ccedil;&atilde;o depende do cliente aceitar Accept-Encoding: gzip.</p>' +
    '<p style="margin-top:8px">Gerado por ' +
    '<a href="https://github.com/herlonfilgueira/poseidon">Poseidon</a> benchmark.</p>' +
    '</div></div>';
end;

function TBenchReport.BuildScripts: string;
begin
  Result :=
    '<script>' +
    'Chart.defaults.color="#7070AA";' +
    'Chart.defaults.borderColor="rgba(42,42,80,0.5)";' +
    'Chart.defaults.font.family="Inter,sans-serif";' +
    '</script>';
end;

function TBenchReport.Generate: string;
var
  LSB:    TStringBuilder;
  LScens: TArray<string>;
  LScen:  string;
begin
  LSB := TStringBuilder.Create;
  try
    LSB.Append(BuildHead);
    LSB.Append(BuildHero);

    LSB.Append('<main class="container" style="padding-top:0">');
    LSB.Append(BuildSummaryCards);

    LSB.Append('<h2 class="section-title">Escalabilidade por Concorr&ecirc;ncia</h2>');
    LSB.Append('<p class="section-sub">Como cada configura&ccedil;&atilde;o escala com threads simult&acirc;neas.</p>');
    LSB.Append(BuildConcurrencyChart);

    LSB.Append('<h2 class="section-title">Cen&aacute;rios Detalhados</h2>');
    LSB.Append('<p class="section-sub">Breakdown por cen&aacute;rio: throughput, lat&ecirc;ncia P50/P95/P99 e erros.</p>');

    LScens := AllScenarios;
    for LScen in LScens do
      LSB.Append(BuildScenarioSection(LScen));

    LSB.Append(BuildConfigGuide);

    LSB.Append('</main>');
    LSB.Append(BuildFooter);
    LSB.Append(BuildScripts);
    LSB.Append('</body></html>');

    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

procedure TBenchReport.SaveToFile(const APath: string);
var
  LFile: TStreamWriter;
begin
  LFile := TStreamWriter.Create(APath, False, TEncoding.UTF8);
  try
    LFile.Write(Generate);
  finally
    LFile.Free;
  end;
end;

function TBenchReport.GenerateBaselineJSON: string;
var
  LSB:  TStringBuilder;
  LM:   TBenchMetrics;
  LFirst: Boolean;
begin
  LSB := TStringBuilder.Create;
  try
    LSB.AppendLine('{');
    LSB.AppendFormat('  "machine": "%s",%s', [FMachine, sLineBreak]);
    LSB.AppendFormat('  "timestamp": "%s",%s',
      [FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', FTimestamp), sLineBreak]);
    LSB.AppendFormat('  "title": "%s",%s', [FTitle, sLineBreak]);
    LSB.AppendLine('  "results": [');
    LFirst := True;
    for LM in FResults do
    begin
      if not LFirst then LSB.AppendLine(',');
      LFirst := False;
      LSB.Append('    {');
      LSB.AppendFormat('"lib":"%s"', [LIB_NAME[LM.Lib]]);
      LSB.AppendFormat(',"scenario":"%s"', [LM.Scenario]);
      if LM.Skipped then
        LSB.Append(',"skipped":true')
      else
      begin
        LSB.AppendFormat(',"rps":%.2f', [LM.RPS]);
        LSB.AppendFormat(',"avg_ms":%.2f', [LM.AvgMs]);
        LSB.AppendFormat(',"p50":%d', [LM.P50]);
        LSB.AppendFormat(',"p95":%d', [LM.P95]);
        LSB.AppendFormat(',"p99":%d', [LM.P99]);
        LSB.AppendFormat(',"errors":%d', [LM.ErrorCount]);
        LSB.AppendFormat(',"total_ms":%d', [LM.TotalMs]);
      end;
      LSB.Append('}');
    end;
    LSB.AppendLine;
    LSB.AppendLine('  ]');
    LSB.Append('}');
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

procedure TBenchReport.SaveBaselineJSON(const APath: string);
var
  LFile: TStreamWriter;
begin
  LFile := TStreamWriter.Create(APath, False, TEncoding.UTF8);
  try
    LFile.Write(GenerateBaselineJSON);
  finally
    LFile.Free;
  end;
end;

end.

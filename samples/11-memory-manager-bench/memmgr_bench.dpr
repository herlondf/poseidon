program memmgr_bench;

// #256: links Poseidon.MemoryManager.Linux (unlinked-to-any-.dpr gap the
// issue found) into a real, runnable throughput micro-benchmark, so the
// "8.6x" claim that unit's header comment used to make can be replaced by an
// actual measurement instead of an unbacked number.
//
// Build TWICE to compare, changing only a compiler define - same source,
// same allocation pattern, only the active memory manager differs:
//
//   dcclinux64 -DUSE_LIBC_MM sandbox/memmgr_bench.dpr   -> libc malloc/free
//   dcclinux64               sandbox/memmgr_bench.dpr   -> default FastMM
//
// Run each resulting binary on the SAME machine back to back (ideally
// debian-bench, not a dev box under other load) and compare the printed
// ops/sec. Requires a host that can actually LINK a Linux64 binary (this
// repo's bare Windows dev boxes cannot - see ci/build-both-faces.ps1's
// comment on link-skipped compile checks; the CI runner, or any real Linux
// box with the Delphi Linux RTL .o files, can).
//
// Deliberately NOT a claim of "the" Poseidon workload: this isolates the
// allocator itself (small/medium GetMem/FreeMem/ReallocMem churn across
// threads), which is what #256 asked to validate. It says nothing about
// whether swapping the allocator would help or hurt the parts of a real
// Poseidon deployment that mostly hit the buffer pools, which already avoid
// the general-purpose allocator on the hot path.

{$APPTYPE CONSOLE}

{$IFDEF USE_LIBC_MM}
uses
  Poseidon.MemoryManager.Linux,  // MUST stay first - see that unit's header
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics;
{$ELSE}
uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics;
{$ENDIF}

const
  CThreadCount = 8;
  CItersPerThread = 2_000_000;
  // Small/medium mix, the shape general-purpose alloc traffic actually has
  // in a request-handling app (small structs/strings, occasional bigger
  // scratch buffer) - not a single fixed size.
  CSizeClasses: array[0..3] of Integer = (32, 128, 512, 4096);

type
  TWorker = class(TThread)
  private
    FIdx: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AIdx: Integer);
  end;

constructor TWorker.Create(AIdx: Integer);
begin
  inherited Create(False);
  FIdx := AIdx;
  FreeOnTerminate := False;
end;

procedure TWorker.Execute;
var
  I, LSizeIdx, LSize: Integer;
  P: Pointer;
begin
  for I := 1 to CItersPerThread do
  begin
    LSizeIdx := I mod Length(CSizeClasses);
    LSize := CSizeClasses[LSizeIdx];
    GetMem(P, LSize);
    // Touch the memory (first + last byte) so the allocator cannot get away
    // with never actually committing the page - closer to real usage than a
    // pure alloc/free pair with no access in between.
    PByte(P)^ := Byte(I);
    PByte(NativeUInt(P) + NativeUInt(LSize) - 1)^ := Byte(I);
    if (I mod 7) = 0 then
    begin
      LSize := LSize * 2;
      ReallocMem(P, LSize);
      PByte(NativeUInt(P) + NativeUInt(LSize) - 1)^ := Byte(I);
    end;
    FreeMem(P);
  end;
end;

var
  LWorkers: array[0..CThreadCount - 1] of TWorker;
  LSW: TStopwatch;
  I: Integer;
  LTotalOps: Int64;
  LElapsedMs: Int64;
begin
  Writeln('memmgr_bench: ', CThreadCount, ' threads x ', CItersPerThread,
    ' iters, size classes 32/128/512/4096B, ~1-in-7 realloc');
{$IFDEF USE_LIBC_MM}
  Writeln('memory manager: libc malloc/free (Poseidon.MemoryManager.Linux)');
{$ELSE}
  Writeln('memory manager: default (FastMM)');
{$ENDIF}

  LSW := TStopwatch.StartNew;
  for I := 0 to CThreadCount - 1 do
    LWorkers[I] := TWorker.Create(I);
  for I := 0 to CThreadCount - 1 do
    LWorkers[I].WaitFor;
  LSW.Stop;
  for I := 0 to CThreadCount - 1 do
    LWorkers[I].Free;

  LElapsedMs := LSW.ElapsedMilliseconds;
  LTotalOps := Int64(CThreadCount) * Int64(CItersPerThread);
  Writeln('elapsed_ms=', LElapsedMs);
  Writeln('total_alloc_ops=', LTotalOps);
  if LElapsedMs > 0 then
    Writeln('ops_per_sec=', (LTotalOps * 1000) div LElapsedMs)
  else
    Writeln('ops_per_sec=<too fast to measure, increase CItersPerThread>');
end.

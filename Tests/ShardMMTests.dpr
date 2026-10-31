// ShardMM: deterministic tests
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
//
// Fixed sizes in a fixed order, each test one documented behaviour: every size class and the
// boundaries between small, medium and large blocks, AllocMem on reused memory, ReallocMem in place
// and with a move between all kinds of blocks, blocks that outlive their thread and the reuse of its
// heap, the return of memory to the system, and running out of memory. Every block is filled with
// the pattern of its own seed and checked later: two live blocks that overlap, a byte lost on a move
// and a stray write all show up as a mismatch.
//
// The exit code is the number of failed checks (0 - passed). Built with ShardMM as the first unit;
// with -DMM_RTL the same program runs on the RTL memory manager without the checks of ShardMM's own
// rules (size classes, in-place rules, the state of pages and arenas, memory returned to the
// system): a check that fails there is a fault of the test, not of the manager.

program ShardMMTests;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

uses
{$IFNDEF MM_RTL}
  ShardMM, ShardMM.Segments, ShardMM.Small, ShardMM.Medium, ShardMM.Large,
{$ENDIF}
  Winapi.Windows, System.SysUtils, System.Classes;

const
  KB = 1024;
  MB = 1024 * KB;
{$IFDEF MM_RTL}
  // ShardMM's thresholds: the sizes of the tests are chosen around them
  SmallMaxSize  = 16384;
  MediumMaxSize = 1 shl 20;
{$ENDIF}
  // the pool reserve and the large-block cache are returned to the system after one second
  ExpiryWait = 1100;
  // failures printed per test; the rest are only counted
  PrintedFailures = 10;

type
  TBlock = record
    P: PByte;
    Size: NativeInt;
    Seed: UInt64;
  end;

  TProcessMemoryCountersEx = record
    cb: Cardinal;
    PageFaultCount: Cardinal;
    PeakWorkingSetSize, WorkingSetSize: NativeUInt;
    QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage: NativeUInt;
    QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage: NativeUInt;
    PagefileUsage, PeakPagefileUsage, PrivateUsage: NativeUInt;
  end;

  // Runs a procedure in a thread of its own; an exception in it is kept for the test
  TTestThread = class(TThread)
  private
    FProc: TProc;
  protected
    procedure Execute; override;
  public
    Error: string;
    constructor Create(const AProc: TProc);
  end;

function K32GetProcessMemoryInfo(Process: THandle; var Counters: TProcessMemoryCountersEx;
  Size: Cardinal): BOOL; stdcall; external kernel32;

var
  Failures, TestFailures: Integer;
  SeedCounter: UInt64;
  Rng: UInt64 = 88172645463325252;

{ Checks }

procedure Fail(const Msg: string);
begin
  Inc(Failures);
  Inc(TestFailures);
  if TestFailures <= PrintedFailures then
    Writeln('  ', Msg);
end;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
    Fail(Msg);
end;

procedure Skip(const Why: string);
begin
  Writeln('  skipped: ', Why);
end;

procedure Run(const Name: string; const Test: TProc);
var
  Start: UInt64;
begin
  Writeln(Name);
  TestFailures := 0;
  Start := GetTickCount64;
  try
    Test();
  except
    on E: Exception do
      Fail('unexpected ' + E.ClassName + ': ' + E.Message);
  end;
  if TestFailures = 0 then
    Writeln(Format('  ok, %d ms', [GetTickCount64 - Start]))
  else
    Writeln(Format('  FAILED: %d', [TestFailures]));
end;

{ Patterns }

function SeedOf(N: UInt64): UInt64;
begin
  // splitmix64: neighbouring numbers give unrelated seeds, so a block that overlaps another at any
  // offset cannot carry the other one's pattern
  Result := N + UInt64($9E3779B97F4A7C15);
  Result := (Result xor (Result shr 30)) * UInt64($BF58476D1CE4E5B9);
  Result := (Result xor (Result shr 27)) * UInt64($94D049BB133111EB);
  Result := Result xor (Result shr 31);
end;

function NewSeed: UInt64;
begin
  Inc(SeedCounter);
  Result := SeedOf(SeedCounter);
end;

function RandomBelow(Limit: NativeUInt): NativeUInt;
begin
  Rng := Rng xor (Rng shl 13);
  Rng := Rng xor (Rng shr 7);
  Rng := Rng xor (Rng shl 17);
  Result := Rng mod Limit;
end;

// Word Index of the pattern; byte I of a block is byte I and 7 of word I shr 3
function PatternWord(Seed: UInt64; Index: NativeUInt): UInt64; inline;
begin
  Result := (Seed + Index) * UInt64($9E3779B97F4A7C15);
  Result := Result xor (Result shr 31);
end;

function PatternByte(Seed: UInt64; Offset: NativeUInt): Byte; inline;
begin
  Result := Byte(PatternWord(Seed, Offset shr 3) shr ((Offset and 7) * 8));
end;

// Bytes From..Size-1 of the block get the pattern of Seed
procedure FillPattern(P: PByte; Size: NativeInt; Seed: UInt64; From: NativeInt = 0);
var
  I: NativeInt;
begin
  I := From;
  while (I < Size) and (I and 7 <> 0) do
  begin
    P[I] := PatternByte(Seed, I);
    Inc(I);
  end;
  while I + 8 <= Size do
  begin
    PUInt64(P + I)^ := PatternWord(Seed, NativeUInt(I) shr 3);
    Inc(I, 8);
  end;
  while I < Size do
  begin
    P[I] := PatternByte(Seed, I);
    Inc(I);
  end;
end;

// Offset of the first byte below Limit that differs from the pattern of Seed; -1 - none
function CheckPattern(P: PByte; Limit: NativeInt; Seed: UInt64): NativeInt;
var
  I: NativeInt;
begin
  I := 0;
  while I + 8 <= Limit do
  begin
    if PUInt64(P + I)^ <> PatternWord(Seed, NativeUInt(I) shr 3) then
      Break;
    Inc(I, 8);
  end;
  while I < Limit do
  begin
    if P[I] <> PatternByte(Seed, I) then
      Exit(I);
    Inc(I);
  end;
  Result := -1;
end;

// Offset of the first non-zero byte; -1 - none
function FirstNonZero(P: PByte; Size: NativeInt): NativeInt;
var
  I: NativeInt;
begin
  I := 0;
  while I + 8 <= Size do
  begin
    if PUInt64(P + I)^ <> 0 then
      Break;
    Inc(I, 8);
  end;
  while I < Size do
  begin
    if P[I] <> 0 then
      Exit(I);
    Inc(I);
  end;
  Result := -1;
end;

{ Blocks }

function NewBlock(Size: NativeInt): TBlock;
begin
  Result.Size := Size;
  Result.Seed := NewSeed;
  GetMem(Pointer(Result.P), Size);
  FillPattern(Result.P, Size, Result.Seed);
end;

// The block holds its pattern up to Limit
function Intact(const B: TBlock; Limit: NativeInt; const What: string): Boolean;
var
  Bad: NativeInt;
begin
  Bad := CheckPattern(B.P, Limit, B.Seed);
  Result := Bad < 0;
  if not Result then
    Fail(Format('%s: block %p of %d bytes differs at offset %d', [What, Pointer(B.P), B.Size, Bad]));
end;

// Checks the whole block and frees it
procedure DropBlock(var B: TBlock; const What: string);
begin
  if B.P = nil then
    Exit;
  Intact(B, B.Size, What);
  FreeMem(B.P);
  B.P := nil;
end;

// ReallocMem to NewSize: the kept part must survive, the rest gets the pattern
procedure Resize(var B: TBlock; NewSize: NativeInt; const What: string);
var
  Kept: NativeInt;
begin
  ReallocMem(B.P, NewSize);
  Kept := B.Size;
  if Kept > NewSize then
    Kept := NewSize;
  if NativeUInt(B.P) and 15 <> 0 then
    Fail(Format('%s: %p is not 16-byte aligned', [What, Pointer(B.P)]));
  Intact(B, Kept, What);
  FillPattern(B.P, NewSize, B.Seed, Kept);
  B.Size := NewSize;
end;

{$IFNDEF MM_RTL}
// The smallest size class that holds Size bytes
function ExpectedClass(Size: NativeInt): NativeInt;
var
  I: Integer;
begin
  for I := 0 to SmallClassCount - 1 do
    if SmallClassSizes[I] >= Size then
      Exit(SmallClassSizes[I]);
  Result := 0;
end;
{$ENDIF}

// A new block: aligned to 16 bytes and, in ShardMM, of the kind and size its size calls for
procedure CheckPlace(const B: TBlock; const What: string);
{$IFNDEF MM_RTL}
var
  Usable: NativeUInt;
{$ENDIF}
begin
  if NativeUInt(B.P) and 15 <> 0 then
    Fail(Format('%s: %p of %d bytes is not 16-byte aligned', [What, Pointer(B.P), B.Size]));
{$IFNDEF MM_RTL}
  if B.Size <= SmallMaxSize then
  begin
    if SegmentKindOf(B.P) <> SegmentKindSmall then
      Fail(Format('%s: %d bytes are not a small block', [What, B.Size]))
    else if SmallPageOf(B.P).FItemSize <> NativeUInt(ExpectedClass(B.Size)) then
      Fail(Format('%s: %d bytes are in class %d, not %d',
        [What, B.Size, SmallPageOf(B.P).FItemSize, ExpectedClass(B.Size)]));
  end
  else if B.Size <= MediumMaxSize then
  begin
    if SegmentKindOf(B.P) <> SegmentKindMedium then
      Fail(Format('%s: %d bytes are not a medium block', [What, B.Size]))
    else
    begin
      // the request is rounded up to 16 with the header, and a remainder below MediumMinSplit is
      // not split off
      Usable := MediumSizeOf(B.P);
      if (Usable < NativeUInt(B.Size)) or (Usable >= NativeUInt(B.Size) + MediumMinSplit + 16) then
        Fail(Format('%s: a medium block of %d bytes has %d usable', [What, B.Size, Usable]));
    end;
  end
  else if SegmentKindOf(B.P) <> 0 then
    Fail(Format('%s: %d bytes are not a large block', [What, B.Size]))
  else if LargeSizeOf(B.P) <> (NativeUInt(B.Size) + 15) and not NativeUInt(15) then
    Fail(Format('%s: a large block of %d bytes has %d usable', [What, B.Size, LargeSizeOf(B.P)]));
{$ENDIF}
end;

{$IFNDEF MM_RTL}
// No item of the pages and no chunk of the arenas of these addresses is in use or waits in a
// foreign-free list: for blocks all freed, after the owner of their heap has drained it
procedure CheckDrained(const Addresses: TArray<Pointer>; const What: string);
var
  P: Pointer;
  Page: PSmallPage;
  Arena: PMediumArena;
begin
  for P in Addresses do
    case SegmentKindOf(P) of
      SegmentKindSmall:
        begin
          Page := SmallPageOf(P);
          if (Page.FUsed <> 0) or (Page.FThreadFree <> 0) then
            Fail(Format('%s: the page of %p has %d items in use, foreign-free word %x',
              [What, P, Page.FUsed, Page.FThreadFree]));
        end;
      SegmentKindMedium:
        begin
          Arena := MediumArenaOf(P);
          if (Arena.Used <> 0) or (Arena.ThreadFree <> nil) then
            Fail(Format('%s: the arena of %p has %d chunks in use, foreign-free list %p',
              [What, P, Arena.Used, Arena.ThreadFree]));
        end;
    end;
end;
{$ENDIF}

function PrivateBytes: NativeUInt;
var
  Counters: TProcessMemoryCountersEx;
begin
  FillChar(Counters, SizeOf(Counters), 0);
  Counters.cb := SizeOf(Counters);
  if K32GetProcessMemoryInfo(GetCurrentProcess, Counters, SizeOf(Counters)) then
    Result := Counters.PrivateUsage
  else
    Result := 0;
end;

// Megabytes from Base to Value, negative when Value is below
function Delta(Value, Base: NativeUInt): Int64;
begin
  Result := (Int64(Value) - Int64(Base)) div MB;
end;

{ TTestThread }

constructor TTestThread.Create(const AProc: TProc);
begin
  FProc := AProc;
  inherited Create(False);
end;

procedure TTestThread.Execute;
begin
  try
    FProc();
  except
    on E: Exception do
      Error := E.ClassName + ': ' + E.Message;
  end;
end;

// Runs Proc in a new thread and returns when the thread has exited: its heap is in the stack of
// free heaps by then
procedure InThread(const Proc: TProc);
var
  T: TTestThread;
begin
  T := TTestThread.Create(Proc);
  try
    T.WaitFor;
    if T.Error <> '' then
      Fail('in a thread: ' + T.Error);
  finally
    T.Free;
  end;
end;

{ Edges }

{$IFNDEF MM_RTL}
procedure ExpectInvalidPointer(P: Pointer; const What: string);
begin
  try
    FreeMem(P);
    Fail(What + ': the second FreeMem raised nothing');
  except
    on E: EInvalidPointer do
      ;
    on E: Exception do
      Fail(What + ': the second FreeMem raised ' + E.ClassName);
  end;
end;
{$ENDIF}

procedure TestEdges;
var
  P: Pointer;
{$IFNDEF MM_RTL}
  A, B, C: TBlock;
{$ENDIF}
begin
  GetMem(P, 0);
  Check(P = nil, 'GetMem(0) gave a block');
  P := AllocMem(0);
  Check(P = nil, 'AllocMem(0) gave a block');
  P := nil;
  ReallocMem(P, 0);
  Check(P = nil, 'ReallocMem(nil, 0) gave a block');
  ReallocMem(P, 100);
  Check((P <> nil) and (NativeUInt(P) and 15 = 0), 'ReallocMem(nil, 100) gave no aligned block');
  FillPattern(P, 100, 1);
  ReallocMem(P, 0);
  Check(P = nil, 'ReallocMem(P, 0) left a block');
  FreeMem(nil);

{$IFNDEF MM_RTL}
  Check(ShardGetMem(0) = nil, 'ShardGetMem(0) gave a block');
  Check(ShardGetMem(-1) = nil, 'ShardGetMem(-1) gave a block');
  Check(ShardGetMem(Low(NativeInt)) = nil, 'ShardGetMem(Low(NativeInt)) gave a block');
  Check(ShardAllocMem(0) = nil, 'ShardAllocMem(0) gave a block');
  Check(ShardAllocMem(-16) = nil, 'ShardAllocMem(-16) gave a block');
  Check(ShardFreeMem(nil) = 0, 'ShardFreeMem(nil) failed');
  Check(ShardReallocMem(nil, 0) = nil, 'ShardReallocMem(nil, 0) gave a block');
  Check(ShardReallocMem(nil, -1) = nil, 'ShardReallocMem(nil, -1) gave a block');
  P := ShardReallocMem(nil, 40);
  Check(P <> nil, 'ShardReallocMem(nil, 40) gave nothing');
  Check(ShardReallocMem(P, -1) = nil, 'ShardReallocMem(P, -1) kept the block');

  // a second free of a medium block whose neighbours are in use, and of a large block, is reported
  // (of a small block it is not: an item has no field to mark it)
  A := NewBlock(40000);
  B := NewBlock(40000);
  C := NewBlock(40000);
  if (NativeUInt(B.P) = NativeUInt(A.P) + MediumSizeOf(A.P) + MediumHeaderSize) and
     (NativeUInt(C.P) = NativeUInt(B.P) + MediumSizeOf(B.P) + MediumHeaderSize) then
  begin
    P := B.P;
    DropBlock(B, 'medium double free');
    ExpectInvalidPointer(P, 'medium block');
  end
  else
  begin
    Skip('the three medium blocks are not adjacent');
    DropBlock(B, 'medium double free');
  end;
  DropBlock(A, 'medium double free');
  DropBlock(C, 'medium double free');
  A := NewBlock(2 * MB);
  P := A.P;
  DropBlock(A, 'large double free');
  ExpectInvalidPointer(P, 'large block');
{$ENDIF}
end;

{ Size classes }

// One live block of every size from 1 to SmallMaxSize at once
procedure TestSmallSizes;
var
  Blocks: TArray<TBlock>;
  S: NativeInt;
{$IFNDEF MM_RTL}
  I: Integer;
{$ENDIF}
begin
{$IFNDEF MM_RTL}
  for I := 0 to SmallClassCount - 1 do
    if (SmallClassSizes[I] mod 16 <> 0) or ((I > 0) and (SmallClassSizes[I] <= SmallClassSizes[I - 1])) then
      Fail(Format('class %d (%d bytes) breaks the order of multiples of 16', [I, SmallClassSizes[I]]));
  Check(SmallClassSizes[SmallClassCount - 1] = SmallMaxSize, 'the last class is not SmallMaxSize');
{$ENDIF}
  SetLength(Blocks, SmallMaxSize + 1);
  for S := 1 to SmallMaxSize do
  begin
    Blocks[S] := NewBlock(S);
    CheckPlace(Blocks[S], 'small sizes');
  end;
  for S := 1 to SmallMaxSize do
    Intact(Blocks[S], S, 'small sizes');
  // every second one is freed from the top and allocated again from the bottom: the freed items
  // are handed out again among the live ones
  for S := SmallMaxSize downto 1 do
    if Odd(S) then
      DropBlock(Blocks[S], 'small sizes, first round');
  for S := 1 to SmallMaxSize do
    if Odd(S) then
    begin
      Blocks[S] := NewBlock(S);
      CheckPlace(Blocks[S], 'small sizes, second round');
    end;
  for S := 1 to SmallMaxSize do
    DropBlock(Blocks[S], 'small sizes, second round');
end;

// Medium sizes at the thresholds and in a sweep, three blocks of each; then a mixed set with frees
// in between, so chunks are split and merged
procedure TestMediumSizes;
const
  Fixed: array[0..16] of NativeInt = (SmallMaxSize + 1, SmallMaxSize + 15, SmallMaxSize + 16,
    SmallMaxSize + 17, 20000, 32767, 32768, 32769, 65535, 65536, 65537, 131072, 524288,
    MediumMaxSize - 256, MediumMaxSize - 16, MediumMaxSize - 1, MediumMaxSize);
var
  Sizes: TArray<NativeInt>;
  Size: NativeInt;
  Three: array[0..2] of TBlock;
  Mixed: TArray<TBlock>;
  I: Integer;
begin
  for Size in Fixed do
    Sizes := Sizes + [Size];
  Size := SmallMaxSize + 1;
  while Size <= MediumMaxSize do
  begin
    Sizes := Sizes + [Size];
    Inc(Size, 4093);
  end;
  for Size in Sizes do
  begin
    for I := 0 to 2 do
    begin
      Three[I] := NewBlock(Size);
      CheckPlace(Three[I], 'medium sizes');
    end;
    for I := 0 to 2 do
      Intact(Three[I], Size, 'medium sizes');
    DropBlock(Three[1], 'medium sizes');
    DropBlock(Three[0], 'medium sizes');
    DropBlock(Three[2], 'medium sizes');
  end;

  SetLength(Mixed, 400);
  for I := 0 to 299 do
    Mixed[I] := NewBlock(SmallMaxSize + 1 + NativeInt(RandomBelow(300000)));
  for I := 0 to 299 do
    if I mod 3 = 0 then
      DropBlock(Mixed[I], 'medium mixed set');
  for I := 300 to 399 do
    Mixed[I] := NewBlock(SmallMaxSize + 1 + NativeInt(RandomBelow(300000)));
  for I := 0 to 399 do
    if (Mixed[I].P <> nil) and (I mod 5 = 1) then
      Resize(Mixed[I], SmallMaxSize + 1 + NativeInt(RandomBelow(300000)), 'medium mixed set, resized');
  for I := 0 to 399 do
    DropBlock(Mixed[I], 'medium mixed set');
end;

procedure TestLargeSizes;
const
  Sizes: array[0..11] of NativeInt = (MediumMaxSize + 1, MediumMaxSize + 15, MediumMaxSize + 16,
    MediumMaxSize + 17, 2 * MB - 1, 2 * MB, 2 * MB + 1, 16 * MB - 48, 16 * MB - 32, 16 * MB,
    16 * MB + 1, 100 * MB);
var
  Size: NativeInt;
  Two: array[0..1] of TBlock;
  I: Integer;
begin
  for Size in Sizes do
  begin
    for I := 0 to 1 do
    begin
      Two[I] := NewBlock(Size);
      CheckPlace(Two[I], 'large sizes');
    end;
    for I := 0 to 1 do
      DropBlock(Two[I], 'large sizes');
  end;
end;

{ AllocMem }

// Count blocks of Size are filled with $A5 and freed, then the same number is taken by AllocMem:
// those are the same, dirty items, and they must come back zeroed
procedure DirtyThenZero(Size: NativeInt; Count: Integer; const What: string);
var
  Blocks: TArray<Pointer>;
  I: Integer;
  Bad: NativeInt;
begin
  SetLength(Blocks, Count);
  for I := 0 to Count - 1 do
  begin
    GetMem(Blocks[I], Size);
    FillChar(Blocks[I]^, Size, $A5);
  end;
  for I := 0 to Count - 1 do
    FreeMem(Blocks[I]);
  for I := 0 to Count - 1 do
    Blocks[I] := AllocMem(Size);
  for I := 0 to Count - 1 do
  begin
    Bad := FirstNonZero(Blocks[I], Size);
    if Bad >= 0 then
      Fail(Format('%s: AllocMem(%d) gave %p with a non-zero byte at offset %d', [What, Size, Blocks[I], Bad]));
    FreeMem(Blocks[I]);
  end;
end;

procedure TestAllocMem;
const
{$IFDEF MM_RTL}
  SmallSizes: array[0..9] of NativeInt = (1, 16, 48, 64, 100, 1000, 2048, 4096, 10000, SmallMaxSize);
{$ENDIF}
  MediumSizes: array[0..3] of NativeInt = (SmallMaxSize + 1, 40000, 300000, MediumMaxSize);
{$IFNDEF MM_RTL}
  DirectSizes: array[0..2] of NativeInt = (48, 30000, 3 * MB);
{$ENDIF}
var
  Size: NativeInt;
  P: Pointer;
  Bad: NativeInt;
{$IFNDEF MM_RTL}
  I: Integer;
{$ENDIF}
begin
{$IFNDEF MM_RTL}
  for I := 0 to SmallClassCount - 1 do
  begin
    DirtyThenZero(SmallClassSizes[I], 64, 'small class');
    DirtyThenZero(SmallClassSizes[I] - 1, 64, 'small class');
  end;
{$ELSE}
  for Size in SmallSizes do
    DirtyThenZero(Size, 64, 'small');
{$ENDIF}
  for Size in MediumSizes do
    DirtyThenZero(Size, 8, 'medium');
  DirtyThenZero(3 * MB, 2, 'large');

  // a freed large block waits in the cache and comes back dirty: smaller than it was, and larger,
  // which commits the rest in place
  GetMem(P, 3 * MB);
  FillChar(P^, 3 * MB, $A5);
  FreeMem(P);
  P := AllocMem(2 * MB);
  Bad := FirstNonZero(P, 2 * MB);
  Check(Bad < 0, Format('AllocMem of 2 MB after a freed 3 MB block: non-zero byte at offset %d', [Bad]));
  FillChar(P^, 2 * MB, $A5);
  FreeMem(P);
  P := AllocMem(5 * MB);
  Bad := FirstNonZero(P, 5 * MB);
  Check(Bad < 0, Format('AllocMem of 5 MB after a freed 2 MB block: non-zero byte at offset %d', [Bad]));
  FreeMem(P);

{$IFNDEF MM_RTL}
  for Size in DirectSizes do
  begin
    P := ShardGetMem(Size);
    FillChar(P^, Size, $A5);
    ShardFreeMem(P);
    P := ShardAllocMem(Size);
    Bad := FirstNonZero(P, Size);
    Check(Bad < 0, Format('ShardAllocMem(%d): non-zero byte at offset %d', [Size, Bad]));
    ShardFreeMem(P);
  end;
{$ENDIF}
end;

{ ReallocMem }

// Every pair of sizes from tiny small blocks to large ones: the kept part survives the move, and the
// whole new size can be written
procedure TestReallocMoves;
const
  Sizes: array[0..16] of NativeInt = (1, 15, 16, 17, 100, 1000, 2048, 2049, 5000, SmallMaxSize,
    SmallMaxSize + 1, 20000, 100000, MediumMaxSize, MediumMaxSize + 1, 3 * MB, 20 * MB);
var
  From, Into, S: NativeInt;
  B: TBlock;
  Old: PByte;
  Moves: Integer;
begin
  for From in Sizes do
    for Into in Sizes do
    begin
      B := NewBlock(From);
      Resize(B, Into, Format('ReallocMem %d -> %d', [From, Into]));
      DropBlock(B, Format('ReallocMem %d -> %d', [From, Into]));
    end;

  // grown by one byte at a time up to 70000 bytes, as a string appended a character at a time
  B := NewBlock(1);
  Moves := 0;
  for S := 2 to 70000 do
  begin
    Old := B.P;
    ReallocMem(B.P, S);
    if B.P <> Old then
    begin
      Inc(Moves);
      Intact(B, S - 1, 'growth by one byte, after a move');
    end
    else if B.P[S - 2] <> PatternByte(B.Seed, S - 2) then
      Fail(Format('growth by one byte to %d: the last kept byte changed', [S]));
    B.P[S - 1] := PatternByte(B.Seed, S - 1);
    B.Size := S;
  end;
  DropBlock(B, 'growth by one byte');
  Writeln(Format('  growth by one byte to 70000 bytes moved the block %d times', [Moves]));
{$IFNDEF MM_RTL}
  // the headroom of a move: a half plus 32 bytes for small blocks, a quarter for medium ones
  Check(Moves <= 64, 'too many moves on growth by one byte');
{$ENDIF}

  // halved from 4 MB down to one byte
  B := NewBlock(4 * MB);
  S := 4 * MB;
  while S > 1 do
  begin
    S := S div 2;
    Resize(B, S, Format('shrink to %d', [S]));
  end;
  DropBlock(B, 'shrink by halves');
end;

{$IFNDEF MM_RTL}
// A small block keeps its place while the new size is within its class and not below a quarter of it
// less 64 bytes; a medium block of the own thread when shrinking and when a free chunk follows; a
// large block within its reservation
procedure TestReallocInPlace;
var
  I: Integer;
  C, S, Lowest, Grown: NativeInt;
  P, Q: Pointer;
  A, B, G: TBlock;
  Old: PByte;
begin
  for I := 0 to SmallClassCount - 1 do
  begin
    C := SmallClassSizes[I];
    GetMem(P, C);
    PByte(P)^ := $5A;
    for S := C downto 1 do
    begin
      Q := P;
      ReallocMem(Q, S);
      if S + 64 >= C shr 2 then
      begin
        if Q <> P then
        begin
          Fail(Format('class %d: ReallocMem to %d moved the block', [C, S]));
          P := Q;
          Break;
        end;
      end
      else
      begin
        if Q = P then
          Fail(Format('class %d: ReallocMem to %d left the block in place', [C, S]))
        else if SmallPageOf(Q).FItemSize <> NativeUInt(ExpectedClass(S)) then
          Fail(Format('class %d: ReallocMem to %d moved it to class %d, not %d',
            [C, S, SmallPageOf(Q).FItemSize, ExpectedClass(S)]))
        else if PByte(Q)^ <> $5A then
          Fail(Format('class %d: ReallocMem to %d lost the first byte', [C, S]));
        FreeMem(Q);
        GetMem(P, C);
        PByte(P)^ := $5A;
      end;
    end;

    // back up to the whole class from the lowest size kept in place, then one byte beyond it
    Lowest := C shr 2 - 64;
    if Lowest < 1 then
      Lowest := 1;
    Q := P;
    ReallocMem(Q, Lowest);
    Check(Q = P, Format('class %d: ReallocMem to %d moved the block', [C, Lowest]));
    P := Q;
    ReallocMem(Q, C);
    Check(Q = P, Format('class %d: growth within the class moved the block', [C]));
    P := Q;
    ReallocMem(Q, C + 1);
    Check(Q <> P, Format('class %d: growth beyond the class kept the block in place', [C]));
    Grown := C + 1 + (C + 1) shr 1 + 32;
    if Grown <= SmallMaxSize then
      Check(SmallPageOf(Q).FItemSize = NativeUInt(ExpectedClass(Grown)),
        Format('class %d: growth to %d went to class %d, not %d with the headroom',
          [C, C + 1, SmallPageOf(Q).FItemSize, ExpectedClass(Grown)]))
    else
      Check(SegmentKindOf(Q) = SegmentKindMedium, Format('class %d: growth to %d is not a medium block', [C, C + 1]));
    Check(PByte(Q)^ = $5A, Format('class %d: growth lost the first byte', [C]));
    FreeMem(Q);
  end;

  // a medium block grows into the free chunk after it and shrinks in place
  A := NewBlock(100000);
  B := NewBlock(100000);
  G := NewBlock(100000);
  if NativeUInt(B.P) = NativeUInt(A.P) + MediumSizeOf(A.P) + MediumHeaderSize then
  begin
    DropBlock(B, 'medium in place');
    Old := A.P;
    Resize(A, 180000, 'medium growth into a free neighbour');
    Check(A.P = Old, 'medium growth into a free neighbour moved the block');
    Resize(A, 40000, 'medium shrink');
    Check(A.P = Old, 'medium shrink moved the block');
    Check(MediumSizeOf(A.P) < 40000 + MediumMinSplit + 16, Format('medium shrink to 40000 kept %d bytes', [MediumSizeOf(A.P)]));
    // with a block in use after it, growth moves it
    B := NewBlock(20000);
    Resize(A, 60000, 'medium growth');
    if NativeUInt(B.P) = NativeUInt(Old) + MediumSizeOf(Old) + MediumHeaderSize then
      Check(A.P <> Old, 'medium growth over a block in use kept the place');
    Resize(A, 10000, 'medium to small');
    Check(SegmentKindOf(A.P) = SegmentKindSmall, 'a medium block shrunk to 10000 bytes is not small');
  end
  else
    Skip('the medium blocks are not adjacent');
  DropBlock(A, 'medium in place');
  DropBlock(B, 'medium in place');
  DropBlock(G, 'medium in place');

  // a large block: its reservation is at least 16 MB, growth within it and shrinking keep the place
  A := NewBlock(2 * MB);
  Old := A.P;
  Resize(A, 8 * MB, 'large growth within the reservation');
  Check(A.P = Old, 'large growth to 8 MB moved the block');
  Resize(A, 6 * MB, 'large shrink by less than half');
  Check(A.P = Old, 'large shrink to 6 MB moved the block');
  Resize(A, 3 * MB, 'large shrink by more than half');
  Check(A.P = Old, 'large shrink to 3 MB moved the block');
  Resize(A, 40 * MB, 'large growth');
  Resize(A, 500 * KB, 'large to medium');
  Check(SegmentKindOf(A.P) = SegmentKindMedium, 'a large block shrunk to 500 KB is not medium');
  DropBlock(A, 'large in place');
end;
{$ENDIF}

{ Thread exit }

// Blocks of every kind allocated in a thread are read, resized and freed after it has exited
procedure TestOutliveThread;
const
  Sizes: array[0..11] of NativeInt = (1, 40, 64, 300, 2048, 2049, SmallMaxSize, SmallMaxSize + 1,
    100000, MediumMaxSize, MediumMaxSize + 1, 5 * MB);
var
  Blocks: TArray<TBlock>;
  I: Integer;
{$IFNDEF MM_RTL}
  Old: PByte;
{$ENDIF}
begin
  SetLength(Blocks, Length(Sizes));
  InThread(
    procedure
    var
      I: Integer;
    begin
      for I := 0 to High(Blocks) do
        Blocks[I] := NewBlock(Sizes[I]);
    end);
  for I := 0 to High(Blocks) do
  begin
    CheckPlace(Blocks[I], 'after the thread exited');
    Intact(Blocks[I], Blocks[I].Size, 'after the thread exited');
  end;
  for I := 0 to High(Blocks) do
  begin
    if Blocks[I].Size <= SmallMaxSize then
    begin
      if Blocks[I].Size > 1 then
      begin
{$IFNDEF MM_RTL}
        Old := Blocks[I].P;
{$ENDIF}
        Resize(Blocks[I], Blocks[I].Size - 1, 'small block of an exited thread, shrunk');
{$IFNDEF MM_RTL}
        // the in-place rule does not depend on the owner
        Check(Blocks[I].P = Old, Format('a small block of %d bytes of an exited thread moved on a shrink by one byte',
          [Blocks[I].Size + 1]));
{$ENDIF}
      end;
    end
    else
      Resize(Blocks[I], Blocks[I].Size * 2, 'block of an exited thread, grown');
  end;
  for I := 0 to High(Blocks) do
    DropBlock(Blocks[I], 'block of an exited thread');
end;

{$IFNDEF MM_RTL}
// The next thread takes the heap at the top of the stack of free heaps and drains its foreign frees
// when it exits
procedure DrainTopHeap;
begin
  InThread(
    procedure
    var
      P: Pointer;
    begin
      GetMem(P, 48);
      FreeMem(P);
    end);
end;
{$ENDIF}

const
  PooledSmall = 4000;
  PooledMedium = 64;

// A thread allocates and exits; this thread frees its blocks while the heap waits in the stack of
// free heaps; the next thread gets that heap, allocates as many again and checks them
procedure PooledHeapRound(Wait: Boolean; const What: string);
var
  A, B: TArray<TBlock>;
  Addresses: TArray<Pointer>;
  Name: string;
  I, Count: Integer;
  P: Pointer;
begin
  Name := What;
  SetLength(A, PooledSmall + PooledMedium);
  SetLength(B, PooledSmall + PooledMedium);
  SetLength(Addresses, Length(A) + Length(B));
  Count := 0;
  InThread(
    procedure
    var
      I: Integer;
    begin
      for I := 0 to PooledSmall - 1 do
        A[I] := NewBlock(48);
      for I := PooledSmall to High(A) do
        A[I] := NewBlock(30000);
    end);
  for I := 0 to High(A) do
  begin
    Addresses[Count] := A[I].P;
    Inc(Count);
    DropBlock(A[I], What + ': freed after its thread exited');
  end;
  if Wait then
  begin
    // the reserve of the heaps in the stack goes back to the system at the next slow path of any
    // thread after the deadline
    Sleep(ExpiryWait);
    GetMem(P, 20000);
    FreeMem(P);
  end;
  InThread(
    procedure
    var
      I: Integer;
    begin
      for I := 0 to PooledSmall - 1 do
        B[I] := NewBlock(48);
      for I := PooledSmall to High(B) do
        B[I] := NewBlock(30000);
      for I := 0 to High(B) do
        Intact(B[I], B[I].Size, Name + ': allocated in the reused heap');
      for I := 0 to High(B) do
        if Odd(I) then
          DropBlock(B[I], Name + ': freed by its thread');
    end);
{$IFNDEF MM_RTL}
  Check(SmallHeapOf(B[0].P) = SmallHeapOf(Addresses[0]),
    What + ': the next thread did not get the heap of the exited one');
{$ENDIF}
  for I := 0 to High(B) do
    if B[I].P <> nil then
    begin
      Addresses[Count] := B[I].P;
      Inc(Count);
      DropBlock(B[I], What + ': freed after its thread exited');
    end;
  SetLength(Addresses, Count);
{$IFNDEF MM_RTL}
  DrainTopHeap;
  CheckDrained(Addresses, What);
{$ENDIF}
end;

procedure TestPooledHeap;
begin
  PooledHeapRound(False, 'at once');
  PooledHeapRound(True, 'after the reserve expired');
end;

const
  ChainThreads = 64;
  ChainBlocks = 50;

function ChainSize(Index: Integer): NativeInt;
begin
  case Index mod ChainBlocks of
    0: Result := 2 * MB;
    1: Result := 17000;
    2: Result := 70000;
    3: Result := 300000;
  else
    Result := 1 + (Index * 37) mod 2000;
  end;
end;

// Short threads one after another, each leaving its blocks alive: every thread gets the heap of the
// previous one with its live blocks and allocates next to them
procedure TestThreadChain;
var
  All: TArray<TBlock>;
  Addresses: TArray<Pointer>;
  T, First, I: Integer;
begin
  SetLength(All, ChainThreads * ChainBlocks);
  for T := 0 to ChainThreads - 1 do
  begin
    First := T * ChainBlocks;
    InThread(
      procedure
      var
        I: Integer;
      begin
        for I := First to First + ChainBlocks - 1 do
          All[I] := NewBlock(ChainSize(I));
      end);
  end;
  for I := 0 to High(All) do
    Intact(All[I], All[I].Size, 'chain of threads');
  SetLength(Addresses, Length(All));
  for I := 0 to High(All) do
  begin
    Addresses[I] := All[I].P;
    DropBlock(All[I], 'chain of threads');
  end;
{$IFNDEF MM_RTL}
  DrainTopHeap;
  CheckDrained(Addresses, 'chain of threads');
{$ENDIF}
end;

// A thread allocates 256 MB of medium and 48 MB of small blocks, frees them and exits: its heap keeps
// a reserve for the next thread, and after the deadline the reserve goes back to the system; the
// large-block cache empties after its delay
procedure TestMemoryReturn;
{$IFNDEF MM_RTL}
var
  Base, Peak, AfterExit, AfterExpiry, Cached, AfterCache: NativeUInt;
  P: Pointer;
  Large: array[0..9] of Pointer;
  I: Integer;
{$ENDIF}
begin
{$IFDEF MM_RTL}
  Skip('ShardMM''s reserve rules');
{$ELSE}
  Base := PrivateBytes;
  Peak := 0;
  InThread(
    procedure
    var
      Medium, Small: TArray<Pointer>;
      I: Integer;
    begin
      SetLength(Medium, 8192);
      SetLength(Small, 100000);
      for I := 0 to High(Medium) do
        GetMem(Medium[I], 32000);
      for I := 0 to High(Small) do
        GetMem(Small[I], 480);
      Peak := PrivateBytes;
      for I := 0 to High(Medium) do
        FreeMem(Medium[I]);
      for I := 0 to High(Small) do
        FreeMem(Small[I]);
    end);
  AfterExit := PrivateBytes;
  Sleep(ExpiryWait);
  GetMem(P, 20000);
  FreeMem(P);
  AfterExpiry := PrivateBytes;
  Writeln(Format('  private bytes over the start: peak %d MB, after the exit %d MB, after the deadline %d MB',
    [Delta(Peak, Base), Delta(AfterExit, Base), Delta(AfterExpiry, Base)]));
  Check(Peak > Base + 280 * MB, 'the blocks did not commit the memory they take');
  Check(AfterExit < Base + 48 * MB, 'the exited thread kept more than its reserve');
  Check(AfterExpiry < Base + 24 * MB, 'the reserve of the pooled heap did not go back to the system');

  // the large blocks of the earlier tests have waited past the delay above: a large allocation
  // returns them, and the cache holds only this block
  GetMem(P, 2 * MB);
  FreeMem(P);
  Base := PrivateBytes;
  for I := 0 to High(Large) do
  begin
    GetMem(Large[I], 8 * MB);
    FillChar(Large[I]^, 8 * MB, 1);
  end;
  for I := 0 to High(Large) do
    FreeMem(Large[I]);
  Cached := PrivateBytes;
  Sleep(ExpiryWait);
  // a large allocation looks at the cache and returns the blocks older than its delay
  GetMem(P, 2 * MB);
  FreeMem(P);
  AfterCache := PrivateBytes;
  Writeln(Format('  large blocks: %d MB in the cache, %d MB after its delay',
    [Delta(Cached, Base), Delta(AfterCache, Base)]));
  Check(Cached > Base + 64 * MB, 'freed large blocks did not stay in the cache');
  Check(AfterCache < Base + 16 * MB, 'the large-block cache did not empty after its delay');
{$ENDIF}
end;

{ Out of memory }

procedure ExpectOutOfMemory(const What: string; const Action: TProc);
begin
  try
    Action();
    Fail(What + ': no exception');
  except
    on E: EOutOfMemory do
      ;
    on E: Exception do
      Fail(What + ': ' + E.ClassName + ' instead of EOutOfMemory');
  end;
end;

// Sizes nobody can have: beyond the address space, and 4 TB, whose reservation fits the address space
// while its commit exceeds the commit limit. Nothing is allocated, the exception is EOutOfMemory, a
// block that was to be resized keeps its place and contents, and the manager keeps working
procedure TestOutOfMemory;
const
  Huge: array[0..2] of NativeInt = (High(NativeInt), High(NativeInt) div 2, NativeInt(1) shl 42);
  Kinds: array[0..2] of NativeInt = (100, 50000, 3 * MB);
  After: array[0..3] of NativeInt = (16, 3000, 50000, 3 * MB);
var
  H, Size, HugeSize: NativeInt;
  B: TBlock;
  Kept: PByte;
begin
  for H in Huge do
  begin
    // a loop variable cannot be captured
    HugeSize := H;
    ExpectOutOfMemory(Format('GetMem(%d)', [H]),
      procedure
      var
        P: Pointer;
      begin
        GetMem(P, HugeSize);
        FreeMem(P);
      end);
    ExpectOutOfMemory(Format('AllocMem(%d)', [H]),
      procedure
      begin
        FreeMem(AllocMem(HugeSize));
      end);
    for Size in Kinds do
    begin
      B := NewBlock(Size);
      Kept := B.P;
      ExpectOutOfMemory(Format('ReallocMem of %d bytes to %d', [Size, H]),
        procedure
        begin
          ReallocMem(B.P, HugeSize);
        end);
      Check(B.P = Kept, Format('a failed ReallocMem of %d bytes to %d changed the pointer', [Size, H]));
      Intact(B, Size, Format('after a failed ReallocMem to %d', [H]));
      Resize(B, Size * 2, 'growth after a failed ReallocMem');
      DropBlock(B, 'after a failed ReallocMem');
    end;
  end;
  for Size in After do
  begin
    B := NewBlock(Size);
    CheckPlace(B, 'after out of memory');
    DropBlock(B, 'after out of memory');
  end;
end;

begin
{$IFDEF MM_RTL}
  Writeln('memory manager: RTL');
{$ELSE}
  Writeln('memory manager: ShardMM');
{$ENDIF}
  Run('edges: nil, zero and negative sizes, double free', TestEdges);
  Run('small blocks: every size up to SmallMaxSize at once', TestSmallSizes);
  Run('medium blocks: thresholds, a sweep, a mixed set', TestMediumSizes);
  Run('large blocks: thresholds', TestLargeSizes);
  Run('AllocMem: reused memory comes back zeroed', TestAllocMem);
  Run('ReallocMem: contents across all kinds of blocks', TestReallocMoves);
{$IFNDEF MM_RTL}
  Run('ReallocMem: in-place rules', TestReallocInPlace);
{$ENDIF}
  Run('thread exit: blocks outlive their thread', TestOutliveThread);
  Run('thread exit: foreign frees into a pooled heap', TestPooledHeap);
  Run('thread exit: a chain of short threads', TestThreadChain);
  Run('thread exit: memory goes back to the system', TestMemoryReturn);
  Run('out of memory', TestOutOfMemory);
  Writeln(Format('failures: %d', [Failures]));
  ExitCode := Failures;
end.

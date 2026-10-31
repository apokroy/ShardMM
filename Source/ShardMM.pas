// ShardMM: a scalable memory manager for Delphi on Win64
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
unit ShardMM;

(* Design

   Win64 only. By size a block is small (up to SmallMaxSize, pages of ShardMM.Small), medium (up to
   MediumMaxSize, arenas of ShardMM.Medium) or large (its own reservation, ShardMM.Large). The kind of
   a block by its address comes from the segment map (ShardMM.Segments): small and medium blocks live
   in segments of their kind, a large block lives outside segments and carries a mark in its header.

   Every thread has its own heap TThreadHeap - small and medium blocks; large blocks are shared. The
   heap pointer sits in an own TLS slot rather than in a threadvar: reading a threadvar on Win64 is a
   call to SysInit.@GetTls and two more loads, the slot is one load from gs:[offset] without a call.
   Slots 0..63 live in the TEB itself (TlsSlots, gs:[$1480]), the others in the array at gs:[$1780]
   (TlsExpansionSlots) that Windows creates on the first write to such a slot.

   When a thread exits, its heap goes as a whole, with all its pages and arenas, to the stack of free
   heaps (ThreadExitCallback: the FLS callback runs when any thread exits - a TThread, a Windows pool
   thread or a C library thread), and the next thread gets it already warmed up. Blocks other threads
   free while the heap waits in the stack gather in its foreign-free queues and are drained by the
   new owner. The stack changes with one 16-byte CAS on the top and a change counter: the counter
   rules out ABA when the top is popped. Heaps are never freed, so the owner recorded in a segment or
   an arena when it was created is always valid. The exiting thread leaves the heap a reserve for the
   next one - SmallExitFreePages free pages and MediumExitArenasCommitted empty arenas - and returns
   the rest of its free memory to the system at once; the reserve goes back to the system after
   PoolReserveDelay if nobody took the heap by then (ExpirePoolReserve).

   The fast paths ShardGetMem and ShardFreeMem - a small block of the own thread - are assembler
   without calls and without a stack frame; everything else jumps to the slow path in Pascal with the
   same registers. The fast paths do not look at the foreign-free queues: the slow paths drain them. *)

interface

{$R-}{$Q-}{$INLINE ON}

function ShardGetMem(aSize: NativeInt): Pointer;
function ShardAllocMem(aSize: NativeInt): Pointer;
function ShardFreeMem(aMemory: Pointer): Integer;
function ShardReallocMem(aMemory: Pointer; aSize: NativeInt): Pointer;

implementation

uses
  ShardMM.Platform, ShardMM.Segments, ShardMM.Small, ShardMM.Medium, ShardMM.Large;

type
  PThreadHeap = ^TThreadHeap;

  /// Heap of a thread. Small blocks first: their FDirect and class lists, needed by every slow
  /// allocation, lie in the first page of the heap. Both parts are multiples of 64 in size, so each
  /// starts at a cache-line boundary, and the first line of each is its foreign-free queue
  TThreadHeap = record
    SmallHeap: TSmallHeap;
    MediumHeap: TMediumHeap;
    /// next heap in the stack of free heaps
    NextFree: PThreadHeap;
  end;

  /// Top of the stack of free heaps and its change counter; in its own page - cmpxchg16b needs
  /// 16-byte alignment
  TThreadPoolHead = record
    Top: PThreadHeap;
    Tag: NativeUInt;
  end;
  PThreadPoolHead = ^TThreadPoolHead;

var
  GTlsIndex: Cardinal;
  /// $1480 + 8 * GTlsIndex for a slot of TlsSlots, 0 for a slot of TlsExpansionSlots
  GTlsOffset: NativeUInt;
  GFlsIndex: Cardinal;
  GPool: PThreadPoolHead;
  /// InterruptTime after which the reserve of the heaps in the stack of free heaps goes back to the
  /// system; 0 - no heap with a reserve in the stack
  GPoolReserveDeadline: Int64;

const
  /// how long a heap in the stack of free heaps keeps a reserve for the next thread: one second in
  /// the 100 ns units of InterruptTime
  PoolReserveDelay = 10000000;

// Heap of the current thread; nil if the thread has not allocated yet
function CurrentHeap: PThreadHeap;
asm
  .noframe
  mov rcx, GTlsOffset
  test rcx, rcx
  jz @Expansion
  mov rax, gs:[rcx]
  ret
@Expansion:
  mov ecx, $1780
  mov rax, gs:[rcx]
  test rax, rax
  jz @Done
  mov ecx, GTlsIndex
  mov rax, [rax + rcx * 8 - 64 * 8]
@Done:
end;

// A heap for the current thread: the top of the stack of free heaps or a new one
function AcquireHeap: PThreadHeap;
var
  old: TThreadPoolHead;
  heap: PThreadHeap;
begin
  repeat
    old := GPool^;
    heap := old.Top;
    if heap = nil then
      Break;
    // NextFree of a heap another thread popped meanwhile may have changed, but then the CAS fails
    // on the counter
  until CAS128(GPool^, NativeUInt(old.Top), old.Tag, NativeUInt(heap.NextFree), old.Tag + 1);
  if heap = nil then
  begin
    heap := VirtualAlloc(nil, SizeOf(TThreadHeap), MemCommit, PageReadWrite);
    if heap = nil then
      OutOfMemory;
    heap.SmallHeap.Setup;
  end;
  heap.NextFree := nil;
  TlsSetValue(GTlsIndex, heap);
  FlsSetValue(GFlsIndex, heap);
  Result := heap;
end;

function ThreadHeap: PThreadHeap; inline;
begin
  Result := CurrentHeap;
  if not Assigned(Result) then
    Result := AcquireHeap;
end;

// The reserve of the heaps in the stack of free heaps goes back to the system when the first of
// them entered the stack PoolReserveDelay ago: a heap in the stack has no owner to return memory on
// a deadline. The stack is taken as a whole, and its heaps belong to this thread while being
// trimmed; a thread that starts working meanwhile creates a new heap
procedure ExpirePoolReserve;
var
  deadline: Int64;
  old: TThreadPoolHead;
  first, last: PThreadHeap;
begin
  deadline := GPoolReserveDeadline;
  if (deadline = 0) or (InterruptTime < deadline) or
     (AtomicCmpExchange(GPoolReserveDeadline, 0, deadline) <> deadline) then
    Exit;
  repeat
    old := GPool^;
    if old.Top = nil then
      Exit;
  until CAS128(GPool^, NativeUInt(old.Top), old.Tag, 0, old.Tag + 1);
  first := old.Top;
  last := first;
  // The heaps taken off the stack belong to this thread until they go back: it drains their foreign-free
  // queues as their owner, so blocks other threads freed into a heap nobody takes are returned too, and
  // pages and arenas they emptied are trimmed with the rest
  while True do
  begin
    last.SmallHeap.CollectThreadFree;
    last.MediumHeap.ProcessThreadFree;
    last.SmallHeap.TrimFreePages(0, SmallFreePagesCommitted);
    last.MediumHeap.TrimEmptyArenas(0, MediumEmptyArenasCommitted);
    if last.NextFree = nil then
      Break;
    last := last.NextFree;
  end;
  repeat
    old := GPool^;
    last.NextFree := old.Top;
  until CAS128(GPool^, NativeUInt(old.Top), old.Tag, NativeUInt(first), old.Tag + 1);
end;

// The FLS callback runs in the exiting thread while its TLS is still in place. The heap still works
// with memory as the owner (it drains foreign frees), so the thread's slot is cleared afterwards:
// otherwise the next allocation would give the exiting thread a new heap nobody would ever return
procedure ThreadExitCallback(aData: Pointer); stdcall;
var
  heap: PThreadHeap;
  old: TThreadPoolHead;
begin
  heap := aData;
  if heap = nil then
    Exit;
  heap.SmallHeap.CollectThreadFree;
  heap.MediumHeap.ProcessThreadFree;
  // a reserve for the next thread; the rest of the free memory goes back to the system at once, the
  // reserve after PoolReserveDelay (ExpirePoolReserve) if nobody takes the heap by then
  heap.SmallHeap.TrimFreePages(0, SmallExitFreePages);
  heap.MediumHeap.TrimEmptyArenas(0, MediumExitArenasCommitted);
  LargeCacheExpire;
  ExpirePoolReserve;
  repeat
    old := GPool^;
    heap.NextFree := old.Top;
  until CAS128(GPool^, NativeUInt(old.Top), old.Tag, NativeUInt(heap), old.Tag + 1);
  if GPoolReserveDeadline = 0 then
    GPoolReserveDeadline := InterruptTime + PoolReserveDelay;
  TlsSetValue(GTlsIndex, nil);
end;

// The foreign-free queue of medium blocks; the small-block one is drained by AllocSlow when a page
// runs out of items
procedure ProcessMediumThreadFree(aHeap: PThreadHeap); inline;
begin
  if aHeap.MediumHeap.ThreadFreeArenas <> nil then
    aHeap.MediumHeap.ProcessThreadFree;
end;

// The deadline of the reserve in the stack of free heaps is checked by the slow paths: the fast ones
// have no cycles to spare, and the slow ones run in any thread that works with memory at all. The
// check is two loads without calls: the deadline and the InterruptTime field (ShardMM.Platform's
// InterruptTime is not expanded inside an inline function, so the field is read right here); nobody
// writes either cache line per operation
procedure CheckPoolReserve; inline;
begin
  if (GPoolReserveDeadline <> 0) and (PInt64(NativeUInt(KUserInterruptTime))^ >= GPoolReserveDeadline) then
    ExpirePoolReserve;
end;

function GetMemSlow(aSize: NativeInt): Pointer;
var
  heap: PThreadHeap;
begin
  if aSize <= 0 then
    Exit(nil);
  heap := ThreadHeap;
  ProcessMediumThreadFree(heap);
  CheckPoolReserve;
  if aSize <= SmallMaxSize then
    Result := heap.SmallHeap.Alloc(aSize)
  else if aSize <= MediumMaxSize then
    Result := heap.MediumHeap.Alloc(aSize)
  else
    Result := LargeGetMem(aSize);
end;

function FreeMemSlow(aMemory: Pointer): Integer;
var
  heap: PThreadHeap;
  page: PSmallPage;
begin
  if not Assigned(aMemory) then
    Exit(0);
  heap := CurrentHeap;
  if heap <> nil then
    ProcessMediumThreadFree(heap);
  CheckPoolReserve;
  case SegmentKindOf(aMemory) of
    SegmentKindSmall:
      begin
        page := SmallPageOf(aMemory);
        if (heap <> nil) and (page.FHeap = @heap.SmallHeap) then
          heap.SmallHeap.Release(aMemory, page)
        else
          page.ThreadFree(aMemory);
      end;
    SegmentKindMedium:
      if (heap <> nil) and (MediumArenaOf(aMemory).Owner = @heap.MediumHeap) then
        heap.MediumHeap.Release(aMemory)
      else
        MediumThreadFree(aMemory);
  else
    LargeFreeMem(aMemory);
  end;
  Exit(0);
end;

// The item is already in FLocalFree: the page became empty or is not in its class list
function SmallFreeFinish(aPage: PSmallPage): Integer;
begin
  if aPage.FUsed = 0 then
    aPage.ReleaseIfUnused
  else
    aPage.LinkToTail;
  Exit(0);
end;

const
  FastSegmentMapMask   = High(SegmentMap);
  FastSegmentKindsMask = High(TSegmentKinds);
  FastSegmentMask      = -NativeInt(SegmentSize);
  /// log2(SizeOf(TSmallPage)); ShardMM.Small checks the size at compile time
  FastPageDescShift    = 7;

// Fast path: the heap from the TLS slot, the page from FDirect, the item from its FFree
function ShardGetMem(aSize: NativeInt): Pointer;
asm
  .noframe
  lea rax, [rcx - 1]
  cmp rax, SmallDirectMax - 1
  ja GetMemSlow
  mov r8, GTlsOffset
  test r8, r8
  jz GetMemSlow
  mov r9, gs:[r8]
  test r9, r9
  jz GetMemSlow
  lea rax, [rcx + 15]
  shr rax, 4
  mov rdx, [r9 + rax * 8 + TThreadHeap.SmallHeap + TSmallHeap.FDirect]
  mov rax, [rdx + TSmallPage.FFree]
  test rax, rax
  jz GetMemSlow
  mov rcx, [rax]
  mov [rdx + TSmallPage.FFree], rcx
  // The next free item: the next allocation of this class reads its link, and the caller writes
  // into it. Fetched now, with write intent, its line arrives while the caller works on this item;
  // at the end of the list rcx is nil, and a prefetch never faults. The register is rcx and not
  // r8-r15: dcc64 drops the REX prefix of prefetchw and would encode [r8] as [rax]
  prefetchw [rcx]
  add qword ptr [rdx + TSmallPage.FUsed], 1
end;

// Fast path: a small block of the own thread - the item goes to FLocalFree of its page
function ShardFreeMem(aMemory: Pointer): Integer;
asm
  .noframe
  // segment map: not a small block (or nil) - the slow path
  mov rax, rcx
  shr rax, 32
  and eax, FastSegmentMapMask
  lea r8, SegmentMap
  mov r8, [r8 + rax * 8]
  mov rax, rcx
  shr rax, SegmentShift
  and eax, FastSegmentKindsMask
  cmp byte ptr [r8 + rax], SegmentKindSmall
  jne FreeMemSlow
  // the segment owner is in descriptor 0
  mov rdx, rcx
  and rdx, FastSegmentMask
  mov r8, GTlsOffset
  test r8, r8
  jz FreeMemSlow
  mov r9, gs:[r8]
  test r9, r9
  jz FreeMemSlow
  lea r9, [r9 + TThreadHeap.SmallHeap]
  cmp r9, [rdx + TSmallPage.FHeap]
  jne FreeMemSlow
  // the page descriptor is Pages[(P - segment) shr SmallPageShift]
  mov rax, rcx
  sub rax, rdx
  shr rax, SmallPageShift
  shl rax, FastPageDescShift
  add rdx, rax
  mov rax, [rdx + TSmallPage.FLocalFree]
  mov [rcx], rax
  mov [rdx + TSmallPage.FLocalFree], rcx
  sub qword ptr [rdx + TSmallPage.FUsed], 1
  jz @Finish
  cmp qword ptr [rdx + TSmallPage.FInList], 0
  je @Finish
  sub eax, eax
  ret
@Finish:
  mov rcx, rdx
  jmp SmallFreeFinish
end;

function ShardAllocMem(aSize: NativeInt): Pointer;
var
  block: Pointer;
begin
  block := ShardGetMem(aSize);
  if block <> nil then
    FillChar(block^, aSize, 0);
  Result := block;
end;

// In place: a small block while the new size is within its class and not below a quarter of it; a
// medium block of the own thread - always when shrinking, and when growing if a free chunk follows;
// a large block - within its reservation (one shrunk by no more than half is left alone). Otherwise
// the block moves, with headroom when growing: a half plus 32 bytes for small blocks, a quarter for
// medium ones, 1/16 for large ones. Without the 32 bytes a short string appended character by
// character moves to the next class on every step, and XPath over a libxml2 DOM (LX2Bench) runs 8 %
// longer; with a quarter instead of a half a string grown by concatenation moves twice as often and
// the AppBench concat scenario runs 4-5 % longer, for 2-5 % less memory held. A small block that
// stays in place never gets here: ShardReallocMem answers it
function ReallocMemSlow(aMemory: Pointer; aSize: NativeInt): Pointer;
var
  size, oldsize, grown: NativeUInt;
  heap: PThreadHeap;
begin
  if not Assigned(aMemory) then
    Exit(ShardGetMem(aSize));
  if aSize <= 0 then
  begin
    ShardFreeMem(aMemory);
    Exit(nil);
  end;
  size := aSize;
  case SegmentKindOf(aMemory) of
    SegmentKindSmall:
      begin
        oldsize := SmallPageOf(aMemory).FItemSize;
        if (size <= oldsize) and (size + 64 >= oldsize shr 2) then
          Exit(aMemory);
      end;
    SegmentKindMedium:
      begin
        oldsize := MediumSizeOf(aMemory);
        if (size > SmallMaxSize) and (size <= MediumMaxSize) then
        begin
          heap := CurrentHeap;
          if (heap <> nil) and (MediumArenaOf(aMemory).Owner = @heap.MediumHeap) and
             heap.MediumHeap.ResizeInPlace(aMemory, size) then
            Exit(aMemory);
        end;
      end;
  else
    begin
      oldsize := LargeSizeOf(aMemory);
      if size > MediumMaxSize then
      begin
        if (size <= oldsize) and (size > oldsize shr 1) then
          Exit(aMemory);
        grown := size;
        if size > oldsize then
          Inc(grown, size shr 4);
        if LargeResize(aMemory, grown) then
          Exit(aMemory);
      end;
    end;
  end;

  grown := size;
  if size > oldsize then
    if size <= SmallMaxSize then
      Inc(grown, size shr 1 + 32)
    else if size <= MediumMaxSize then
      Inc(grown, size shr 2)
    else
      Inc(grown, size shr 4);
  // ShardGetMem takes a NativeInt: headroom that would carry the size beyond it is dropped, and a
  // request that large fails on its own size
  if grown > NativeUInt(High(NativeInt)) then
    grown := size;
  Result := ShardGetMem(grown);
  if size < oldsize then
    oldsize := size;
  Move(aMemory^, Result^, oldsize);
  ShardFreeMem(aMemory);
end;

// Fast path: a small block whose new size stays within its class and not below a quarter of it
// keeps its place, whichever thread owns it - nothing changes but the size the caller uses, and the
// class of a page with a live item does not change. Everything else jumps to the slow path with the
// same registers. A string appended a piece at a time and a dynamic array grown by one element come
// here on every step, mostly within the class thanks to the headroom of the slow path
function ShardReallocMem(aMemory: Pointer; aSize: NativeInt): Pointer;
asm
  .noframe
  // nil and a size not above zero - the slow path allocates or frees
  test rcx, rcx
  jz ReallocMemSlow
  test rdx, rdx
  jle ReallocMemSlow
  // segment map: not a small block - the slow path
  mov rax, rcx
  shr rax, 32
  and eax, FastSegmentMapMask
  lea r8, SegmentMap
  mov r8, [r8 + rax * 8]
  mov rax, rcx
  shr rax, SegmentShift
  and eax, FastSegmentKindsMask
  cmp byte ptr [r8 + rax], SegmentKindSmall
  jne ReallocMemSlow
  // the page descriptor is Pages[(P - segment) shr SmallPageShift]; its FItemSize is the class
  mov r8, rcx
  and r8, FastSegmentMask
  mov rax, rcx
  sub rax, r8
  shr rax, SmallPageShift
  shl rax, FastPageDescShift
  mov r9, [r8 + rax + TSmallPage.FItemSize]
  // in place while Size <= ItemSize and Size + 64 >= ItemSize shr 2
  cmp rdx, r9
  ja ReallocMemSlow
  lea rax, [rdx + 64]
  shr r9, 2
  cmp rax, r9
  jb ReallocMemSlow
  mov rax, rcx
end;

// Expected leaks are not tracked
function IgnoreLeak(P: Pointer): Boolean;
begin
  Exit(True);
end;

const
  ShardMemoryManager: TMemoryManagerEx = (
    GetMem: ShardGetMem;
    FreeMem: ShardFreeMem;
    ReallocMem: ShardReallocMem;
    AllocMem: ShardAllocMem;
    RegisterExpectedMemoryLeak: IgnoreLeak;
    UnregisterExpectedMemoryLeak: IgnoreLeak);

// True when the memory manager of the RTL has handed out a block
function RtlHasAllocated: Boolean;
var
  state: TMemoryManagerState;
  i: Integer;
begin
  // GetMemoryManagerState is marked platform; ShardMM is Win64 only anyway
  {$WARNINGS OFF}
  GetMemoryManagerState(state);
  {$WARNINGS ON}
  if (state.AllocatedMediumBlockCount <> 0) or (state.AllocatedLargeBlockCount <> 0) then
    Exit(True);
  for i := Low(state.SmallBlockTypeStates) to High(state.SmallBlockTypeStates) do
    if state.SmallBlockTypeStates[i].AllocatedBlockCount <> 0 then
      Exit(True);
  Exit(False);
end;

// The TLS slot and the FLS callback are needed by the very first allocation, that is before
// SetMemoryManager. The manager is not uninstalled at shutdown: blocks it handed out are freed up to
// the last moment, and the system reclaims the process memory
procedure InstallShardMM;
begin
  // ShardMM is not the first unit of the program, or something already allocated through the RTL
  if IsMemoryManagerSet or RtlHasAllocated then
    System.Error(TRuntimeError.reAssertionFailed);
  GTlsIndex := TlsAlloc;
  if GTlsIndex = OutOfIndexes then
    OutOfMemory;
  if GTlsIndex < 64 then
    GTlsOffset := $1480 + 8 * NativeUInt(GTlsIndex)
  else
    GTlsOffset := 0;
  GFlsIndex := FlsAlloc(@ThreadExitCallback);
  if GFlsIndex = OutOfIndexes then
    OutOfMemory;
  GPool := VirtualAlloc(nil, SizeOf(TThreadPoolHead), MemCommit, PageReadWrite);
  if GPool = nil then
    OutOfMemory;
  SetMemoryManager(ShardMemoryManager);
end;

{$IF (SizeOf(TSmallHeap) mod 64 <> 0) or (SizeOf(TMediumHeap) mod 64 <> 0)}
  {$MESSAGE ERROR 'thread heap sizes must be multiples of a cache line'}
{$IFEND}

initialization
  InstallShardMM;

end.

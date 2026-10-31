// ShardMM: large blocks and their cache
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
unit ShardMM.Large;

(* Large blocks - above MediumMaxSize: each one in its own VirtualAlloc reservation, freed ones in a
   cache shared by all threads.

   A block starts with a TLargeBlock header: the first Committed bytes of the reservation are
   committed, the rest up to Reserved is address space the block grows into in place. Usable is the
   requested size rounded up to 16; Magic tells a live block from a freed one and from a foreign
   address. A block belongs to no thread: any thread frees and reallocates it.

   A new large block costs a VirtualAlloc, a page fault on every page at first touch with the kernel
   zeroing it, and a VirtualFree when it is released; for a block of a few megabytes that is hundreds
   of microseconds. So a freed block is not returned to the system but goes to the cache: a block
   allocated by one thread and freed by another comes back to the first one. The cache is an array
   ordered from old to new under an SRW lock; only the choice and the reordering happen under the
   lock, system calls come after it.

   A block goes back to the system when it has stayed in the cache longer than LargeCacheDelay, when
   the cache runs out of slots or bytes (the oldest blocks leave), and when it is larger than
   LargeCacheMaxBytes. The age is checked on every cache access, when a small-block page is freed and
   when a thread exits (LargeCacheExpire), so the cache empties after a burst of large blocks even if
   no new large blocks follow. A process that stops freeing memory altogether keeps up to
   LargeCacheMaxBytes in the cache.

   The cache hands out a block whose reservation fits the request: the smallest of those already
   committed enough, otherwise the one with the most committed memory (the least to commit). Memory
   committed beyond the request stays with the block for growth - otherwise every growth pays page
   faults again - and goes back to the system (MEM_DECOMMIT) only when it exceeds the request both
   LargeKeepRatio times and by more than LargeKeepExcess. LargeResize returns the tail to the system
   only when the block shrinks to less than half.

   A new reservation gets address headroom equal to the block size (at most LargeHeadroomMax) and is
   never smaller than LargeMinReserve: a block growing through ReallocMem commits pages in place and
   moves with a copy only beyond its reservation, that is no more often than it doubles, and a cached
   block fits almost any later request. Addresses are plentiful in Win64, and a reservation without
   committed memory takes neither memory nor commit charge. *)

interface

{$R-}{$Q-}{$INLINE ON}

/// large block of at least aSize bytes
function  LargeGetMem(aSize: NativeUInt): Pointer;
procedure LargeFreeMem(aMemory: Pointer);
/// new size in place (above MediumMaxSize); False - beyond the reservation
function  LargeResize(aMemory: Pointer; aSize: NativeUInt): Boolean;
/// usable bytes of the block
function  LargeSizeOf(aMemory: Pointer): NativeUInt;
/// return to the system the blocks cached longer than LargeCacheDelay; without such a block - two
/// loads and GetTickCount
procedure LargeCacheExpire;

implementation

uses
  ShardMM.Platform;

type
  PLargeBlock = ^TLargeBlock;
  TLargeBlock = record
    Committed: NativeUInt;
    Reserved: NativeUInt;
    Usable: NativeUInt;
    Magic: NativeUInt;
  end;

const
  /// the bytes 'SHARDMML' and 'SHARDMMF' in memory
  LargeLiveMagic  = NativeUInt($4C4D4D4452414853);
  LargeFreedMagic = NativeUInt($464D4D4452414853);

  LargeGranularity   = 64 * 1024;
  LargeCacheSlots    = 32;
  LargeCacheMaxBytes = 128 shl 20;
  /// ms in the cache before the block goes back to the system
  LargeCacheDelay    = 1000;
  LargeKeepRatio     = 4;
  LargeKeepExcess    = 16 shl 20;
  LargeHeadroomMax   = NativeUInt(1) shl 30;
  LargeMinReserve    = 16 shl 20;

type
  TLargeCacheSlot = record
    Block: PLargeBlock;
    /// GetTickCount when the block entered the cache
    Tick: Cardinal;
  end;
  TLargeBlockList = array[0..LargeCacheSlots - 1] of PLargeBlock;

var
  /// SRWLOCK
  LargeCacheLock: Pointer;
  LargeCacheCount: Integer;
  /// sum of Committed of the cached blocks
  LargeCacheBytes: NativeUInt;
  LargeCache: array[0..LargeCacheSlots - 1] of TLargeCacheSlot;

function RoundLarge(aSize: NativeUInt): NativeUInt; inline;
begin
  Result := (aSize + (LargeGranularity - 1)) and not NativeUInt(LargeGranularity - 1);
end;

function RoundRequest(aSize: NativeUInt): NativeUInt; inline;
begin
  Result := (aSize + 15) and not NativeUInt(15);
end;

function BlockOf(aMemory: Pointer): PLargeBlock; inline;
begin
  Result := PLargeBlock(NativeUInt(aMemory) - SizeOf(TLargeBlock));
  if Result.Magic <> LargeLiveMagic then
    InvalidPointer;
end;

function CommitRange(aAddress, aSize: NativeUInt): Boolean; inline;
begin
  Result := VirtualAlloc(Pointer(aAddress), aSize, MemCommit, PageReadWrite) <> nil;
end;

procedure DecommitTo(aBlock: PLargeBlock; aSize: NativeUInt);
begin
  VirtualFree(Pointer(NativeUInt(aBlock) + aSize), aBlock.Committed - aSize, MemDecommit);
  aBlock.Committed := aSize;
end;

procedure ReleaseBlocks(const aBlocks: TLargeBlockList; aCount: Integer);
var
  i: Integer;
begin
  for i := 0 to aCount - 1 do
    if not VirtualFree(aBlocks[i], 0, MemRelease) then
      InvalidPointer;
end;

// Under the lock: remove entry aIndex, keeping the order from old to new
procedure CacheDelete(aIndex: Integer);
begin
  Dec(LargeCacheBytes, LargeCache[aIndex].Block.Committed);
  Dec(LargeCacheCount);
  if aIndex < LargeCacheCount then
    Move(LargeCache[aIndex + 1], LargeCache[aIndex], (LargeCacheCount - aIndex) * SizeOf(TLargeCacheSlot));
end;

// Under the lock: the oldest block goes to aBlocks to be returned to the system
procedure CacheEvictOldest(var aBlocks: TLargeBlockList; var aCount: Integer);
begin
  aBlocks[aCount] := LargeCache[0].Block;
  Inc(aCount);
  CacheDelete(0);
end;

// Under the lock: blocks cached longer than LargeCacheDelay go to aBlocks to be returned to the system
procedure CacheExpire(aTick: Cardinal; var aBlocks: TLargeBlockList; var aCount: Integer);
begin
  while (LargeCacheCount > 0) and (aTick - LargeCache[0].Tick >= LargeCacheDelay) do
    CacheEvictOldest(aBlocks, aCount);
end;

function CacheTake(aNeed: NativeUInt): PLargeBlock;
var
  i, best: Integer;
  block, bestblock: PLargeBlock;
  expired: TLargeBlockList;
  n: Integer;
begin
  if LargeCacheCount = 0 then
    Exit(nil);

  n := 0;
  best := -1;
  AcquireSRWLockExclusive(LargeCacheLock);
  CacheExpire(GetTickCount, expired, n);
  for i := 0 to LargeCacheCount - 1 do
  begin
    block := LargeCache[i].Block;
    if block.Reserved < aNeed then
      Continue;
    if best >= 0 then
    begin
      bestblock := LargeCache[best].Block;
      if bestblock.Committed >= aNeed then
      begin
        if (block.Committed < aNeed) or (block.Committed >= bestblock.Committed) then
          Continue;
      end
      else if (block.Committed < aNeed) and (block.Committed <= bestblock.Committed) then
        Continue;
    end;
    best := i;
  end;
  if best >= 0 then
  begin
    block := LargeCache[best].Block;
    CacheDelete(best);
  end
  else
    block := nil;
  ReleaseSRWLockExclusive(LargeCacheLock);
  ReleaseBlocks(expired, n);
  Result := block;
end;

procedure CachePut(aBlock: PLargeBlock);
var
  expired: TLargeBlockList;
  n: Integer;
  tick: Cardinal;
begin
  n := 0;
  if aBlock.Committed <= LargeCacheMaxBytes then
  begin
    tick := GetTickCount;
    AcquireSRWLockExclusive(LargeCacheLock);
    CacheExpire(tick, expired, n);
    while (LargeCacheCount = LargeCacheSlots) or
          (LargeCacheBytes + aBlock.Committed > LargeCacheMaxBytes) do
      CacheEvictOldest(expired, n);
    LargeCache[LargeCacheCount].Block := aBlock;
    LargeCache[LargeCacheCount].Tick := tick;
    Inc(LargeCacheCount);
    Inc(LargeCacheBytes, aBlock.Committed);
    ReleaseSRWLockExclusive(LargeCacheLock);
  end
  else
  begin
    expired[0] := aBlock;
    n := 1;
  end;
  ReleaseBlocks(expired, n);
end;

// The expiry is opportunistic, so the lock is only tried: LargeCacheExpire runs in the FLS callback of an
// exiting thread, and Windows runs that callback in ExitProcess too, after the other threads are killed -
// one of them may have been killed inside CacheTake or CachePut holding the lock, and waiting for it would
// hang the exit forever. A busy lock means another thread is in the cache and checks the age itself
procedure LargeCacheExpire;
var
  expired: TLargeBlockList;
  n: Integer;
  tick: Cardinal;
begin
  // reading without the lock is only a hint, the decision is made under it
  if LargeCacheCount = 0 then
    Exit;
  tick := GetTickCount;
  if tick - LargeCache[0].Tick < LargeCacheDelay then
    Exit;
  n := 0;
  if not TryAcquireSRWLockExclusive(LargeCacheLock) then
    Exit;
  CacheExpire(tick, expired, n);
  ReleaseSRWLockExclusive(LargeCacheLock);
  ReleaseBlocks(expired, n);
end;

// New reservation with address headroom and its first aNeed bytes committed
function ReserveBlock(aNeed: NativeUInt): PLargeBlock;
var
  headroom, reserve: NativeUInt;
  block: PLargeBlock;
begin
  headroom := aNeed;
  if headroom > LargeHeadroomMax then
    headroom := LargeHeadroomMax;
  reserve := aNeed + headroom;
  if reserve < LargeMinReserve then
    reserve := LargeMinReserve;
  block := VirtualAlloc(nil, reserve, MemReserve, PageReadWrite);
  if block = nil then
  begin
    // the headroom does not fit: the block alone
    reserve := aNeed;
    block := VirtualAlloc(nil, reserve, MemReserve, PageReadWrite);
    if block = nil then
      OutOfMemory;
  end;
  if not CommitRange(NativeUInt(block), aNeed) then
  begin
    VirtualFree(block, 0, MemRelease);
    OutOfMemory;
  end;
  block.Committed := aNeed;
  block.Reserved := reserve;
  Result := block;
end;

// A block with at least aNeed bytes committed: from the cache or a new reservation
function AcquireBlock(aNeed: NativeUInt): PLargeBlock;
var
  block: PLargeBlock;
begin
  block := CacheTake(aNeed);
  if block = nil then
    block := ReserveBlock(aNeed)
  else if block.Committed < aNeed then
  begin
    if not CommitRange(NativeUInt(block) + block.Committed, aNeed - block.Committed) then
    begin
      VirtualFree(block, 0, MemRelease);
      OutOfMemory;
    end;
    block.Committed := aNeed;
  end
  else if (block.Committed > aNeed * LargeKeepRatio) and
          (block.Committed - aNeed > LargeKeepExcess) then
    DecommitTo(block, aNeed);
  Result := block;
end;

function LargeGetMem(aSize: NativeUInt): Pointer;
var
  block: PLargeBlock;
begin
  block := AcquireBlock(RoundLarge(aSize + SizeOf(TLargeBlock)));
  block.Usable := RoundRequest(aSize);
  block.Magic := LargeLiveMagic;
  Result := Pointer(NativeUInt(block) + SizeOf(TLargeBlock));
end;

procedure LargeFreeMem(aMemory: Pointer);
var
  block: PLargeBlock;
begin
  block := BlockOf(aMemory);
  block.Magic := LargeFreedMagic;
  CachePut(block);
end;

// Growth within the committed part changes only Usable, within the reservation it commits pages in
// place; shrinking to less than half returns the tail to the system
function LargeResize(aMemory: Pointer; aSize: NativeUInt): Boolean;
var
  block: PLargeBlock;
  need: NativeUInt;
begin
  block := BlockOf(aMemory);
  need := RoundLarge(aSize + SizeOf(TLargeBlock));
  if need <= block.Committed then
  begin
    if (aSize < block.Usable) and (need < block.Committed shr 1) then
      DecommitTo(block, need);
  end
  else if (need <= block.Reserved) and
          CommitRange(NativeUInt(block) + block.Committed, need - block.Committed) then
    block.Committed := need
  else
    Exit(False);
  block.Usable := RoundRequest(aSize);
  Exit(True);
end;

function LargeSizeOf(aMemory: Pointer): NativeUInt;
begin
  Result := BlockOf(aMemory).Usable;
end;

{$IF SizeOf(TLargeBlock) and 15 <> 0}
  {$MESSAGE ERROR 'large block data must stay 16-byte aligned'}
{$IFEND}

end.

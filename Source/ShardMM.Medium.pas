// ShardMM: medium blocks
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
unit ShardMM.Medium;

(* Medium blocks - from SmallMaxSize to MediumMaxSize (1 MB): chunks with a header in per-thread
   arenas; a free chunk is found by TLSF (two-level segregated fit).

   An arena is a segment of kind SegmentKindMedium (ShardMM.Segments, 4 MB): the TMediumArena header,
   then chunks back to back up to the end of the segment. A chunk has a 16-byte header - the size of
   the previous chunk (0 for the first one) and its own size with the "free" flag in the low bit;
   sizes are multiples of 16, data is 16-byte aligned. Adjacent free chunks are always merged: both
   neighbours of a free chunk are in use or absent. Arena memory is committed as chunks are carved,
   in MediumCommitStep steps, and is not returned to the system until the whole arena is empty.

   Free chunks sit in the bins TMediumHeap.Free[FL, SL]: FL is the highest set bit of the size, SL the
   next MediumSLShift bits, that is 16 bins per power of two. The bitmaps FLBitmap and SLBitmap give a
   non-empty bin with one or two BSF. The request is rounded up to the start of the next bin, so any
   chunk of the bin found fits without a search; the excess is split off when the remainder is at
   least MediumMinSplit - less than MediumMinSplit bytes are lost per block.

   An arena belongs to the heap of one thread and never changes its owner: thread heaps pass to a new
   thread as a whole. A chunk freed by another thread is pushed with one CAS onto
   TMediumArena.ThreadFree, whose low bit means "the arena is queued at its owner": the push that finds
   the bit clear sets it and queues the arena, exactly once until the owner exchanges the list for nil.
   The owner visits every chunk of the list anyway - each one is merged with its neighbours - so the
   list is a plain pointer, not the head-tail-count word of small-block pages (ShardMM.Small). The rule
   is the same as for pages: an empty arena leaves the bins only when it has neither chunks in use nor
   pending foreign frees. The owner drains the queue at the start of every medium-block operation, in
   the slow paths of ShardMM and when the thread exits.

   An empty arena (one free chunk over the whole arena) waits in EmptyArenas still committed: the next
   new arena is taken from there without page faults. The MediumEmptyArenasCommitted most recent ones
   always stay committed; the others, after MediumEmptyDelay ms there, return all their memory except
   the first MediumCommitStep bytes to the system and wait in Decommitted. When the thread exits, the
   MediumExitArenasCommitted most recent ones stay committed and the others give their memory back at
   once: the thread that gets the heap next starts with medium blocks without page faults, and a heap
   nobody took is trimmed down to MediumEmptyArenasCommitted (ExpirePoolReserve in ShardMM). *)

interface

{$R-}{$Q-}{$INLINE ON}

uses
  ShardMM.Segments;

const
  MediumMaxSize      = 1 shl 20;
  MediumHeaderSize   = 16;
  MediumMinSplit     = 256;
  MediumCommitStep   = 64 * 1024;
  MediumEmptyDelay   = 1000;
  /// how many empty arenas a heap always keeps committed, and how many when its thread exits
  MediumEmptyArenasCommitted = 1;
  MediumExitArenasCommitted  = 4;
  MediumSLShift      = 4;
  MediumSLCount      = 1 shl MediumSLShift;
  /// highest bits of chunk sizes: below SegmentShift
  MediumFLCount      = SegmentShift;

type
  PMediumChunk = ^TMediumChunk;
  TMediumChunk = record
    PrevSize: NativeUInt;
    SizeFlags: NativeUInt;
    /// only in a free chunk - in place of the data
    NextFree, PrevFree: PMediumChunk;
  end;

  PMediumHeap = ^TMediumHeap;
  PMediumArena = ^TMediumArena;

  /// Arena header, two cache lines: the owner's fields and the fields of other threads
  TMediumArena = record
    Owner: PMediumHeap;
    /// bytes committed from the start of the arena
    Committed: NativeUInt;
    /// chunks in use, including those freed by other threads and not yet drained
    Used: NativeInt;
    /// in the EmptyArenas or Decommitted list of the heap
    Next: PMediumArena;
    /// GetTickCount when the arena became empty
    FreeTick: NativeUInt;
    Pad1: array[0..2] of NativeUInt;
    /// chunks freed by other threads, and in the low bit "the arena is queued at its owner"
    ThreadFree: Pointer;
    /// next arena in the ThreadFreeArenas queue of the owner
    NextNotified: PMediumArena;
    Pad2: array[0..5] of NativeUInt;
  end;

  /// Medium blocks of one thread
  TMediumHeap = record
  public
    /// queue of arenas with foreign frees: other threads push at the head (CAS), the owner takes the
    /// whole queue by exchanging it for nil; in its own cache line
    ThreadFreeArenas: PMediumArena;
    Pad: array[0..6] of NativeUInt;
  private
    FLBitmap: Cardinal;
    SLBitmap: array[0..MediumFLCount - 1] of Word;
    Free: array[0..MediumFLCount - 1, 0..MediumSLCount - 1] of PMediumChunk;
    EmptyArenas: PMediumArena;
    Decommitted: PMediumArena;

    procedure InsertFree(aChunk: PMediumChunk; aSize: NativeUInt);
    procedure RemoveFree(aChunk: PMediumChunk; aSize: NativeUInt);
    function  FindFree(aNeed: NativeUInt): PMediumChunk;
    procedure AddArena;
    procedure ArenaEmpty(aArena: PMediumArena);
    procedure FreeChunk(aChunk: PMediumChunk);
  public
    function  Alloc(aSize: NativeUInt): Pointer;
    /// free a block of this heap by its own thread
    procedure Release(aMemory: Pointer);
    /// new size in place: shrinking puts the tail into the free bins, growth takes the free chunk
    /// that follows; False - does not fit in place
    function  ResizeInPlace(aMemory: Pointer; aSize: NativeUInt): Boolean;
    procedure ProcessThreadFree;
    /// Empty arenas, except the aKeep most recent ones, return their memory to the system if they
    /// have been empty for at least aMinAge ms
    procedure TrimEmptyArenas(aMinAge: Cardinal; aKeep: NativeInt);
  end;

const
  /// chunk size in TMediumChunk.SizeFlags
  MediumSizeMask = not NativeUInt(15);

/// arena of a block
function MediumArenaOf(aMemory: Pointer): PMediumArena; inline;
/// usable bytes of a block
function MediumSizeOf(aMemory: Pointer): NativeUInt; inline;
/// free a block of another thread's heap
procedure MediumThreadFree(aMemory: Pointer);

implementation

uses
  ShardMM.Platform;

const
  ChunkFree = 1;
  SizeMask  = MediumSizeMask;
  FirstChunkOffset = SizeOf(TMediumArena);

function MediumArenaOf(aMemory: Pointer): PMediumArena;
begin
  Result := PMediumArena(SegmentOf(aMemory));
end;

function MediumSizeOf(aMemory: Pointer): NativeUInt;
begin
  Result := (PMediumChunk(NativeUInt(aMemory) - MediumHeaderSize).SizeFlags and MediumSizeMask) - MediumHeaderSize;
end;

function ArenaEnd(aArena: PMediumArena): NativeUInt; inline;
begin
  Result := NativeUInt(aArena) + SegmentSize;
end;

procedure EnsureCommitted(aArena: PMediumArena; aUpTo: NativeUInt);
var
  c: NativeUInt;
begin
  if aUpTo <= NativeUInt(aArena) + aArena.Committed then
    Exit;
  c := (aUpTo - NativeUInt(aArena) + MediumCommitStep - 1) and not NativeUInt(MediumCommitStep - 1);
  if VirtualAlloc(Pointer(NativeUInt(aArena) + aArena.Committed), c - aArena.Committed, MemCommit, PageReadWrite) = nil then
    OutOfMemory;
  aArena.Committed := c;
end;

// Bin of a chunk of size aSize: FL - the highest set bit, SL - the next MediumSLShift bits
procedure Mapping(aSize: NativeUInt; out aFL, aSL: NativeUInt); inline;
begin
  aFL := Bsr(aSize);
  aSL := (aSize shr (aFL - MediumSLShift)) and (MediumSLCount - 1);
end;

procedure MediumThreadFree(aMemory: Pointer);
var
  chunk: PMediumChunk;
  arena: PMediumArena;
  old: NativeUInt;
  owner: PMediumHeap;
  head: PMediumArena;
begin
  chunk := PMediumChunk(NativeUInt(aMemory) - MediumHeaderSize);
  if chunk.SizeFlags and ChunkFree <> 0 then
    InvalidPointer;
  arena := MediumArenaOf(chunk);
  repeat
    old := NativeUInt(arena.ThreadFree);
    chunk.NextFree := PMediumChunk(old and not NativeUInt(1));
  until AtomicCmpExchange(arena.ThreadFree, Pointer(NativeUInt(chunk) or 1), Pointer(old)) = Pointer(old);
  // the bit was clear: this thread, and only this one, queues the arena at its owner
  if old and 1 = 0 then
  begin
    owner := arena.Owner;
    repeat
      head := owner.ThreadFreeArenas;
      arena.NextNotified := head;
    until AtomicCmpExchange(Pointer(owner.ThreadFreeArenas), Pointer(arena), Pointer(head)) = Pointer(head);
  end;
end;

{ TMediumHeap }

procedure TMediumHeap.InsertFree(aChunk: PMediumChunk; aSize: NativeUInt);
var
  fl, sl: NativeUInt;
  head: PMediumChunk;
begin
  Mapping(aSize, fl, sl);
  head := Free[fl, sl];
  aChunk.NextFree := head;
  aChunk.PrevFree := nil;
  if head <> nil then
    head.PrevFree := aChunk;
  Free[fl, sl] := aChunk;
  FLBitmap := FLBitmap or (Cardinal(1) shl fl);
  SLBitmap[fl] := SLBitmap[fl] or (Word(1) shl sl);
end;

procedure TMediumHeap.RemoveFree(aChunk: PMediumChunk; aSize: NativeUInt);
var
  fl, sl: NativeUInt;
begin
  Mapping(aSize, fl, sl);
  if aChunk.NextFree <> nil then
    aChunk.NextFree.PrevFree := aChunk.PrevFree;
  if aChunk.PrevFree <> nil then
    aChunk.PrevFree.NextFree := aChunk.NextFree
  else
  begin
    Free[fl, sl] := aChunk.NextFree;
    if aChunk.NextFree = nil then
    begin
      SLBitmap[fl] := SLBitmap[fl] and not (Word(1) shl sl);
      if SLBitmap[fl] = 0 then
        FLBitmap := FLBitmap and not (Cardinal(1) shl fl);
    end;
  end;
end;

// A chunk of at least aNeed bytes: the request is rounded up to the start of the next bin, so the
// first chunk of the first non-empty bin not below it fits
function TMediumHeap.FindFree(aNeed: NativeUInt): PMediumChunk;
var
  fl, sl, slMap, flMap: NativeUInt;
begin
  Mapping(aNeed + (NativeUInt(1) shl (Bsr(aNeed) - MediumSLShift)) - 1, fl, sl);
  slMap := SLBitmap[fl] and (NativeUInt(-1) shl sl);
  if slMap = 0 then
  begin
    flMap := FLBitmap and (NativeUInt(-1) shl (fl + 1));
    if flMap = 0 then
      Exit(nil);
    fl := Bsf(flMap);
    slMap := SLBitmap[fl];
  end;
  Result := Free[fl, Bsf(slMap)];
end;

// An arena into the bins: an empty committed one, one returned to the system, or a new one
procedure TMediumHeap.AddArena;
var
  arena: PMediumArena;
  chunk: PMediumChunk;
begin
  arena := EmptyArenas;
  if arena <> nil then
    EmptyArenas := arena.Next
  else
  begin
    arena := Decommitted;
    if arena <> nil then
      Decommitted := arena.Next
    else
    begin
      arena := AllocSegment(SegmentKindMedium, MediumCommitStep);
      arena.Owner := @Self;
      arena.Committed := MediumCommitStep;
    end;
  end;
  arena.Next := nil;
  chunk := PMediumChunk(NativeUInt(arena) + FirstChunkOffset);
  chunk.PrevSize := 0;
  chunk.SizeFlags := (SegmentSize - FirstChunkOffset) or ChunkFree;
  InsertFree(chunk, SegmentSize - FirstChunkOffset);
end;

// An arena without chunks in use: its single chunk is not in the bins yet
procedure TMediumHeap.ArenaEmpty(aArena: PMediumArena);
begin
  aArena.FreeTick := GetTickCount;
  aArena.Next := EmptyArenas;
  EmptyArenas := aArena;
  TrimEmptyArenas(MediumEmptyDelay, MediumEmptyArenasCommitted);
end;

// EmptyArenas goes from recent to old: new ones enter at the head
procedure TMediumHeap.TrimEmptyArenas(aMinAge: Cardinal; aKeep: NativeInt);
var
  now: Cardinal;
  arena, next: PMediumArena;
  prev: ^PMediumArena;
begin
  now := GetTickCount;
  prev := @EmptyArenas;
  arena := EmptyArenas;
  while arena <> nil do
  begin
    next := arena.Next;
    Dec(aKeep);
    if (aKeep < 0) and (now - Cardinal(arena.FreeTick) >= aMinAge) then
    begin
      prev^ := next;
      // VirtualFree treats size 0 specially (the whole region from its base), not as an empty range
      if arena.Committed > MediumCommitStep then
        VirtualFree(Pointer(NativeUInt(arena) + MediumCommitStep), arena.Committed - MediumCommitStep, MemDecommit);
      arena.Committed := MediumCommitStep;
      arena.Next := Decommitted;
      Decommitted := arena;
    end
    else
      prev := @arena.Next;
    arena := next;
  end;
end;

function TMediumHeap.Alloc(aSize: NativeUInt): Pointer;
var
  need, csize, rsize: NativeUInt;
  chunk, rest, next: PMediumChunk;
  arena: PMediumArena;
begin
  if ThreadFreeArenas <> nil then
    ProcessThreadFree;
  need := (aSize + MediumHeaderSize + 15) and SizeMask;
  chunk := FindFree(need);
  if chunk = nil then
  begin
    AddArena;
    chunk := FindFree(need);
  end;
  csize := chunk.SizeFlags and SizeMask;
  arena := MediumArenaOf(chunk);
  // Commit before the chunk leaves its bin: a failed commit raises, and a chunk flagged free but outside
  // the bins would corrupt the bins when a neighbour is freed later
  if csize - need >= MediumMinSplit then
    // the header of the remainder follows the allocated part: commit up to it and its links
    EnsureCommitted(arena, NativeUInt(chunk) + need + SizeOf(TMediumChunk))
  else
    EnsureCommitted(arena, NativeUInt(chunk) + csize);
  RemoveFree(chunk, csize);
  if csize - need >= MediumMinSplit then
  begin
    rest := PMediumChunk(NativeUInt(chunk) + need);
    rsize := csize - need;
    rest.PrevSize := need;
    rest.SizeFlags := rsize or ChunkFree;
    next := PMediumChunk(NativeUInt(rest) + rsize);
    if NativeUInt(next) < ArenaEnd(arena) then
      next.PrevSize := rsize;
    InsertFree(rest, rsize);
    csize := need;
  end;
  chunk.SizeFlags := csize;
  Inc(arena.Used);
  Result := Pointer(NativeUInt(chunk) + MediumHeaderSize);
end;

procedure TMediumHeap.FreeChunk(aChunk: PMediumChunk);
var
  arena: PMediumArena;
  size, nsize, psize: NativeUInt;
  next, prev: PMediumChunk;
begin
  size := aChunk.SizeFlags;
  if size and ChunkFree <> 0 then
    InvalidPointer;
  arena := MediumArenaOf(aChunk);
  Dec(arena.Used);
  next := PMediumChunk(NativeUInt(aChunk) + size);
  if (NativeUInt(next) < ArenaEnd(arena)) and (next.SizeFlags and ChunkFree <> 0) then
  begin
    nsize := next.SizeFlags and SizeMask;
    RemoveFree(next, nsize);
    Inc(size, nsize);
  end;
  if aChunk.PrevSize <> 0 then
  begin
    prev := PMediumChunk(NativeUInt(aChunk) - aChunk.PrevSize);
    if prev.SizeFlags and ChunkFree <> 0 then
    begin
      psize := prev.SizeFlags and SizeMask;
      RemoveFree(prev, psize);
      Inc(size, psize);
      aChunk := prev;
    end;
  end;
  aChunk.SizeFlags := size or ChunkFree;
  next := PMediumChunk(NativeUInt(aChunk) + size);
  if NativeUInt(next) < ArenaEnd(arena) then
    next.PrevSize := size;
  if (arena.Used = 0) and (arena.ThreadFree = nil) then
    ArenaEmpty(arena)
  else
    InsertFree(aChunk, size);
end;

procedure TMediumHeap.Release(aMemory: Pointer);
begin
  if ThreadFreeArenas <> nil then
    ProcessThreadFree;
  FreeChunk(PMediumChunk(NativeUInt(aMemory) - MediumHeaderSize));
end;

function TMediumHeap.ResizeInPlace(aMemory: Pointer; aSize: NativeUInt): Boolean;
var
  chunk, rest, next: PMediumChunk;
  arena: PMediumArena;
  need, csize, nsize, rsize, total: NativeUInt;
begin
  if ThreadFreeArenas <> nil then
    ProcessThreadFree;
  chunk := PMediumChunk(NativeUInt(aMemory) - MediumHeaderSize);
  arena := MediumArenaOf(chunk);
  csize := chunk.SizeFlags;
  need := (aSize + MediumHeaderSize + 15) and SizeMask;
  next := PMediumChunk(NativeUInt(chunk) + csize);
  if need <= csize then
  begin
    rsize := csize - need;
    if rsize >= MediumMinSplit then
    begin
      // the tail goes to the free bins, merged with a free neighbour
      if (NativeUInt(next) < ArenaEnd(arena)) and (next.SizeFlags and ChunkFree <> 0) then
      begin
        nsize := next.SizeFlags and SizeMask;
        RemoveFree(next, nsize);
        Inc(rsize, nsize);
      end;
      rest := PMediumChunk(NativeUInt(chunk) + need);
      rest.PrevSize := need;
      rest.SizeFlags := rsize or ChunkFree;
      next := PMediumChunk(NativeUInt(rest) + rsize);
      if NativeUInt(next) < ArenaEnd(arena) then
        next.PrevSize := rsize;
      chunk.SizeFlags := need;
      InsertFree(rest, rsize);
    end;
    Exit(True);
  end;

  if (NativeUInt(next) >= ArenaEnd(arena)) or (next.SizeFlags and ChunkFree = 0) then
    Exit(False);
  nsize := next.SizeFlags and SizeMask;
  total := csize + nsize;
  if total < need then
    Exit(False);
  rsize := total - need;
  // Commit before the neighbour leaves its bin (see Alloc)
  if rsize >= MediumMinSplit then
    EnsureCommitted(arena, NativeUInt(chunk) + need + SizeOf(TMediumChunk))
  else
    EnsureCommitted(arena, NativeUInt(chunk) + total);
  RemoveFree(next, nsize);
  if rsize >= MediumMinSplit then
  begin
    rest := PMediumChunk(NativeUInt(chunk) + need);
    rest.PrevSize := need;
    rest.SizeFlags := rsize or ChunkFree;
    next := PMediumChunk(NativeUInt(rest) + rsize);
    if NativeUInt(next) < ArenaEnd(arena) then
      next.PrevSize := rsize;
    InsertFree(rest, rsize);
    csize := need;
  end
  else
  begin
    next := PMediumChunk(NativeUInt(chunk) + total);
    if NativeUInt(next) < ArenaEnd(arena) then
      next.PrevSize := total;
    csize := total;
  end;
  chunk.SizeFlags := csize;
  Exit(True);
end;

procedure TMediumHeap.ProcessThreadFree;
var
  arena, next: PMediumArena;
  list: NativeUInt;
  chunk: PMediumChunk;
begin
  arena := AtomicExchange(Pointer(ThreadFreeArenas), nil);
  while arena <> nil do
  begin
    // the link to the next one is read before the exchange: once the bit is cleared another thread
    // may queue the arena again and overwrite NextNotified
    next := arena.NextNotified;
    list := NativeUInt(AtomicExchange(arena.ThreadFree, nil)) and not NativeUInt(1);
    while list <> 0 do
    begin
      chunk := PMediumChunk(list);
      list := NativeUInt(chunk.NextFree);
      FreeChunk(chunk);
    end;
    arena := next;
  end;
end;

{$IF SizeOf(TMediumArena) <> 128}
  {$MESSAGE ERROR 'TMediumArena must take two cache lines'}
{$IFEND}
{$IF MediumMaxSize + MediumHeaderSize + MediumMinSplit > SegmentSize - SizeOf(TMediumArena)}
  {$MESSAGE ERROR 'the largest medium block must fit an arena'}
{$IFEND}

end.

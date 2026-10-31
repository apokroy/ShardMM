// ShardMM: small blocks
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
unit ShardMM.Small;

(* Small blocks - up to SmallMaxSize: pages after the design of mimalloc.

   Memory comes in segments of kind SegmentKindSmall (ShardMM.Segments, 4 MB): SmallPagesPerSegment
   pages of 64 KB, page 0 holding the segment header with the descriptors of all pages. An item has
   no header: its page is the descriptor Pages[(P - segment) shr SmallPageShift].

   The fast paths (ShardGetMem and ShardFreeMem in ShardMM.pas, in assembler) rely on three things
   from here: FDirect of the heap - the first page of the class by size up to SmallDirectMax,
   directly, without the class table; the segment owner in descriptor 0 - nobody writes it, so the
   "is this block mine" check of every thread reads a shared, never changing cache line; and the
   layout of TSmallPage over two lines - the owner's fields in the first, the fields of other threads
   in the second.

   A segment belongs to the heap of one thread with all its pages and never changes its owner: thread
   heaps pass to a new thread as a whole. A page is taken by one size class and goes to another class
   when no items are left in it. The classes are SmallClassSizes: 16, 32, 64, 80, 96, 112, 128, then
   four per power of two up to 2 KB, eight (a 12.5 % step) up to 8 KB and four up to SmallMaxSize.
   There is no class 48: half of its items would take one cache line (64 bytes) more than their size
   needs, while 33-48-byte objects are common in Delphi, and zeroing a new object and the atomic
   operations on its reference count would touch two lines instead of one. Class 112 exists although
   it has the same property: without it 97-112-byte objects share the pages of class 128 with
   113-128-byte ones, and walking one kind touches the lines of the other - libxml2 DOM attributes
   (104 bytes) and nodes (120) interleave that way. The 12.5 % step in 2-8 KB: a page holds 8-28 items
   and the page tail where no whole item fits is at most 9 %; above 8 KB a page holds 4-6 items, the
   tails grow, and the step stays 25 %.

   The uncarved part of a page is cut in batches of SmallCarveBatch in ascending address order:
   objects created one after another lie next to each other, and walking them in the same order
   moves forward through memory, as the hardware prefetcher expects.

   Free items are linked through the items themselves, in three lists per page:
     FFree       - the owner allocates from it;
     FLocalFree  - the owner puts freed items here; it becomes FFree when that runs empty;
     FThreadFree - other threads push freed items here, with one CAS.
   Allocation and freeing by the owner do no atomic operation at all.

   FThreadFree is not a pointer but one word that describes the whole list: the offsets of its head
   and of its tail in the page (bits 0-15 and 16-31: items lie at multiples of 16 bytes in a 64 KB
   page) and the number of items (bits 32-63). The owner takes the list by exchanging the word for 0,
   splices it into FLocalFree by the tail and subtracts the count from FUsed without walking it:
   other threads have just written the items, and a walk would wait for a cache miss on every one. A
   push computes the new word from the old one alone - the new item as the head, the same tail (the
   new item when the list was empty), the count plus one - so a CAS that succeeds always describes the
   list as it is, even if the owner took the list and other pushes brought the word back to the same
   value in between.

   A non-zero FThreadFree means "the page is queued at its owner" (FThreadFreePages): the push that
   finds 0 queues the page - exactly once until the next drain. The owner exchanges FThreadFree for 0
   only after taking the page from the queue, and drains the queue when a page runs out of items
   (AllocSlow); outside the queue the owner never reads FThreadFree. Hence the rule for releasing a
   page: FUsed = 0 and FThreadFree = 0 - no items in use, no other thread touches the page, and it is
   not queued.

   FUsed counts items handed out and not yet back in the owner's lists; an item freed by another
   thread but not yet drained counts as handed out. A double free of a small block goes undetected:
   an item has no field to mark it. *)

interface

{$R-}{$Q-}{$INLINE ON}

uses
  ShardMM.Segments;

const
  SmallPageShift = 16;
  SmallPageSize = 1 shl SmallPageShift;
  SmallPagesPerSegment = SegmentSize div SmallPageSize;
  SmallClassCount = 43;
  /// the largest small block; larger ones are medium blocks (ShardMM.Medium)
  SmallMaxSize = 16384;
  /// the largest size with an FDirect entry and a fast allocation path
  SmallDirectMax = 2048;
  /// how many items are carved at a time from the uncarved part of a page
  SmallCarveBatch = 64;
  /// how many freed pages a thread always keeps committed; the memory of pages beyond that goes
  /// back to the system (MEM_DECOMMIT) once a page has been free for SmallDecommitDelay
  /// milliseconds, while the addresses stay with the segment. Without the delay a "free everything,
  /// allocate again" cycle pays VirtualFree, VirtualAlloc and 16 page faults for every page
  SmallFreePagesCommitted = 16;
  SmallDecommitDelay = 1000;
  /// how many free pages stay committed when the thread exits: the next thread to get the heap
  /// takes them without page faults. A heap nobody took has its reserve trimmed down to
  /// SmallFreePagesCommitted (ExpirePoolReserve in ShardMM)
  SmallExitFreePages = 64;

  /// FThreadFree: the head offset in bits 0-15, the tail offset in bits 16-31, the count above
  SmallThreadFreeOffsetMask = SmallPageSize - 1;
  SmallThreadFreeTailShift = 16;
  SmallThreadFreeCountShift = 32;

  SmallClassSizes: array[0..SmallClassCount - 1] of Word = (16, 32, 64, 80, 96, 112, 128,
    160, 192, 224, 256, 320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 1792, 2048,
    2304, 2560, 2816, 3072, 3328, 3584, 3840, 4096, 4608, 5120, 5632, 6144, 6656, 7168, 7680, 8192,
    10240, 12288, 14336, 16384);

type
  PSmallFreeItem = ^TSmallFreeItem;
  PSmallPage     = ^TSmallPage;
  PSmallClass    = ^TSmallClass;
  PSmallHeap     = ^TSmallHeap;
  PSmallSegment  = ^TSmallSegment;

  /// A free item: its first bytes link to the next one
  TSmallFreeItem = record
    Next: PSmallFreeItem;
  end;

  /// Page descriptor; it lives in the segment header, not in the page. It takes two cache lines:
  /// the first holds what the owner writes on every allocation and free, the second what other
  /// threads write (FThreadFree, FNextNotified) and rarely needed fields. A foreign free does not
  /// touch the first line, and the owner reads the second one only on the slow path.
  TSmallPage = record
    FFree: PSmallFreeItem;
    FLocalFree: PSmallFreeItem;
    FUsed: NativeInt;
    FInList: NativeInt;
    FItemSize: NativeUInt;
    /// the uncarved part of the page
    FBump: NativeUInt;
    FBumpEnd: NativeUInt;
    FClass: PSmallClass;

    /// items freed by other threads: head, tail and count in one word; 0 - none, and the page is not
    /// queued at its owner
    FThreadFree: NativeUInt;
    /// next page in the owner's FThreadFreePages queue
    FNextNotified: PSmallPage;
    /// the owning heap; in descriptor 0 (the segment header) - the owner of the segment
    FHeap: PSmallHeap;
    /// pages of the class that have or may get a free item; for a free page - the heap's list of
    /// free pages
    FNext, FPrev: PSmallPage;
    FCommitted: NativeInt;
    FData: NativeUInt;
    /// GetTickCount when the page became free
    FFreeTick: NativeUInt;

    /// free an item by another thread
    procedure ThreadFree(aMemory: Pointer);
    /// a new page goes to the head of the class list
    procedure LinkFirst;
    /// a page that got free items again goes to the tail: by the time allocation reaches it, more
    /// than one item has gathered, and it need not be unlinked and relinked for every item
    procedure LinkToTail;
    procedure Unlink;
    procedure TakeFreed(aList: NativeUInt);
    /// an empty page goes to the heap's free pages; the last page of a class stays
    procedure ReleaseIfUnused;
  end;

  TSmallSegment = record
    Pages: array[0..SmallPagesPerSegment - 1] of TSmallPage;
  end;

  /// The pages of one size class
  TSmallClass = record
    FHeap: PSmallHeap;
    FFirst: PSmallPage;
    FLast: PSmallPage;
    FItemSize: NativeUInt;
    /// the FDirect entries of the heap that point to the first page of this class
    FDirectFrom, FDirectTo: Integer;
    /// keeps the size a multiple of 16 bytes
    FFiller: NativeUInt;

    /// the only place where the first page of the class changes, and with it FDirect
    procedure SetFirst(aPage: PSmallPage);
    function  AllocSlow: PSmallFreeItem;
  end;

  /// Small blocks of one thread
  TSmallHeap = record
  public
    /// queue of pages with foreign frees: other threads push at the head (CAS), the owner takes the
    /// whole queue by exchanging it for nil; in its own cache line
    FThreadFreePages: PSmallPage;
    FPad: array[0..6] of NativeUInt;
    /// the first page of the class by (Size + 15) shr 4, and for a class without pages - EmptyPage
    /// with an empty FFree: the fast allocation path is one load from here and FFree of the page,
    /// without the class table and without a nil check
    FDirect: array[0..SmallDirectMax div 16] of PSmallPage;
    /// 16-byte alignment after the 129 pointers of FDirect
    FDirectFiller: Pointer;
  private
    FSegment: PSmallSegment;
    FSegmentNext: NativeInt;
    /// free committed pages, recent ones at the head (FNext/FPrev), old ones at the tail
    FFreePages: PSmallPage;
    FFreeTail: PSmallPage;
    FFreePageCount: NativeInt;
    /// free pages whose memory went back to the system
    FDecommitted: PSmallPage;
    FClasses: array[0..SmallClassCount - 1] of TSmallClass;

    function  NewPage(aClass: PSmallClass): PSmallPage;
    procedure FreePage(aPage: PSmallPage);
  public
    procedure Setup;
    function  Alloc(aSize: NativeUInt): Pointer; inline;
    /// free an item of this heap's own page
    procedure Release(aMemory: Pointer; aPage: PSmallPage); inline;
    procedure CollectThreadFree;
    /// Return to the system the memory of free pages, except the aKeep most recent ones, that have
    /// been free for at least aMinAge milliseconds
    procedure TrimFreePages(aMinAge: Cardinal; aKeep: NativeInt);
  public
    /// the heap size is a multiple of the cache line: the medium heap follows it in TThreadHeap
    FTailPad: array[0..5] of NativeUInt;
  end;

var
  /// size class by (Size + 15) shr 4, Size from 1 to SmallMaxSize
  SmallClassOfSize: array[0..SmallMaxSize div 16] of Byte;
  /// a page without items for the FDirect entries of classes without pages; never changes
  EmptyPage: TSmallPage;

/// Page of a small block by its address; nil - the address is not in a small-block segment
function SmallPageOf(aMemory: Pointer): PSmallPage; inline;
/// Heap that owns the segment of a small block
function SmallHeapOf(aMemory: Pointer): PSmallHeap; inline;

implementation

uses
  ShardMM.Platform, ShardMM.Large;

function SmallPageOf(aMemory: Pointer): PSmallPage;
var
  seg: NativeUInt;
begin
  if SegmentKindOf(aMemory) <> SegmentKindSmall then
    Exit(nil);
  seg := SegmentOf(aMemory);
  Result := @PSmallSegment(seg).Pages[(NativeUInt(aMemory) - seg) shr SmallPageShift];
end;

function SmallHeapOf(aMemory: Pointer): PSmallHeap;
begin
  Result := PSmallSegment(SegmentOf(aMemory)).Pages[0].FHeap;
end;

var
  /// FDirect entries of every class: from and to
  ClassDirectFrom, ClassDirectTo: array[0..SmallClassCount - 1] of Integer;

{ TSmallPage }

procedure TSmallPage.LinkFirst;
begin
  FPrev := nil;
  FNext := FClass.FFirst;
  if FNext <> nil then
    FNext.FPrev := @Self
  else
    FClass.FLast := @Self;
  FClass.SetFirst(@Self);
  FInList := 1;
end;

procedure TSmallPage.LinkToTail;
begin
  FNext := nil;
  FPrev := FClass.FLast;
  if FPrev <> nil then
    FPrev.FNext := @Self
  else
    FClass.SetFirst(@Self);
  FClass.FLast := @Self;
  FInList := 1;
end;

procedure TSmallPage.Unlink;
begin
  if FPrev <> nil then
    FPrev.FNext := FNext
  else
    FClass.SetFirst(FNext);
  if FNext <> nil then
    FNext.FPrev := FPrev
  else
    FClass.FLast := FPrev;
  FNext := nil;
  FPrev := nil;
  FInList := 0;
end;

// The items of aList, a value taken from FThreadFree, move to FLocalFree
procedure TSmallPage.TakeFreed(aList: NativeUInt);
var
  first, last: PSmallFreeItem;
begin
  if aList = 0 then
    Exit;
  first := PSmallFreeItem(FData + (aList and SmallThreadFreeOffsetMask));
  last := PSmallFreeItem(FData + ((aList shr SmallThreadFreeTailShift) and SmallThreadFreeOffsetMask));
  last.Next := FLocalFree;
  FLocalFree := first;
  Dec(FUsed, NativeInt(aList shr SmallThreadFreeCountShift));
  if FInList = 0 then
    LinkToTail;
end;

procedure TSmallPage.ReleaseIfUnused;
begin
  if (FUsed <> 0) or (FThreadFree <> 0) or
     ((FClass.FFirst = @Self) and (FNext = nil)) or (FClass.FFirst = nil) then
  begin
    if FInList = 0 then
      LinkToTail;
    Exit;
  end;
  if FInList <> 0 then
    Unlink;
  FHeap.FreePage(@Self);
end;

procedure TSmallPage.ThreadFree(aMemory: Pointer);
var
  old, pushed, offset, base: NativeUInt;
  owner: PSmallHeap;
  head: PSmallPage;
begin
  offset := NativeUInt(aMemory) and SmallThreadFreeOffsetMask;
  base := NativeUInt(aMemory) - offset;
  repeat
    old := FThreadFree;
    if old = 0 then
    begin
      PSmallFreeItem(aMemory).Next := nil;
      pushed := (NativeUInt(1) shl SmallThreadFreeCountShift) or (offset shl SmallThreadFreeTailShift) or offset;
    end
    else
    begin
      PSmallFreeItem(aMemory).Next := PSmallFreeItem(base + (old and SmallThreadFreeOffsetMask));
      pushed := ((old + NativeUInt(1) shl SmallThreadFreeCountShift) and not NativeUInt(SmallThreadFreeOffsetMask)) or offset;
    end;
  until AtomicCmpExchange(FThreadFree, pushed, old) = old;

  // the list was empty: this thread, and only this one, queues the page at its owner
  if old = 0 then
  begin
    owner := FHeap;
    repeat
      head := owner.FThreadFreePages;
      FNextNotified := head;
    until AtomicCmpExchange(Pointer(owner.FThreadFreePages), Pointer(@Self), Pointer(head)) = Pointer(head);
  end;
end;

{ TSmallClass }

procedure TSmallClass.SetFirst(aPage: PSmallPage);
var
  i: Integer;
  direct: PSmallPage;
begin
  FFirst := aPage;
  direct := aPage;
  if direct = nil then
    direct := @EmptyPage;
  for i := FDirectFrom to FDirectTo do
    FHeap.FDirect[i] := direct;
end;

// The next batch of at most SmallCarveBatch items from the uncarved part of aPage, where at least one
// item fits, linked in ascending address order. A function of its own and without calls: dcc64 keeps
// the cursor, the item size and the limit in registers here, while in a function with calls it keeps
// fields and parameters in memory and reloads them for every item
function CarveBatch(aPage: PSmallPage; aItemSize: NativeUInt): PSmallFreeItem;
var
  item: PSmallFreeItem;
  next, stop: NativeUInt;
  count: Integer;
begin
  item := PSmallFreeItem(aPage.FBump);
  // an item fits when it starts at or below stop
  stop := aPage.FBumpEnd - aItemSize;
  Result := item;
  next := NativeUInt(item) + aItemSize;
  count := SmallCarveBatch - 1;
  while (count > 0) and (next <= stop) do
  begin
    item.Next := PSmallFreeItem(next);
    item := PSmallFreeItem(next);
    Inc(next, aItemSize);
    Dec(count);
  end;
  item.Next := nil;
  aPage.FBump := next;
end;

// Allocation when FFree of the first page of the class is empty: the foreign-free queue, the
// page's local frees, carving, the next pages, a new page. A page where nothing was found leaves the
// list, so the page found ends up first. FThreadFree of the pages is not read here: whatever other
// threads pushed before the queue was drained has been taken, and whatever they push later queues
// the page again.
function TSmallClass.AllocSlow: PSmallFreeItem;
var
  page, next: PSmallPage;
  item: PSmallFreeItem;
begin
  // The queue of pages with foreign frees is drained here, when a page runs out of items, and not
  // on every allocation: while a page stays queued, further foreign frees into it are one CAS
  // without queueing
  if FHeap.FThreadFreePages <> nil then
    FHeap.CollectThreadFree;
  page := FFirst;
  while True do
  begin
    if page = nil then
      page := FHeap.NewPage(@Self);
    if page.FFree = nil then
    begin
      if page.FLocalFree <> nil then
      begin
        page.FFree := page.FLocalFree;
        page.FLocalFree := nil;
      end
      else if page.FBump + FItemSize <= page.FBumpEnd then
        // carve a batch: the next allocations take the fast path from FFree
        page.FFree := CarveBatch(page, FItemSize)
      else
      begin
        next := page.FNext;
        page.Unlink;
        page := next;
        Continue;
      end;
    end;
    item := page.FFree;
    page.FFree := item.Next;
    Inc(page.FUsed);
    Exit(item);
  end;
end;

{ TSmallHeap }

// A page whose memory cannot be committed goes back where it was taken from before OutOfMemory, so neither
// its descriptor nor its addresses are lost. Aged free pages are trimmed by FreePage only: a trim check
// here costs 2 % in allocation-heavy work, and a thread that takes new pages uses up its free ones first
function TSmallHeap.NewPage(aClass: PSmallClass): PSmallPage;
var
  page: PSmallPage;
  fromDecommitted: Boolean;
begin
  // a recently freed committed page first, then one returned to the system, then a new one
  fromDecommitted := False;
  page := FFreePages;
  if page <> nil then
  begin
    FFreePages := page.FNext;
    if FFreePages <> nil then
      FFreePages.FPrev := nil
    else
      FFreeTail := nil;
    Dec(FFreePageCount);
  end
  else if FDecommitted <> nil then
  begin
    page := FDecommitted;
    FDecommitted := page.FNext;
    fromDecommitted := True;
  end
  else
  begin
    if (FSegment = nil) or (FSegmentNext >= SmallPagesPerSegment) then
    begin
      FSegment := AllocSegment(SegmentKindSmall, SizeOf(TSmallSegment));
      FSegment.Pages[0].FHeap := @Self;
      // page 0 holds the segment header
      FSegmentNext := 1;
    end;
    page := @FSegment.Pages[FSegmentNext];
    page.FData := NativeUInt(FSegment) + NativeUInt(FSegmentNext) shl SmallPageShift;
    page.FCommitted := 0;
    Inc(FSegmentNext);
  end;
  if page.FCommitted = 0 then
  begin
    if VirtualAlloc(Pointer(page.FData), SmallPageSize, MemCommit, PageReadWrite) = nil then
    begin
      if fromDecommitted then
      begin
        page.FNext := FDecommitted;
        FDecommitted := page;
      end
      else
        Dec(FSegmentNext);
      OutOfMemory;
    end;
    page.FCommitted := 1;
  end;
  page.FHeap := @Self;
  page.FClass := aClass;
  page.FItemSize := aClass.FItemSize;
  page.FFree := nil;
  page.FLocalFree := nil;
  page.FThreadFree := 0;
  page.FNextNotified := nil;
  page.FUsed := 0;
  page.FBump := page.FData;
  page.FBumpEnd := page.FData + SmallPageSize;
  page.LinkFirst;
  Result := page;
end;

procedure TSmallHeap.FreePage(aPage: PSmallPage);
begin
  aPage.FClass := nil;
  aPage.FFreeTick := GetTickCount;
  aPage.FPrev := nil;
  aPage.FNext := FFreePages;
  if FFreePages <> nil then
    FFreePages.FPrev := aPage
  else
    FFreeTail := aPage;
  FFreePages := aPage;
  Inc(FFreePageCount);
  if FFreePageCount > SmallFreePagesCommitted then
    TrimFreePages(SmallDecommitDelay, SmallFreePagesCommitted);
  LargeCacheExpire;
end;

procedure TSmallHeap.TrimFreePages(aMinAge: Cardinal; aKeep: NativeInt);
var
  now: Cardinal;
  page: PSmallPage;
begin
  now := GetTickCount;
  while (FFreePageCount > aKeep) and (FFreeTail <> nil) and
        (now - Cardinal(FFreeTail.FFreeTick) >= aMinAge) do
  begin
    page := FFreeTail;
    FFreeTail := page.FPrev;
    if FFreeTail <> nil then
      FFreeTail.FNext := nil
    else
      FFreePages := nil;
    Dec(FFreePageCount);
    VirtualFree(Pointer(page.FData), SmallPageSize, MemDecommit);
    page.FCommitted := 0;
    page.FPrev := nil;
    page.FNext := FDecommitted;
    FDecommitted := page;
  end;
end;

function TSmallHeap.Alloc(aSize: NativeUInt): Pointer;
var
  page: PSmallPage;
  item: PSmallFreeItem;
begin
  if aSize <= SmallDirectMax then
    page := FDirect[(aSize + 15) shr 4]
  else
  begin
    page := FClasses[SmallClassOfSize[(aSize + 15) shr 4]].FFirst;
    if page = nil then
      page := @EmptyPage;
  end;
  item := page.FFree;
  if item <> nil then
  begin
    page.FFree := item.Next;
    Inc(page.FUsed);
  end
  else
    item := FClasses[SmallClassOfSize[(aSize + 15) shr 4]].AllocSlow;
  Result := item;
end;

procedure TSmallHeap.Release(aMemory: Pointer; aPage: PSmallPage);
begin
  PSmallFreeItem(aMemory).Next := aPage.FLocalFree;
  aPage.FLocalFree := aMemory;
  Dec(aPage.FUsed);
  if aPage.FUsed = 0 then
    aPage.ReleaseIfUnused
  else if aPage.FInList = 0 then
    aPage.LinkToTail;
end;

procedure TSmallHeap.CollectThreadFree;
var
  page, next: PSmallPage;
begin
  if FThreadFreePages = nil then
    Exit;
  page := AtomicExchange(Pointer(FThreadFreePages), nil);
  while page <> nil do
  begin
    // the link to the next one is read before the exchange: once FThreadFree is 0 another thread may
    // queue the page again and overwrite FNextNotified
    next := page.FNextNotified;
    page.TakeFreed(AtomicExchange(page.FThreadFree, 0));
    if page.FUsed = 0 then
      page.ReleaseIfUnused;
    page := next;
  end;
end;

procedure TSmallHeap.Setup;
var
  i: Integer;
begin
  Self := Default(TSmallHeap);
  FDirect[0] := @EmptyPage;
  for i := Low(FClasses) to High(FClasses) do
  begin
    FClasses[i].FHeap := @Self;
    FClasses[i].FItemSize := SmallClassSizes[i];
    FClasses[i].FDirectFrom := ClassDirectFrom[i];
    FClasses[i].FDirectTo := ClassDirectTo[i];
    FClasses[i].SetFirst(nil);
  end;
end;

// Before the memory manager is installed: ShardMM uses this unit, so this initialization runs first
procedure InitTables;
var
  size, c: Integer;
begin
  for c := Low(ClassDirectTo) to High(ClassDirectTo) do
    ClassDirectTo[c] := -1;
  c := 0;
  for size := 0 to High(SmallClassOfSize) do
  begin
    while SmallClassSizes[c] < size * 16 do
      Inc(c);
    SmallClassOfSize[size] := c;
    // FDirect entry 0 (Size = 0) is unused and points to EmptyPage; classes above SmallDirectMax
    // have no FDirect entries (ClassDirectTo < ClassDirectFrom)
    if (size > 0) and (size <= SmallDirectMax div 16) then
    begin
      if ClassDirectFrom[c] = 0 then
        ClassDirectFrom[c] := size;
      ClassDirectTo[c] := size;
    end;
  end;
end;

{$IF SizeOf(TSmallPage) <> 128}
  {$MESSAGE ERROR 'TSmallPage must take two cache lines (ShardFreeMem relies on 128)'}
{$IFEND}
{$IF SizeOf(TSmallSegment) > SmallPageSize}
  {$MESSAGE ERROR 'segment header does not fit page 0'}
{$IFEND}

initialization
  InitTables;

end.

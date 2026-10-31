# ShardMM

A scalable memory manager for Delphi on Win64: a heap per thread, small blocks in pages with sharded
free lists after the design of [mimalloc](https://github.com/microsoft/mimalloc), medium blocks in
per-thread arenas with TLSF, large blocks in their own reservations with a shared cache, and
assembler fast paths for the common case. MIT licensed.

Requirements: Delphi 13 (tested with 13.2), Win64. Other platforms stop with a compile-time error.

## Usage

Put `ShardMM` first in the `uses` clause of the program, before any unit that allocates memory:

```pascal
program MyApp;

uses
  ShardMM,
  System.SysUtils;
```

The unit installs itself in its initialization; if another memory manager is already installed or
the RTL memory manager has already handed out a block, it stops with runtime error 227 (assertion
failed). `ShardGetMem`, `ShardFreeMem`, `ShardReallocMem` and `ShardAllocMem` are declared in the
interface of the unit for callers that bypass the RTL, such as an allocator shim for C code.

```
Source\ShardMM.pas           installation, thread heaps, fast paths, ReallocMem
Source\ShardMM.Segments.pas  4 MB segments and the segment map
Source\ShardMM.Small.pas     small blocks, up to 16 KB
Source\ShardMM.Medium.pas    medium blocks, up to 1 MB
Source\ShardMM.Large.pas     large blocks and their cache
Source\ShardMM.Platform.pas  Windows functions, CAS128, Bsr, Bsf
Tests\ShardMMTests.dpr       deterministic tests of the documented behaviour
Tests\ShardMMStress.dpr      multithreaded stress test that checks block contents
Bench\AppBench.dpr           application-shaped workloads under ShardMM, mimalloc, FastMM5, RTL
Bench\AppBench.ps1           builds the variants and runs them interleaved
```

Every unit starts with a comment on how its part works; this file is the overview.

## Design

### Thread heaps

- **A heap per thread**, found through an own TLS slot (`TlsAlloc`) rather than a `threadvar`:
  reading it is one `gs:[$1480 + 8 * index]` load. If Windows hands out an index of 64 or above
  (`TlsExpansionSlots`), the fast paths always take the slow path and the slot is read through the
  array at `gs:[$1780]`.
- **Thread exit through an FLS callback.** Windows calls it when any thread exits - a `TThread`, a
  pool thread, a thread of a C library. The heap goes as a whole, with its pages and arenas, to a
  stack of free heaps, and the next thread gets it warmed up. The stack changes with one 16-byte CAS
  (`cmpxchg16b`) on the top and a change counter that rules out ABA. Blocks other threads free while a
  heap waits in the stack gather in its foreign-free queues and are drained by its next owner.
- **A reserve for the next thread.** An exiting thread leaves its heap up to 64 free small-block
  pages (4 MB) and up to 4 empty medium arenas and returns the rest of its free memory to the system
  at once. Without the reserve every new thread pays page faults again for the memory its
  predecessor just returned: in mimalloc-bench's mstress (25 rounds of 8 threads) that was 490
  thousand page faults and 0.59 s against 112 thousand and 0.457 s with the reserve.
- **The reserve expires after a second.** A heap in the stack has no owner to return memory on a
  deadline, so the slow paths of any thread and thread exit check it: one second after the first
  heap with a reserve entered the stack, the stack is taken as a whole, every reserve is trimmed down
  to what a live thread always keeps (16 pages and one arena) and the stack is put back. The clock is
  the `InterruptTime` field of `KUSER_SHARED_DATA`, the page Windows maps into every process at a
  fixed address: the check is two loads without a call, and neither cache line is written per
  operation. Without the expiry the reserve of heaps nobody takes again would stay committed forever.

### Foreign frees

A small or medium block freed by another thread is pushed with one CAS onto the foreign-free list of
its page or arena; the owner takes the whole list with one exchange. Pages and arenas never
change their owner - heaps are never freed, they pass to the next thread - so the owner recorded when
a page or an arena was created is always valid. A large block belongs to no thread: any thread frees
it directly.

### Small blocks (`ShardMM.Small`)

- **4 MB segments aligned to 4 MB**, 64 pages of 64 KB each; page 0 holds the segment header with the
  descriptors of all pages. A segment belongs to one heap; a page serves one size class and goes to
  another class when it becomes empty.
- **No header per item.** The page of an item is the descriptor `Pages[(P - segment) shr 16]`, the
  segment is the address with the low 22 bits cleared. The segment map tells which kind an address
  belongs to: indexed by address bits 32..46 it points to a table per 4 GB with one byte per segment;
  two loads.
- **43 size classes**: 16, 32, 64, 80, 96, 112, 128, then four per power of two up to 2 KB (160, 192,
  224, 256, 320, ..., 2048), eight up to 8 KB (2304, 2560, ..., 8192) and four up to 16 KB (10240, 12288,
  14336, 16384) - steps of 12.5-25 %. A 64 KB page holds from 4 items (14 and 16 KB) to 4096; the page
  tail where no whole item fits is at most 9 % for the 2-8 KB classes and at most 12.5 % above 8 KB (a
  12.5 % step there would leave up to 19 %, so the step stays 25 %). The class comes from one table
  load by `(Size + 15) shr 4`.
- **No class 48, for the sake of cache lines.** Items are laid out from the start of a page aligned to
  64 KB, and half of the items of class 48 would take one more cache line than their size needs: a
  44-byte object would lie in two lines instead of one. The extra line is expensive in Delphi:
  zeroing a new object and the atomic operations on its reference count (`AfterConstruction`,
  `_AddRef`, `_Release`) touch it every time. Requests of 33-48 bytes go to class 64.
- **Class 112 exists** although it has the same property: without it 97-112-byte and 113-128-byte
  objects interleave on the same pages, and walking objects of one kind touches the lines of the
  other. That is how libxml2 DOM attributes (104 bytes) and nodes (120) interleave: XPath over a
  document was 20 % slower without class 112 (85 against 68 ms) with the same allocation code.
- **Carving in ascending address order.** Objects created one after another get adjacent addresses,
  and walking them in the same order moves forward through memory, as the hardware prefetcher
  expects. Handing out a batch in reverse order cost XPath over a libxml2 DOM another 20 % (103 against
  85 ms). The uncarved part of a page is cut in batches of 64 items, by a function without calls:
  there dcc64 keeps the cursor, the item size and the limit in registers. With the loop inside the
  slow path it kept the cursor in the page descriptor and reloaded it for every item, and `objects`,
  `pack` and `strings` of AppBench ran 1.5-2.3 % longer.
- **Three free lists per page**, linked through the free items themselves: `FFree` - the owner
  allocates from it, `FLocalFree` - the owner puts freed items here, `FThreadFree` - other threads push
  freed items here. Allocation and freeing by the owner do no atomic operation at all.
- **The foreign-free list is one word.** `FThreadFree` is not a pointer: it holds the offsets of the
  head and of the tail of the list in the page (items lie at multiples of 16 bytes in 64 KB, 16 bits
  each) and the number of items. The owner takes the list by exchanging the word for 0, splices it
  into `FLocalFree` by the tail and subtracts the count from `FUsed` without walking it. The items have
  just been written by other threads, and a walk waits for a cache miss on every one of them: in
  AppBench's `pipeline` (one thread packs messages, another unpacks and frees them) the walk took 9 %
  of the time, and without it the scenario runs 13 % faster. A push computes the new word from the old
  one alone - the new item as the head, the same tail (the new item when the list was empty), the
  count plus one - so a CAS that succeeds always describes the list as it is, even if the owner took
  the list and other pushes brought the word back to the same value in between: the ABA problem of a
  lock-free stack comes from popping single items, and nobody does that here.
- **A non-zero word means "the page is queued at its owner".** The push that finds 0 queues the
  page - exactly once until the next drain; the owner exchanges the word for 0 only after taking the
  page from the queue. So a page goes back to the free pages only when `FUsed = 0` and
  `FThreadFree = 0`: no items in use, no other thread touches it, and it is not queued. A separate
  flag set by a second CAS after the push would not do: between the two operations the owner may take
  the item and free the page, and the other thread then queues freed memory.
- **The queue is drained lazily**, when a page runs out of items rather than on every allocation:
  while a page stays queued, further foreign frees into it are one CAS without queueing. Outside the
  queue the owner never reads `FThreadFree`: the second line of the descriptor is not needed on the
  slow path.
- **A page that got free items again goes to the tail of its class list**, not to the head (as in
  mimalloc): by the time allocation reaches it, more than one item has gathered. At the head it would
  hand its single free item to the very next allocation and leave the list again. On a
  random-replacement workload the head insertion together with reading `FThreadFree` on the slow path
  cost a third of the time (0.62 against 0.40 s).
- **Delayed return to the system.** An empty page goes to the free pages of its heap. Up to 16 free
  pages per thread always stay committed; the memory of the others goes back to the system
  (`MEM_DECOMMIT`) once a page has been free for a second. Without the delay a "free everything,
  allocate again" cycle paid `VirtualFree`, `VirtualAlloc` and 16 page faults for every page and ran
  8-13 % slower.

### Fast paths (`ShardMM`, `ShardMM.Small`)

`ShardGetMem` and `ShardFreeMem` for a small block of the own thread are about fifteen instructions
of assembler without calls and without a stack frame, `ShardReallocMem` of a small block that keeps its
place about twenty; everything else jumps to the slow path in Pascal with the same registers.

- **A page per size** (`FDirect`, like `pages_free_direct` in mimalloc): the first page of the class by
  `(Size + 15) shr 4` for sizes up to 2 KB, and for a class without pages a shared empty page.
  Allocation is the slot load, `FDirect[i]`, `FFree` of the page and the next item, without the class
  table and without a nil check. Only `TSmallClass.SetFirst`, the single place where the first page of
  a class changes, writes the array. Blocks of 2-16 KB are allocated through the class table: their
  pages hold few items, and `SetFirst` would rewrite dozens of array entries on every change.
- **The next free item is prefetched.** Having taken an item, `ShardGetMem` issues `prefetchw` for
  the next one: the next allocation of the class reads its link, and the caller writes into it. When
  the items come back from another core (`pipeline` of AppBench) this saves 8-10 %; in the scenarios
  of one thread the difference is within the noise. The next item is kept in `rcx`: dcc64 encodes
  `prefetchw` with `r8`-`r15` without the REX prefix, so `[r8]` would become `[rax]`.
- **A small block within its class is resized without leaving the fast path.** `ShardReallocMem`
  looks the block up in the segment map, reads the class size from the page descriptor and returns
  the same pointer while the new size is within the class and not below a quarter of it, whichever
  thread owns the block: nothing changes but the size the caller uses, and the class of a page with a
  live item does not change. A string appended a piece at a time and a dynamic array grown by one
  element come here on every step, mostly within the class thanks to the headroom of growth
  (`ReallocMem` below). In AppBench `concat` and `arrays` run 3.4-4.1 % faster with it and `pipeline`
  1.6-2.1 %: the slow path builds a stack frame and looks the block up in the segment map twice.
- **The segment owner lives in descriptor 0.** The "is this block mine" check of `ShardFreeMem`
  compares that pointer - a cache line nobody writes - rather than a field of the page descriptor the
  owner writes on every allocation.
- **The page descriptor is laid out by cache lines.** The first line holds `FFree`, `FLocalFree`,
  `FUsed`, `FInList` and the other owner fields, the second `FThreadFree` and `FNextNotified`, which
  other threads write, and rarely needed fields. A foreign free does not take the line with the
  owner's lists away from it.
- **The fast paths do not look at the foreign-free queues.** The small-block queue is drained by an
  allocation that found its page empty; the medium-arena queue by every medium-block operation, the
  slow paths of allocation and freeing, and thread exit.

### Medium blocks (`ShardMM.Medium`)

Blocks from 16 KB to 1 MB.

- **Per-thread arenas of 4 MB** - segments like those of small blocks, with their own kind in the
  segment map. An arena belongs to the heap of one thread; its memory is committed as chunks are
  carved, in 64 KB steps.
- **TLSF** (two-level segregated fit): 16 bins per power of two and bitmaps of the non-empty bins. The
  request is rounded up to the start of the next bin, so any chunk of the bin found fits without a
  search: an allocation is two `BSF`, unlinking a chunk and splitting off the remainder when it is at
  least 256 bytes.
- **Adjacent free chunks are merged at once**: the 16-byte chunk header holds the size of the previous
  chunk and the own size with a "free" flag.
- **Resizing in place.** `ReallocMem` of a medium block of the own thread shrinks it by putting the
  tail into the free bins and grows it by taking the free chunk that follows.
- **Foreign frees** - one CAS onto the `ThreadFree` list of the arena with the "queued at the owner"
  bit in the low bit of the same word. The owner visits every chunk of the list anyway - each one is
  merged with its neighbours - so the list is a plain pointer, not the head-tail-count word of
  small-block pages; the rule for an empty arena (no chunks in use, no pending foreign frees) is the
  same.
- **An empty arena** is not returned to the system at once: the most recent one always stays
  committed, the others return all their memory except the first 64 KB after a second and wait until
  a new arena is needed - the addresses stay with them. When a thread exits, up to 4 of the most recent
  ones stay committed.

The boundary between small and medium blocks is 16 KB. With 8 KB, blocks of 8-16 KB would get an
exact fit and the peak for 1.5 million blocks of 9000 and 13000 bytes would be 13.0 and 18.7 GB
instead of 15.7 and 23.5, but after freeing 15 blocks of 16 such a build returned nothing to the
system (with 16 KB - up to 5.9 GB of 15.7), and a probe of 8-16 KB blocks ran 2.4 times longer.

### Large blocks (`ShardMM.Large`)

Blocks above 1 MB.

- **A block is one reservation** with address headroom equal to its size, at most 1 GB, and never
  smaller than 16 MB in total: the first `Committed` bytes are committed, the rest up to `Reserved` is
  address space only. Growing through `ReallocMem` within the committed part changes one header field,
  within the reservation it commits pages in place, beyond it the block moves - no more moves than
  doublings. Addresses are plentiful in Win64, and a reservation without committed memory takes
  neither memory nor commit charge.
- **A cache of freed blocks shared by the process** - up to 32 blocks and 128 MB of committed memory,
  under an SRW lock; only the choice and the reordering happen under it, system calls come after.
  The cache is shared rather than per thread because large buffers are often allocated by one thread
  and freed by another.
- **Choosing from the cache:** among the blocks whose reservation fits the request, the smallest of
  those already committed enough, otherwise the one with the most committed memory. Memory committed
  beyond the request stays with the block for growth and goes back to the system only when it exceeds
  the request both four times and by 16 MB. Shrinking a large block to less than half returns the
  tail to the system in place, without a copy.
- **Back to the system:** a block cached for a second, the oldest blocks when slots or bytes run out,
  a block above 128 MB - at once. The age is checked on every cache access, when a small-block page is
  freed and when a thread exits.
- **A mark in the header.** A live block carries one mark, a freed one another: freeing or
  reallocating an address without a live large block raises runtime error 204 (invalid pointer).

### `ReallocMem`

In place: a small block while the new size is within its class and not below a quarter of it (the
fast path, above); a medium block of the own thread - always when shrinking, and when growing if a
free chunk follows; a large block - within its reservation (one shrunk by no more than half is left
alone). Otherwise the block moves, with headroom when growing: a half plus 32 bytes for small blocks,
a quarter for medium ones, 1/16 for large ones. Without the 32 bytes a short string appended
character by character moves to the next class on every step (16 → 32 → 64 → 96 ...), and XPath over
a libxml2 DOM ran 8 % longer (81.7 against 75.3 ms). With a quarter instead of a half a string grown
by concatenation moves twice as often: AppBench `concat` ran 4-5 % longer and `arrays` 1-2 %, for
2-5 % less memory held in `concat`, `json` and `objects`.

## Known behaviour

- Win64 only. Assembler: the fast paths, reading the TLS slot, `CAS128`, `Bsr` and `Bsf`; the rest is
  Pascal.
- ShardMM takes one TLS slot and one FLS slot per process, and never frees the FLS slot: a DLL with
  ShardMM must stay loaded while its threads run, or their exit calls the callback in unloaded code.
- Every unit compiles with `{$INLINE ON}`: only routines marked `inline` are expanded, whatever the
  inlining setting of the project. With `--inline:auto` the compiler would also try the error paths
  inside inline routines and stop with hint H2445.
- Blocks up to 16 KB are small, up to 1 MB medium, larger ones live in their own reservations, freed
  ones in the shared cache.
- Classes of 2-8 KB go in steps of 12.5 %, 8-16 KB in steps of 25 %: a request of 2100 bytes takes 2304,
  one of 9000 takes 10240. For 1.5 million blocks of 2100 bytes the peak is 3.4 GB (mimalloc 3.8). A
  string growing by concatenation past 2 KB moves to the next class with a copy, where a medium block
  could have grown in place.
- A medium arena keeps its memory committed up to the high-water mark of its carving until it is empty
  as a whole: buffers that grow alternately through medium sizes keep more committed than with exact
  free-space trimming.
- A large block taken from the cache may keep up to 16 MB (or four times the request) committed beyond
  what it needs until it is freed; after a burst of large blocks the cache keeps up to 128 MB for
  another second, and a process that stops freeing memory altogether keeps it longer.
- All blocks are aligned to 16 bytes (small classes are multiples of 16 from a page aligned to 64 KB;
  medium blocks follow a 16-byte chunk header; large ones a 32-byte header at the start of the
  reservation); the stress test checks this on every allocation. Small blocks of classes that are
  multiples of 64 (64, 128, 192, 256, 320 and on) start at a cache-line boundary; medium and large
  ones do not. There is no function for alignment beyond 16 bytes.
- Every thread keeps at least one 64 KB page per size class it used (up to 2.75 MB with all 43
  classes), up to 16 free pages (1 MB) and one empty medium arena committed up to its high-water mark
  (up to 4 MB).
- The heap of an exited thread waits in the stack for the next thread with its pages and arenas that
  still hold live blocks and with a reserve of 64 free pages (4 MB) and 4 empty arenas (up to 16 MB);
  the rest of its free memory goes back to the system when the thread exits, the reserve after a
  second - but only once some thread passes a slow path or exits. Heaps are never freed: there are as
  many as threads ever ran at the same time, plus one for every thread that started while the stack
  was being trimmed.
- A segment (small-block pages or a medium arena) reserves 8 MB of addresses to get 4 MB aligned;
  segment addresses are never released, their memory is.
- A double free of a small block goes undetected: an item has no field to mark it. Medium blocks catch
  it by the "free" flag of the chunk header, large ones by the mark - until the chunk or the block is
  handed out again.
- Memory is not released at process exit and leaks are not reported.

## Measurements

Intel Core Ultra 7 356H, the process on the eight E-cores (affinity mask), Windows 11 with power mode
"Best performance", the variants interleaved within every row.

**mimalloc-bench** - the portable programs of [mimalloc-bench](https://github.com/daanx/mimalloc-bench)
built for Windows with clang-cl, with `malloc`, `calloc`, `realloc`, `free` and `new`/`delete` of the
tests redirected to a DLL per memory manager (for ShardMM it calls `ShardGetMem` and the others
directly). Median of three runs; mimalloc 3.6.0, FastMM5 5.07, ucrt - the C runtime heap of Windows.
This table was taken with a power plan that keeps the minimum processor state at 100 %, the
energy-performance preference at 0 and core parking off, turbo on. Time, s (lower is better), and for
larson, rptest, xmalloc-test and glibc-thread the "relative time" they print, as in mimalloc-bench:

| test | ucrt | mimalloc | ShardMM | FastMM5 |
|---|---:|---:|---:|---:|
| cfrac | 5.810 | 3.667 | 3.743 | 4.268 |
| espresso | 4.923 | 3.887 | 3.875 | 4.079 |
| barnes | 0.140 | 0.143 | 0.141 | 0.142 |
| larsonN | 12.690 | 3.950 | 3.613 | 31.467 |
| larsonN-sized | 13.257 | 3.961 | 3.418 | 31.981 |
| alloc-test1 | 7.479 | 3.890 | 3.914 | 4.439 |
| alloc-testN | 14.304 | 3.941 | 3.888 | 32.263 |
| xmalloc-testN | 0.791 | 0.363 | 0.250 | 12.220 |
| cache-thrash1 | 1.012 | 1.013 | 1.013 | 1.015 |
| cache-thrashN | 0.176 | 0.168 | 0.159 | 0.167 |
| cache-scratch1 | 1.011 | 1.013 | 1.013 | 1.014 |
| cache-scratchN | 0.155 | 0.176 | 0.159 | 0.196 |
| malloc-large | 6.820 | 2.168 | 2.191 | 6.797 |
| mstressN | 0.933 | 0.409 | 0.442 | 0.636 |
| mleak10 | 0.178 | 0.222 | 0.193 | 0.194 |
| mleak100 | 1.753 | 2.156 | 1.851 | 1.873 |
| rptestN | 0.810 | 0.303 | 0.355 | 0.489 |
| glibc-simple | 3.989 | 1.137 | 1.104 | 1.791 |
| glibc-thread | 6.002 | 1.386 | 1.363 | 52.206 |

Peak working set, MB, where the managers differ by more than 5 MB (4-8 MB for everyone in the other
tests, 40-42 for barnes, 15-18 for alloc-test):

| test | ucrt | mimalloc | ShardMM | FastMM5 |
|---|---:|---:|---:|---:|
| larsonN | 45 | 68 | 77 | 35 |
| larsonN-sized | 48 | 73 | 77 | 35 |
| xmalloc-testN | 46 | 68 | 89 | 11 |
| malloc-large | 401 | 598 | 533 | 404 |
| mstressN | 131 | 336 | 217 | 133 |
| rptestN | 52 | 81 | 116 | 84 |
| glibc-thread | 9 | 9 | 16 | 8 |

- The geometric mean of the time ratios ShardMM / mimalloc over the 19 tests is 0.96. ShardMM is faster
  in xmalloc-test by 31 %, in mleak by 13-14 %, in larson by 9-14 %; slower in rptest by 17 % (see
  below) and in mstress by 8 % (with 35 % less memory); within 3 % in the other tests except the
  multithreaded Hoard tests (below).
- larson also measures its own false sharing: the per-thread `thread_data` structures (464 bytes)
  lie back to back on the stack of the main thread, and the counters of neighbouring threads share
  cache lines. The cost depends on whether neighbouring threads land in the same cluster of E-cores,
  so larson varies by 5-10 % between runs. With `thread_data` aligned to 128 bytes larson runs 20 %
  faster for every manager and varies by 0.5 % (an earlier build: ShardMM 2.699 s, mimalloc 2.965).
- rptest is noisier than the rest: single runs of one manager differ by up to 20 % in time, and the
  ratio to mimalloc of the same ShardMM code moves between days from 0.96 to 1.25. Its peak memory
  varies twofold between runs (mimalloc 76-167 MB, ShardMM 81-153 in six runs).
- The multithreaded false-sharing tests of Hoard (cache-thrashN, cache-scratchN, 0.15-0.21 s) measure
  the scheduler rather than the memory manager. A context-switch trace gives every worker the same CPU
  time in every run and with every manager, and no manager puts the objects of two threads into one
  cache line. Now and then the Windows scheduler starts two of the eight workers on one E-core while
  another E-core of the affinity mask sleeps (C2) and picks a thread up only 10-130 ms later; the two
  take turns at quantum ends meanwhile. The time is that of the last worker, so it varies by up to 40 %
  from run to run, with core parking off as well; with six threads on the eight cores it varies by
  0.5 %.
- glibc-simple depends on where the fast paths land in the code: the same build with `ShardGetMem`
  moved by 16 bytes runs 2.5 % faster or slower on the E-cores, and the best position on the P-cores is a
  different one. The other tests do not react to it.

**XML workload** - `LX2Bench` of [LX2](https://github.com/apokroy/LX2) with libxml2 allocating through
the Delphi memory manager, best of two runs, ms:

| operation | C runtime heap | mimalloc | ShardMM |
|---|---:|---:|---:|
| DOM parse UTF-8 | 328.5 | 161.3 | 145.3 |
| XPath, node set | 173.0 | 73.2 | 74.0 |
| XPath, count(contains) | 152.2 | 81.2 | 88.1 |
| XSD validate | 314.4 | 155.9 | 146.1 |
| C14N | 249.8 | 150.5 | 127.3 |
| Serialize UTF-8 | 102.4 | 61.1 | 53.3 |
| DOM parse, 8 threads | 2463 | 791 | 668 |

**Application workload** - `Bench\AppBench` (see [Application benchmark](#application-benchmark)), the
eight E-cores with the workers pinned (`-cores E`), median of three runs, mimalloc 3.6.0, FastMM5 5.07.
Time, s (lower is better); the work per thread is constant, so at 8 threads there is 8 times as much
work, and linear scaling keeps the time. `pipeline` runs producer-consumer pairs, so its smallest
count is 2 threads:

| scenario | threads | ShardMM | mimalloc | FastMM5 | RTL |
|---|---:|---:|---:|---:|---:|
| objects | 1 | 1.316 | 1.407 | 1.577 | 1.544 |
| objects | 8 | 1.384 | 1.520 | 18.822 | 12.462 |
| pack | 1 | 1.128 | 1.164 | 1.238 | 1.404 |
| pack | 8 | 1.320 | 1.395 | 9.736 | 10.285 |
| json | 1 | 1.253 | 1.325 | 1.361 | 1.348 |
| json | 8 | 1.656 | 1.685 | 9.996 | 10.905 |
| strings | 1 | 1.588 | 1.643 | 1.672 | 1.632 |
| strings | 8 | 2.025 | 2.100 | 10.050 | 13.289 |
| maps | 1 | 1.308 | 1.322 | 1.427 | 1.455 |
| maps | 8 | 2.050 | 2.120 | 12.200 | 12.992 |
| interfaces | 1 | 0.818 | 0.886 | 0.995 | 1.112 |
| interfaces | 8 | 0.864 | 0.948 | 14.486 | 7.861 |
| pipeline | 2 | 0.512 | 0.548 | 0.963 | 17.482 |
| pipeline | 8 | 0.783 | 0.938 | 4.784 | 81.789 |
| mixed | 1 | 1.347 | 1.450 | 1.425 | 1.419 |
| mixed | 8 | 1.632 | 1.753 | 8.542 | 11.575 |
| threads | 1 | 1.266 | 1.462 | 1.447 | 1.436 |
| threads | 8 | 0.358 | 0.399 | 1.500 | 50.657 |

Peak committed memory of the process at 8 threads, MB:

| scenario | ShardMM | mimalloc | FastMM5 | RTL |
|---|---:|---:|---:|---:|
| objects | 17 | 17 | 18 | 10 |
| pack | 75 | 155 | 72 | 76 |
| json | 16 | 54 | 12 | 4 |
| strings | 14 | 23 | 9 | 4 |
| maps | 73 | 229 | 62 | 48 |
| interfaces | 10 | 11 | 9 | 4 |
| pipeline | 16 | 15 | 9 | 10 |
| mixed | 30 | 132 | 18 | 10 |
| threads | 11 | 11 | 12 | 5 |

- ShardMM is faster than mimalloc in every row: by 1-13 % on one thread and by 2-17 % on eight, most in
  `pipeline` (blocks freed by another thread) and `threads` (thread creation and exit). Its peak at
  8 threads is 2-4 times below mimalloc where much is allocated and freed per thread (`pack`, `json`,
  `maps`, `mixed`) and up to 1.7 times above FastMM5.
- FastMM5 does not scale on this code: at 8 threads it takes 4-17 times as long as ShardMM. Its arenas
  are shared by all threads, so neighbouring blocks of one arena go to different threads, and the
  reference counts of strings, interfaces and dynamic arrays, changed by atomic instructions in the
  memory of the object itself, make the threads fight over cache lines. The RTL memory manager takes
  6-9 times as long, and 100-140 times with foreign frees and thread churn.
- On one thread the memory manager is only a part of the work: the slowest of the four takes 5-36 %
  longer than the fastest, most in `interfaces` (500 small objects and as many closures per round).

**Application workload on a server and a desktop** - the same benchmark on two more machines, with
`AppBench.ps1 -Threads 1,4,8 -Runs 3` (median of three interleaved runs, threads not pinned): a
production server, Intel Xeon Silver 4210 (10 cores, 2.2 GHz) with Windows Server 2016, measured while it
was serving its own load, and a desktop, Intel Core i5-12500 (6 cores). Time of each manager relative to
ShardMM (above 1 - slower than ShardMM), geometric mean over the scenarios without `pipeline`, the range
over the scenarios in parentheses:

| machine | threads | mimalloc | FastMM5 | RTL |
|---|---:|---:|---:|---:|
| Xeon Silver 4210 | 1 | 1.08 | 1.09 | 1.07 |
| | 4 | 1.06 | 3.77 (2.72-5.21) | 5.57 |
| | 8 | 1.06 | 5.07 (3.77-8.12) | 10.45 |
| Core i5-12500 | 1 | 1.08 | 1.10 | 1.12 |
| | 4 | 1.06 | 2.76 (1.72-4.61) | 5.00 |
| | 8 | 1.04 | 3.73 (2.38-7.30) | 8.16 |

The server at 8 threads, time, s:

| scenario | ShardMM | mimalloc | FastMM5 | RTL |
|---|---:|---:|---:|---:|
| objects | 2.962 | 3.270 | 20.753 | 24.546 |
| pack | 2.660 | 2.695 | 12.832 | 18.000 |
| json | 2.886 | 2.987 | 12.539 | 20.375 |
| strings | 3.528 | 3.641 | 13.298 | 23.926 |
| maps | 3.537 | 3.683 | 14.349 | 25.361 |
| interfaces | 1.942 | 2.058 | 15.773 | 13.945 |
| pipeline | 1.703 | 1.709 | 5.873 | 60.080 |
| mixed | 2.738 | 3.016 | 12.113 | 20.566 |
| threads | 0.398 | 0.446 | 2.168 | 54.478 |

- On the server ShardMM is at least as fast as mimalloc in every row (`pipeline` at 2 threads is a tie
  within 0.2 %) and up to 12 % faster. On the desktop mimalloc is ahead by 2-5 % in `pack`, `maps` and
  `interfaces` at 4 threads and in `pack` and `interfaces` at 8, and within 1 % in two more rows.
- With the work per thread constant, the server keeps the time almost flat from 1 to 8 threads under
  ShardMM and mimalloc (geometric mean of T(8)/T(1) 1.25 and 1.23), while FastMM5 takes 5.8 times and the
  RTL manager 8.4 times as long: under RTL the eight threads run as if one after another. On the
  six-core desktop eight threads share cores through Hyper-Threading, and ShardMM and mimalloc reach 1.8
  and 1.7, FastMM5 6.1, RTL 8.2.
- The peaks at 8 threads hardly depend on the machine: ShardMM has 75 MB in `pack`, 73 in `maps` and 30
  in `mixed`, here as above, FastMM5 72, 59-65 and 18, mimalloc 152-164, 168-197 and 131-132.
- The checksums agree across the four managers and both machines in all 216 rows.

**Medium blocks** - a probe with 2000 live blocks and 2 million random replacements on one thread,
median of two runs (Windows power mode "Balanced"): 64 KB - 1 MB - 559 ms, peak 1195 MB, 292 thousand
page faults (mimalloc 2140 ms, 1481 MB, 282 thousand); 16-256 KB - 321 ms and 301 MB (mimalloc 440 ms
and 408 MB); 8-16 KB, small blocks - 80 ms (mimalloc 130 ms).

## Deterministic tests

`Tests\ShardMMTests.dpr`: fixed sizes in a fixed order, each test one documented behaviour. Every
block is filled with the pattern of its own seed and checked later, so overlapping live blocks, a byte
lost on a move and a stray write show up as a mismatch.

- Size classes: one live block of every size from 1 byte to 16 KB at once, medium sizes at the
  thresholds and in a sweep, large sizes at their thresholds; each block is 16-byte aligned and of the
  kind and class its size calls for.
- `AllocMem` on reused memory: freed dirty items of every class, medium chunks and cached large
  blocks come back zeroed.
- `ReallocMem`: the contents survive every pair of sizes from 1 byte to 20 MB, growth by one byte up
  to 70000 and shrinking by halves; the in-place rules of small, medium and large blocks hold at their
  exact boundaries.
- Thread exit: blocks outlive their thread and are resized and freed by another one; frees into a heap
  waiting in the stack of free heaps are drained by the next thread to take it, with every page and
  arena left without items in use; memory goes back to the system after the reserve delay, and the
  large-block cache empties after its delay.
- Out of memory: sizes beyond the address space and 4 TB (reserved, then refused at commit) raise
  `EOutOfMemory`, a block that was to be resized keeps its place and contents, and the manager keeps
  working.

The exit code is the number of failed checks. With `-DMM_RTL` the program runs on the RTL memory
manager without the checks of ShardMM's own rules - a check of the tests themselves. A run takes
about 4 seconds, two of them waiting for the one-second delays. Build:

```
dcc64 -B -Q -$O+ -NSSystem;Winapi;System.Win -U<Studio>\lib\win64\release;Source Tests\ShardMMTests.dpr
```

## Stress test

`Tests\ShardMMStress.dpr`: worker threads allocate, free, resize and hand blocks to each other; every
fourth worker supplies small blocks to its neighbour, which frees them at once; a separate thread
keeps starting short-lived threads whose blocks are freed after they exit. Every block is filled with
a pattern derived from its seed and checked before it is freed, after `ReallocMem` and after it is
handed over. Options `-threads N -seconds S -large L -medium M` (L - the share of 1-4 MB blocks in
thousandths, 2 by default; M - an extra share of 16 KB - 1 MB blocks in thousandths, 0 by default); the
exit code is the number of errors; with `-DMM_RTL` the test runs on the RTL memory manager (a check
of the test itself). Build:

```
dcc64 -B -Q -$O+ -NSSystem;Winapi;System.Win -U<Studio>\lib\win64\release;Source Tests\ShardMMStress.dpr
```

Do not accept a change without the deterministic tests passing and a 30-second run on 8 and 16
threads without errors; a change to large blocks also needs `-large 10`, a change to medium blocks
`-medium 100`.

## Application benchmark

`Bench\AppBench.dpr` measures memory managers under code shaped like business applications rather
than bare `GetMem`/`FreeMem` loops. Eleven scenarios, each per thread:

| scenario | work |
|---|---|
| `objects` | 1000 times: 300 orders of 1-20 lines with string and `Variant` fields in an owning list, a walk, 300 random replacements, free |
| `pack` | 20 000 rows, 225 passes: packed in packets of 100 into a `RawByteString` and unpacked into new objects |
| `json` | 9000 times: an array of 40 objects to UTF-8 text, parsed back, walked |
| `strings` | a million times: `Format`, `Split`, `Trim`/`UpperCase`, `Join`, `StringReplace`; every 256th time `TStringList.Sort` |
| `maps` | 160 times: string -> Integer and Integer -> object maps of 20 000 keys: insert, look up, delete half, insert |
| `interfaces` | 12 000 times: a list of 500 interface references and a closure per item |
| `pipeline` | pairs of threads: one packs 300 000 messages, the other unpacks and frees them, so blocks are freed by another thread |
| `mixed` | 200 000 requests: parse JSON, look up a catalogue map, build an order, pack the response, log to a `TStringBuilder` |
| `concat` | 300 000 times: 60 words appended to a string one by one, an SQL list of 20 columns with the trailing comma cut off, a word appended character by character four times, a binary packet grown by `SetLength` and `Move` in 40 steps |
| `arrays` | 90 000 times: an `Integer` array grown to 300 elements by `SetLength(A, Length(A) + 1)`, `Int64` to 100 by `A := A + [X]`, strings to 50, records with a string field to 50; then two of them shortened |
| `threads` | 4000 short-lived threads in waves of N, each building and freeing 40 orders |

The work per thread is constant. The time runs up to a barrier at which the threads still hold their
data, and the memory of the process is taken there. The checksum depends only on the scenario, the
thread count and `-scale`, and a difference between memory managers means memory corruption.

The workload comes from a production Delphi code base; its lists, hash maps, binary packets and JSON
DOM are reproduced by the `AppBench.*` units without depending on it: the same instance sizes
(checked at start-up), storage blocks, growth policies and copies - a packet reader copies its packet
on the first read, an owning list being freed copies its items, the JSON writer is a 213 KB object
zero-filled on every creation. Run side by side with the original under a memory manager that counts
calls by size, AppBench makes the same number of `GetMem`, `AllocMem`, `ReallocMem` and `FreeMem`
calls of every size in every scenario and produces the same checksums (`concat` and `arrays` use only
strings and dynamic arrays of the RTL and are the same code in both). Its code outside the memory
manager is shorter: in the same interleaved run it took 6 % less time on average (11-20 % less under
ShardMM and mimalloc in `pack`, `json` and `mixed`), the ShardMM / mimalloc ratios of the two
differed by at most 4 %, and the FastMM5 / mimalloc and RTL / mimalloc ratios by -15 to +22 %.

`Bench\AppBench.ps1` builds the variants with `dcc64` into `-OutDir` and runs every scenario and
thread count as a separate process, the variants interleaved, the median of `-Runs` into a markdown
table on stdout. It finds the newest registered Delphi (or takes `-Delphi <root>`); mimalloc is built
from a release tag with CMake, Ninja and MSVC of Visual Studio (C++ and CMake tools), or taken ready
with `-MimallocDll`; FastMM5 needs its source directory. The program itself takes
`-only <scenario> [-threads N] [-scale F] [-cores P|E|LPE]`; `-cores` keeps a hybrid processor from
moving the same threads between performance and efficiency cores from run to run, and the process
always opts out of EcoQoS. With `-NoBuild` the script runs the executables of an earlier build, so a
copy of `-OutDir` and the script is enough on a machine without Delphi.

```
.\AppBench.ps1 -Threads 1,8 -Runs 3 -Cores E -FastMM5 C:\src\FastMM5 > results.md
```

## Origins and acknowledgements

ShardMM started as a rework of remarkable [ScaleMM2](https://github.com/andremussche/scalemm) by André
Mussche (with contributions by Arnaud Bouchez; MPL 1.1 / GPL 2 / LGPL 2.1). Over eight stages every part of it was replaced - the thread handling, small blocks, medium
blocks, large blocks, the fast paths - and when the result was renamed to ShardMM the last lines of
ScaleMM2 went too. ShardMM is new code under the MIT license; ScaleMM2 is credited
here as the starting point.

The small-block design follows mimalloc by Daan Leijen et al. (Microsoft Research, MIT license;
"Mimalloc: Free List Sharding in Action", 2019): 64 KB pages in 4 MB segments, free-list sharding with
three lists per page, delayed foreign frees with a queue bit, and the page-per-size array of the fast
path. Medium blocks use TLSF (M. Masmano, I. Ripoll, A. Crespo, J. Real, "TLSF: a New Dynamic Memory
Allocator for Real-Time Systems", 2004). No source code of either was used; the implementation is
written from the published designs.

ShardMM was developed with the help of an AI coding assistant (Claude by Anthropic): the design
choices, the measurements and the review are the author's, and every change was verified with the
stress test and the benchmarks above.

## License

MIT, see [LICENSE](LICENSE).

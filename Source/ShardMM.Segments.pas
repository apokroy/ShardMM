// ShardMM: segments and the segment map
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
unit ShardMM.Segments;

(* Segments are SegmentSize (4 MB) regions aligned to their size. They hold small-block pages
   (ShardMM.Small) and medium-block arenas (ShardMM.Medium). The segment of a block is its address
   with the low SegmentShift bits cleared, so the segment header is reachable from any block in it.

   The segment map tells which kind an address belongs to: indexed by address bits 32..46, it points
   to a table per 4 GB of address space with one byte per segment (0 - not a segment, otherwise
   SegmentKindSmall or SegmentKindMedium). Unused map entries point to a shared array of zeros
   instead of nil, and Win64 user-mode addresses are shorter than 47 bits: the lookup is two loads
   and a compare, without branches. The kind byte is set before any address of the segment is
   handed out and never changes afterwards: segment addresses are never released, only their
   memory. *)

interface

{$R-}{$Q-}{$INLINE ON}

const
  SegmentShift = 22;
  SegmentSize  = NativeUInt(1) shl SegmentShift;

  SegmentKindSmall  = 1;
  SegmentKindMedium = 2;

type
  /// kind byte of every segment of a 4 GB range of addresses
  TSegmentKinds = array[0..(1 shl (32 - SegmentShift)) - 1] of Byte;
  PSegmentKinds = ^TSegmentKinds;

var
  /// indexed by address bits 32..46; written only by AllocSegment
  SegmentMap: array[0..(1 shl 15) - 1] of PSegmentKinds;
  NoSegments: TSegmentKinds;

/// kind of the segment the address belongs to; 0 - not a segment address (a large block or foreign)
function SegmentKindOf(P: Pointer): Byte; inline;
/// start of the segment the address belongs to
function SegmentOf(P: Pointer): NativeUInt; inline;
/// new segment of kind aKind with its first aCommit bytes committed
function AllocSegment(aKind: Byte; aCommit: NativeUInt): Pointer;

implementation

uses
  ShardMM.Platform;

function SegmentKindOf(P: Pointer): Byte;
begin
  Result := SegmentMap[(NativeUInt(P) shr 32) and High(SegmentMap)]
    [(NativeUInt(P) shr SegmentShift) and High(TSegmentKinds)];
end;

function SegmentOf(P: Pointer): NativeUInt;
begin
  Result := NativeUInt(P) and not (SegmentSize - 1);
end;

// Twice the size is reserved and the aligned part is used: the rest is address space only, without
// committed memory. A failed commit or kinds table gives the reservation back before OutOfMemory
function AllocSegment(aKind: Byte; aCommit: NativeUInt): Pointer;
var
  raw, seg, hi: NativeUInt;
  kinds, prev: PSegmentKinds;
begin
  raw := NativeUInt(VirtualAlloc(nil, 2 * SegmentSize, MemReserve, PageReadWrite));
  if raw = 0 then
    OutOfMemory;
  seg := (raw + SegmentSize - 1) and not (SegmentSize - 1);
  if VirtualAlloc(Pointer(seg), aCommit, MemCommit, PageReadWrite) = nil then
  begin
    VirtualFree(Pointer(raw), 0, MemRelease);
    OutOfMemory;
  end;

  hi := (seg shr 32) and High(SegmentMap);
  kinds := SegmentMap[hi];
  if kinds = @NoSegments then
  begin
    kinds := VirtualAlloc(nil, SizeOf(TSegmentKinds), MemCommit, PageReadWrite);
    if kinds = nil then
    begin
      VirtualFree(Pointer(raw), 0, MemRelease);
      OutOfMemory;
    end;
    prev := AtomicCmpExchange(Pointer(SegmentMap[hi]), Pointer(kinds), Pointer(@NoSegments));
    if prev <> @NoSegments then
    begin
      VirtualFree(kinds, 0, MemRelease);
      kinds := prev;
    end;
  end;
  kinds[(seg shr SegmentShift) and High(TSegmentKinds)] := aKind;
  Result := Pointer(seg);
end;

procedure InitMap;
var
  i: Integer;
begin
  for i := Low(SegmentMap) to High(SegmentMap) do
    SegmentMap[i] := @NoSegments;
end;

initialization
  InitMap;

end.

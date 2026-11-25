// ShardMM: Windows functions and processor primitives
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
unit ShardMM.Platform;

// The functions are declared here instead of being taken from Winapi.Windows: no unit except System
// and SysInit may be initialized before the memory manager is installed.

interface

{$R-}{$Q-}{$INLINE ON}
{$IF not (Defined(MSWINDOWS) and Defined(CPUX64))}
  {$MESSAGE FATAL 'ShardMM supports Win64 only'}
{$IFEND}

const
  Kernel32Dll   = 'kernel32.dll';
  MemCommit     = $1000;
  MemReserve    = $2000;
  MemDecommit   = $4000;
  MemRelease    = $8000;
  PageReadWrite = 4;
  /// TlsAlloc and FlsAlloc result when no index is left
  OutOfIndexes  = High(Cardinal);
  /// the InterruptTime field of KUSER_SHARED_DATA
  KUserInterruptTime = $7FFE0008;

function VirtualAlloc(Address: Pointer; Size: NativeUInt; AllocationType, Protect: Cardinal): Pointer; stdcall; external Kernel32Dll;
{$IFDEF ShardMM_ClearBeforeReturningToOS}
/// VirtualFree that first zeroes the committed read-write pages of the range (of the whole region
/// for size 0)
function VirtualFree(Address: Pointer; Size: NativeUInt; FreeType: Cardinal): LongBool;
{$ELSE}
function VirtualFree(Address: Pointer; Size: NativeUInt; FreeType: Cardinal): LongBool; stdcall; external Kernel32Dll;
{$ENDIF}
function TlsAlloc: Cardinal; stdcall; external Kernel32Dll;
function TlsSetValue(Index: Cardinal; Value: Pointer): LongBool; stdcall; external Kernel32Dll;
function FlsAlloc(Callback: Pointer): Cardinal; stdcall; external Kernel32Dll;
function FlsSetValue(Index: Cardinal; Value: Pointer): LongBool; stdcall; external Kernel32Dll;
function GetTickCount: Cardinal; stdcall; external Kernel32Dll;
procedure AcquireSRWLockExclusive(var Lock: Pointer); stdcall; external Kernel32Dll;
/// BOOLEAN: nonzero - the lock is taken
function TryAcquireSRWLockExclusive(var Lock: Pointer): ByteBool; stdcall; external Kernel32Dll;
procedure ReleaseSRWLockExclusive(var Lock: Pointer); stdcall; external Kernel32Dll;

/// Windows interrupt time in 100 ns units since boot. The KUSER_SHARED_DATA page is mapped read-only
/// into every process at a fixed address and the kernel updates the field on every timer tick;
/// reading it is one load without a call (GetTickCount reads the same page through a jump into
/// KERNELBASE). The low half and the first high half are read by a single load, so in the tick when
/// the low half wraps (every seven minutes) the value may lag by 2^32 units: fine for deadlines that
/// tolerate being late
function InterruptTime: Int64; inline;
/// 16-byte compare-and-swap (cmpxchg16b) of a pair of words at an address aligned to 16
function CAS128(var Dest; OldLo, OldHi, NewLo, NewHi: NativeUInt): Boolean;
/// index of the highest and of the lowest set bit; undefined for 0
function Bsr(Value: NativeUInt): NativeUInt;
function Bsf(Value: NativeUInt): NativeUInt;
/// runtime errors 203 and 204 of the memory manager
procedure OutOfMemory;
procedure InvalidPointer;

implementation

function InterruptTime: Int64;
begin
  Result := PInt64(NativeUInt(KUserInterruptTime))^;
end;

function CAS128(var Dest; OldLo, OldHi, NewLo, NewHi: NativeUInt): Boolean;
asm
  .noframe
  // Dest - rcx, OldLo - rdx, OldHi - r8, NewLo - r9, NewHi - the fifth argument: [rsp + 40] on entry,
  // [rsp + 48] after push rbx
  push rbx
  mov r10, rcx
  mov rax, rdx
  mov rdx, r8
  mov rbx, r9
  mov rcx, [rsp + 48]
  lock cmpxchg16b [r10]
  setz al
  pop rbx
end;

function Bsr(Value: NativeUInt): NativeUInt;
asm
  .noframe
  bsr rax, rcx
end;

function Bsf(Value: NativeUInt): NativeUInt;
asm
  .noframe
  bsf rax, rcx
end;

procedure OutOfMemory;
begin
  System.Error(TRuntimeError.reOutOfMemory);
end;

procedure InvalidPointer;
begin
  System.Error(TRuntimeError.reInvalidPtr);
end;

{$IFDEF ShardMM_ClearBeforeReturningToOS}
type
  /// MEMORY_BASIC_INFORMATION
  TMemoryInfo = record
    BaseAddress: Pointer;
    AllocationBase: Pointer;
    AllocationProtect: Cardinal;
    PartitionId: Word;
    RegionSize: NativeUInt;
    State: Cardinal;
    Protect: Cardinal;
    Kind: Cardinal;
  end;

function VirtualQuery(Address: Pointer; var Info: TMemoryInfo; Length: NativeUInt): NativeUInt; stdcall; external Kernel32Dll;
function SystemVirtualFree(Address: Pointer; Size: NativeUInt; FreeType: Cardinal): LongBool; stdcall; external Kernel32Dll name 'VirtualFree';

// Windows zeroes a page before it gives the page to another process, but nobody knows when; until
// then the data of freed blocks stays in physical memory. Only committed read-write pages are
// written: the range of a large block covers address space reserved for its growth, and a write
// there would fault. A committed page the program never touched becomes resident while it is
// zeroed - the price of the option for large blocks committed ahead of their use
function VirtualFree(Address: Pointer; Size: NativeUInt; FreeType: Cardinal): LongBool;
var
  info: TMemoryInfo;
  base: Pointer;
  first: Boolean;
  addr, last, next: NativeUInt;
begin
  addr := NativeUInt(Address);
  if Size = 0 then
    last := High(NativeUInt)
  else
    last := addr + Size;
  base := nil;
  first := True;
  // the walk stops at the end of the range or of the reservation it started in
  while (addr < last) and (VirtualQuery(Pointer(addr), info, SizeOf(info)) = SizeOf(info)) do
  begin
    if first then
    begin
      base := info.AllocationBase;
      first := False;
    end
    else if info.AllocationBase <> base then
      Break;
    next := NativeUInt(info.BaseAddress) + info.RegionSize;
    if next > last then
      next := last;
    if (info.State = MemCommit) and (info.Protect = PageReadWrite) then
      FillChar(Pointer(addr)^, next - addr, 0);
    addr := next;
  end;
  Result := SystemVirtualFree(Address, Size, FreeType);
end;

{$IF SizeOf(TMemoryInfo) <> 48}
  {$MESSAGE ERROR 'TMemoryInfo must match MEMORY_BASIC_INFORMATION of Win64'}
{$IFEND}
{$ENDIF}

end.

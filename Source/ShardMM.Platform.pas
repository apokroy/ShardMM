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
function VirtualFree(Address: Pointer; Size: NativeUInt; FreeType: Cardinal): LongBool; stdcall; external Kernel32Dll;
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

end.

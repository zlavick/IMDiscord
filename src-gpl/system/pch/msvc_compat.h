// MinGW-w64 compatibility shims for the MSVC-specific bits this no-CRT tree
// relies on. Included from pch.h only when _MSC_VER is not defined, so the
// MSVC build path (build.bat) never sees any of it. Everything here keeps the
// original semantics: the intrinsics stay intrinsics, the pragmas that GCC
// ignores are left in place (unknown pragma), and the MSVC linker directives
// are reproduced as real definitions or --alt-link-flags below.
#pragma once

#include <cstddef>
#include <cstring>

// __forceinline inline is a legal MSVC spelling but a duplicate storage class
// for GCC; drop our define where an explicit inline already follows.
#ifndef __forceinline
#define __forceinline inline
#endif
#define __forceinline_inline__ hack
#undef __forceinline_inline__

// #pragma function(memcpy) makes MSVC emit real calls into our own memcpy
// replacement. GCC expands mem*() to builtins unless told otherwise, which
// build.sh does globally with -fno-builtin-mem*.

// The two spellings of "static" thread-local storage.
#ifndef thread_local_win
#if defined(_MSC_VER)
#define thread_local_win __declspec(thread)
#else
#define thread_local_win _Thread_local
#endif
#endif

// MSVC's 64-bit integer literals.
#ifndef __int64
#define __int64 long long
#endif
#ifndef __int32
#define __int32 int
#endif
#ifndef __int16
#define __int16 short
#endif
#ifndef __int8
#define __int8 signed char
#endif

// Interlocked helpers the client uses through MSVC intrinsics.
#ifndef _InterlockedExchangeAdd
#define _InterlockedExchangeAdd(ptr, val) InterlockedExchangeAdd((volatile LONG*)(ptr), (LONG)(val))
#endif
#ifndef _InterlockedExchange
#define _InterlockedExchange(ptr, val) InterlockedExchange((volatile LONG*)(ptr), (LONG)(val))
#endif
#ifndef _InterlockedCompareExchange
#define _InterlockedCompareExchange(ptr, exch, comp) InterlockedCompareExchange((volatile LONG*)(ptr), (LONG)(exch), (LONG)(comp))
#endif

// __uuidof(IID). mingw's <mmdeviceapi.h>/<audioclient.h> do not carry the
// __MINGW_UUID_TO_GUID__ translation that the C++ headers normally install,
// because we deliberately include the plain C flavour; map it by hand.
#ifndef __uuidof
#define IMD_UUIDOF(x) IMD_UUIDOF_IMPL_(x)
#define __uuidof IMD_UUIDOF
#define IMD_UUIDOF_IMPL_(x) (__mingw_uuidof_##x())
#endif

// The .CRT$XC* initializer-table trick in entry.cpp is MSVC-only; MinGW gets
// its static constructors run through .init_array instead (see entry patch).
#ifndef _MSC_VER
#define IMD_NO_MSVC_CTOR_TABLE 1
#endif

---
title: "C++ Atomics and Memory Order"
description: "How C++ atomic operations enforce thread synchronization and instruction ordering without data races."
keywords:
  - C++ memory model
  - std atomic
  - memory order relaxed
  - memory order acquire
  - memory order release
  - memory order seq cst
  - data race vs atomic update
  - happens before relation
  - release acquire synchronization
  - CPU reordering
  - hardware store buffer
  - memory fences
displayed_sidebar: parallelComputingSidebar
slug: /parallel-computing/cpp-atomics-and-memory-order
---

This lesson is part of Chapter 2 (*CPU parallel programming*), Subchapter 2.3 (*Threads and OpenMP*). It explains how `std::atomic` prevents data races and controls memory reordering in multithreaded C++ code.

Concurrent data access without synchronization causes undefined behavior. Atomic operations eliminate data races at the language level and allow control over hardware and compiler memory reordering.

:::tip Read these first
- [/docs/parallel-computing/fundamentals/memory-models](/docs/parallel-computing/fundamentals/memory-models)
- [/docs/parallel-computing/pthreads-mutex-and-barrier](/docs/parallel-computing/pthreads-mutex-and-barrier)
:::

:::important What you should leave with
An atomic variable prevents data races on a single memory location, but it only synchronizes surrounding non-atomic memory accesses across threads when paired with explicit acquire and release memory orderings.
:::

## Why you should care

A data race occurs when two threads access the same memory location concurrently, at least one access is a write, and neither access is atomic. When a data race exists, the C++ standard grants no behavioral guarantees.

Consider a thread publishing a data payload to a buffer and signaling completion to a reader thread:

```cpp
#include <iostream>
#include <thread>

int payload = 0;
bool ready = false; // Plain non-atomic boolean

void producer() {
    payload = 42;    // Plain write
    ready = true;    // Plain write (Data Race if consumer reads concurrently)
}

void consumer() {
    while (!ready) { // Plain read (Data Race)
        // Spin
    }
    std::cout << payload << "\n";
}
```

This code contains two major flaws:
1. **Data Race:** Concurrent unsynchronized read/write on `ready` is undefined behavior. The compiler may hoist `!ready` out of the loop into a register, spinning forever.
2. **Memory Reordering:** Even if `ready` were marked `volatile`, the CPU or compiler could reorder `ready = true` before `payload = 42`. The consumer thread could observe `ready == true` while `payload` still contains `0`.

## The mechanism

The C++ memory model specifies how atomic operations interact with hardware caches and compiler transformations. Every atomic access carries a `std::memory_order` parameter.



The C++ standard defines memory orderings to balance performance against ordering guarantees:

1. **`std::memory_order_relaxed`**: Ensures atomic operations on that variable execute atomically without data races. It imposes **no** ordering constraints on surrounding memory reads or writes relative to other threads.
2. **`std::memory_order_release`**: Used on store operations. Prevents reads and writes in the current thread from being reordered *after* this store.
3. **`std::memory_order_acquire`**: Used on load operations. Prevents reads and writes in the current thread from being reordered *before* this load.
4. **`std::memory_order_seq_cst`** (Sequentially Consistent): Default ordering. Establishes a total global order of all `seq_cst` operations across all threads.

When a store-release operation in Thread 1 reads `true` in a load-acquire operation in Thread 2, a **synchronizes-with** relationship is established. All memory accesses performed by Thread 1 before the release store become visible to Thread 2 after the acquire load.

## A worked example

This example demonstrates lock-free publication of a data structure using acquire-release semantic synchronization.

```cpp
#include <atomic>
#include <iostream>
#include <thread>
#include <cassert>

struct Data {
    int value;
};

Data* shared_data = nullptr;
std::atomic<bool> data_ready(false);

void producer() {
    Data* d = new Data{42};
    shared_data = d; // 1. Non-atomic write to pointer
    
    // 2. Atomic store with release ordering
    data_ready.store(true, std::memory_order_release);
}

void consumer() {
    // 3. Atomic load with acquire ordering
    while (!data_ready.load(std::memory_order_acquire)) {
        // Spin or yield
    }
    
    // 4. Non-atomic read of pointer guaranteed to see step 1
    assert(shared_data != nullptr);
    std::cout << "Read value: " << shared_data->value << "\n";
    delete shared_data;
}

int main() {
    std::thread t2(consumer);
    std::thread t1(producer);
    
    t1.join();
    t2.join();
    return 0;
}
```

### Line-by-line explanation

- **Line 14 (`shared_data = d;`)**: Assigns a newly allocated object address to a non-atomic pointer.
- **Line 17 (`data_ready.store(true, std::memory_order_release);`)**: Marks `data_ready` as `true`. The `memory_order_release` ensures that the store to `shared_data` on Line 14 cannot be reordered after this atomic write by either the compiler or the hardware store buffer.
- **Line 21 (`data_ready.load(std::memory_order_acquire)`)**: Repeatedly checks `data_ready`. When this load observes `true`, the `acquire` fence guarantees that subsequent non-atomic reads (Line 26) cannot be reordered prior to this load.
- **Line 26 (`shared_data->value`)**: Safely reads the structure payload. Because `data_ready.store(release)` synchronizes with `data_ready.load(acquire)`, all operations prior to the release store are guaranteed visible to the thread following the acquire load.

## What the compiler and runtime can and cannot do

- **Compiler transformations**: The compiler cannot reorder a memory access across an acquire load or release store if that reordering violates C++ memory model contracts. It can freely reorder instructions around `memory_order_relaxed` operations provided single-thread execution semantics (the "as-if" rule) are preserved.
- **Hardware fences**: On weak hardware memory architectures (such as ARM or POWER), the compiler emits explicit fence instructions (`dmb`, `lwsync`) to enforce `acquire` and `release` orderings. On strongly ordered hardware (x86-64), plain load and store assembly instructions naturally enforce acquire-release semantics, so the compiler emits no extra hardware fence instructions for acquire/release, though compiler-level barrier directives are still enforced.
- **Sequential consistency overhead**: `memory_order_seq_cst` requires a full hardware memory fence (e.g., `mfence` or `lock xadd` on x86, `dmb ish` on ARM) for store operations to ensure global total ordering across all CPU cores.

## Common misconceptions

### "Volatile in C++ provides thread synchronization"
In C++, `volatile` does not provide atomicity, does not introduce hardware memory barriers, and does not prevent data races across threads. It only prevents the compiler from optimizing away loads or stores to a specific memory address within a single thread. Use `std::atomic` instead.

### "Relaxed atomics cause data races"
Operations using `std::memory_order_relaxed` are completely atomic and free of data races. However, they only guarantee atomicity for *that single variable*. They offer no ordering guarantees for neighboring non-atomic accesses.

### "Acquire and release lock all system memory"
Acquire and release semantics do not pause or block CPU access to global memory. They act strictly as execution barriers for instruction ordering within the calling thread relative to an atomic operation.

## Where this leaves you

Check your codebase for multithreaded flag-checking routines or custom lock-free primitives. Replace volatile flags and naked accesses with `std::atomic`, and use `std::memory_order_acquire` and `std::memory_order_release` to enforce cross-thread dependencies without paying the cost of full sequential consistency fences (`std::memory_order_seq_cst`).

## What To Read Next

- [/docs/parallel-computing/fundamentals/memory-models](/docs/parallel-computing/fundamentals/memory-models) — Standard memory models and memory ordering primitives.
- [/docs/parallel-computing/pthreads-mutex-and-barrier](/docs/parallel-computing/pthreads-mutex-and-barrier) — Traditional mutex locking versus atomic synchronization.

![Diagram](/img/parallel/cpp-atomics-and-memory-order.svg)

## References

- Anthony Williams, *C++ Concurrency in Action*.
- Peter Pacheco, *An Introduction to Parallel Programming*.

## Quiz

- [Quiz](/docs/mcq/questions/domain/parallel/daily/cpp-atomics-and-memory-order/)

---
title: "Cache mapping: direct, set-associative, fully associative"
description: "How memory addresses decompose into tag, index, and offset fields, driving cache conflict misses and layout optimizations in modern compilers."
keywords:
  - cache mapping
  - direct mapped cache
  - set associative cache
  - fully associative cache
  - cache tag index offset
  - cache index bit extraction
  - conflict misses
  - cache thrashing
  - average memory access time
  - AMAT formula
  - memory alignment
  - structure padding compiler
displayed_sidebar: coasidebar
slug: /coa/cache-mapping
---

import AdBanner from '@site/src/components/AdBanner';
import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

# Cache mapping: direct, set-associative, fully associative

A memory address split into bits determines exactly where a cache line can reside in hardware placement logic. A compiler engineer who understands tag, index, and offset extraction can structure data layouts and loop strides to prevent severe conflict misses.

:::tip Read these first
- [/docs/coa/memory-hierarchy](/docs/coa/memory-hierarchy) — Memory hierarchy: locality and miss cost dominate compiler output
- [/docs/coa/measuring_throughput_cache_misses_cpu_behavior_cpp](/docs/coa/measuring_throughput_cache_misses_cpu_behavior_cpp) — Measuring throughput and cache misses: perf counters beat guesses
:::

:::important What you should leave with
- How a physical or virtual memory address decomposes into Tag, Index, and Offset fields based on line size and set count.
- Why mapping multiple active variables to the same cache set causes thrashing, even when total working set size is far below total cache capacity.
- How to evaluate access latency using the Average Memory Access Time (AMAT) formula.
- What levers compilers use—such as array padding, structure reordering, loop tiling, and alignment attributes—to mitigate cache index collisions.
:::

:::caution Who this is not for
If you are looking for an overview of general cache levels (L1, L2, L3) or hit/miss latency penalties, start with [/docs/coa/memory-hierarchy](/docs/coa/memory-hierarchy) first.
:::

:::note
This lesson focuses on hardware address mapping mechanisms and hardware placement policies. It does not cover virtual-to-physical address translation (TLBs and page tables), which operate above the cache indexing layer in physically indexed caches.
:::

<div>
  <AdBanner />
</div>

## Table of Contents
1. [TL;DR](#tldr)
2. [The mechanism](#the-mechanism)
3. [The AMAT equation and compiler control](#the-amat-equation-and-compiler-control)
4. [Associativity trade-offs](#associativity-trade-offs)
5. [A worked example: power-of-two stride thrashing](#a-worked-example-power-of-two-stride-thrashing)
6. [What the compiler can and cannot do](#what-the-compiler-can-and-cannot-do)
7. [Common misconceptions](#common-misconceptions)
8. [What To Read Next](#what-to-read-next)
9. [References](#references)

---

## TL;DR
- Addresses split into **Offset** (selects byte within line), **Index** (selects set), and **Tag** (verifies identity).
- **Direct-mapped** caches force each address to exactly one slot; two addresses with identical index bits evict each other continuously (**thrashing**).
- **$N$-way set-associative** caches provide $N$ slots per set, tolerating up to $N$ concurrent hot addresses mapping to the same index before conflict misses occur.
- Compilers cannot change cache hardware parameters, but they control byte offsets, array strides, variable alignment, and loop access patterns to avoid index collisions.

---

## The mechanism

Hardware caches store memory in fixed-size blocks called **cache lines** (typically 64 bytes). When the CPU requests a byte at a specific memory address, the cache hardware splits the binary bits of that memory address into three contiguous fields:

1. **Offset (lower bits):** Identifies the exact byte byte-location within a single cache line. For a 64-byte line ($2^6$ bytes), the lowest 6 bits form the offset.
2. **Index (middle bits):** Selects which cache **set** the memory block maps to. For a cache with $S = 2^k$ sets, $k$ bits are used as the index.
3. **Tag (upper bits):** Uniquely identifies the physical block of memory stored in that slot. Hardware compares the address tag bits against the tag stored in the cache line metadata.

```
+------------------------+------------------+-----------------+
|       Tag Bits         |    Index Bits    |   Offset Bits   |
+------------------------+------------------+-----------------+
  (Higher Address Bits)    (Selects Set S)    (Selects Byte B)
```

The placement policy determines how many slots (ways) are available inside a targeted set.

| Mapping Policy | Number of Sets | Ways per Set | Hardware Search Mechanism | Primary Compiler Vulnerability |
| :--- | :--- | :--- | :--- | :--- |
| **Direct-Mapped** | $N$ (Total Lines) | 1 | Zero-search logic; direct index decode to single line. | Severe conflict misses when two hot buffers share index bits. |
| **Set-Associative** | $S = \frac\{\text\{Lines\}\}\{N\}$ | $N$ (typically 2, 4, 8, 16) | Parallel tag match across $N$ lines in selected set. | Thrashing when $> N$ hot addresses map to the exact same index. |
| **Fully Associative** | 1 | $N$ (Total Lines) | Parallel tag match across every single line in cache. | High power/area overhead; high hit latency for large capacities. |

:::tip Note
In physically indexed, physically tagged (PIPT) caches, the index bits are drawn directly from the physical memory address. In virtually indexed, physically tagged (VIPT) caches, index bits must fall within the page offset range (lower 12 bits for standard 4 KB pages) so that page translation does not alter the set index.
:::

The diagram below illustrates how an address is sliced into bits and routed to a 2-way set-associative cache memory structure.

![Address decoding and tag matching in a set-associative cache](/img/coa/THE-SLUG.svg)

*Diagram: Address bit fields route execution to a specific cache set, where parallel tag comparison gates data hit or miss outcomes.*

---

## The AMAT equation and compiler control

The performance impact of memory access is modeled using the **Average Memory Access Time (AMAT)** formula:

$$\text\{AMAT\} = \text\{Hit Time\} + (\text\{Miss Rate\} \times \text\{Miss Penalty\})$$

Where:
- **Hit Time:** The time (in CPU cycles) required to index the cache, read the tag, compare it, and return the byte.
- **Miss Rate:** The fraction of memory accesses that fail to find the requested line in cache.
- **Miss Penalty:** The additional latency incurred to fetch the missing line from lower memory levels (L2, L3, or DRAM).

### What the compiler can and cannot change

```
+-----------------------------------------------------------------+
| CPU Time = Instruction Count  *  CPI  *  Cycle Time             |
+-----------------------------------------------------------------+
                           ^
                           | (Compiler heavily influences via AMAT)
                           v
+-----------------------------------------------------------------+
| AMAT = Hit Time + (Miss Rate * Miss Penalty)                    |
+-----------------------------------------------------------------+
```

- **Cycle Time:** Fixed by processor clock frequency. The compiler has zero control over this.
- **Hit Time:** Dictated by hardware cache design and silicon routing latency. The compiler cannot alter hardware hit cycles.
- **Miss Penalty:** Dictated by memory controller width, bus clock rates, and DRAM access timings. The compiler cannot change DRAM latency directly (though it can initiate hardware prefetching to hide miss penalty).
- **Miss Rate:** **Strongly influenced by the compiler.** The compiler controls variable positioning in memory, array strides, loop order, structure layout, and memory alignment. Minimizing conflict, capacity, and compulsory misses directly reduces the miss rate.

:::warning
Reducing instruction count by unrolling loops can inadvertently increase compulsory and conflict misses if the code size expands beyond the instruction cache (I-Cache) capacity or set limits.
:::

---

## Associativity trade-offs

Hardware designers choose associativity based on target clock frequency, silicon area, and power budgets. The compiler must adapt to these choices.

<Tabs>
<TabItem value="direct" label="Direct-Mapped" default>

### Direct-Mapped Cache
- **Structure:** Exactly 1 way per set.
- **Lookup:** Extremely fast. Zero search logic; the index points directly to one data block and tag memory location.
- **Hardware Cost:** Lowest power, minimal logic gates.
- **Compiler Challenge:** High risk of **conflict misses**. If two frequently accessed pointers `A` and `B` have addresses such that `(AddrA >> OffsetBits) % Sets == (AddrB >> OffsetBits) % Sets`, accessing them in an alternating loop `A[i]; B[i];` causes 100% miss rates regardless of total cache size.

</TabItem>
<TabItem value="setassoc" label="Set-Associative">

### $N$-Way Set-Associative Cache
- **Structure:** Cache is divided into sets, each containing $N$ independent lines (ways).
- **Lookup:** Index selects the set; hardware simultaneously compares the Tag against all $N$ tags inside that set using $N$ parallel comparators.
- **Hardware Cost:** Moderate area and power overhead due to multiplexing and parallel tag checks.
- **Compiler Impact:** Permits up to $N$ active, colliding memory streams to reside in the exact same set without evicting each other. If $N+1$ streams collide on the same set index, conflict thrashing occurs (subject to the replacement policy, e.g., LRU).

</TabItem>
<TabItem value="fullyassoc" label="Fully Associative">

### Fully Associative Cache
- **Structure:** Only 1 set containing all cache lines.
- **Lookup:** Address has no Index bits. The Tag is compared in parallel against every single entry in the cache.
- **Hardware Cost:** Extremely high power and gate count. Unscalable for large structures.
- **Compiler Impact:** Eliminates conflict misses entirely. Only compulsory and capacity misses remain. Primarily used for small structures like Translation Lookaside Buffers (TLBs) or small victim caches.

</TabItem>
</Tabs>

---

## A worked example: power-of-two stride thrashing

Consider a microarchitecture with a **4 KB direct-mapped L1 Data Cache** using **64-byte lines**.

- Total Cache Capacity = 4096 bytes.
- Line Size = 64 bytes ($2^6 \rightarrow 6$ **Offset bits**).
- Number of Sets = $\frac\{4096\}\{64\} = 64$ sets ($2^6 \rightarrow 6$ **Index bits**).
- Bit breakdown for a 32-bit address:
  - `[31:12]` = Tag (20 bits)
  - `[11:6]` = Index (6 bits)
  - `[5:0]` = Offset (6 bits)

Notice that any address that is a multiple of $4096$ bytes ($0 \text\{x\}1000$) will have identical Index bits `[11:6]`.

### The Bad C Code (Power-of-Two Array Strides)

```c
#define SIZE 1024 // 1024 floats = 4096 bytes

float A[SIZE];
float B[SIZE];

// Accumulate matching elements
float sum = 0.0f;
for (int i = 0; i = i + 1; i < SIZE) {
    // Array A and Array B allocated back-to-back in memory
    // Address of B[0] is exactly Address of A[0] + 4096 bytes!
    sum += A[i] + B[i];
}
```

### Walkthrough of Address Bits and Cache Index Hits

Assume compiler static allocation places:
- `Base Address of A` = `0x00010000`
- `Base Address of B` = `0x00011000` (`Base A + 4096`)

Let's dissect iteration `i = 0`:

1. **Access `A[0]` at address `0x00010000`**:
   - Binary: `0000 0000 0000 0001 0000 0000 0000 0000`
   - Tag: `0x00010`
   - Index: `0b000000` (Set 0)
   - Offset: `0b000000`
   - **Outcome:** Miss! Load line `0x00010000` into Set 0.

2. **Access `B[0]` at address `0x00011000`**:
   - Binary: `0000 0000 0000 0001 0001 0000 0000 0000`
   - Tag: `0x00011`
   - Index: `0b000000` (Set 0!)
   - Offset: `0b000000`
   - **Outcome:** Conflict Miss! Hardware evicts `A`'s line from Set 0 and loads `B`'s line into Set 0.

3. **Iteration `i = 1` accessing `A[1]` at `0x00010004`**:
   - Index remains `0b000000` (Set 0).
   - Tag matches `A` (`0x00010`), but Set 0 currently contains `B`'s tag (`0x00011`).
   - **Outcome:** Conflict Miss! Evicts `B`, loads `A`.

Every single memory access results in a **conflict miss**, even though the combined working set size ($4096 + 4096 = 8192$ bytes) would easily fit into a slightly larger cache, and individual arrays fit within cache capacity.

### The Compiler Solution: Array Padding

The optimizing compiler inserts unused bytes (padding) between `A` and `B` or alters array pitch.

```c
// Compiler injects 64-byte offset padding between allocations
struct PaddedBuffers {
    float A[1024];
    char  pad[64]; // Shift B's base address by 1 cache line
    float B[1024];
};
```

- `Base Address of A` = `0x00010000` (Index = Set 0)
- `Base Address of B` = `0x00011040` (Index = Set 1)

Now `A[i]` maps to Set 0 while `B[i]` maps to Set 1. Both cache lines remain resident simultaneously for 16 iterations ($64 \text\{ bytes\} / 4 \text\{ bytes per float\} = 16 \text\{ hits per line miss\}$).

---

## What the compiler can and cannot do

A compiler cannot alter cache hardware topology, set counts, line sizes, or replacement policies. However, it controls data location and access order.

```
+-----------------------------------------------------------------------+
| COMPILER HARD LEVERS                                                  |
+-----------------------------------------------------------------------+
| 1. Array Padding: Injects dummy elements to shift set indices.        |
| 2. Structure Realignment: Forces variables to line boundaries.       |
| 3. Loop Tiling (Blocking): Constrains loops to subset of set indices.|
| 4. Field Reordering: Packs hot struct fields into single cache lines. |
+-----------------------------------------------------------------------+
                                  |
                                  v
+-----------------------------------------------------------------------+
| HARDWARE BOUNDARIES (OUTSIDE COMPILER CONTROL)                         |
+-----------------------------------------------------------------------+
| 1. Number of physical cache sets (S).                                 |
| 2. Cache line sizes (L).                                              |
| 3. Way associativity count (N).                                       |
| 4. Hardware Replacement Policies (LRU, Pseudo-LRU, Random).           |
+-----------------------------------------------------------------------+
```

### Compiler Optimization Techniques

1. **Global/Stack Variable Alignment:**
   Using alignment specifiers (e.g., `alignas(64)`) guarantees that base pointers start at offset bit `0`. This prevents a single data structure from spanning extra cache line boundaries unnecessarily.

2. **Structure Field Reordering:**
   If a `struct` contains hot members accessed together in critical loops, the compiler groups them sequentially.
   ```c
   // Bad layout: Hot fields separated by cold data across cache line boundary
   struct NodeBad \{
       uint64_t hot1;
       char cold_buffer[56];
       uint64_t hot2; // Forced into next cache line!
   \};

   // Good layout: Hot fields packed inside first offset range
   struct NodeGood \{
       uint64_t hot1;
       uint64_t hot2;
       char cold_buffer[48];
   \};
   ```

3. **Loop Tiling / Blocking:**
   For multi-dimensional matrix operations, loops are broken down into small blocks (tiles) sized to ensure that all data accessed within the inner loop fits entirely inside available cache sets without causing replacement evictions.

---

## Common misconceptions

### Misconception 1: "A program whose total dataset size is smaller than the cache capacity cannot suffer from cache misses."
**Reality:** Capacity is only one constraint. Direct-mapped and set-associative caches can suffer catastrophic **conflict misses** if memory addresses collide on identical set indices, evicting active data repeatedly while other cache sets remain completely empty.

### Misconception 2: "Fully associative caches are always superior and should replace set-associative caches everywhere."
**Reality:** Fully associative caches require comparing incoming address tags against every single tag line in parallel. As capacity grows, the delay of large multiplexers and the dynamic energy consumption of broad tag comparison render fully associative designs unusable for large L1/L2 data caches.

### Misconception 3: "Adding structure padding always wastes memory and hurts performance."
**Reality:** Unpadded structures can cause variables to straddle cache lines or map to identical set indices as other active structures. Injecting calculated padding bytes increases memory footprint slightly but yields dramatic latency reductions by eliminating split-line accesses and index set conflict thrashing.

---

## What To Read Next

Explore how these cache concepts interact with execution models and pipeline architectures:

- [/docs/coa/memory-hierarchy](/docs/coa/memory-hierarchy) — Locality principles, latency numbers, and cache hierarchy structures.
- [/docs/coa/measuring_throughput_cache_misses_cpu_behavior_cpp](/docs/coa/measuring_throughput_cache_misses_cpu_behavior_cpp) — Measuring performance and cache miss events using hardware performance counters.
- [/docs/coa/instruction_flow_modern_cpu](/docs/coa/instruction_flow_modern_cpu) — How memory load/store queues schedule cache accesses out-of-order.

<div>
  <AdBanner />
</div>

## References

- Hennessy, J. L., & Patterson, D. A. *Computer Architecture: A Quantitative Approach*. 6th Edition, Morgan Kaufmann. (Chapter 2: Memory Hierarchy Design).
- Stallings, W. *Computer Organization and Architecture: Designing for Performance*. Pearson. (Memory Organization chapters).

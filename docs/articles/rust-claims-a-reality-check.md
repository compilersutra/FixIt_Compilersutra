---
title: "Rust Claims, a Reality Check: Safety, Tools, and Systems Programming"
description: "What rustc actually proves, how that reaches LLVM, and where the proof stops. Compiled on rustc 1.93.1 vs gcc 13.3 and clang 18."
keywords:
  - Rust memory safety
  - Rust safety guarantees
  - Rust borrow checker
  - Rust ownership
  - Rust compiler
  - rustc
  - Rust compiler bugs
  - Rust soundness
  - Rust unsoundness
  - Rust unsafe code
  - Rust unsafe
  - Rust FFI
  - Rust memory bugs
  - Rust use after free
  - Rust buffer overflow
  - Rust data races
  - Rust lifetime
  - Rust lifetimes
  - Rust ownership system
  - Rust borrowing
  - Rust type system
  - Rust compiler soundness
  - rustc soundness
  - rustc bug
  - Rust compiler bug
  - Rust security
  - Rust systems programming
  - Rust systems programming language
  - Rust compile time safety
  - Rust compile time checks
  - Rust runtime safety
  - Rust memory-safe language
  - Rust safety limitations
  - Rust unsafe FFI
  - Rust lending iterator
  - Rust iterator safety
  - Rust compiler verification
  - Rust static analysis
  - Rust safety tools
  - Rust sanitizers
  - Rust Miri
  - Rust Clippy
  - Rust fuzzing
  - Rust compiler fuzzing
  - Rust bug discovery
  - Rust soundness bugs
  - ISSTA 2026
  - Rust ISSTA 2026
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';
import Head from '@docusaurus/Head';

<Head>
  <meta name="description" content="Plain English: what 'Rust is memory safe' really means, what it does not cover, and a rustc bug with no unsafe keyword." />
</Head>

# Rust Claims, a Reality Check: What rustc Proves, and Where the Proof Stops

:::note
Related: [Rust vs Modern C++](/docs/articles/rust-vs-modern-cpp-memory-safety-beyond-the-hype) · [How rustc compiles vs C++](/docs/articles/rustc-pipeline-vs-cpp-compilation-pipeline)
:::

People say **Rust is memory safe**. I wanted the compiler version of that sentence, not the slide. So I compiled the same bugs with rustc 1.93.1, gcc/g++ 13.3, and clang 18, then asked where the proof stops: language, rustc, LLVM, or the OS.

C++ already has `unique_ptr`, `span`, `v.at(i)`, sanitizers. The interesting difference is **what happens when the programmer forgets to use them.** Rust’s normal `v[i]` is checked. C++’s normal `v[i]` is not.

The claim is real. It is also smaller than “Rust is memory safe.”

```text
                    RUST SAFETY
                         |
        +----------------+----------------+
        |                |                |
   LANGUAGE          TOOLCHAIN        REAL WORLD
 ownership            rustc              FFI
 borrowing            LLVM               TOCTOU
 bounds               optimizer          logic / .ok()
 data races                              OS APIs
```

**Results of the programs I compiled** (default flags unless noted: `-Wall -Wextra`, no sanitizer):

| Bug | C/C++ default | C/C++ + ASan/UBSan | Safe Rust |
|---|---|---|---|
| Use-after-free | Compiles (gcc may warn; clang often silent) | Runtime abort | Rejected (`E0515` / `E0382`) |
| Constant OOB (`a[10]` on size 4) | Compiles (clang warns, still links) | Runtime report | Rejected (compile error) |
| Runtime OOB (`a[i]`) | UB; my run smashed a neighbor `flag` | Often a message; default UBSan still continues | Panic, exit 101 |
| Data race (`n += 1` from two threads) | Compiles | Tool-dependent | Rejected (`E0499`) |
| TOCTOU (check path, swap, open) | Compiles; reads the swapped file | ASan silent | Compiles; same wrong file |
| Bad FFI length / `unsafe` lie | Possible | Not solved | Possible (Level 2–3) |
| Logic / ignored `Result` | Possible | Not solved | Possible |

Evidence is below. Three different index stories, say them once:

1. **Constant index rustc can see** → compile-time rejection. No binary.
2. **Runtime index** → rustc emits a bounds check → **panic** (defined). Not C undefined behavior.
3. **`unsafe { *v.get_unchecked(i) }`** → you hold the proof. Broken invariant is UB.

## Table of Contents

- [The short answer](#the-short-answer)
- [Three levels of Rust safety](#three-levels-of-rust-safety)
- [What the borrow checker actually proves](#what-the-borrow-checker-actually-proves)
- [The same bug in C, C++, and Rust](#the-same-bug-in-c-c-and-rust)
- [Data races](#data-races)
- [What I compiled](#what-i-compiled)
- [C++23 and sanitizers](#c23-and-sanitizers)
- [`unsafe` is a proof boundary](#unsafe-is-a-proof-boundary)
- [From borrow checking to LLVM](#from-borrow-checking-to-llvm)
- [A 2026 research paper](#a-2026-research-paper)
- [Bug #25860, which I compiled](#bug-25860-which-i-compiled)
- [What you pay for the checks](#what-you-pay-for-the-checks)
- [The claim I would actually make](#the-claim-i-would-actually-make)
- [Limits](#limits)
- [References](#references)

## The short answer

The table above is the claim. These three programs are the evidence. Toolchains: rustc 1.93.1, gcc/g++ 13.3, clang/clang++ 18.1.3. Full logs: [What I compiled](#what-i-compiled).

**Example 1.** This function makes a `String` on the stack, then tries to hand a pointer to it back to the caller:

```rust
fn dangling() -> &'static str {
    let s = String::from("secret");
    &s
}
```

What it is doing: `s` lives only while `dangling` is running. When the function returns, `s` is destroyed. `&s` is a pointer into that dead memory. If rustc allowed this, the caller would read bytes that no longer belong to the program.

What rustc did (default, no extra flag):

```text
error[E0515]: cannot return reference to local variable `s`
 --> uaf.rs:3:5
  |
3 |     &s
  |     ^^ returns a reference to data owned by the current function
```

No binary. That reject is the good outcome.

In C you can `free(p)` then `printf("%s", p)`: gcc warns `-Wuse-after-free` and still links. **clang 18.1.3** with `-Wall -Wextra` said **nothing** and still linked. In C++ you can keep a `string_view` after `delete`: g++ 13.3 and clang++ 18 both said nothing and still linked. Those programs can crash, print garbage, or read data an attacker put in the reused heap.

Same C, with a sanitizer:

```text
$ gcc -O0 -Wall -Wextra -fsanitize=address uaf.c -o uaf_c_asan
$ ./uaf_c_asan
ERROR: AddressSanitizer: heap-use-after-free
SUMMARY: AddressSanitizer: heap-use-after-free ... in printf_common
# abort, exit 1

$ clang -O0 -Wall -Wextra -fsanitize=address uaf.c -o uaf_clang_asan
$ ./uaf_clang_asan
ERROR: AddressSanitizer: heap-use-after-free
SUMMARY: AddressSanitizer: heap-use-after-free ... in printf_common
```

C++ `string_view` after `delete`, ASan: `heap-use-after-free` in `fwrite`, abort. So yes: **a sanitizer can report the same class of bug Rust refused.** You had to rebuild with `-fsanitize=address` and actually run `main`. rustc never let a binary out.

**Example 2.** This program makes an array of four zeros, then writes index 10:

```rust
fn main() {
    let mut a = [0; 4];
    a[10] = 42;
}
```

What it is doing: valid indexes are 0, 1, 2, 3. Index 10 is six slots past the end. In C and C++ that write is undefined behavior: smash the stack, overwrite a return address, or look fine until it does not. gcc and g++ 13.3 with `-Wall -Wextra` built it with **no diagnostic**. clang and clang++ 18 warned `-Warray-bounds` and **still linked**.

What rustc did (default):

```text
error: this operation will panic at runtime
 --> oob.rs:3:5
  |
3 |     a[10] = 42;
  |     ^^^^^ index out of bounds: the length is 4 but the index is 10
  |
  = note: `#[deny(unconditional_panic)]` on by default
```

No binary.

Same C with UBSan (ASan alone did not print a clean stack-overflow report on this tiny `int a[4]` in my run; UBSan did):

```text
$ gcc -O0 -Wall -Wextra -fsanitize=undefined oob.c -o oob_ubsan
$ ./oob_ubsan
oob.c:3:6: runtime error: index 10 out of bounds for type 'int [4]'

$ clang -O0 -Wall -Wextra -fsanitize=undefined oob.c -o oob_clang_ubsan
# also -Warray-bounds at compile time, then:
oob.c:3:5: runtime error: index 10 out of bounds for type 'int[4]'
```

Again: the sanitizer can name the same bug. Default gcc still shipped a binary. Default rustc did not.

**Example 3.** Constant `a[10]` is the easy case. rustc can see the number. Now `i` comes from the command line, so the compiler cannot reject it up front.

```rust
fn main() {
    let mut a = [0i32; 4];
    let i: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);
    a[i] = 42;
    println!("still running, a[0]={}", a[0]);
}
```

What it is doing: same four-slot array. The index is not in the source as `10`. rustc **accepts** this. You get a binary. The language still gives you a check: at run time.

```text
$ rustc slice_i.rs -o slice_i_rs    # exit 0
$ ./slice_i_rs 4
thread 'main' panicked at slice_i.rs:7:5:
index out of bounds: the len is 4 but the index is 4
# exit 101: never prints "still running"
```

Same with `rustc -O`. Bounds checks stay in. Valid index `0` prints `still running, a[0]=42`.

The C side, same idea: `i` from argv, array of 4, a neighbor `flag` sitting right after it:

```c
struct Box {
    int a[4];
    int flag;
};
int i = atoi(argv[1]);   /* we passed 4 */
b.a[i] = 42;
printf("still running  a[0]=%d  flag=%d\n", b.a[0], b.flag);
```

```text
$ gcc -O0 -Wall -Wextra slice_i.c -o slice_i_c    # exit 0, no warning
$ ./slice_i_c 4
still running  a[0]=0  flag=42
# exit 0

$ clang -O0 -Wall -Wextra slice_i.c -o slice_i_clang
$ ./slice_i_clang 4
still running  a[0]=0  flag=42
# exit 0: same smash
```

`flag` started as `7`. After `a[4] = 42` it is `42`. The program kept going. That is the unsafe failure.

Now the sanitizer: this is the honest part. ASan + UBSan, **defaults**:

```text
$ gcc -O0 -Wall -Wextra -fsanitize=address,undefined slice_i.c -o slice_i_san
$ ./slice_i_san 4
slice_i.c:12:8: runtime error: index 4 out of bounds for type 'int [4]'
still running  a[0]=0  flag=42
# exit 0

$ clang -O0 -Wall -Wextra -fsanitize=address,undefined slice_i.c -o slice_i_clang_san
$ ./slice_i_clang_san 4
slice_i.c:12:5: runtime error: index 4 out of bounds for type 'int[4]'
SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior ...
still running  a[0]=0  flag=42
# exit 0
```

UBSan **printed** the same “index out of bounds” story Rust panics with. Then the program **kept running** and `flag` was still smashed. Default UBSan recovers. ASan did not stop this one: `a[4]` is the next field in the same `struct`, an intra-object overflow sanitizers often miss.

If I add `-fno-sanitize-recover=undefined`, UBSan aborts and does not print `still running`. That flag is extra. Rust’s panic on `a[i]` needed no extra flag.

Sanitizers can name the same bugs. They are a flag you pass and a path you must run. Safe Rust’s reject/panic is the default. C does not mark `a[i] = 42` as `unsafe`. rustc bugs and FFI still sit outside that default; those sections come later.

## Three levels of Rust safety

The slide says “Rust.” That is several products glued together.

**Level 1: safe Rust.** No `unsafe` in *your* function. rustc checks ownership, lifetimes, aliases, and (for `a[i]`) whether the index fits.

**Level 2: `unsafe`.** You told rustc to trust you. Callers still see a safe type. The proof is a human.

**Level 3: FFI + the toolchain.** C libraries, ABI, file descriptors, `mmap`, rustc itself, LLVM. Language rules stop at `extern "C"`. They also stop if rustc is wrong.

### Where the language guarantee ends

This is the compiler article’s spine. **Memory-safety as a language model** is not the same as **an implementation bug in rustc.**

1. **Safe Rust** — ownership, borrows, bounds, data-race rules (if rustc is sound).
2. **`unsafe`** — you assume the invariant.
3. **FFI** — rustc trusts C lengths, pointers, and ABI.
4. **Library implementation** — `std` and crates contain `unsafe`; `Cargo.lock` is in the TCB.
5. **rustc** — a soundness bug accepts code the language forbids. That is not “Rust lied”; the *implementation* did.
6. **LLVM** — optimizes IR it was given (`noalias` on a lie is still “correct” LLVM).
7. **OS / hardware** — TOCTOU, `mmap`, permissions, cosmic rays.

The rest of the article fills that list with programs.

## What the borrow checker actually proves

People say the borrow checker “prevents memory bugs.” True, and incomplete. It does **not** watch machine code. It checks ownership, lifetimes, and aliases **before** LLVM.

```rust
fn use_string() {
    let s = String::from("hello");
    let r = &s;
    println!("{}", r);
}
```

`s` owns the heap `String`. `r` only borrows. rustc’s rule is: **owner lives at least as long as the borrow.**

Move the owner first:

```rust
fn example() {
    let s = String::from("hello");
    let r = &s;
    drop(s);
    println!("{}", r);
}
```

```text
s owns memory
   |
   +---- r borrows it
          |
          +---- s is destroyed
                    |
                    X  r is still alive
```

I compiled that shape as [Example 1](#the-short-answer) (`&s` returned from the function). rustc: `E0515`. No binary.

ASan asks: “did this **run** access dead memory?” The borrow checker asks: “can this program even **name** that relationship?” Sanitizer: observe an execution. Borrow checker: reject the program.

Safe `v[100]` on a length-3 `Vec` is **not** C undefined behavior. rustc emits a bounds check; miss → **panic** (defined stop). C `v[100]` on `int v[3]` is UB: the optimizer may assume it never happens. `unsafe` is the second Rust path: broken contract → UB.

## The same bug in C, C++, and Rust

One hole, three spellings. Allocate an `int`, free it, write through the old pointer.

<Tabs groupId="same-uaf">
  <TabItem value="c" label="C: still a binary">

```c
int *p = malloc(sizeof(int));
free(p);
*p = 42;   /* gcc: -Wuse-after-free, then links */
```

  </TabItem>
  <TabItem value="cxx" label="C++: still a binary">

```cpp
int *p = new int;
delete p;
*p = 42;   /* g++ / clang++: still a program */
```

  </TabItem>
  <TabItem value="rs" label="Rust: E0382">

```rust
fn main() {
    let mut p = Box::new(10);
    drop(p);
    *p = 42;
}
```

```text
$ rustc drop.rs
error[E0382]: use of moved value: `p`
 --> drop.rs:4:5
  |
2 |     let mut p = Box::new(10);
  |         ----- move occurs because `p` has type `Box<i32>`
3 |     drop(p);
  |          - value moved here
4 |     *p = 42;
  |     ^^^^^^^ value used here after move
```

  </TabItem>
</Tabs>

**Why rustc rejects this**, not “because Rust is safer” as a slogan. `Box` **owns** the heap `i32`. `drop(p)` **moves** that owner into `drop`. After the move, `p` is gone. There is no pointer left to write. C `free(p)` only marks the heap free; the **variable** `p` is still a number you can store through. That is the language rule, not a smarter programmer.

The longer `String` / `string_view` demos in [What I compiled](#what-i-compiled) are the same rule with more bytes.

## Data races

Memory safety is also threads. I compiled this:

```rust
fn main() {
    let mut n = 0i32;
    std::thread::scope(|s| {
        s.spawn(|| { n += 1; });
        s.spawn(|| { n += 1; });
    });
}
```

```text
error[E0499]: cannot borrow `n` as mutable more than once at a time
```

No binary. Two closures both want `&mut n`. rustc refuses.

The C++ cousin `int counter = 0; void worker() { counter++; }` compiled with g++ and clang++ 18, `-Wall -Wextra`, exit 0. Two threads on that `worker` is a data race. `counter++` is not one machine step: load, add, store. Both threads can store the same old value.

Safe Rust wants `Arc<Mutex<i32>>` or an `AtomicUsize`. Deadlock, starvation, and **file** races are still possible. The type system only blocks **unsynchronized conflicting memory access** in safe code.

## What I compiled

Same computer. **rustc 1.93.1** (`01f6ddf75`, 2026-02-11). **gcc/g++ 13.3.0**. **clang/clang++ 18.1.3**. Flags: `-Wall -Wextra` for C and C++. No AddressSanitizer unless I say so. Commands:

```bash
gcc    -Wall -Wextra uaf.c  -o uaf_c       # exit 0, warns -Wuse-after-free
clang  -Wall -Wextra uaf.c  -o uaf_clang   # exit 0, no warning
g++    -std=c++20 -Wall -Wextra uaf.cpp -o uaf_cpp      # exit 0, silent
clang++ -std=c++20 -Wall -Wextra uaf.cpp -o uaf_clangpp # exit 0, silent
rustc uaf.rs -o uaf_rs                     # error, no binary

gcc    -Wall -Wextra oob.c  -o oob_c       # exit 0, no diagnostic
clang  -Wall -Wextra oob.c  -o oob_clang   # exit 0, -Warray-bounds, still a binary
rustc oob.rs -o oob_rs                     # error, no binary

clang -O0 -Wall -Wextra slice_i.c -o slice_i_clang
./slice_i_clang 4                          # still running, flag smashed
```

### 1. Use memory after free

<Tabs groupId="exp-uaf">
  <TabItem value="c" label="C: still builds">

```c
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    char *p = malloc(32);
    if (!p) return 1;
    free(p);
    printf("%s", p);
    return 0;
}
```

```text
$ gcc -Wall -Wextra uaf.c -o uaf_c
uaf.c: In function ‘main’:
uaf.c:7:5: warning: pointer ‘p’ used after ‘free’ [-Wuse-after-free]
    7 |     printf("%s", p);
      |     ^~~~~~~~~~~~~~~
uaf.c:6:5: note: call to ‘free’ here
    6 |     free(p);
      |     ^~~~~~~
# exit code 0: you still get a binary
```

```text
$ clang -Wall -Wextra uaf.c -o uaf_clang
# no diagnostic
# exit code 0
```

**Why that is bad.** `free` gave the heap block back. `printf` still reads it. The bytes may be garbage, may crash, or may be data an attacker put there after reuse. gcc saw the bug and **still linked**. clang 18 with `-Wall -Wextra` did not even warn. A warning is not a stop.

  </TabItem>
  <TabItem value="cxx" label="C++: no warning">

```cpp
#include <iostream>
#include <string>
int main() {
    auto* s = new std::string("secret");
    std::string_view v = *s;
    delete s;
    std::cout << v << "\n";
}
```

```text
$ g++ -std=c++20 -Wall -Wextra uaf.cpp -o uaf_cpp
$ clang++ -std=c++20 -Wall -Wextra uaf.cpp -o uaf_clangpp
# both: no output, exit 0, binary produced
```

**Why that is bad.** `string_view` is only a pointer plus length. After `delete s`, those bytes are dead. Printing `v` is use-after-free. g++ 13.3 and clang++ 18 did not even warn. You can ship this.

  </TabItem>
  <TabItem value="rs" label="Rust: no binary">

```rust
fn dangling() -> &'static str {
    let s = String::from("secret");
    &s
}
fn main() { println!("{}", dangling()); }
```

```text
$ rustc uaf.rs -o uaf_rs
error[E0515]: cannot return reference to local variable `s`
 --> uaf.rs:3:5
  |
3 |     &s
  |     ^^ returns a reference to data owned by the current function

error: aborting due to 1 previous error
```

**What rustc did.** `s` dies at the end of `dangling`. The `&s` would point at dead memory. rustc refused. **No object file, no binary.**

**Why that reject is good.** You cannot run this program. You cannot put it in a release. The same class of bug that gcc warned-and-linked, clang silently linked, and g++/clang++ silently linked, never leaves rustc. That is the memory-safety claim in one command.

  </TabItem>
</Tabs>

What surprised me was C++, not Rust. g++ and clang++ made a binary and said nothing. gcc at least warned, then still linked. clang 18 did not warn on the `free` then `printf` case. Tools like AddressSanitizer can catch the C/C++ bugs **if you turn them on**. I did not turn them on for the default builds. The slogan is about the normal build, not the special test build.

### 2. Write past the array

<Tabs groupId="exp-oob">
  <TabItem value="c" label="C: still builds">

```c
int main(void) {
    int a[4] = {0};
    a[10] = 42;
    return a[10];
}
```

```text
$ gcc -Wall -Wextra oob.c -o oob_c
# no diagnostic
# exit code 0

$ clang -Wall -Wextra oob.c -o oob_clang
oob.c:3:5: warning: array index 10 is past the end of the array (that has type 'int[4]') [-Warray-bounds]
    3 |     a[10] = 42;
      |     ^ ~~
# exit code 0: you still get a binary
```

**Why that is bad.** The array has four `int`s. Index 10 is six slots past the end. In C that is undefined behavior: smash the stack, overwrite a return address, or “work” until it does not. gcc 13.3 with `-Wall -Wextra` still built it with no warning. clang 18 warned, then **still linked**. rustc refused.

  </TabItem>
  <TabItem value="cxx" label="C++: still builds">

```cpp
int main() {
    int a[4] = {0};
    a[10] = 42;
    return a[10];
}
```

```text
$ g++ -std=c++20 -Wall -Wextra oob.cpp -o oob_cpp
# no diagnostic, exit 0

$ clang++ -std=c++20 -Wall -Wextra oob.cpp -o oob_clangpp
# -Warray-bounds, exit 0, binary produced
```

**Why that is bad.** Same write. Same undefined behavior. gcc silent. clang warns. Both ship a binary.

  </TabItem>
  <TabItem value="rs" label="Rust: no binary">

```rust
fn main() {
    let mut a = [0; 4];
    a[10] = 42;
}
```

```text
$ rustc oob.rs -o oob_rs
warning: value assigned to `a` is never read
 --> oob.rs:3:5
  |
3 |     a[10] = 42;
  |     ^^^^^^^^^^

error: this operation will panic at runtime
 --> oob.rs:3:5
  |
3 |     a[10] = 42;
  |     ^^^^^ index out of bounds: the length is 4 but the index is 10
  |
  = note: `#[deny(unconditional_panic)]` on by default

error: aborting due to 1 previous error; 1 warning emitted
```

**What rustc did.** It saw length 4 and index 10 in the source. That write would always panic. The default `deny(unconditional_panic)` turns that into a **hard error**. Again: no binary.

**Why that reject is good.** You never get a program that writes off the end of the array. In C that write can corrupt memory and keep running. rustc stops the constant case at compile time.

  </TabItem>
</Tabs>

### 3. Variable index (`slice[i]`)

rustc cannot reject this at compile time: `i` comes from `argv`. Full programs:

<Tabs groupId="exp-slice-i">
  <TabItem value="c" label="C: builds, keeps running">

```c
#include <stdio.h>
#include <stdlib.h>
struct Box {
    int a[4];
    int flag;
};
int main(int argc, char **argv) {
    struct Box b;
    b.a[0] = b.a[1] = b.a[2] = b.a[3] = 0;
    b.flag = 7;
    int i = argc > 1 ? atoi(argv[1]) : 4;
    b.a[i] = 42;
    printf("still running  a[0]=%d  flag=%d\n", b.a[0], b.flag);
    return 0;
}
```

```text
$ gcc -O0 -Wall -Wextra slice_i.c -o slice_i_c
# no diagnostic, exit 0
$ ./slice_i_c 4
still running  a[0]=0  flag=42
# exit 0
```

**Why that is bad.** Valid indexes of `a` are 0..3. Index 4 is the next `int`, which is `flag`. gcc wrote 42 into `flag` and continued. A bigger `i` (I tried 10) hit a segfault (exit 139). Either way: undefined behavior. The “lucky” case is the scary one: the program looks alive while it has already corrupted memory.

  </TabItem>
  <TabItem value="rs" label="Rust: builds, then panics">

```rust
fn main() {
    let mut a = [0i32; 4];
    let i: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);
    a[i] = 42;
    println!("still running, a[0]={}", a[0]);
}
```

```text
$ rustc slice_i.rs -o slice_i_rs
# exit 0: unlike a[10] in the source, this is allowed
$ ./slice_i_rs 4
thread 'main' panicked at slice_i.rs:7:5:
index out of bounds: the len is 4 but the index is 4
# exit 101
```

`rustc -O` panicked the same way. `./slice_i_rs 0` prints `still running, a[0]=42`.

**What rustc did.** It could not prove `i` was in range, so it compiled a bounds check. At run time the check failed. The process stopped. It never printed `still running`.

**Why that panic is good.** Some people call it a crash. It is the *safe* failure: no write past the array, no smashed `flag`. I would rather have a panic than silent corruption.

  </TabItem>
</Tabs>

### 4. File race (TOCTOU)

You check a file path. Then someone swaps the file. Then you open the path. The compiler does not see that. That bug has a name: [TOCTOU](https://en.wikipedia.org/wiki/Time-of-check_to_time-of-use) (time-of-check to time-of-use). Rust [`std::fs`](https://doc.rust-lang.org/std/fs/) takes paths, like many C programs. Two syscalls on the same path string are two lookups. The file can change in between.

Let’s look at a small program I compiled. It is the same shape as the CVEs, squeezed into one process so the window is visible. **Check** the path. **Swap** the file behind that name. **Use** the same path. rustc and gcc both accept it. ASan does not save you: this is not a memory smash.

**What it is doing.** Write `target` with `hello`. Write `other` with `secret`. Call `metadata` / `stat` on `target` (the check). Replace `target` with `other`. Open `target` and read (the use). The check saw `hello`. The read got `secret`.

<Tabs groupId="exp-toctou">
  <TabItem value="rs" label="Rust: builds, reads secret">

```rust
use std::fs::{self, File};
use std::io::Read;

fn main() {
    let dir = std::env::temp_dir().join("cs_toctou_rs");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("target");
    let other = dir.join("other");
    fs::write(&path, b"hello\n").unwrap();
    fs::write(&other, b"secret\n").unwrap();

    let meta = fs::metadata(&path).unwrap();
    println!("check: is_file={} size={}", meta.is_file(), meta.len());

    fs::remove_file(&path).unwrap();
    fs::rename(&other, &path).unwrap();

    let mut s = String::new();
    File::open(&path).unwrap().read_to_string(&mut s).unwrap();
    println!("use: read {:?}", s.trim());
}
```

```text
$ rustc toctou.rs -o toctou_rs
# exit 0: no error. The borrow checker does not see files.
$ ./toctou_rs
check: is_file=true size=6
use: read "secret"
# exit 0
```

**Why rustc is silent.** `path` is a string. Both calls are legal. Nothing was freed. No index was out of range. The bug is two lookups of one name.

  </TabItem>
  <TabItem value="c" label="C: same bug, same output">

```c
struct stat st;
stat(path, &st);                 /* check */
printf("check: is_reg=%d size=%ld\n", S_ISREG(st.st_mode), (long)st.st_size);

unlink(path);
rename(other, path);             /* swap */

f = fopen(path, "r");            /* use */
fgets(buf, sizeof buf, f);
printf("use: read \"%s\"\n", buf);
```

```text
$ gcc -Wall -Wextra toctou.c -o toctou_c
# exit 0
$ ./toctou_c
check: is_reg=1 size=6
use: read "secret"
# exit 0

$ gcc -O0 -Wall -Wextra -fsanitize=address toctou.c -o toctou_c_asan
$ ASAN_OPTIONS=detect_leaks=0 ./toctou_c_asan
check: is_reg=1 size=6
use: read "secret"
# exit 0: ASan has nothing to say

$ clang -Wall -Wextra toctou.c -o toctou_clang
$ ./toctou_clang
check: is_reg=1 size=6
use: read "secret"
$ clang -O0 -Wall -Wextra -fsanitize=address toctou.c -o toctou_clang_asan
$ ASAN_OPTIONS=detect_leaks=0 ./toctou_clang_asan
check: is_reg=1 size=6
use: read "secret"
# exit 0
```

  </TabItem>
</Tabs>

Rust can compile the program, ASan can stay silent, and the program can still use the wrong file. Memory safety is not general security.

The production cousin is [CVE-2026-35359](https://www.openwall.com/lists/oss-security/2026/05/02/2) in Ubuntu’s Rust [uutils](https://github.com/uutils/coreutils) `cp`: check a path, open without `O_NOFOLLOW`, swap a symlink. Canonical / [Zellic](https://github.com/Zellic/publications/blob/master/uutils%20coreutils%20-%20Zellic%20Audit%20Report.pdf) found mostly file races and ignored errors, not a pile of UAF. GNU still shipped a heap overflow: [CVE-2026-56392](https://osv.dev/vulnerability/CVE-2026-56392). Different class, both real. uutils `dd` [CVE-2026-35344](https://github.com/advisories/GHSA-wh8p-h9hw-x2mc) hid a truncate failure with `.ok()`: memory fine, program wrong.

Fix for the experiment: open **once**, then `fstat` / operate on the **file descriptor**, or `O_NOFOLLOW`.

### 5. Talking to C

When Rust calls C (`extern "C"`), rustc trusts the C side ([FFI](https://doc.rust-lang.org/nomicon/ffi.html)). Wrong length, a “success” null, `from_raw_parts(ptr, len)`: rustc never measured `len`. Tests 1–2 are compile-time reject. Test 3 is runtime panic. Tests 4–5 are where the proof stops.

Panic / OOM are still bugs. They are not [`strcpy`](https://en.cppreference.com/w/c/string/byte/strcpy) UB. Safe indexing is not on the [UB list](https://doc.rust-lang.org/reference/behavior-considered-undefined.html); it panics.

## C++23 and sanitizers

Default C++ still lets you `new`/`delete` and `v[i]`. C++ also has tools. I re-ran the bugs with **C++23**, `std::span`, `std::vector`, and [ASan](https://github.com/google/sanitizers/wiki/AddressSanitizer) (`g++` 13.3 / `clang++` 18.1.3, `-std=c++23`).

`span[i]` does **not** check `i`. Same silent write past a vector of length 4:

```text
$ g++ -std=c++23 -O0 -Wall -Wextra cxx23_span.cpp -o cxx23_span
$ ./cxx23_span 4
still running  s[0]=0
# clang++ 18: same, exit 0
$ g++ -std=c++23 -O0 -Wall -Wextra -fsanitize=address cxx23_span.cpp -o cxx23_span_asan
$ ./cxx23_span_asan 4
ERROR: AddressSanitizer: heap-buffer-overflow
# abort
```

C++23 `string_view` after `delete` printed `secret` (exit 0). With ASan: `heap-use-after-free`, abort.

C++23 + ASan caught both **at run time**, if you pass the flag and **run the path**. rustc’s check on `&s` / `a[10]` is compile time with no extra flag. The variable-index panic is in every binary, debug or `-O`.

[`vector::at`](https://en.cppreference.com/w/cpp/container/vector/at) throws `out_of_range` — closer to Rust `v[i]`. The usual C++ spelling is still unchecked `v[i]` / `span[i]`. Rust’s usual spelling is the checked one. Unchecked Rust is `unsafe { *v.get_unchecked(i) }`.

Boost became a lot of `std`; the rest of the kitchen sink is crates.io on the Rust side. Trusting a crate is the same problem as trusting Boost. Neither makes `span[i]` check bounds by default.

## `unsafe` is a proof boundary

`unsafe` means: “compiler, trust me here.” The hole is **named**, so you can keep it small. Callers stay in safe Rust; inside, you own the invariant.

```rust
pub fn first_byte(data: &[u8]) -> u8 {
    unsafe { *data.as_ptr() }
}
```

Ten lines of `unsafe` under a thousand lines of safe code is the design. Five thousand lines of `transmute` and FFI is C with extra steps. Count invariants, not blocks.

```rust
pub fn as_static(s: &str) -> &'static str {
    unsafe { std::mem::transmute(s) }
}
```

`main` has no `unsafe`. The program can still use-after-free. rustc checks the **function type**, not the proof inside `unsafe`. `std` hides dangerous bits on purpose. A lie in that hiding is still a lie.

“Our crate has no `unsafe`” is incomplete: `Cargo.lock` may pull crates that do. `cargo audit` finds **known** advisories; it does not prove libraries correct.

## From borrow checking to LLVM

Safe Rust is only as strong as rustc. If rustc **accepts an invalid program**, the language said no and the implementation said yes. LLVM then optimizes as if the type were true. That is a miscompile of the *language*, not a random backend crash.

```text
source → AST → HIR → type check → borrow check → MIR → LLVM IR → machine code
```

Ownership is checked **before** LLVM. `&mut` is not “any C pointer”; rustc can lower it as `noalias`. If rustc **wrongly** emits `&'static`, LLVM may treat that pointer as forever. A hole in lifetime rules is permission for the optimizer.

The guarantee is not “the borrow checker is perfect.” It is: **the whole pipeline preserves the language’s safety rules.** Same numbered list as above: language → `unsafe` → FFI → libraries → **rustc** → **LLVM** → OS. ISSTA 2026 and #25860 sit on the rustc step. They are not a gotcha against `Vec`.

The [pipeline article](/docs/articles/rustc-pipeline-vs-cpp-compilation-pipeline) draws the C++ side.

## A 2026 research paper

Yusung Sim, Sukyoung Ryu (KAIST), Jaemin Hong (UNIST) wrote [Rust's Type Checker Implementation is Unsound](https://conf.researchr.org/details/issta-2026/issta-2026-research-papers/129/Rust-s-Type-Checker-Implementation-is-Unsound-An-Empirical-Study-on-Soundness-Bugs-i) for ISSTA 2026. Extra files: [Zenodo](https://doi.org/10.5281/zenodo.20698055).

This paper is **not** “Rust apps have bugs.” It is “rustc sometimes accepts programs it should reject.”

Three different compiler bugs:

1. rustc **crashes**: annoying, not a memory smash in your app
2. rustc **rejects good code**: also annoying
3. rustc **accepts bad code**: this is the soundness bug. This one can hide a use-after-free behind `cargo build` with no `unsafe`

Another paper (Liu et al., OOPSLA 2025) counted many kinds of rustc bugs. This ISSTA paper looks only at type (3), and compares with Liu.

How they built the list: GitHub issues from Jan 2022 to Sep 2025 about types (969) → bug / unsound labels (320) → read by hand (**23**). The short abstract says 23. I almost stopped there. The extra files add 7 more from Liu. Final study set: **30**. I wish the abstract said both numbers.

What they found, in simple words:

- Some of these bugs (often “implied bounds” or trait objects) can break memory safety.
- Hard cases are associated types and lifetimes mixed with traits: not `Vec` indexing.
- Many bugs were there from the day the feature shipped. Issue #25860 (2015) is the long example, even though it is older than their 2022–2025 window.
- **[Miri](https://github.com/rust-lang/miri)** can catch the ones that blow up at run time. Other formal tools (Chalk, a-mir-formality) are not ready as a full test of rustc.
- The official docs are often not precise enough to use as an automatic test.

Why #25860 can stay open for years: if the rule is not written as a machine-checkable test, you cannot fail rustc with a spec. You fail it with a program plus a human saying “this should not compile.” That is slow.

The [compiler guide](https://rustc-dev-guide.rust-lang.org/traits/implied-bounds.html) already lists this family: #25860, [#84591](https://github.com/rust-lang/rust/issues/84591), [#100051](https://github.com/rust-lang/rust/issues/100051).

C and C++ also do not have a full machine spec of “this must be rejected.” I am not picking on Rust for that. The difference is the **claim**. Rust’s short sentence needs rustc to be right. If tests cannot decide the edge, you have a team process (issues, types team, new solver), not a finished proof.

Normal `HashMap` code is not this set. The set is also not empty. Next is the file I compiled.

## Bug #25860, which I compiled

[#25860](https://github.com/rust-lang/rust/issues/25860) has been open since May 2015. A real fix is waiting on bigger type-system work. [PR #156077](https://github.com/rust-lang/rust/pull/156077) in May 2026 was closed. It did not even build rustc.

The [cve-rs](https://github.com/Speykious/cve-rs) example uses **zero** `unsafe`. A helper that is fine on its own:

```rust
fn lifetime_translator<'a, 'b, T: ?Sized>(
    _val_a: &'a &'b (),
    val_b: &'b T,
) -> &'a T {
    val_b
}
```

gets copied as a function pointer in a way that drops a lifetime rule. Then a dummy `&&()` is used to pretend a short-lived value lives forever:

```rust
const STATIC_UNIT: &&() = &&();

pub fn as_static<T: ?Sized>(x: &T) -> &'static T {
    let f: for<'x> fn(_, &'x T) -> &'static T = lifetime_translator;
    f(STATIC_UNIT, x)
}
```

I compiled this with **rustc 1.93.1**. It accepted it. I dropped a `String`, allocated something the same size, then read the “forever” string. Debug build stopped inside a copy check. Release printed zeros. That is when “if it compiled, rustc proved it” died for me. Not for normal `Vec` code. For rustc.

Normal app code does not look like this. If you start a tools argument with this file, people will say “that is a compiler bug.” They are right. Start with docs search if that is your point. I keep this file because I ran it.

## What you pay for the checks

The guarantee is not free. This is the bill I actually hit.

- **Learning:** ownership and lifetimes. The first month is slower than C++ if you already know C++.
- **Compile time.** rustc is still slow. A parallel frontend is a 2026 goal (about 20–30% faster in tests, not the default yet). Waiting is a real cost on large crates.
- **Docs.** I typed `replace` in rustdoc on the `String` page. Methods from `str` are listed if you scroll. Search still does not find them through `Deref`. rust-analyzer does. Weak for “I don’t know the name yet.”
- **Runtime index checks** on `a[i]` when rustc cannot prove `i`. Usually cheap. Hot loops sometimes use `get_unchecked` (`unsafe`, Level 2).
- **`unsafe` boundaries and FFI.** You still write C ABI glue. That glue is where Level 1 ends.
- **Layout control.** Packed structs, custom allocators, MMIO: you will touch `unsafe` or stay in C.
- **No std lending iterator.** A standard `Iterator` cannot yield a borrow from inside itself. Other crates exist ([rust-streaming](https://github.com/emk/rust-streaming)).

Around 2015 some people said: skip the borrow-checker fight, look at the tools. serde, `impl Trait`, `cargo install` got better. The three bullets above (docs search, compile wait, lending iterator) did not vanish.

A May 2023 [forum thread](https://users.rust-lang.org/t/why-are-some-people-against-the-rust-lang/93906) asked why people dislike Rust. Fair replies: a tiny part of a kernel is special CPU instructions; Rust and C can live together; nobody will rewrite a billion lines of old C. In 2026 some Linux kernel code is Rust, most is still C.

Docs search and compile wait are one argument. #25860 is another. Do not mix them.

## The claim I would actually make

Yes, for new code where ownership is hard: a parser, a cache with threads, a small C API you can wrap.

No, as a “moral upgrade” of a huge old C/C++ SDK wrapper, or a math kernel that is already correct and fast in C++. Waiting on rustc is a real cost on those teams.

These stars are **taste, not a score**. I would not defend them in a standards meeting. They are how I explain the trade to a teammate in five minutes.

| Situation | C | C++ | Rust |
|---|---:|---:|---:|
| Existing legacy code | ★★★★★ | ★★★★★ | ★★ |
| New systems component | ★★★★ | ★★★★ | ★★★★★ |
| Memory safety as the main risk | ★★ | ★★★ | ★★★★★ |
| Maximum ecosystem / ABI compatibility | ★★★★★ | ★★★★★ | ★★★ |
| Kernel / embedded | ★★★★★ | ★★★★ | ★★★★ |
| Rewrite a large C/C++ tree | ★★★★ | ★★★★★ | ★★ |
| New security-sensitive component | ★★★ | ★★★ | ★★★★★ |

“Rewrite it in Rust” is usually a bad plan. New drivers or a new sealed component can be a plan. For one new cache, see the [Rust vs C++ comparison](/docs/articles/rust-vs-modern-cpp-memory-safety-beyond-the-hype).

I would not write: “Rust makes programs memory safe.” Too broad. I would write:

**Safe Rust moves a large class of memory-safety errors from runtime into compile-time rules. `unsafe`, FFI, compiler bugs, OS interfaces, and logic errors stay outside that guarantee.**

:::tip What exactly does Rust guarantee?
**In safe code (if rustc is sound), Rust is built to stop:** no use-after-free, no dangling references, no double-free, no data races, bounds-checked indexing, ownership/lifetime consistency.

**It does not guarantee:** correct business logic, race-free filesystem operations, correct FFI contracts, absence of `unsafe` bugs, absence of library / rustc / LLVM bugs, absence of DoS / panic / OOM.
:::

The interesting difference between Rust and C++ is not whether safety tools exist. It is **what happens when the programmer forgets to use them.**

Rust did not delete the need for correctness. It moved a big piece of it into the type system. Memory safety is a floor, not the whole building.

## Limits

The small C/C++/Rust programs and #25860 were run on rustc 1.93.1, gcc/g++ 13.3, and clang/clang++ 18.1.3 on one machine. C++23 tests used `-std=c++23`; ASan used `-fsanitize=address`. #25860 is still open. ISSTA numbers come from the public abstract and artifact; I did not invent extra stats. uutils notes come from Canonical’s 2026 post, the Zellic PDF, and oss-security, not “every Rust CLI is clean.” Docs search and compile speed change every release.

C and Rust can live together. People are still the expensive part. Checking more at compile time is a bet that computers got cheaper faster than human attention. I just wanted the extra words on the claim written down.

## References

Claims in the article point here: rustc soundness and #25860 (2–9); uutils / GNU CVEs and TOCTOU (10–13); ASan, `span`, `at` (14).

1. [Why are some people against the Rust-Lang?](https://users.rust-lang.org/t/why-are-some-people-against-the-rust-lang/93906), May 2023.
2. [rust-lang/rust#25860](https://github.com/rust-lang/rust/issues/25860).
3. [PR #156077](https://github.com/rust-lang/rust/pull/156077) (closed, did not land).
4. [cve-rs](https://github.com/Speykious/cve-rs).
5. Sim, Ryu, Hong, [Rust's Type Checker Implementation is Unsound](https://conf.researchr.org/details/issta-2026/issta-2026-research-papers/129/Rust-s-Type-Checker-Implementation-is-Unsound-An-Empirical-Study-on-Soundness-Bugs-i), ISSTA 2026.
6. Artifact [10.5281/zenodo.20698055](https://doi.org/10.5281/zenodo.20698055).
7. Liu et al., [Bugs in the rustc Compiler](https://doi.org/10.1145/3763800), OOPSLA 2025.
8. rustc-dev-guide, [Implied bounds](https://rustc-dev-guide.rust-lang.org/traits/implied-bounds.html).
9. [Miri](https://github.com/rust-lang/miri), [Chalk](https://github.com/rust-lang/chalk), [a-mir-formality](https://github.com/rust-lang/a-mir-formality), [FLS](https://spec.ferrocene.dev/).
10. [Bugs Rust Won’t Catch](https://corrode.dev/blog/bugs-rust-wont-catch/).
11. Canonical, [An update on rust-coreutils](https://discourse.ubuntu.com/t/an-update-on-rust-coreutils/80773); [Zellic audit PDF](https://github.com/Zellic/publications/blob/master/uutils%20coreutils%20-%20Zellic%20Audit%20Report.pdf); [oss-security CVE list](https://www.openwall.com/lists/oss-security/2026/05/02/2).
12. [CVE-2026-35344](https://github.com/advisories/GHSA-wh8p-h9hw-x2mc). [CVE-2026-56392](https://osv.dev/vulnerability/CVE-2026-56392); [CERT Polska on GNU coreutils](https://cert.pl/en/posts/2026/07/CVE-2026-56391/).
13. [TOCTOU](https://en.wikipedia.org/wiki/Time-of-check_to_time-of-use); Rust [`std::fs`](https://doc.rust-lang.org/std/fs/); [FFI](https://doc.rust-lang.org/nomicon/ffi.html); [panic](https://doc.rust-lang.org/book/ch09-01-unrecoverable-errors-with-panic.html); [`strcpy`](https://en.cppreference.com/w/c/string/byte/strcpy); [undefined behavior (C)](https://en.cppreference.com/w/c/language/behavior).
14. [AddressSanitizer](https://github.com/google/sanitizers/wiki/AddressSanitizer); [UBSan](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html); [`std::span`](https://en.cppreference.com/w/cpp/container/span); [`vector::at`](https://en.cppreference.com/w/cpp/container/vector/at); [Boost](https://www.boost.org/); [crates.io](https://crates.io/).
15. rustdoc [Search](https://doc.rust-lang.org/nightly/rustdoc/read-documentation/search.html); [#19190](https://github.com/rust-lang/rust/issues/19190).
16. [Parallel Front End (2026)](https://rust-lang.github.io/rust-project-goals/2026/parallel-front-end.html); Nethercote, [July 2026](https://nnethercote.github.io/2026/07/31/how-to-speed-up-the-rust-compiler-in-july-2026.html).
17. [cargo-dist](https://github.com/axodotdev/cargo-dist), [cargo-binstall](https://github.com/cargo-bins/cargo-binstall), [rust-streaming](https://github.com/emk/rust-streaming).
18. Walleij, [*Rust in Perspective*](https://people.kernel.org/linusw/rust-in-perspective).
19. [Rust vs Modern C++](/docs/articles/rust-vs-modern-cpp-memory-safety-beyond-the-hype); [Rustc pipeline](/docs/articles/rustc-pipeline-vs-cpp-compilation-pipeline).

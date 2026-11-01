---
title: "OpenMP Tasks and Sections"
description: "How OpenMP sections create fixed structural units while task constructs and task dependencies allow dynamic runtime scheduling of irregular or graph-based parallel work."
keywords:
  - openmp tasks
  - openmp sections
  - explicit tasking
  - openmp taskwait
  - openmp task depend
  - task outlining
  - runtime task queue
  - task scheduling
  - dynamic worksharing
  - asynchronous execution
  - task allocation
  - pointer chasing parallelism
displayed_sidebar: parallelComputingSidebar
slug: /parallel-computing/openmp-tasks-and-sections
---

OpenMP loop directives schedule work over uniform index spaces, but irregular graphs, linked structures, and heterogeneous functional phases require fine-grained unit creation. OpenMP tasks decouple task generation from execution, placing explicit units onto runtime queues with optional dependency constraints.

:::tip Read these first
- [/docs/parallel-computing/decomposition-tasks-and-mapping](/docs/parallel-computing/decomposition-tasks-and-mapping) — How tasks, data decomposition, and mapping interact.
- [/docs/parallel-computing/openmp-reduction-and-dependence](/docs/parallel-computing/openmp-reduction-and-dependence) — OpenMP parallel regions and loop-carried dependencies.
:::

:::important What you should leave with
A loop split requires a known iteration count at loop entry; an OpenMP task lets a thread queue work dynamically as it discovers it. The compiler outlines the task body into a separate call and packages variables, but the developer must explicitly define the dependency edges (`depend(in: ...)`, `depend(out: ...)`, or `taskwait`) to preserve correctness.
:::

## Why you should care

When work can be divided by array index, `#pragma omp for` splits the iteration space across a thread team. However, real compilers and runtime engines frequently traverse trees, parse linked AST nodes, or execute static processing pipelines where iteration counts are unknown in advance.

Consider processing a singly linked list where each node contains an independent data block:

```c
#include <stdio.h>
#include <stdlib.h>

struct Node {
    int data;
    struct Node* next;
};

void process_node(struct Node* node) {
    if (node) {
        node->data += 1;
    }
}

void process_list_serial(struct Node* head) {
    struct Node* curr = head;
    while (curr != NULL) {
        process_node(curr);
        curr = curr->next;
    }
}
```

A standard OpenMP loop construct (`#pragma omp for`) cannot parallelize this `while` loop directly because the iteration count is unknown at runtime entry, and evaluating `curr = curr->next` requires sequential traversal. Attempting to copy pointer targets into an array first adds memory allocation overhead and extra passes over uncached memory.

## The mechanism

OpenMP provides two mechanisms for non-loop or irregular parallelism: **sections** and **tasks**.

### OpenMP Sections: Static Structural Decomposition

The `sections` construct explicitly divides work into fixed, statically known blocks.

```c
#pragma omp parallel sections
{
    #pragma omp section
    {
        do_stage_a();
    }
    #pragma omp section
    {
        do_stage_b();
    }
}
```

The runtime assigns each `section` block to an available thread in the parallel team. If there are four threads and two sections, two threads run a section each, while the remaining two threads idle or wait at the implicit barrier at the end of the `sections` region. `sections` work well when functional phases are distinct and fixed at compile time, but fail to scale when work is dynamically generated or unbounded.

### OpenMP Tasks: Dynamic Allocation and Execution

A `task` construct explicitly packaging a block of code and its associated data context into a discrete execution unit. When a thread encounters `#pragma omp task`, it allocates a task frame, packages capturing variables, and places the task onto a runtime queue.

```
+-------------------------------------------------------------+
| Parallel Region (Single Thread Generating Tasks)            |
|                                                             |
|  Thread 0 (Traversing List)                                 |
|  +-----------------------+                                  |
|  | #pragma omp task      | ---> [Task Queue]                |
|  +-----------------------+           |                      |
+--------------------------------------|----------------------+
                                       v
                     +-----------------------------------+
                     | Thread Team Pulls From Queue      |
                     | Thread 0 | Thread 1 | Thread 2    |
                     +-----------------------------------+
```

1. **Task Creation**: One thread (often inside a `#pragma omp single` block) traverses the data structure and instantiates tasks.
2. **Task Deferral or Execution**: The runtime can execute the task immediately on the encountering thread or place it in a pool for idle worker threads in the team to steal.
3. **Synchronization**: Tasks execute asynchronously. To guarantee completion before subsequent dependent steps run, code must issue `#pragma omp taskwait` or set fine-grained task dependencies (`depend`).



## A comparison

| Work Model | Task Discovery Time | Memory Overhead | Best Used For |
| :--- | :--- | :--- | :--- |
| **`#pragma omp for`** | Static (Loop entry) | Low (Contiguous iteration bounds) | Dense arrays, regular loops |
| **`#pragma omp sections`** | Static (Compile time) | Low (Fixed block structure) | Fixed pipeline stages, independent calls |
| **`#pragma omp task`** | Dynamic (Runtime execution) | Medium (Task allocations and captures) | Pointer chasing, graph traversals, recursion |

## A worked example

This example demonstrates parallelizing a dynamic linked list traversal using `task` directives and enforcing a global execution boundary with `taskwait`.

```c
#include <stdio.h>
#include <stdlib.h>
#include <omp.h>

struct Node {
    int id;
    int data;
    struct Node* next;
};

void heavy_computation(struct Node* n) {
    n->data = n->id * 2;
}

void process_list_parallel(struct Node* head) {
    #pragma omp parallel
    {
        #pragma omp single
        {
            struct Node* curr = head;
            while (curr != NULL) {
                // First-private pointer passed to task allocation
                #pragma omp task firstprivate(curr)
                {
                    heavy_computation(curr);
                }
                curr = curr->next;
            }
            // Wait for all child tasks created in this single construct to complete
            #pragma omp taskwait
        }
    }
}

int main(void) {
    const int count = 5;
    struct Node* head = NULL;
    struct Node* tail = NULL;

    for (int i = 0; i < count; i++) {
        struct Node* n = (struct Node*)malloc(sizeof(struct Node));
        n->id = i + 1;
        n->data = 0;
        n->next = NULL;
        if (!head) {
            head = n;
            tail = n;
        } else {
            tail->next = n;
            tail = n;
        }
    }

    process_list_parallel(head);

    struct Node* curr = head;
    while (curr) {
        printf("Node %d: %d\n", curr->id, curr->data);
        struct Node* tmp = curr;
        curr = curr->next;
        free(tmp);
    }

    return 0;
}
```

### Line-by-Line Explanation

1. **`#pragma omp parallel`**: Spawns a team of threads. All threads enter the block and wait for work assignments.
2. **`#pragma omp single`**: Ensures that exactly *one* thread executes the list traversal and produces task descriptors. The remaining threads bypass the `while` loop and wait to steal and execute tasks from the team task queue.
3. **`#pragma omp task firstprivate(curr)`**: Creates an explicit OpenMP task for each list node. The `firstprivate(curr)` clause captures the value of `curr` at the moment the task is created, making each task's pointer invariant even as the generator thread advances `curr = curr->next`.
4. **`heavy_computation(curr)`**: The task body executed by whichever thread picks up the task.
5. **`#pragma omp taskwait`**: Holds the generating thread inside the `single` region until all child tasks instantiated by that thread complete.

## What the compiler and runtime can and cannot do

### What the compiler does
When encountering `#pragma omp task`, the compiler performs **task outlining**:
1. It extracts the body of the task into a synthesized internal function (e.g., `.omp_task_entry.0`).
2. It constructs a dynamic frame structure containing room for captured variables (like `curr` under `firstprivate`).
3. It emits a runtime call (such as `__kmpc_omp_task_alloc` in LLVM) to allocate the task structure, fills in captured variables, and calls `__kmpc_omp_task` to queue or immediately execute the task.

### What the compiler cannot do
1. **Discover task dependencies automatically**: The compiler does not inspect memory access inside task outlined functions across iterations to deduce data dependency graphs.
2. **Eliminate task creation overhead**: Creating millions of lightweight tasks (e.g., operating on 2 instructions each) introduces task framing overhead that can dominate runtime. The compiler cannot automatically merge fine-grained tasks unless explicitly instructed by user thresholds or chunking strategies.

### Fine-Grained Dependencies with `depend`

When tasks have explicit data dependencies, OpenMP allows specifying dependency graphs without requiring global barriers (`taskwait`):

```c
#pragma omp task depend(out: A)
init_array(A);

#pragma omp task depend(out: B)
init_array(B);

#pragma omp task depend(in: A, B) depend(out: C)
combine_arrays(A, B, C);
```

The OpenMP runtime tracks address dependencies (`A`, `B`, and `C`). Task `combine_arrays` is held in a suspended state in the runtime graph until both initialization tasks complete, freeing threads to run unblocked tasks elsewhere.

## Common misconceptions

### Misconception 1: `#pragma omp task` automatically executes on another thread immediately
**Correction**: The directive simply packages a unit of work. The encountering thread may choose to run the task inline immediately, or place it on a deque where another idle thread pulls it later.

### Misconception 2: Tasks created within a parallel region are automatically waited on at the end of a `single` block
**Correction**: An OpenMP `single` directive has an implicit barrier at its *end*, but it only synchronizes the threads of the parallel team; it does not automatically wait for pending nested async tasks unless explicit `taskwait` or `taskgroup` directives are specified, or when exiting the enclosing `#pragma omp parallel` boundary.

### Misconception 3: Tasks replace `#pragma omp for` for regular loops
**Correction**: Directives like `#pragma omp for` have significantly lower scheduling overhead for dense ranges because they do not require dynamic allocation of task descriptors for individual units.

## Where this leaves you

When converting irregular loops or producer-consumer graphs to OpenMP:
1. Ensure loop variables or node pointers are captured via `firstprivate` so that state changes on the discovery thread do not mutate active task pointers.
2. Ensure correctness by adding `#pragma omp taskwait` or matching explicit `depend(in: ...)` and `depend(out: ...)` annotations.

## What To Read Next

- [/docs/parallel-computing/openmp-schedules](/docs/parallel-computing/openmp-schedules) — How static, dynamic, and guided schedules handle loop work distribution.
- [/docs/parallel-computing/pthreads-mutex-and-barrier](/docs/parallel-computing/pthreads-mutex-and-barrier) — Low-level primitives for threads, synchronization, and manual task queues.

![Diagram](/img/parallel/openmp-tasks-and-sections.svg)

## References

- Pacheco, Peter. *An Introduction to Parallel Programming*. Morgan Kaufmann.
- OpenMP Application Program Interface, Version 5.2. OpenMP Architecture Review Board.

## Quiz

- [Quiz](/docs/mcq/questions/domain/parallel/daily/openmp-tasks-and-sections/)

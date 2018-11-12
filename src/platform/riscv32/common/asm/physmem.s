# kernel low-level physical memory management
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global platform_physmem_set_ram_size
.global platform_physmem_get_kernel_start
.global platform_physmem_get_kernel_end
.global platform_pgstack_push
.global platform_pgstack_pull

# include kernel constants, such as stack and lock locations
.include "src/platform/riscv32/common/asm/consts.s"

# define how many bytes of physical ram are available in total
# => a0 = number of bytes
platform_physmem_set_ram_size:
  la    t0, __kernel_top_page_base
  addi  t0, t0, KERNEL_PHYS_RAM_SIZE
  sw    a0, (t0)
  ret

# return in a0 the start of the kernel, its static structures and payload in physical RAM,
# as defined by the linker script
platform_physmem_get_kernel_start:
  la    a0, __kernel_start
  ret
# return in a0, the end of the kernel, its static structures and payload in physical RAM
# as defined by the linker script
platform_physmem_get_kernel_end:
  la    a0, __kernel_end
  ret

# push a page onto the physical page stack
# => a0 = physical address to push
#    a1 = 0 to check against stack limit and fail if reached,
#         1 to incrememnt limit without failure
# <= a0 = 0 for success, or 1 for failure due to stack limit reached
#    a1 preserved
platform_pgstack_push:
  # stack return address
  addi  sp, sp, -4
  sw    ra, (sp)

  # keep this in a back pocket to use again and again
  la    t6, __kernel_top_page_base

  # preserve a0 in t1 across acquire_spin_lock
  add   t1, a0, x0
  # acquire lock, corrupts t0
  addi  a0, t6, KERNEL_PGSTACK_SPIN_LOCK
  call  platform_acquire_spin_lock
  # restore a0
  add   a0, t1, x0

  # check if we're at the limit, and if so, and we're not allowed to
  # update the stack limit (a1 == 0) then fail out
  addi  t0, t6, KERNEL_PGSTACK_PTR
  lw    t2, (t0)                    # load stack pointer value into t2
  addi  t1, t6, KERNEL_PGSTACK_MAX
  lw    t3, (t1)                    # load stack limit value into t3
  bltu  t2, t3, push_to_pgstack     # branch if stack ptr < limit

  # if we're here then ptr >= limit. if we're allowed to, incrememt the
  # limit. if not, then fail out
  beq   a1, x0, pgstack_limit_hit   # a1 == 0 to prevent limit increase
  # increment stack limit and store new value
  addi  t3, t3, 4
  sw    t3, (t1)

push_to_pgstack:
  # write page address in a0 to the stack at current ptr location
  sw    a0, (t2)
  # increment stack pointer and store new value
  addi  t2, t2, 4
  sw    t2, (t0)
  # indicate success in t0 with a zero
  add   t0, x0, x0

pgstack_push_exit:
  # release lock
  addi  a0, t6, KERNEL_PGSTACK_SPIN_LOCK
  call  platform_release_spin_lock

  # fix up stack, return success or failure (from t0) in a0
  add   a0, t0, x0
  lw    ra, (sp)
  addi  sp, sp, 4
  ret

pgstack_limit_hit:
  # stick 1 (non-zero) in t0 to indicate failure: stack limit hit
  li    t0, 1
  j     pgstack_push_exit

# pull a physical page address from the stack
# => a0 = pointer to 32-bit word to write valid pulled value into
# <= a0 = 0 for success or 1 for empty stack (nothing to pull)
# corrupts t0-t5
platform_pgstack_pull:
  # stack ra
  addi  sp, sp, -4
  sw    ra, (sp)

  # keep this in a back pocket to use again and again
  la    t6, __kernel_top_page_base

  # preserve a0 in t1 across acquire_spin_lock
  add   t1, a0, x0
  # acquire lock, corrupts t0
  addi  a0, t6, KERNEL_PGSTACK_SPIN_LOCK
  call  platform_acquire_spin_lock
  # restore a0
  add   a0, t1, x0

  # load stack pointer value into t1 and make sure we're not looking at an
  # empty page stack - if so, bail out, we're out of physical memory
  addi  t0, t6, KERNEL_PGSTACK_PTR
  lw    t1, (t0)
  la    t2, __kernel_pg_stack_base
  beq   t1, t2, pgstack_empty

  # decrement stack ptr, save stack value into (a0), save new stack ptr back
  addi  t1, t1, -4
  lw    t3, (t1)
  sw    t3, (a0)
  # write updated stack ptr back to memory, set t0 to 0 for success
  sw    t1, (t0)
  li    t0, 0

pgstack_pull_exit:
  # release lock
  addi  a0, t6, KERNEL_PGSTACK_SPIN_LOCK
  call  platform_release_spin_lock

  # fix up stack, return success or failure in a0 from t0
  lw    ra, (sp)
  addi  sp, sp, 4
  add   a0, t0, x0
  ret

pgstack_empty:
  # no addresses to pull from stack
  li    t0, 1
  j     pgstack_pull_exit

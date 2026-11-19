// SPDX-License-Identifier: MIT
/*
 * Diosix Hypervisor Guest Character Driver - Device Passthrough Helpers.
 *
 * Forwards scoped child MMIO region mapping, child RAM range queries, and
 * physical PLIC IRQ delegation ioctls to M-mode SBI hypercalls.
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 */

#include <linux/kernel.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/io.h>
#include <linux/capability.h>
#include <asm/sbi.h>

#include "diosix.h"

static long handle_map_child_mmio(unsigned long arg)
{
    struct map_child_mmio_args *kargs;
    phys_addr_t kargs_pa;
    struct sbiret ret;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    kargs = kzalloc(sizeof(*kargs), GFP_KERNEL);
    if (!kargs)
        return -ENOMEM;

    if (copy_from_user(kargs, (void __user *)arg, sizeof(*kargs))) {
        kfree(kargs);
        return -EFAULT;
    }

    kargs_pa = virt_to_phys(kargs);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_MAP_CHILD_MMIO,
        (unsigned long)kargs_pa,
        0,
        0,
        0,
        0,
        0
    );
    if (ret.error) {
        kfree(kargs);
        return diosix_sbi_to_errno(ret.error);
    }

    if (copy_to_user((void __user *)arg, kargs, sizeof(*kargs))) {
        kfree(kargs);
        return -EFAULT;
    }

    kfree(kargs);
    return ret.value;
}

static long handle_delegate_child_irq(unsigned long arg)
{
    struct delegate_child_irq_args *kargs;
    phys_addr_t kargs_pa;
    struct sbiret ret;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    kargs = kzalloc(sizeof(*kargs), GFP_KERNEL);
    if (!kargs)
        return -ENOMEM;

    if (copy_from_user(kargs, (void __user *)arg, sizeof(*kargs))) {
        kfree(kargs);
        return -EFAULT;
    }

    kargs_pa = virt_to_phys(kargs);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_DELEGATE_CHILD_IRQ,
        (unsigned long)kargs_pa,
        0,
        0,
        0,
        0,
        0
    );
    if (ret.error) {
        kfree(kargs);
        return diosix_sbi_to_errno(ret.error);
    }

    if (copy_to_user((void __user *)arg, kargs, sizeof(*kargs))) {
        kfree(kargs);
        return -EFAULT;
    }

    kfree(kargs);
    return ret.value;
}

long diosix_ioctl_passthrough(unsigned int cmd, unsigned long arg)
{
    switch (cmd) {
    case IOCTL_MAP_CHILD_MMIO:
        return handle_map_child_mmio(arg);

    case IOCTL_DELEGATE_CHILD_IRQ:
        return handle_delegate_child_irq(arg);

    default:
        return -ENOTTY;
    }
}

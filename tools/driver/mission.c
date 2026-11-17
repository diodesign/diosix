// SPDX-License-Identifier: MIT
/*
 * Diosix Hypervisor Guest Character Driver - Cryptographic Mission Governance.
 *
 * Handles Principal-signed Mission sealing and conserved physical quota-stake
 * ratification voting via M-mode SBI hypercalls.
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 */

#include <linux/kernel.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/io.h>
#include <linux/capability.h>
#include <linux/gfp.h>
#include <linux/string.h>
#include <asm/sbi.h>

#include "diosix.h"

static long handle_seal_or_get_mission(unsigned int cmd, unsigned long arg)
{
    struct mission_args *kargs;
    phys_addr_t kargs_pa;
    unsigned long seal_flag = (cmd == IOCTL_SEAL_MISSION) ?
        DIOSIX_CHARTER_OP_SEAL : DIOSIX_CHARTER_OP_QUERY;
    struct sbiret ret;

    if (cmd == IOCTL_SEAL_MISSION && !capable(CAP_SYS_ADMIN))
        return -EPERM;

    kargs = kzalloc(sizeof(*kargs), GFP_KERNEL);
    if (!kargs)
        return -ENOMEM;

    if (copy_from_user(kargs, (void __user *)arg, sizeof(*kargs))) {
        memzero_explicit(kargs, sizeof(*kargs));
        kfree(kargs);
        return -EFAULT;
    }

    kargs_pa = virt_to_phys(kargs);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_SEAL_MISSION,
        (unsigned long)kargs_pa,
        seal_flag,
        0,
        0,
        0,
        0
    );
    if (ret.error) {
        memzero_explicit(kargs, sizeof(*kargs));
        kfree(kargs);
        return diosix_sbi_to_errno(ret.error);
    }

    if (copy_to_user((void __user *)arg, kargs, sizeof(*kargs))) {
        memzero_explicit(kargs, sizeof(*kargs));
        kfree(kargs);
        return -EFAULT;
    }

    memzero_explicit(kargs, sizeof(*kargs));
    kfree(kargs);
    return ret.value;
}

static long handle_vote_mission(unsigned long arg)
{
    struct mission_vote_args *kargs;
    phys_addr_t kargs_pa;
    struct sbiret ret;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    kargs = kzalloc(sizeof(*kargs), GFP_KERNEL);
    if (!kargs)
        return -ENOMEM;

    if (copy_from_user(kargs, (void __user *)arg, sizeof(*kargs))) {
        memzero_explicit(kargs, sizeof(*kargs));
        kfree(kargs);
        return -EFAULT;
    }

    kargs_pa = virt_to_phys(kargs);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_VOTE_MISSION,
        (unsigned long)kargs_pa,
        0,
        0,
        0,
        0,
        0
    );
    if (ret.error) {
        memzero_explicit(kargs, sizeof(*kargs));
        kfree(kargs);
        return diosix_sbi_to_errno(ret.error);
    }

    if (copy_to_user((void __user *)arg, kargs, sizeof(*kargs))) {
        memzero_explicit(kargs, sizeof(*kargs));
        kfree(kargs);
        return -EFAULT;
    }

    memzero_explicit(kargs, sizeof(*kargs));
    kfree(kargs);
    return ret.value;
}

long diosix_ioctl_mission(unsigned int cmd, unsigned long arg)
{
    switch (cmd) {
    case IOCTL_SEAL_MISSION:
    case IOCTL_GET_MISSION:
        return handle_seal_or_get_mission(cmd, arg);

    case IOCTL_VOTE_MISSION:
        return handle_vote_mission(arg);

    default:
        return -ENOTTY;
    }
}

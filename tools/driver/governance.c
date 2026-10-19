// SPDX-License-Identifier: MIT
/*
 * Diosix Hypervisor Guest Character Driver - Manifest, Memory & Governance.
 *
 * Handles manifest management, child guest memory mapping, deferred VM start,
 * charter sealing/ratification, and steward failover hypercalls.
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 */

#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/io.h>
#include <linux/capability.h>
#include <linux/gfp.h>
#include <linux/mm.h>
#include <asm/sbi.h>

#include "diosix.h"

static long handle_get_manifest(unsigned long arg)
{
    struct manifest_args args;
    struct manifest_args *sbi_margs;
    char *kbuf = NULL;
    phys_addr_t margs_pa, kbuf_pa = 0;
    struct sbiret ret;

    if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
        return -EFAULT;

    if (args.max_len > DIOSIX_MAX_MANIFEST_SIZE)
        return -EINVAL;

    if (args.max_len > 0 && !args.data_ptr)
        return -EINVAL;

    sbi_margs = kzalloc(sizeof(*sbi_margs), GFP_KERNEL);
    if (!sbi_margs)
        return -ENOMEM;

    if (args.max_len > 0) {
        kbuf = kzalloc(args.max_len, GFP_KERNEL);
        if (!kbuf) {
            kfree(sbi_margs);
            return -ENOMEM;
        }
        kbuf_pa = virt_to_phys(kbuf);
    }

    sbi_margs->target_cid = args.target_cid;
    sbi_margs->data_ptr = (unsigned long)kbuf_pa;
    sbi_margs->max_len = args.max_len;

    margs_pa = virt_to_phys(sbi_margs);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_GET_MANIFEST,
        (unsigned long)margs_pa,
        0,
        0,
        0,
        0,
        0
    );

    if (ret.error) {
        kfree(kbuf);
        kfree(sbi_margs);
        return -EIO;
    }

    args.actual_len = sbi_margs->actual_len;
    if (sbi_margs->actual_len > 0 && args.data_ptr && kbuf) {
        unsigned long copy_len = min(args.max_len, sbi_margs->actual_len);
        if (copy_to_user((void __user *)args.data_ptr, kbuf, copy_len)) {
            kfree(kbuf);
            kfree(sbi_margs);
            return -EFAULT;
        }
    }

    if (copy_to_user((void __user *)arg, &args, sizeof(args))) {
        kfree(kbuf);
        kfree(sbi_margs);
        return -EFAULT;
    }

    kfree(kbuf);
    kfree(sbi_margs);
    return 0;
}

static long handle_set_manifest(unsigned long arg)
{
    struct manifest_args args;
    struct manifest_args *sbi_margs;
    char *kbuf = NULL;
    phys_addr_t margs_pa, kbuf_pa = 0;
    struct sbiret ret;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
        return -EFAULT;

    if (args.max_len > DIOSIX_MAX_MANIFEST_SIZE)
        return -EINVAL;

    if (args.max_len > 0 && !args.data_ptr)
        return -EINVAL;

    sbi_margs = kzalloc(sizeof(*sbi_margs), GFP_KERNEL);
    if (!sbi_margs)
        return -ENOMEM;

    if (args.max_len > 0) {
        kbuf = kzalloc(args.max_len, GFP_KERNEL);
        if (!kbuf) {
            kfree(sbi_margs);
            return -ENOMEM;
        }
        if (copy_from_user(kbuf, (void __user *)args.data_ptr, args.max_len)) {
            kfree(kbuf);
            kfree(sbi_margs);
            return -EFAULT;
        }
        kbuf_pa = virt_to_phys(kbuf);
    }

    sbi_margs->target_cid = args.target_cid;
    sbi_margs->data_ptr = (unsigned long)kbuf_pa;
    sbi_margs->max_len = args.max_len;

    margs_pa = virt_to_phys(sbi_margs);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_SET_MANIFEST,
        (unsigned long)margs_pa,
        0,
        0,
        0,
        0,
        0
    );

    kfree(kbuf);
    kfree(sbi_margs);

    if (ret.error)
        return -EIO;

    return 0;
}

static long handle_map_child_mem(unsigned long arg)
{
    struct map_child_mem_args args;
    struct map_child_mem_args *sbi_margs;
    phys_addr_t margs_pa;
    unsigned long max_gpa = DIOSIX_CHILD_MEM_BASE + DIOSIX_CHILD_MEM_MAX_SIZE;
    struct sbiret ret;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
        return -EFAULT;

    if (args.parent_gpa == 0)
        args.parent_gpa = DIOSIX_CHILD_MEM_BASE;

    if (args.size == 0 || args.size > DIOSIX_CHILD_MEM_MAX_SIZE)
        return -EINVAL;

    if ((args.parent_gpa & (PAGE_SIZE - 1)) ||
        (args.child_gpa & (PAGE_SIZE - 1)) ||
        (args.size & (PAGE_SIZE - 1)))
        return -EINVAL;

    if (args.child_gpa + args.size < args.child_gpa)
        return -EINVAL;

    if (args.parent_gpa < DIOSIX_CHILD_MEM_BASE ||
        args.parent_gpa + args.size < args.parent_gpa ||
        args.parent_gpa + args.size > max_gpa)
        return -EINVAL;

    sbi_margs = kzalloc(sizeof(*sbi_margs), GFP_KERNEL);
    if (!sbi_margs)
        return -ENOMEM;

    memcpy(sbi_margs, &args, sizeof(args));
    margs_pa = virt_to_phys(sbi_margs);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_MAP_CHILD_MEM,
        (unsigned long)margs_pa,
        0,
        0,
        0,
        0,
        0
    );
    kfree(sbi_margs);

    if (ret.error)
        return -EIO;

    if (copy_to_user((void __user *)arg, &args, sizeof(args)))
        return -EFAULT;

    return 0;
}

static long handle_unmap_child_mem(unsigned long arg)
{
    struct unmap_child_mem_args args;
    struct unmap_child_mem_args *sbi_uargs;
    phys_addr_t uargs_pa;
    unsigned long max_gpa = DIOSIX_CHILD_MEM_BASE + DIOSIX_CHILD_MEM_MAX_SIZE;
    struct sbiret ret;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
        return -EFAULT;

    if (args.parent_gpa == 0)
        args.parent_gpa = DIOSIX_CHILD_MEM_BASE;

    if (args.size == 0 || args.size > DIOSIX_CHILD_MEM_MAX_SIZE)
        return -EINVAL;

    if ((args.parent_gpa & (PAGE_SIZE - 1)) ||
        (args.size & (PAGE_SIZE - 1)))
        return -EINVAL;

    if (args.parent_gpa < DIOSIX_CHILD_MEM_BASE ||
        args.parent_gpa + args.size < args.parent_gpa ||
        args.parent_gpa + args.size > max_gpa)
        return -EINVAL;

    sbi_uargs = kzalloc(sizeof(*sbi_uargs), GFP_KERNEL);
    if (!sbi_uargs)
        return -ENOMEM;

    memcpy(sbi_uargs, &args, sizeof(args));
    uargs_pa = virt_to_phys(sbi_uargs);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_UNMAP_CHILD_MEM,
        (unsigned long)uargs_pa,
        0,
        0,
        0,
        0,
        0
    );
    kfree(sbi_uargs);

    if (ret.error)
        return -EIO;

    return 0;
}

static long handle_start_guest(unsigned long arg)
{
    struct start_args args;
    struct start_args *sbi_sargs;
    phys_addr_t sargs_pa;
    struct sbiret ret;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
        return -EFAULT;

    sbi_sargs = kzalloc(sizeof(*sbi_sargs), GFP_KERNEL);
    if (!sbi_sargs)
        return -ENOMEM;

    memcpy(sbi_sargs, &args, sizeof(args));
    sargs_pa = virt_to_phys(sbi_sargs);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_START,
        (unsigned long)sargs_pa,
        0,
        0,
        0,
        0,
        0
    );
    kfree(sbi_sargs);

    if (ret.error)
        return -EIO;

    return ret.value;
}

static long handle_charter(unsigned int cmd, unsigned long arg)
{
    struct charter_args *kargs;
    phys_addr_t kargs_pa;
    unsigned long seal_flag = (cmd == IOCTL_SEAL_CHARTER) ?
        DIOSIX_CHARTER_OP_SEAL : DIOSIX_CHARTER_OP_QUERY;
    struct sbiret ret;

    if (cmd == IOCTL_SEAL_CHARTER && !capable(CAP_SYS_ADMIN))
        return -EPERM;

    kargs = kzalloc(sizeof(*kargs), GFP_KERNEL);
    if (!kargs)
        return -ENOMEM;

    if (cmd == IOCTL_SEAL_CHARTER) {
        if (copy_from_user(kargs, (void __user *)arg, sizeof(*kargs))) {
            kfree(kargs);
            return -EFAULT;
        }
    }

    kargs_pa = virt_to_phys(kargs);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_SEAL_CHARTER,
        (unsigned long)kargs_pa,
        seal_flag,
        0,
        0,
        0,
        0
    );
    if (ret.error) {
        kfree(kargs);
        return -EPERM;
    }

    if (cmd == IOCTL_GET_CHARTER) {
        if (copy_to_user((void __user *)arg, kargs, sizeof(*kargs))) {
            kfree(kargs);
            return -EFAULT;
        }
    }

    kfree(kargs);
    return ret.value;
}

long diosix_ioctl_governance(unsigned int cmd, unsigned long arg)
{
    struct sbiret ret;

    switch (cmd) {
    case IOCTL_GET_MANIFEST:
        return handle_get_manifest(arg);

    case IOCTL_SET_MANIFEST:
        return handle_set_manifest(arg);

    case IOCTL_MAP_CHILD_MEM:
        return handle_map_child_mem(arg);

    case IOCTL_UNMAP_CHILD_MEM:
        return handle_unmap_child_mem(arg);

    case IOCTL_START:
        return handle_start_guest(arg);

    case IOCTL_SEAL_CHARTER:
    case IOCTL_GET_CHARTER:
        return handle_charter(cmd, arg);

    case IOCTL_RATIFY_CHARTER:
        if (!capable(CAP_SYS_ADMIN))
            return -EPERM;
        ret = sbi_ecall(
            EXT_DIOSIX,
            DIOSIX_FUNC_RATIFY_CHARTER,
            arg,
            0,
            0,
            0,
            0,
            0
        );
        if (ret.error)
            return -EPERM;
        return ret.value;

    case IOCTL_RESET_STEWARD:
        if (!capable(CAP_SYS_ADMIN))
            return -EPERM;
        ret = sbi_ecall(
            EXT_DIOSIX,
            DIOSIX_FUNC_RESET_STEWARD,
            arg,
            0,
            0,
            0,
            0,
            0
        );
        if (ret.error)
            return -EPERM;
        return ret.value;

    case IOCTL_REQUEST_ROOT_FAILOVER:
        if (!capable(CAP_SYS_ADMIN))
            return -EPERM;
        ret = sbi_ecall(
            EXT_DIOSIX,
            DIOSIX_FUNC_REQUEST_ROOT_FAILOVER,
            arg,
            0,
            0,
            0,
            0,
            0
        );
        if (ret.error)
            return -EPERM;
        return ret.value;

    default:
        return -ENOTTY;
    }
}

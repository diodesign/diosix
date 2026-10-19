// SPDX-License-Identifier: MIT
/*
 * Diosix Hypervisor Guest Character Driver (/dev/diosix).
 *
 * Exposes hypercall interfaces to guest userspace applications.
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/io.h>
#include <linux/capability.h>
#include <linux/gfp.h>
#include <linux/dma-mapping.h>
#include <linux/mm.h>
#include <linux/sched/signal.h>
#include <asm/sbi.h>

#include "diosix.h"

static struct miscdevice diosix_dev;

static int diosix_open(struct inode *inode, struct file *file)
{
    /* Restrict access strictly to root / administrative capabilities. */
    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;
    return 0;
}

static long handle_get_info(unsigned long arg)
{
    struct guest_info *kinfo = kzalloc(sizeof(*kinfo), GFP_KERNEL);
    phys_addr_t pa;
    unsigned long target_cid = 1;
    struct sbiret ret;

    if (!kinfo)
        return -ENOMEM;

    if (copy_from_user(kinfo, (void __user *)arg, sizeof(*kinfo))) {
        kfree(kinfo);
        return -EFAULT;
    }
    if (kinfo->guest_id > 0) {
        target_cid = kinfo->guest_id;
    }
    pa = virt_to_phys(kinfo);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_GET_INFO,
        target_cid,
        (unsigned long)pa,
        sizeof(*kinfo),
        0,
        0,
        0
    );
    if (ret.error) {
        kfree(kinfo);
        return -EIO;
    }
    if (copy_to_user((void __user *)arg, kinfo, sizeof(*kinfo))) {
        kfree(kinfo);
        return -EFAULT;
    }
    kfree(kinfo);
    return 0;
}

static long handle_run_guest(unsigned long arg)
{
    struct run_args kargs;
    void *elf_kbuf = NULL;
    void *dtb_kbuf = NULL;
    phys_addr_t elf_pa = 0, dtb_pa = 0;
    dma_addr_t elf_dma_handle = 0;
    bool elf_is_dma = false;
    struct run_args *sbi_args = kzalloc(sizeof(*sbi_args), GFP_KERNEL);
    phys_addr_t sbi_args_pa;
    struct sbiret ret;
    int ret_val = 0;

    if (!sbi_args)
        return -ENOMEM;

    if (copy_from_user(&kargs, (void __user *)arg, sizeof(kargs))) {
        ret_val = -EFAULT;
        goto out_free_sbi;
    }

    if (kargs.elf_size > DIOSIX_MAX_ELF_SIZE ||
        kargs.dtb_size > DIOSIX_MAX_DTB_SIZE) {
        ret_val = -EINVAL;
        goto out_free_sbi;
    }

    if ((kargs.elf_size > 0 && !kargs.elf_ptr) ||
        (kargs.dtb_size > 0 && !kargs.dtb_ptr)) {
        ret_val = -EINVAL;
        goto out_free_sbi;
    }

    if (kargs.elf_size > 0 && kargs.elf_ptr) {
        if (kargs.elf_size <= 2 * 1024 * 1024) {
            elf_kbuf = alloc_pages_exact(kargs.elf_size, GFP_KERNEL);
            if (elf_kbuf) {
                elf_pa = virt_to_phys(elf_kbuf);
            }
        }
        if (!elf_kbuf) {
            elf_kbuf = dma_alloc_coherent(
                diosix_dev.this_device,
                kargs.elf_size,
                &elf_dma_handle,
                GFP_KERNEL
            );
            if (elf_kbuf) {
                elf_is_dma = true;
                elf_pa = (phys_addr_t)elf_dma_handle;
            }
        }
        if (!elf_kbuf) {
            ret_val = -ENOMEM;
            goto out_free_sbi;
        }
        if (copy_from_user(
                elf_kbuf,
                (void __user *)kargs.elf_ptr,
                kargs.elf_size
            )) {
            ret_val = -EFAULT;
            goto out_free_elf;
        }
    }

    if (kargs.dtb_size > 0 && kargs.dtb_ptr) {
        dtb_kbuf = alloc_pages_exact(kargs.dtb_size, GFP_KERNEL);
        if (!dtb_kbuf) {
            ret_val = -ENOMEM;
            goto out_free_elf;
        }
        if (copy_from_user(
                dtb_kbuf,
                (void __user *)kargs.dtb_ptr,
                kargs.dtb_size
            )) {
            ret_val = -EFAULT;
            goto out_free_dtb;
        }
        dtb_pa = virt_to_phys(dtb_kbuf);
    }

    sbi_args->child_id = kargs.child_id;
    sbi_args->elf_ptr = (unsigned long)elf_pa;
    sbi_args->elf_size = kargs.elf_size;
    sbi_args->dtb_ptr = (unsigned long)dtb_pa;
    sbi_args->dtb_size = kargs.dtb_size;
    sbi_args->target_arch = kargs.target_arch;
    sbi_args->flags = kargs.flags;
    sbi_args_pa = virt_to_phys(sbi_args);

    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_RUN,
        (unsigned long)sbi_args_pa,
        0,
        0,
        0,
        0,
        0
    );

    if (ret.error) {
        ret_val = -EIO;
        goto out_free_dtb;
    }

    kargs.child_id = ret.value;
    if (copy_to_user((void __user *)arg, &kargs, sizeof(kargs))) {
        ret_val = -EFAULT;
        goto out_free_dtb;
    }

    ret_val = (int)ret.value;

out_free_dtb:
    if (dtb_kbuf)
        free_pages_exact(dtb_kbuf, kargs.dtb_size);
out_free_elf:
    if (elf_kbuf) {
        if (elf_is_dma) {
            dma_free_coherent(
                diosix_dev.this_device,
                kargs.elf_size,
                elf_kbuf,
                elf_dma_handle
            );
        } else {
            free_pages_exact(elf_kbuf, kargs.elf_size);
        }
    }
out_free_sbi:
    kfree(sbi_args);
    return ret_val;
}

static long handle_wait_event(unsigned long arg)
{
    struct wait_event_args wargs;
    struct diosix_event *kev = kzalloc(sizeof(*kev), GFP_KERNEL);
    phys_addr_t pa;
    struct sbiret ret;
    int ret_val = 0;

    if (!kev)
        return -ENOMEM;

    if (copy_from_user(&wargs, (void __user *)arg, sizeof(wargs))) {
        kfree(kev);
        return -EFAULT;
    }

    pa = virt_to_phys(kev);

    while (1) {
        ret = sbi_ecall(
            EXT_DIOSIX,
            DIOSIX_FUNC_POLL_EVENT,
            (unsigned long)pa,
            sizeof(*kev),
            wargs.target_cid,
            0,
            0,
            0
        );
        if (ret.error) {
            ret_val = -EIO;
            break;
        }
        if (ret.value == 1) {
            memcpy(&wargs.event, kev, sizeof(*kev));
            if (copy_to_user((void __user *)arg, &wargs, sizeof(wargs))) {
                ret_val = -EFAULT;
                break;
            }
            ret_val = 0;
            break;
        }
        if (wargs.flags & 1) {
            ret_val = -EAGAIN;
            break;
        }
        if (signal_pending(current)) {
            ret_val = -ERESTARTSYS;
            break;
        }
        schedule_timeout_interruptible(msecs_to_jiffies(50));
    }

    kfree(kev);
    return ret_val;
}

static long diosix_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    struct sbiret ret;

    /* Defense-in-depth: enforce admin capability for all hypervisor ioctls. */
    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    switch (cmd) {
    case IOCTL_DROP_TRUST:
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_DROP_TRUST, 0, 0, 0, 0, 0, 0);
        if (ret.error)
            return -EIO;
        return 0;

    case IOCTL_GET_INFO:
        return handle_get_info(arg);

    case IOCTL_RUN:
        return handle_run_guest(arg);

    case IOCTL_TERMINATE: {
        struct terminate_args targs;
        if (copy_from_user(&targs, (void __user *)arg, sizeof(targs)))
            return -EFAULT;
        ret = sbi_ecall(
            EXT_DIOSIX,
            DIOSIX_FUNC_TERMINATE,
            targs.target_id,
            targs.exit_code,
            0,
            0,
            0,
            0
        );
        if (ret.error)
            return -EPERM;
        return 0;
    }

    case IOCTL_YIELD:
        sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_YIELD, 0, 0, 0, 0, 0, 0);
        return 0;

    case IOCTL_WAIT_EVENT:
        return handle_wait_event(arg);

    case IOCTL_SET_QUOTA: {
        struct quota_args qargs;
        struct quota_args *sbi_qargs = kzalloc(sizeof(*sbi_qargs), GFP_KERNEL);
        phys_addr_t pa;

        if (!sbi_qargs)
            return -ENOMEM;

        if (copy_from_user(&qargs, (void __user *)arg, sizeof(qargs))) {
            kfree(sbi_qargs);
            return -EFAULT;
        }

        memcpy(sbi_qargs, &qargs, sizeof(qargs));
        pa = virt_to_phys(sbi_qargs);
        ret = sbi_ecall(
            EXT_DIOSIX,
            DIOSIX_FUNC_SET_QUOTA,
            (unsigned long)pa,
            0,
            0,
            0,
            0,
            0
        );
        kfree(sbi_qargs);

        if (ret.error)
            return -EPERM;
        return 0;
    }

    case IOCTL_GET_HV_INFO: {
        struct hypervisor_info *hv_info =
            kzalloc(sizeof(*hv_info), GFP_KERNEL);
        phys_addr_t pa;

        if (!hv_info)
            return -ENOMEM;

        pa = virt_to_phys(hv_info);
        ret = sbi_ecall(
            EXT_DIOSIX,
            DIOSIX_FUNC_GET_HV_INFO,
            (unsigned long)pa,
            sizeof(*hv_info),
            0,
            0,
            0,
            0
        );
        if (ret.error) {
            kfree(hv_info);
            return -EIO;
        }
        if (copy_to_user((void __user *)arg, hv_info, sizeof(*hv_info))) {
            kfree(hv_info);
            return -EFAULT;
        }
        kfree(hv_info);
        return 0;
    }

    default:
        return diosix_ioctl_governance(cmd, arg);
    }
}

static int diosix_mmap(struct file *file, struct vm_area_struct *vma)
{
    unsigned long size;
    unsigned long pfn = vma->vm_pgoff;
    unsigned long base_pfn = DIOSIX_CHILD_MEM_BASE >> PAGE_SHIFT;
    unsigned long max_pfn =
        (DIOSIX_CHILD_MEM_BASE + DIOSIX_CHILD_MEM_MAX_SIZE) >> PAGE_SHIFT;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    if (vma->vm_end <= vma->vm_start)
        return -EINVAL;

    size = vma->vm_end - vma->vm_start;

    if (size == 0 || size > DIOSIX_CHILD_MEM_MAX_SIZE)
        return -EINVAL;

    if (pfn == 0)
        pfn = base_pfn;

    if (pfn < base_pfn || pfn >= max_pfn)
        return -EINVAL;

    if ((size >> PAGE_SHIFT) > (max_pfn - pfn))
        return -EINVAL;

    vm_flags_set(vma, VM_IO | VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP);

    if (remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot))
        return -EAGAIN;

    return 0;
}

static const struct file_operations diosix_fops = {
    .owner          = THIS_MODULE,
    .open           = diosix_open,
    .mmap           = diosix_mmap,
    .unlocked_ioctl = diosix_ioctl,
    .compat_ioctl   = diosix_ioctl,
};

static struct miscdevice diosix_dev = {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = "diosix",
    .fops  = &diosix_fops,
    .mode  = 0600,
};

static int __init diosix_init(void)
{
    int ret = misc_register(&diosix_dev);
    if (ret) {
        pr_err("diosix: failed to register /dev/diosix device\n");
        return ret;
    }
    dma_coerce_mask_and_coherent(diosix_dev.this_device, DMA_BIT_MASK(64));
    pr_info("diosix: /dev/diosix hypercall bridge registered\n");

    init_diosix_net();
    return 0;
}

static void __exit diosix_exit(void)
{
    cleanup_diosix_net();
    misc_deregister(&diosix_dev);
    pr_info("diosix: /dev/diosix device unregistered\n");
}

module_init(diosix_init);
module_exit(diosix_exit);

MODULE_LICENSE("Dual MIT/GPL");
MODULE_AUTHOR("Chris Williams <chrisw@diosix.org>");
MODULE_DESCRIPTION("Diosix Hypervisor Guest Interface Driver");
MODULE_VERSION("1.0");

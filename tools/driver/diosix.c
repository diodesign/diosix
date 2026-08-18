// SPDX-License-Identifier: MIT
/*
 * Diosix Hypervisor Guest Character Driver (/dev/diosix)
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
#include <asm/sbi.h>

#define EXT_DIOSIX 0x0A000005

#define DIOSIX_FUNC_TERMINATE   0
#define DIOSIX_FUNC_EXIT        0
#define DIOSIX_FUNC_YIELD       1
#define DIOSIX_FUNC_FORK        2
#define DIOSIX_FUNC_DROP_TRUST  3
#define DIOSIX_FUNC_SPAWN       4
#define DIOSIX_FUNC_GET_INFO    5
#define DIOSIX_FUNC_SET_QUOTA   6
#define DIOSIX_FUNC_IPC_SEND    7
#define DIOSIX_FUNC_IPC_RECV    8

#define IOCTL_FORK        0x1001
#define IOCTL_DROP_TRUST  0x1002
#define IOCTL_SPAWN       0x1003
#define IOCTL_GET_INFO    0x1004
#define IOCTL_SET_QUOTA   0x1005
#define IOCTL_TERMINATE   0x1006
#define IOCTL_EXIT        0x1006
#define IOCTL_KILL        0x1006
#define IOCTL_YIELD       0x1007

struct spawn_args {
    unsigned long child_id;
    unsigned long elf_ptr;
    unsigned long elf_size;
    unsigned long dtb_ptr;
    unsigned long dtb_size;
    unsigned long target_arch;
};

struct guest_info {
    unsigned long guest_id;
    unsigned long parent_id;
    unsigned char is_trusted;
    unsigned char is_root;
    unsigned char target_arch;
    unsigned char _reserved;
    unsigned long used_ram_pages;
    unsigned long max_ram_pages;
    unsigned long used_vcpus;
    unsigned long max_vcpus;
    unsigned long child_count;
};

static long diosix_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    struct sbiret ret;

    switch (cmd) {
    case IOCTL_FORK: {
        unsigned long child_id;
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_FORK, 0, 0, 0, 0, 0, 0);
        if (ret.error)
            return -EIO;
        child_id = ret.value;
        if (copy_to_user((void __user *)arg, &child_id, sizeof(child_id)))
            return -EFAULT;
        return 0;
    }

    case IOCTL_DROP_TRUST: {
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_DROP_TRUST, 0, 0, 0, 0, 0, 0);
        if (ret.error)
            return -EIO;
        return 0;
    }

    case IOCTL_GET_INFO: {
        struct guest_info *kinfo = kzalloc(sizeof(*kinfo), GFP_KERNEL);
        phys_addr_t pa;
        if (!kinfo)
            return -ENOMEM;
        pa = virt_to_phys(kinfo);
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_GET_INFO, (unsigned long)pa, sizeof(*kinfo), 0, 0, 0, 0);
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

    case IOCTL_SPAWN: {
        struct spawn_args kargs;
        void *elf_kbuf = NULL;
        void *dtb_kbuf = NULL;
        phys_addr_t elf_pa = 0, dtb_pa = 0;
        struct spawn_args *sbi_args = kzalloc(sizeof(*sbi_args), GFP_KERNEL);
        phys_addr_t sbi_args_pa;

        if (!sbi_args)
            return -ENOMEM;

        if (copy_from_user(&kargs, (void __user *)arg, sizeof(kargs))) {
            kfree(sbi_args);
            return -EFAULT;
        }

        if (kargs.elf_size > 0 && kargs.elf_ptr) {
            elf_kbuf = kmalloc(kargs.elf_size, GFP_KERNEL);
            if (!elf_kbuf) {
                kfree(sbi_args);
                return -ENOMEM;
            }
            if (copy_from_user(elf_kbuf, (void __user *)kargs.elf_ptr, kargs.elf_size)) {
                kfree(elf_kbuf);
                kfree(sbi_args);
                return -EFAULT;
            }
            elf_pa = virt_to_phys(elf_kbuf);
        }

        if (kargs.dtb_size > 0 && kargs.dtb_ptr) {
            dtb_kbuf = kmalloc(kargs.dtb_size, GFP_KERNEL);
            if (!dtb_kbuf) {
                if (elf_kbuf) kfree(elf_kbuf);
                kfree(sbi_args);
                return -ENOMEM;
            }
            if (copy_from_user(dtb_kbuf, (void __user *)kargs.dtb_ptr, kargs.dtb_size)) {
                if (elf_kbuf) kfree(elf_kbuf);
                kfree(dtb_kbuf);
                kfree(sbi_args);
                return -EFAULT;
            }
            dtb_pa = virt_to_phys(dtb_kbuf);
        }

        sbi_args->child_id = kargs.child_id;
        sbi_args->elf_ptr = (unsigned long)elf_pa;
        sbi_args->elf_size = kargs.elf_size;
        sbi_args->dtb_ptr = (unsigned long)dtb_pa;
        sbi_args->dtb_size = kargs.dtb_size;
        sbi_args->target_arch = kargs.target_arch;
        sbi_args_pa = virt_to_phys(sbi_args);

        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_SPAWN, (unsigned long)sbi_args_pa, 0, 0, 0, 0, 0);

        if (elf_kbuf) kfree(elf_kbuf);
        if (dtb_kbuf) kfree(dtb_kbuf);
        kfree(sbi_args);

        if (ret.error)
            return -EIO;
        return 0;
    }

    case IOCTL_TERMINATE: {
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_TERMINATE, arg, 0, 0, 0, 0, 0);
        if (ret.error)
            return -EPERM;
        return 0;
    }

    case IOCTL_YIELD: {
        sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_YIELD, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    default:
        return -ENOTTY;
    }
}

static const struct file_operations diosix_fops = {
    .owner          = THIS_MODULE,
    .unlocked_ioctl = diosix_ioctl,
    .compat_ioctl   = diosix_ioctl,
};

static struct miscdevice diosix_dev = {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = "diosix",
    .fops  = &diosix_fops,
    .mode  = 0666,
};

static int __init diosix_init(void)
{
    int ret = misc_register(&diosix_dev);
    if (ret) {
        pr_err("diosix: failed to register /dev/diosix device\n");
        return ret;
    }
    pr_info("diosix: /dev/diosix hypercall bridge registered\n");
    return 0;
}

static void __exit diosix_exit(void)
{
    misc_deregister(&diosix_dev);
    pr_info("diosix: /dev/diosix device unregistered\n");
}

module_init(diosix_init);
module_exit(diosix_exit);

MODULE_LICENSE("Dual MIT/GPL");
MODULE_AUTHOR("Chris Williams <chrisw@diosix.org>");
MODULE_DESCRIPTION("Diosix Hypervisor Guest Interface Driver");
MODULE_VERSION("1.0");

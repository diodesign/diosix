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
        struct guest_info info;
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_GET_INFO, (unsigned long)&info, sizeof(info), 0, 0, 0, 0);
        if (ret.error)
            return -EIO;
        if (copy_to_user((void __user *)arg, &info, sizeof(info)))
            return -EFAULT;
        return 0;
    }

    case IOCTL_SPAWN: {
        struct spawn_args kargs;
        if (copy_from_user(&kargs, (void __user *)arg, sizeof(kargs)))
            return -EFAULT;
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_SPAWN, (unsigned long)&kargs, 0, 0, 0, 0, 0);
        if (ret.error)
            return -EIO;
        return 0;
    }

    case IOCTL_EXIT: {
        sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_EXIT, arg, 0, 0, 0, 0, 0);
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

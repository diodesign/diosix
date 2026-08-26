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
#include <linux/capability.h>
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
#define DIOSIX_FUNC_POLL_EVENT  9
#define DIOSIX_FUNC_GET_HV_INFO 10
#define DIOSIX_FUNC_GET_MANIFEST 11
#define DIOSIX_FUNC_SET_MANIFEST 12

#define IOCTL_FORK        0x1001
#define IOCTL_DROP_TRUST  0x1002
#define IOCTL_SPAWN       0x1003
#define IOCTL_GET_INFO    0x1004
#define IOCTL_SET_QUOTA   0x1005
#define IOCTL_TERMINATE   0x1006
#define IOCTL_EXIT        0x1006
#define IOCTL_KILL        0x1006
#define IOCTL_YIELD       0x1007
#define IOCTL_WAIT_EVENT  0x1008
#define IOCTL_IPC_SEND    0x1009
#define IOCTL_IPC_RECV    0x100A
#define IOCTL_GET_HV_INFO 0x100B
#define IOCTL_GET_MANIFEST 0x100C
#define IOCTL_SET_MANIFEST 0x100D


struct hypervisor_info {
    uint16_t abi_version_major;
    uint16_t abi_version_minor;
    uint16_t abi_version_patch;
    uint16_t version_major;
    uint16_t version_minor;
    uint16_t _reserved0;
    uint32_t _reserved1;
    char     build_commit[16];
    uint64_t features;
    uint32_t host_physical_cores;
    uint32_t host_timer_freq_hz;
    uint64_t host_total_ram_kb;
    uint64_t host_free_ram_kb;
};


struct diosix_event {
    unsigned long cid;
    uint32_t event_type;
    uint32_t exit_code;
    uint64_t _reserved;
};

struct wait_event_args {
    unsigned long target_cid;
    unsigned long flags;
    struct diosix_event event;
};

struct quota_args {
    unsigned long target_cid;
    unsigned long max_ram_pages;
    unsigned long max_vcpus;
    unsigned long max_child_depth;
    unsigned long max_descendants;
};

struct ipc_send_args {
    unsigned long target_cid;
    unsigned long data_ptr;
    unsigned long data_len;
};

struct ipc_recv_args {
    unsigned long sender_cid;
    unsigned long data_ptr;
    unsigned long max_len;
    unsigned long actual_len;
    unsigned long actual_sender_cid;
};

struct manifest_args {
    unsigned long target_cid;
    unsigned long data_ptr;
    unsigned long max_len;
    unsigned long actual_len;
};



struct spawn_args {
    unsigned long child_id;
    unsigned long elf_ptr;
    unsigned long elf_size;
    unsigned long dtb_ptr;
    unsigned long dtb_size;
    unsigned long target_arch;
    unsigned long flags;
};


struct terminate_args {
    unsigned long target_id;
    unsigned long exit_code;
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

static int diosix_open(struct inode *inode, struct file *file)
{
    // Restrict access strictly to root / administrative capabilities
    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;
    return 0;
}

static long diosix_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    struct sbiret ret;

    // Defense-in-depth: enforce root/admin capability for all hypervisor ioctls
    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    switch (cmd) {
    case IOCTL_FORK: {
        unsigned long child_id;
        unsigned long fork_flags = 0;
        if (arg) {
            if (copy_from_user(&fork_flags, (void __user *)arg, sizeof(fork_flags)))
                fork_flags = (unsigned long)arg;
        }
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_FORK, fork_flags, 0, 0, 0, 0, 0);
        if (ret.error)
            return -EIO;
        child_id = ret.value;
        if (arg) {
            if (copy_to_user((void __user *)arg, &child_id, sizeof(child_id))) {
                // If arg was a direct int rather than pointer, ignore fault
            }
        }
        return (int)child_id;
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
        sbi_args->flags = kargs.flags;
        sbi_args_pa = virt_to_phys(sbi_args);


        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_SPAWN, (unsigned long)sbi_args_pa, 0, 0, 0, 0, 0);

        if (elf_kbuf) kfree(elf_kbuf);
        if (dtb_kbuf) kfree(dtb_kbuf);
        kfree(sbi_args);

        if (ret.error)
            return -EIO;

        kargs.child_id = ret.value;
        if (copy_to_user((void __user *)arg, &kargs, sizeof(kargs)))
            return -EFAULT;

        return (int)ret.value;
    }


    case IOCTL_TERMINATE: {
        struct terminate_args targs;
        if (copy_from_user(&targs, (void __user *)arg, sizeof(targs)))
            return -EFAULT;
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_TERMINATE, targs.target_id, targs.exit_code, 0, 0, 0, 0);
        if (ret.error)
            return -EPERM;
        return 0;
    }

    case IOCTL_YIELD: {
        sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_YIELD, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    case IOCTL_WAIT_EVENT: {
        struct wait_event_args wargs;
        struct diosix_event *kev = kzalloc(sizeof(*kev), GFP_KERNEL);
        phys_addr_t pa;
        int ret_val = 0;

        if (!kev)
            return -ENOMEM;

        if (copy_from_user(&wargs, (void __user *)arg, sizeof(wargs))) {
            kfree(kev);
            return -EFAULT;
        }

        pa = virt_to_phys(kev);

        while (1) {
            ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_POLL_EVENT, (unsigned long)pa, sizeof(*kev), 0, 0, 0, 0);
            if (ret.error) {
                ret_val = -EIO;
                break;
            }
            if (ret.value == 1) {
                if (wargs.target_cid == 0 || wargs.target_cid == kev->cid) {
                    memcpy(&wargs.event, kev, sizeof(*kev));
                    if (copy_to_user((void __user *)arg, &wargs, sizeof(wargs))) {
                        ret_val = -EFAULT;
                        break;
                    }
                    ret_val = 0;
                    break;
                }
            } else {
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
        }

        kfree(kev);
        return ret_val;
    }

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
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_SET_QUOTA, (unsigned long)pa, 0, 0, 0, 0, 0);
        kfree(sbi_qargs);

        if (ret.error)
            return -EPERM;
        return 0;
    }

    case IOCTL_IPC_SEND: {
        struct ipc_send_args sargs;
        struct ipc_send_args *sbi_sargs = kzalloc(sizeof(*sbi_sargs), GFP_KERNEL);
        void *kbuf = NULL;
        phys_addr_t pa, kbuf_pa = 0;

        if (!sbi_sargs)
            return -ENOMEM;

        if (copy_from_user(&sargs, (void __user *)arg, sizeof(sargs))) {
            kfree(sbi_sargs);
            return -EFAULT;
        }

        if (sargs.data_len > 0 && sargs.data_ptr) {
            kbuf = kmalloc(sargs.data_len, GFP_KERNEL);
            if (!kbuf) {
                kfree(sbi_sargs);
                return -ENOMEM;
            }
            if (copy_from_user(kbuf, (void __user *)sargs.data_ptr, sargs.data_len)) {
                kfree(kbuf);
                kfree(sbi_sargs);
                return -EFAULT;
            }
            kbuf_pa = virt_to_phys(kbuf);
        }

        sbi_sargs->target_cid = sargs.target_cid;
        sbi_sargs->data_ptr = (unsigned long)kbuf_pa;
        sbi_sargs->data_len = sargs.data_len;
        pa = virt_to_phys(sbi_sargs);

        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_IPC_SEND, (unsigned long)pa, 0, 0, 0, 0, 0);

        if (kbuf) kfree(kbuf);
        kfree(sbi_sargs);

        if (ret.error)
            return -EIO;
        return 0;
    }

    case IOCTL_IPC_RECV: {
        struct ipc_recv_args rargs;
        struct ipc_recv_args *sbi_rargs = kzalloc(sizeof(*sbi_rargs), GFP_KERNEL);
        void *kbuf = NULL;
        phys_addr_t pa, kbuf_pa = 0;

        if (!sbi_rargs)
            return -ENOMEM;

        if (copy_from_user(&rargs, (void __user *)arg, sizeof(rargs))) {
            kfree(sbi_rargs);
            return -EFAULT;
        }

        if (rargs.max_len > 0) {
            kbuf = kzalloc(rargs.max_len, GFP_KERNEL);
            if (!kbuf) {
                kfree(sbi_rargs);
                return -ENOMEM;
            }
            kbuf_pa = virt_to_phys(kbuf);
        }

        sbi_rargs->sender_cid = rargs.sender_cid;
        sbi_rargs->data_ptr = (unsigned long)kbuf_pa;
        sbi_rargs->max_len = rargs.max_len;
        pa = virt_to_phys(sbi_rargs);

        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_IPC_RECV, (unsigned long)pa, 0, 0, 0, 0, 0);

        if (ret.error) {
            if (kbuf) kfree(kbuf);
            kfree(sbi_rargs);
            return -EIO;
        }

        if (ret.value == 1) {
            rargs.actual_len = sbi_rargs->actual_len;
            rargs.actual_sender_cid = sbi_rargs->actual_sender_cid;
            if (rargs.actual_len > 0 && kbuf && rargs.data_ptr) {
                if (copy_to_user((void __user *)rargs.data_ptr, kbuf, rargs.actual_len)) {
                    if (kbuf) kfree(kbuf);
                    kfree(sbi_rargs);
                    return -EFAULT;
                }
            }
            if (copy_to_user((void __user *)arg, &rargs, sizeof(rargs))) {
                if (kbuf) kfree(kbuf);
                kfree(sbi_rargs);
                return -EFAULT;
            }
            if (kbuf) kfree(kbuf);
            kfree(sbi_rargs);
            return 1;
        } else {
            if (kbuf) kfree(kbuf);
            kfree(sbi_rargs);
            return 0;
        }
    }

    case IOCTL_GET_HV_INFO: {
        struct hypervisor_info *hv_info = kzalloc(sizeof(*hv_info), GFP_KERNEL);
        phys_addr_t pa;

        if (!hv_info)
            return -ENOMEM;

        pa = virt_to_phys(hv_info);
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_GET_HV_INFO, (unsigned long)pa, sizeof(*hv_info), 0, 0, 0, 0);

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

    case IOCTL_GET_MANIFEST: {
        struct manifest_args args;
        struct manifest_args *sbi_margs;
        char *kbuf = NULL;
        phys_addr_t margs_pa, kbuf_pa = 0;

        if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
            return -EFAULT;

        if (args.max_len > 64 * 1024)
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
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_GET_MANIFEST, (unsigned long)margs_pa, 0, 0, 0, 0, 0);

        if (ret.error) {
            if (kbuf) kfree(kbuf);
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
            if (kbuf) kfree(kbuf);
            kfree(sbi_margs);
            return -EFAULT;
        }

        if (kbuf) kfree(kbuf);
        kfree(sbi_margs);
        return 0;
    }

    case IOCTL_SET_MANIFEST: {
        struct manifest_args args;
        struct manifest_args *sbi_margs;
        char *kbuf = NULL;
        phys_addr_t margs_pa, kbuf_pa = 0;

        if (!capable(CAP_SYS_ADMIN))
            return -EPERM;

        if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
            return -EFAULT;

        if (args.max_len > 64 * 1024)
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
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_SET_MANIFEST, (unsigned long)margs_pa, 0, 0, 0, 0, 0);

        if (kbuf) kfree(kbuf);
        kfree(sbi_margs);

        if (ret.error)
            return -EIO;

        return 0;
    }

    default:
        return -ENOTTY;
    }



}

static const struct file_operations diosix_fops = {
    .owner          = THIS_MODULE,
    .open           = diosix_open,
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

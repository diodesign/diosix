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
#include <linux/gfp.h>
#include <linux/dma-mapping.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/skbuff.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <asm/sbi.h>

#define EXT_DIOSIX 0x0A000005

#define DIOSIX_FUNC_TERMINATE   0
#define DIOSIX_FUNC_EXIT        0
#define DIOSIX_FUNC_YIELD       1
#define DIOSIX_FUNC_DROP_TRUST  3
#define DIOSIX_FUNC_RUN         4
#define DIOSIX_FUNC_SPAWN       4
#define DIOSIX_FUNC_GET_INFO    5
#define DIOSIX_FUNC_SET_QUOTA   6
#define DIOSIX_FUNC_POLL_EVENT  9
#define DIOSIX_FUNC_GET_HV_INFO 10
#define DIOSIX_FUNC_GET_MANIFEST 11
#define DIOSIX_FUNC_SET_MANIFEST 12
#define DIOSIX_FUNC_MAP_CHILD_MEM   13
#define DIOSIX_FUNC_UNMAP_CHILD_MEM 14
#define DIOSIX_FUNC_START           15
#define DIOSIX_FUNC_NET_SEND        16
#define DIOSIX_FUNC_NET_RECV        17
#define DIOSIX_FUNC_NET_POLL        18

#define IOCTL_DROP_TRUST  0x1002
#define IOCTL_RUN         0x1003
#define IOCTL_SPAWN       0x1003
#define IOCTL_GET_INFO    0x1004
#define IOCTL_SET_QUOTA   0x1005
#define IOCTL_TERMINATE   0x1006
#define IOCTL_EXIT        0x1006
#define IOCTL_KILL        0x1006
#define IOCTL_YIELD       0x1007
#define IOCTL_WAIT_EVENT  0x1008
#define IOCTL_GET_HV_INFO 0x100B
#define IOCTL_GET_MANIFEST 0x100C
#define IOCTL_SET_MANIFEST 0x100D
#define IOCTL_MAP_CHILD_MEM    0x100E
#define IOCTL_UNMAP_CHILD_MEM  0x100F
#define IOCTL_START            0x1010

struct map_child_mem_args {
    unsigned long child_id;
    unsigned long child_gpa;
    unsigned long parent_gpa;
    unsigned long size;
    unsigned long flags;
};

struct unmap_child_mem_args {
    unsigned long parent_gpa;
    unsigned long size;
};

struct start_args {
    unsigned long child_id;
    unsigned long entry_point;
    unsigned long dtb_ptr;
};


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

struct manifest_args {
    unsigned long target_cid;
    unsigned long data_ptr;
    unsigned long max_len;
    unsigned long actual_len;
};



struct run_args {
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
    unsigned char assigned_cid;
    unsigned long vcpus;
    unsigned long self_ram_pages;
    unsigned long used_vcpus;
    unsigned long max_vcpus;
    unsigned long used_ram_pages;
    unsigned long max_ram_pages;
    unsigned long child_count;
};

static struct miscdevice diosix_dev;

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
    case IOCTL_DROP_TRUST: {
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_DROP_TRUST, 0, 0, 0, 0, 0, 0);
        if (ret.error)
            return -EIO;
        return 0;
    }

    case IOCTL_GET_INFO: {
        struct guest_info *kinfo = kzalloc(sizeof(*kinfo), GFP_KERNEL);
        phys_addr_t pa;
        unsigned long target_cid = 1;
        if (!kinfo)
            return -ENOMEM;
        if (copy_from_user(kinfo, (void __user *)arg, sizeof(*kinfo)) == 0) {
            if (kinfo->guest_id > 0) {
                target_cid = kinfo->guest_id;
            }
        }
        pa = virt_to_phys(kinfo);
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_GET_INFO, target_cid, (unsigned long)pa, sizeof(*kinfo), 0, 0, 0);
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

    case IOCTL_RUN: {
        struct run_args kargs;
        void *elf_kbuf = NULL;
        void *dtb_kbuf = NULL;
        phys_addr_t elf_pa = 0, dtb_pa = 0;
        dma_addr_t elf_dma_handle = 0;
        bool elf_is_dma = false;
        struct run_args *sbi_args = kzalloc(sizeof(*sbi_args), GFP_KERNEL);
        phys_addr_t sbi_args_pa;

        if (!sbi_args)
            return -ENOMEM;

        if (copy_from_user(&kargs, (void __user *)arg, sizeof(kargs))) {
            kfree(sbi_args);
            return -EFAULT;
        }

        if (kargs.elf_size > 0 && kargs.elf_ptr) {
            if (kargs.elf_size <= 2 * 1024 * 1024) {
                elf_kbuf = alloc_pages_exact(kargs.elf_size, GFP_KERNEL);
                if (elf_kbuf) {
                    elf_pa = virt_to_phys(elf_kbuf);
                }
            }
            if (!elf_kbuf) {
                elf_kbuf = dma_alloc_coherent(diosix_dev.this_device, kargs.elf_size, &elf_dma_handle, GFP_KERNEL);
                if (elf_kbuf) {
                    elf_is_dma = true;
                    elf_pa = (phys_addr_t)elf_dma_handle;
                }
            }
            if (!elf_kbuf) {
                kfree(sbi_args);
                return -ENOMEM;
            }
            if (copy_from_user(elf_kbuf, (void __user *)kargs.elf_ptr, kargs.elf_size)) {
                if (elf_is_dma) {
                    dma_free_coherent(diosix_dev.this_device, kargs.elf_size, elf_kbuf, elf_dma_handle);
                } else {
                    free_pages_exact(elf_kbuf, kargs.elf_size);
                }
                kfree(sbi_args);
                return -EFAULT;
            }
        }

        if (kargs.dtb_size > 0 && kargs.dtb_ptr) {
            dtb_kbuf = alloc_pages_exact(kargs.dtb_size, GFP_KERNEL);
            if (!dtb_kbuf) {
                if (elf_kbuf) {
                    if (elf_is_dma) dma_free_coherent(diosix_dev.this_device, kargs.elf_size, elf_kbuf, elf_dma_handle);
                    else free_pages_exact(elf_kbuf, kargs.elf_size);
                }
                kfree(sbi_args);
                return -ENOMEM;
            }
            if (copy_from_user(dtb_kbuf, (void __user *)kargs.dtb_ptr, kargs.dtb_size)) {
                if (elf_kbuf) {
                    if (elf_is_dma) dma_free_coherent(diosix_dev.this_device, kargs.elf_size, elf_kbuf, elf_dma_handle);
                    else free_pages_exact(elf_kbuf, kargs.elf_size);
                }
                free_pages_exact(dtb_kbuf, kargs.dtb_size);
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

        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_RUN, (unsigned long)sbi_args_pa, 0, 0, 0, 0, 0);

        if (elf_kbuf) {
            if (elf_is_dma) dma_free_coherent(diosix_dev.this_device, kargs.elf_size, elf_kbuf, elf_dma_handle);
            else free_pages_exact(elf_kbuf, kargs.elf_size);
        }
        if (dtb_kbuf) free_pages_exact(dtb_kbuf, kargs.dtb_size);
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

    case IOCTL_MAP_CHILD_MEM: {
        struct map_child_mem_args args;
        struct map_child_mem_args *sbi_margs;
        phys_addr_t margs_pa;

        if (!capable(CAP_SYS_ADMIN))
            return -EPERM;

        if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
            return -EFAULT;

        if (args.parent_gpa == 0)
            args.parent_gpa = 0x200000000UL;

        sbi_margs = kzalloc(sizeof(*sbi_margs), GFP_KERNEL);
        if (!sbi_margs)
            return -ENOMEM;

        memcpy(sbi_margs, &args, sizeof(args));
        margs_pa = virt_to_phys(sbi_margs);
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_MAP_CHILD_MEM, (unsigned long)margs_pa, 0, 0, 0, 0, 0);
        kfree(sbi_margs);

        if (ret.error)
            return -EIO;

        if (copy_to_user((void __user *)arg, &args, sizeof(args)))
            return -EFAULT;

        return 0;
    }

    case IOCTL_UNMAP_CHILD_MEM: {
        struct unmap_child_mem_args args;
        struct unmap_child_mem_args *sbi_uargs;
        phys_addr_t uargs_pa;

        if (!capable(CAP_SYS_ADMIN))
            return -EPERM;

        if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
            return -EFAULT;

        if (args.parent_gpa == 0)
            args.parent_gpa = 0x200000000UL;

        sbi_uargs = kzalloc(sizeof(*sbi_uargs), GFP_KERNEL);
        if (!sbi_uargs)
            return -ENOMEM;

        memcpy(sbi_uargs, &args, sizeof(args));
        uargs_pa = virt_to_phys(sbi_uargs);
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_UNMAP_CHILD_MEM, (unsigned long)uargs_pa, 0, 0, 0, 0, 0);
        kfree(sbi_uargs);

        if (ret.error)
            return -EIO;

        return 0;
    }

    case IOCTL_START: {
        struct start_args args;
        struct start_args *sbi_sargs;
        phys_addr_t sargs_pa;

        if (!capable(CAP_SYS_ADMIN))
            return -EPERM;

        if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
            return -EFAULT;

        sbi_sargs = kzalloc(sizeof(*sbi_sargs), GFP_KERNEL);
        if (!sbi_sargs)
            return -ENOMEM;

        memcpy(sbi_sargs, &args, sizeof(args));
        sargs_pa = virt_to_phys(sbi_sargs);
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_START, (unsigned long)sargs_pa, 0, 0, 0, 0, 0);

        kfree(sbi_sargs);

        if (ret.error)
            return -EIO;

        return (int)ret.value;
    }

    default:
        return -ENOTTY;
    }
}

static int diosix_mmap(struct file *file, struct vm_area_struct *vma)
{
    unsigned long size = vma->vm_end - vma->vm_start;
    unsigned long pfn = vma->vm_pgoff;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    if (pfn == 0)
        pfn = 0x200000000UL >> PAGE_SHIFT;

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

struct diosix_net_priv {
    struct net_device *netdev;
    struct task_struct *rx_kthread;
    unsigned long self_cid;
    struct net_device_stats stats;
};

static struct net_device *diosix_netdev = NULL;

static int diosix_net_open(struct net_device *dev)
{
    netif_start_queue(dev);
    return 0;
}

static int diosix_net_stop(struct net_device *dev)
{
    netif_stop_queue(dev);
    return 0;
}

static netdev_tx_t diosix_net_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct diosix_net_priv *priv = netdev_priv(dev);
    unsigned long dest_cid = 0;
    struct sbiret ret;
    phys_addr_t pa;
    void *kbuf;

    if (skb->len > 1536) {
        dev_kfree_skb(skb);
        priv->stats.tx_dropped++;
        return NETDEV_TX_OK;
    }

    if (skb->len >= 14) {
        const unsigned char *dest_mac = skb->data;
        if (dest_mac[0] == 0x02 && dest_mac[1] == 0x00 && dest_mac[2] == 0x00 &&
            dest_mac[3] == 0x00 && dest_mac[4] == 0x00) {
            dest_cid = dest_mac[5];
        } else if ((dest_mac[0] & 1) != 0) {
            dest_cid = 0;
        }
    }

    kbuf = kmalloc(skb->len, GFP_ATOMIC);
    if (!kbuf) {
        dev_kfree_skb(skb);
        priv->stats.tx_dropped++;
        return NETDEV_TX_OK;
    }
    memcpy(kbuf, skb->data, skb->len);
    pa = virt_to_phys(kbuf);

    ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_NET_SEND, (unsigned long)pa, skb->len, dest_cid, 0, 0, 0);
    kfree(kbuf);

    if (ret.error == 0) {
        priv->stats.tx_packets++;
        priv->stats.tx_bytes += skb->len;
    } else {
        priv->stats.tx_errors++;
    }

    dev_kfree_skb(skb);
    return NETDEV_TX_OK;
}

static struct net_device_stats *diosix_net_get_stats(struct net_device *dev)
{
    struct diosix_net_priv *priv = netdev_priv(dev);
    return &priv->stats;
}

static const struct net_device_ops diosix_netdev_ops = {
    .ndo_open       = diosix_net_open,
    .ndo_stop       = diosix_net_stop,
    .ndo_start_xmit = diosix_net_xmit,
    .ndo_get_stats  = diosix_net_get_stats,
};

static int diosix_net_rx_worker(void *data)
{
    struct net_device *dev = data;
    struct diosix_net_priv *priv = netdev_priv(dev);
    void *rx_buf = kmalloc(1536, GFP_KERNEL);
    phys_addr_t rx_pa;

    if (!rx_buf)
        return -ENOMEM;

    rx_pa = virt_to_phys(rx_buf);

    while (!kthread_should_stop()) {
        struct sbiret ret;
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_NET_RECV, (unsigned long)rx_pa, 1536, 0, 0, 0, 0);
        if (ret.error == 0 && ret.value > 0) {
            unsigned long pkt_len = ret.value;
            struct sk_buff *skb = netdev_alloc_skb(dev, pkt_len + 2);
            if (skb) {
                skb_reserve(skb, 2);
                memcpy(skb_put(skb, pkt_len), rx_buf, pkt_len);
                skb->protocol = eth_type_trans(skb, dev);
                skb->ip_summed = CHECKSUM_UNNECESSARY;
                netif_rx(skb);
                priv->stats.rx_packets++;
                priv->stats.rx_bytes += pkt_len;
            } else {
                priv->stats.rx_dropped++;
            }
            continue;
        }

        usleep_range(500, 1000);
    }

    kfree(rx_buf);
    return 0;
}

static int init_diosix_net(void)
{
    struct net_device *dev;
    struct diosix_net_priv *priv;
    struct sbiret ret;
    struct guest_info *info;
    unsigned long self_cid = 1;
    phys_addr_t info_pa;
    int err;

    info = kzalloc(sizeof(*info), GFP_KERNEL);
    if (info) {
        info_pa = virt_to_phys(info);
        ret = sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_GET_INFO, 1, (unsigned long)info_pa, sizeof(*info), 0, 0, 0);
        if (ret.error == 0) {
            self_cid = (info->assigned_cid > 0) ? info->assigned_cid : 1;
        }
        kfree(info);
    }

    dev = alloc_etherdev(sizeof(struct diosix_net_priv));
    if (!dev)
        return -ENOMEM;

    strcpy(dev->name, "diosix0");
    dev->netdev_ops = &diosix_netdev_ops;
    dev->flags |= IFF_BROADCAST | IFF_MULTICAST;

    {
        u8 mac_addr[ETH_ALEN] = { 0x02, 0x00, 0x00, 0x00, 0x00, (u8)(self_cid & 0xff) };
        eth_hw_addr_set(dev, mac_addr);
    }

    priv = netdev_priv(dev);
    priv->netdev = dev;
    priv->self_cid = self_cid;

    err = register_netdev(dev);
    if (err) {
        free_netdev(dev);
        return err;
    }

    diosix_netdev = dev;
    priv->rx_kthread = kthread_run(diosix_net_rx_worker, dev, "diosix_net_rx");

    pr_info("diosix: virtual network device 'diosix0' registered (CID %lu, MAC %02x:%02x:%02x:%02x:%02x:%02x)\n",
            self_cid, dev->dev_addr[0], dev->dev_addr[1], dev->dev_addr[2], dev->dev_addr[3], dev->dev_addr[4], dev->dev_addr[5]);

    return 0;
}

static void cleanup_diosix_net(void)
{
    if (diosix_netdev) {
        struct diosix_net_priv *priv = netdev_priv(diosix_netdev);
        if (priv->rx_kthread) {
            kthread_stop(priv->rx_kthread);
        }
        unregister_netdev(diosix_netdev);
        free_netdev(diosix_netdev);
        diosix_netdev = NULL;
    }
}

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

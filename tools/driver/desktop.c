// SPDX-License-Identifier: MIT
/*
 * Diosix Hypervisor Guest Desktop Display & Input Ioctl Bridge.
 *
 * Bridges VirtIO-GPU 2D scanout readout (zero-copy pinned user pages) and
 * VirtIO-Input batched evdev injection between Root VM userspace (diosix-gui)
 * and M-mode SBI hypercalls.
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 */

#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/mutex.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/capability.h>
#include <linux/limits.h>
#include <asm/sbi.h>

#include "diosix.h"

#define PIXEL_ALIGN_MASK 0x3UL

static DEFINE_MUTEX(diosix_scanout_mutex);
static struct file *diosix_scanout_owner;

static long handle_gpu_read_scanout(unsigned long arg)
{
    struct gpu_scanout_args args;
    struct gpu_scanout_args *sbi_args;
    struct page **pages = NULL;
    uint64_t *gpa_list = NULL;
    size_t gpa_list_bytes = 0;
    uint64_t user_pixels_ptr;
    uint64_t old_frame_seq;
    uint64_t total_px;
    size_t byte_len;
    unsigned long first_off;
    unsigned long start_uaddr;
    unsigned long nr_pages;
    unsigned long i;
    int pinned = 0;
    struct sbiret ret;
    long rc = 0;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;
    if (copy_from_user(&args, (void __user *)arg, sizeof(args)))
        return -EFAULT;

    user_pixels_ptr = args.pixels_ptr;
    old_frame_seq = args.frame_seq;

    sbi_args = kzalloc(sizeof(*sbi_args), GFP_KERNEL);
    if (!sbi_args)
        return -ENOMEM;

    /* Probe scanout dimensions and frame sequence before pinning pages. */
    sbi_args->target_cid = args.target_cid;
    sbi_args->pixels_ptr = 0;
    sbi_args->frame_seq = old_frame_seq;
    if (args.flags & DIOSIX_GPU_SCANOUT_SET_SIZE) {
        sbi_args->width = args.width;
        sbi_args->height = args.height;
        sbi_args->flags = DIOSIX_GPU_SCANOUT_SET_SIZE;
    }
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_GPU_READ_SCANOUT,
        (unsigned long)virt_to_phys(sbi_args),
        0, 0, 0, 0, 0
    );
    if (ret.error) {
        rc = diosix_sbi_to_errno(ret.error);
        goto out;
    }

    if (ret.value == 0 || !user_pixels_ptr) {
        args.width = sbi_args->width;
        args.height = sbi_args->height;
        args.flags = sbi_args->flags;
        args.frame_seq = sbi_args->frame_seq;
        args.pixels_ptr = user_pixels_ptr;
        if (copy_to_user((void __user *)arg, &args, sizeof(args)))
            rc = -EFAULT;
        goto out;
    }

    if (user_pixels_ptr & PIXEL_ALIGN_MASK) {
        rc = -EINVAL;
        goto out;
    }

    total_px = (uint64_t)sbi_args->width * (uint64_t)sbi_args->height;
    if (total_px == 0 || total_px > DIOSIX_MAX_GPU_PIXELS ||
        args.max_pixels < total_px) {
        /* Report new dimensions without advancing caller frame_seq. */
        args.width = sbi_args->width;
        args.height = sbi_args->height;
        args.flags = sbi_args->flags & ~DIOSIX_GPU_SCANOUT_UPDATED;
        args.frame_seq = old_frame_seq;
        args.pixels_ptr = user_pixels_ptr;
        if (copy_to_user((void __user *)arg, &args, sizeof(args)))
            rc = -EFAULT;
        goto out;
    }

    byte_len = (size_t)(total_px * sizeof(uint32_t));
    if (user_pixels_ptr > ULONG_MAX - byte_len) {
        rc = -EFAULT;
        goto out;
    }

    first_off = (unsigned long)(user_pixels_ptr & ~PAGE_MASK);
    start_uaddr = (unsigned long)(user_pixels_ptr & PAGE_MASK);
    nr_pages = DIV_ROUND_UP(first_off + byte_len, PAGE_SIZE);
    if (nr_pages == 0 || nr_pages > DIOSIX_MAX_GPU_SCANOUT_PAGES) {
        rc = -EINVAL;
        goto out;
    }

    pages = kvmalloc_array(nr_pages, sizeof(struct page *), GFP_KERNEL);
    if (!pages) {
        rc = -ENOMEM;
        goto out;
    }

    gpa_list_bytes = nr_pages * sizeof(uint64_t);
    gpa_list = alloc_pages_exact(gpa_list_bytes, GFP_KERNEL);
    if (!gpa_list) {
        rc = -ENOMEM;
        goto out;
    }

    pinned = pin_user_pages_fast(start_uaddr, (int)nr_pages, FOLL_WRITE, pages);
    if (pinned < 0) {
        rc = pinned;
        pinned = 0;
        goto out;
    }
    if ((unsigned long)pinned < nr_pages) {
        rc = -EFAULT;
        goto out;
    }

    for (i = 0; i < nr_pages; i++)
        gpa_list[i] = (uint64_t)page_to_phys(pages[i]);

    memset(sbi_args, 0, sizeof(*sbi_args));
    sbi_args->target_cid = args.target_cid;
    sbi_args->pixels_ptr = (uint64_t)virt_to_phys(gpa_list);
    sbi_args->page_count = (uint32_t)nr_pages;
    sbi_args->first_page_offset = (uint32_t)first_off;
    sbi_args->max_pixels = (uint32_t)total_px;
    sbi_args->frame_seq = old_frame_seq;

    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_GPU_READ_SCANOUT,
        (unsigned long)virt_to_phys(sbi_args),
        0, 0, 0, 0, 0
    );

    unpin_user_pages_dirty_lock(pages, pinned, true);
    pinned = 0;

    if (ret.error) {
        rc = diosix_sbi_to_errno(ret.error);
        goto out;
    }

    args.width = sbi_args->width;
    args.height = sbi_args->height;
    args.flags = sbi_args->flags;
    args.frame_seq = sbi_args->frame_seq;
    args.pixels_ptr = user_pixels_ptr;
    if (copy_to_user((void __user *)arg, &args, sizeof(args)))
        rc = -EFAULT;

out:
    if (pinned > 0)
        unpin_user_pages(pages, pinned);
    if (gpa_list)
        free_pages_exact(gpa_list, gpa_list_bytes);
    kvfree(pages);
    kfree(sbi_args);
    return rc;
}

static long handle_input_send_event(unsigned long arg)
{
    struct input_event_args *kargs;
    struct sbiret ret;
    long rc;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    kargs = kzalloc(sizeof(*kargs), GFP_KERNEL);
    if (!kargs)
        return -ENOMEM;

    if (copy_from_user(kargs, (void __user *)arg, sizeof(*kargs))) {
        kfree(kargs);
        return -EFAULT;
    }
    if (kargs->count > DIOSIX_MAX_INPUT_BATCH_EVENTS) {
        kfree(kargs);
        return -EINVAL;
    }

    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_INPUT_SEND_EVENT,
        (unsigned long)virt_to_phys(kargs),
        0, 0, 0, 0, 0
    );
    rc = ret.error ? diosix_sbi_to_errno(ret.error) : 0;
    kfree(kargs);
    return rc;
}

int diosix_mmap_scanout(struct file *file, struct vm_area_struct *vma)
{
    unsigned long pfn = vma->vm_pgoff;
    unsigned long size = vma->vm_end - vma->vm_start;
    unsigned long base_pfn = DIOSIX_SCANOUT_MAP_BASE >> PAGE_SHIFT;
    unsigned long max_pfn =
        (DIOSIX_SCANOUT_MAP_BASE + DIOSIX_SCANOUT_APERTURE_SIZE) >> PAGE_SHIFT;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;
    if (vma->vm_flags & VM_WRITE)
        return -EPERM;
    if (size == 0 || size > DIOSIX_SCANOUT_APERTURE_SIZE ||
        (size & (PAGE_SIZE - 1)) != 0 || pfn < base_pfn || pfn >= max_pfn ||
        (size >> PAGE_SHIFT) > (max_pfn - pfn))
        return -EINVAL;

    vm_flags_clear(vma, VM_MAYWRITE | VM_MAYEXEC);
    vm_flags_set(vma, VM_IO | VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP);

    mutex_lock(&diosix_scanout_mutex);
    if (diosix_scanout_owner && diosix_scanout_owner != file) {
        mutex_unlock(&diosix_scanout_mutex);
        return -EBUSY;
    }
    if (remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot)) {
        mutex_unlock(&diosix_scanout_mutex);
        return -EAGAIN;
    }
    diosix_scanout_owner = file;
    mutex_unlock(&diosix_scanout_mutex);
    return 0;
}

void diosix_release_desktop(struct file *file)
{
    mutex_lock(&diosix_scanout_mutex);
    if (diosix_scanout_owner == file) {
        struct gpu_map_scanout_args *uargs =
            kzalloc(sizeof(*uargs), GFP_KERNEL);
        if (uargs) {
            uargs->target_cid = 0;
            uargs->flags = DIOSIX_GPU_SCANOUT_UNMAP;
            sbi_ecall(EXT_DIOSIX, DIOSIX_FUNC_GPU_MAP_SCANOUT,
                      (unsigned long)virt_to_phys(uargs), 0, 0, 0, 0, 0);
            kfree(uargs);
        }
        diosix_scanout_owner = NULL;
    }
    mutex_unlock(&diosix_scanout_mutex);
}

static long handle_gpu_map_scanout(struct file *file, unsigned long arg)
{
    struct gpu_map_scanout_args *sbi_args;
    void *cursor_kbuf = NULL;
    uint64_t user_cursor_ptr;
    struct sbiret ret;
    long rc = 0;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;

    sbi_args = kzalloc(sizeof(*sbi_args), GFP_KERNEL);
    if (!sbi_args)
        return -ENOMEM;

    if (copy_from_user(sbi_args, (void __user *)arg, sizeof(*sbi_args))) {
        rc = -EFAULT;
        goto out;
    }

    user_cursor_ptr = sbi_args->cursor_pixels_ptr;
    if (user_cursor_ptr != 0) {
        if (!access_ok((void __user *)(unsigned long)user_cursor_ptr,
                       DIOSIX_CURSOR_MAX_BYTES)) {
            rc = -EFAULT;
            goto out;
        }
        cursor_kbuf = kzalloc(DIOSIX_CURSOR_MAX_BYTES, GFP_KERNEL);
        if (!cursor_kbuf) {
            rc = -ENOMEM;
            goto out;
        }
        sbi_args->cursor_pixels_ptr = (uint64_t)virt_to_phys(cursor_kbuf);
    }

    mutex_lock(&diosix_scanout_mutex);
    if (!(sbi_args->flags & DIOSIX_GPU_SCANOUT_UNMAP) &&
        diosix_scanout_owner && diosix_scanout_owner != file) {
        mutex_unlock(&diosix_scanout_mutex);
        rc = -EBUSY;
        goto out;
    }
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_GPU_MAP_SCANOUT,
        (unsigned long)virt_to_phys(sbi_args),
        0, 0, 0, 0, 0
    );
    mutex_unlock(&diosix_scanout_mutex);

    if (ret.error) {
        rc = diosix_sbi_to_errno(ret.error);
        goto out;
    }

    if (cursor_kbuf && (sbi_args->flags & DIOSIX_GPU_SCANOUT_CURSOR_UPD)) {
        if (copy_to_user((void __user *)(unsigned long)user_cursor_ptr,
                         cursor_kbuf, DIOSIX_CURSOR_MAX_BYTES)) {
            rc = -EFAULT;
            goto out;
        }
    }

    sbi_args->cursor_pixels_ptr = user_cursor_ptr;
    if (copy_to_user((void __user *)arg, sbi_args, sizeof(*sbi_args)))
        rc = -EFAULT;

out:
    kfree(cursor_kbuf);
    kfree(sbi_args);
    return rc;
}

long diosix_ioctl_desktop(
    struct file *file,
    unsigned int cmd,
    unsigned long arg
)
{
    switch (cmd) {
    case IOCTL_GPU_READ_SCANOUT:
        return handle_gpu_read_scanout(arg);
    case IOCTL_GPU_MAP_SCANOUT:
        return handle_gpu_map_scanout(file, arg);
    case IOCTL_INPUT_SEND_EVENT:
        return handle_input_send_event(arg);
    default:
        return -ENOTTY;
    }
}

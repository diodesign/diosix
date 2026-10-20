// SPDX-License-Identifier: MIT
/*
 * Diosix Hypervisor Virtual Network Device (diosix0).
 *
 * Bridges guest Ethernet frames across the hypervisor's Vsock inter-VM
 * transport channel.
 *
 * Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
 */

#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/io.h>
#include <linux/gfp.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/skbuff.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <asm/sbi.h>

#include "diosix.h"

struct diosix_net_priv {
    struct net_device *netdev;
    struct task_struct *rx_kthread;
    void *rx_buf;
    unsigned long self_cid;
    struct net_device_stats stats;
};

static struct net_device *diosix_netdev;

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
    unsigned long dest_cid = DIOSIX_CID_PARENT;
    unsigned char dest_mac[ETH_ALEN];
    struct sbiret ret;
    phys_addr_t pa;
    void *kbuf;

    if (skb->len == 0 || skb->len > DIOSIX_NET_MAX_FRAME_SIZE) {
        dev_kfree_skb(skb);
        priv->stats.tx_dropped++;
        return NETDEV_TX_OK;
    }

    /*
     * Peer VMs use synthetic MAC 02:00:00:00:XX:YY encoding their 16-bit CID.
     * Broadcast/multicast frames and upstream gateway frames route via
     * DIOSIX_CID_PARENT (0).
     */
    if (skb->len >= ETH_HLEN &&
        skb_copy_bits(skb, 0, dest_mac, ETH_ALEN) == 0) {
        if ((dest_mac[0] & 1) == 0 &&
            dest_mac[0] == DIOSIX_MAC_PREFIX_BYTE0 &&
            dest_mac[1] == 0x00 && dest_mac[2] == 0x00 &&
            dest_mac[3] == 0x00) {
            dest_cid = ((unsigned long)dest_mac[4] << 8) |
                       (unsigned long)dest_mac[5];
        } else {
            dest_cid = DIOSIX_CID_PARENT;
        }
    }

    kbuf = kmalloc(skb->len, GFP_ATOMIC);
    if (!kbuf) {
        dev_kfree_skb(skb);
        priv->stats.tx_dropped++;
        return NETDEV_TX_OK;
    }

    if (skb_copy_bits(skb, 0, kbuf, skb->len) != 0) {
        kfree(kbuf);
        dev_kfree_skb(skb);
        priv->stats.tx_dropped++;
        return NETDEV_TX_OK;
    }

    pa = virt_to_phys(kbuf);
    ret = sbi_ecall(
        EXT_DIOSIX,
        DIOSIX_FUNC_NET_SEND,
        (unsigned long)pa,
        skb->len,
        dest_cid,
        0,
        0,
        0
    );
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
    void *rx_buf = priv->rx_buf;
    phys_addr_t rx_pa = virt_to_phys(rx_buf);
    int idle_count = 0;

    while (!kthread_should_stop()) {
        struct sbiret ret = sbi_ecall(
            EXT_DIOSIX,
            DIOSIX_FUNC_NET_RECV,
            (unsigned long)rx_pa,
            DIOSIX_NET_MAX_FRAME_SIZE,
            0,
            0,
            0,
            0
        );
        if (ret.error == 0 && ret.value > 0) {
            unsigned long pkt_len = ret.value;
            struct sk_buff *skb;
            if (pkt_len > DIOSIX_NET_MAX_FRAME_SIZE) {
                idle_count = 0;
                continue;
            }
            skb = netdev_alloc_skb(dev, pkt_len + NET_IP_ALIGN);
            if (skb) {
                skb_reserve(skb, NET_IP_ALIGN);
                memcpy(skb_put(skb, pkt_len), rx_buf, pkt_len);
                skb->protocol = eth_type_trans(skb, dev);
                skb->ip_summed = CHECKSUM_UNNECESSARY;
                netif_rx(skb);
                priv->stats.rx_packets++;
                priv->stats.rx_bytes += pkt_len;
            } else {
                priv->stats.rx_dropped++;
            }
            idle_count = 0;
            continue;
        }

        idle_count++;
        if (idle_count < 64) {
            cpu_relax();
        } else if (idle_count < 256) {
            usleep_range(10, 25);
        } else {
            usleep_range(50, 100);
        }
    }

    return 0;
}

int init_diosix_net(void)
{
    struct net_device *dev;
    struct diosix_net_priv *priv;
    struct sbiret ret;
    struct guest_info *info;
    unsigned long self_cid = DIOSIX_CID_SELF;
    phys_addr_t info_pa;
    u8 mac_addr[ETH_ALEN];
    int err;

    info = kzalloc(sizeof(*info), GFP_KERNEL);
    if (info) {
        info_pa = virt_to_phys(info);
        ret = sbi_ecall(
            EXT_DIOSIX,
            DIOSIX_FUNC_GET_INFO,
            DIOSIX_CID_SELF,
            (unsigned long)info_pa,
            sizeof(*info),
            0,
            0,
            0
        );
        if (ret.error == 0) {
            if (info->assigned_cid > 0)
                self_cid = info->assigned_cid;
            else if (info->guest_id > 0)
                self_cid = info->guest_id;
        }
        kfree(info);
    }

    dev = alloc_etherdev(sizeof(struct diosix_net_priv));
    if (!dev)
        return -ENOMEM;

    strscpy(dev->name, "diosix0", IFNAMSIZ);
    dev->netdev_ops = &diosix_netdev_ops;
    dev->flags |= IFF_BROADCAST | IFF_MULTICAST;

    mac_addr[0] = DIOSIX_MAC_PREFIX_BYTE0;
    mac_addr[1] = 0x00;
    mac_addr[2] = 0x00;
    mac_addr[3] = 0x00;
    mac_addr[4] = (u8)((self_cid >> 8) & 0xff);
    mac_addr[5] = (u8)(self_cid & 0xff);
    eth_hw_addr_set(dev, mac_addr);

    priv = netdev_priv(dev);
    priv->netdev = dev;
    priv->self_cid = self_cid;
    priv->rx_buf = kmalloc(DIOSIX_NET_MAX_FRAME_SIZE, GFP_KERNEL);
    if (!priv->rx_buf) {
        free_netdev(dev);
        return -ENOMEM;
    }

    err = register_netdev(dev);
    if (err) {
        kfree(priv->rx_buf);
        free_netdev(dev);
        return err;
    }

    diosix_netdev = dev;
    priv->rx_kthread = kthread_run(diosix_net_rx_worker, dev, "diosix_net_rx");
    if (IS_ERR(priv->rx_kthread)) {
        err = PTR_ERR(priv->rx_kthread);
        priv->rx_kthread = NULL;
        unregister_netdev(dev);
        kfree(priv->rx_buf);
        free_netdev(dev);
        diosix_netdev = NULL;
        return err;
    }

    pr_info(
        "diosix: virtual network device 'diosix0' registered "
        "(CID %lu, MAC %02x:%02x:%02x:%02x:%02x:%02x)\n",
        self_cid,
        dev->dev_addr[0],
        dev->dev_addr[1],
        dev->dev_addr[2],
        dev->dev_addr[3],
        dev->dev_addr[4],
        dev->dev_addr[5]
    );

    return 0;
}

void cleanup_diosix_net(void)
{
    if (diosix_netdev) {
        struct diosix_net_priv *priv = netdev_priv(diosix_netdev);
        if (priv->rx_kthread) {
            kthread_stop(priv->rx_kthread);
            priv->rx_kthread = NULL;
        }
        unregister_netdev(diosix_netdev);
        kfree(priv->rx_buf);
        free_netdev(diosix_netdev);
        diosix_netdev = NULL;
    }
}

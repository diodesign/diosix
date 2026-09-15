// ALSA soundcard initialization utility for Diosix Root VM
// Sets Master Playback Volume to 100% and un-mutes playback switches on boot.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sound/asound.h>

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;

    // Retry opening control device for up to 3 seconds as drivers initialize
    int fd = -1;
    for (int attempts = 0; attempts < 30; attempts++) {
        fd = open("/dev/snd/controlC0", O_RDWR);
        if (fd >= 0) break;
        usleep(100000); // 100ms
    }

    if (fd < 0) {
        // Sound card not present on this machine (or non-audio profile)
        return 0;
    }

    struct snd_ctl_elem_list list;
    memset(&list, 0, sizeof(list));
    if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0 || list.count == 0) {
        close(fd);
        return 0;
    }

    struct snd_ctl_elem_id *pids = calloc(list.count, sizeof(struct snd_ctl_elem_id));
    if (!pids) {
        close(fd);
        return 1;
    }

    list.space = list.count;
    list.pids = pids;
    if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0) {
        free(pids);
        close(fd);
        return 1;
    }

    for (unsigned int i = 0; i < list.used; i++) {
        struct snd_ctl_elem_info info;
        memset(&info, 0, sizeof(info));
        info.id = pids[i];
        if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info) < 0) {
            continue;
        }

        struct snd_ctl_elem_value val;
        memset(&val, 0, sizeof(val));
        val.id = pids[i];
        if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, &val) < 0) {
            continue;
        }

        // Unmute playback switches
        if (info.type == SNDRV_CTL_ELEM_TYPE_BOOLEAN &&
            strstr((const char *)info.id.name, "Playback Switch")) {
            for (unsigned int c = 0; c < info.count; c++) {
                val.value.integer.value[c] = 1;
            }
            ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &val);
        }

        // Maximize playback volume controls
        if (info.type == SNDRV_CTL_ELEM_TYPE_INTEGER &&
            strstr((const char *)info.id.name, "Playback Volume")) {
            for (unsigned int c = 0; c < info.count; c++) {
                val.value.integer.value[c] = info.value.integer.max;
            }
            ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &val);
        }
    }

    free(pids);
    close(fd);
    return 0;
}

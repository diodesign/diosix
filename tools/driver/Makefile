# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
obj-m := diosix_drv.o
diosix_drv-objs := diosix.o governance.o net.o

ccflags-y += -I$(src)

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
	cp -f diosix_drv.ko diosix.ko 2>/dev/null || true

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
	rm -f diosix.ko


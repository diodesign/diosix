# SPDX-License-Identifier: MIT
obj-m := diosix_drv.o
diosix_drv-objs := diosix.o governance.o net.o

ccflags-y += -I$(src)

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean


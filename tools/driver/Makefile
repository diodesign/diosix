# SPDX-License-Identifier: MIT
obj-m := diosix.o

ccflags-y += -I$(src)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

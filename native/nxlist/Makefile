###########################################################
# nxlist - built inside the NX Redux workspace as workspace/all/nxlist
# (mirrors workspace/all/extras/Makefile, the simplest tool pak app)

ifeq (,$(PLATFORM))
PLATFORM=$(UNION_PLATFORM)
endif

ifeq (,$(PLATFORM))
	$(error please specify PLATFORM, eg. PLATFORM=tg5050 make)
endif

ifeq (,$(CROSS_COMPILE))
	$(error missing CROSS_COMPILE for this toolchain)
endif

###########################################################

include ../../$(PLATFORM)/platform/Makefile.env

BUILD_SUBDIR ?= $(PLATFORM)
SDL?=SDL

###########################################################

TARGET = nxlist

INCDIR = -I. -I../common/ -I../../$(PLATFORM)/platform/
include ../common/ui/ui.mk
SOURCE = nxlist.c \
         ../common/utils.c ../common/api.c ../common/text_shape.c ../common/audio_manager.c \
         ../common/config.c ../common/scaler.c ../common/wget_fetch.c \
         $(UI_COMPONENT_SRCS) $(UI_DIR)/ui_list.c $(UI_LISTVIEW_SRCS) \
         ../common/paths.c \
         ../../$(PLATFORM)/platform/platform.c

CC = $(CROSS_COMPILE)gcc
CFLAGS  += $(OPT)
CFLAGS  += $(INCDIR) -I../../$(PLATFORM)/libmsettings -DPLATFORM=\"$(PLATFORM)\" -std=gnu99
LDFLAGS	 += -L../../$(PLATFORM)/libmsettings -lmsettings -lSDL2_image -lSDL2_ttf -lm -ldl -lz -lpthread

PRODUCT= build/$(BUILD_SUBDIR)/$(TARGET).elf

all: $(PREFIX_LOCAL)/include/msettings.h
	mkdir -p build/$(BUILD_SUBDIR)
	$(CC) $(SOURCE) -o $(PRODUCT) $(CFLAGS) $(LDFLAGS)

$(PREFIX_LOCAL)/include/msettings.h:
	cd ../../$(PLATFORM)/libmsettings && make

clean:
	rm -f $(PRODUCT)

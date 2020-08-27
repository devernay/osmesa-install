OSMESA_PATH=/opt/osmesa
LLVM_PATH=/opt/llvm

CFLAGS=-g -pthread
CPPFLAGS=-I$(OSMESA_PATH)/include -USAVE_TARGA
LDFLAGS=-L$(OSMESA_PATH)/lib

LIBADD=-lm

LLVM_LIBS=`$(LLVM_PATH)/bin/llvm-config  --ldflags --libs --system-libs --libs engine`

LIBS=-lGLU -lOSMesa32 $(LLVM_LIBS)

CPPFLAGS_MANGLED=$(CPPFLAGS) -include $(OSMESA_PATH)/include/GL/gl_mangle.h -include $(OSMESA_PATH)/include/GL/glu_mangle.h

LIBS_MANGLED=-lMangledGLU -lMangledOSMesa32 $(LLVM_LIBS)

BINARIES_MANGLED=osdemo-mangled osdemo16-mangled osdemo32-mangled
BINARIES_NONMANGLED=osdemo osdemo16 osdemo32

.PHONY: all mangled nonmangled

all: mangled nonmangled

mangled: $(BINARIES_MANGLED)

nonmangled: $(BINARIES_NONMANGLED)

osdemo-mangled: osdemo.c
	$(CXX) $(CPPFLAGS_MANGLED) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LIBS_MANGLED)

osdemo: osdemo.c
	$(CXX) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LIBS)

osdemo16-mangled: osdemo16.c
	$(CXX) $(CPPFLAGS_MANGLED) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LIBS_MANGLED)

osdemo16: osdemo16.c
	$(CXX) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LIBS)

osdemo32-mangled: osdemo32.c
	$(CXX) $(CPPFLAGS_MANGLED) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LIBS_MANGLED)

osdemo32: osdemo32.c
	$(CXX) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LIBS)

clean:
	-rm -r $(BINARIES) $(BINARIES:=.dSYM) *~ #*#

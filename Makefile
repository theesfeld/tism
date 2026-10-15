# tism: POSIX time(1) in pure assembly. No libc.
AS = as
LD = ld
ASFLAGS = --64

.PHONY: all clean

all: tism

tism: tism.o
	$(LD) -o $@ $<

tism.o: tism.s
	$(AS) $(ASFLAGS) -o $@ $<

clean:
	rm -f tism tism.o

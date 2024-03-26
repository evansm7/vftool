#  Virtualization.framework tool (vftool)

Here lies a _really minimalist_ and very noddy command-line wrapper to run VMs in the macOS Big Sur Virtualization.framework.

Vftool runs Linux virtual machines with virtio block, network, entropy and console devices.  All of the hard work and actual virtualisation is performed by Virtualization.framework -- this wrapper simply sets up configuration objects, describing the VM.

It's intended to be the simplest possible invocation of this framework, whilst allowing configuration for:
- Amount of memory
- Number of VCPUs
- Attached disc images, CDROM images (AKA a read-only disc image), or neither
- Initrd, or no initrd)
- kernel
- kernel commandline

Tested on an M1-based Mac (running arm64/AArch64 VMs), but should work on Intel Macs too (to run x86 VMs).  Requires macOS >= 11.

This is _not a GUI-based app_, and this configuration is provided on the command-line.  Note also that Virtualization.framework does not currently provide public interfaces for framebuffers/video consoles/GUI, so the resulting VM will have a (text) console and networking only.  Consider using VNC into your VM, which is quite usable.


## Building

### In Xcode
It should be one click, though you may have to set up your (free) developer ID/AppleID developer Team in the "Signing & Capabilities" tab of the project configuration.

### Or, from the commandline

Install the commandline tools (or Xcode proper) and run `make`.

This results in `build/vftool`.  The Makefile applies a code signature and required entitlements without an identity, which should be enough to run on your own machine.  I haven't tested whether this binary will then work on other people's machines.


## Running
The following command-line arguments are supported:

~~~
    -k <kernel path>
    -a <kernel cmdline arguments>
    -i <initrd path>
    -d <disc image path>
    -c <CDROM image path>
    -b <bridged ethernet interface>
    -p <number of processors>
    -m <memory size in MB>
    -t <tty type>
~~~

Only the `-k` argument is required (for a path to the kernel image), and all other arguments are optional.  The (current) default is 1 CPU, 512MB RAM, "console=hvc0", NAT-based networking, no discs or initrd and creates a pty for the console.

The `-t` option permits the console to either use stdin/stdout (option `0`), or to create a pseudo terminal (option `1`, the default) and wait for you to attach something to it, as in the example below.  The pseudo terminal (pty) approach gives a useful interactive console (particularly handy for setting up your VM), but stdin/stdout and immediate startup are more useful for launching VMs in a script.

Multiple disc images can be attached by using several `-d` or `-c` options.  The discs are attached in the order they are given on the command line, which should then influence which device they appear as.  For example, `-d foo -d bar -c blah` will create three virtio-blk devices, `/dev/vda`, `/dev/vdb`, `/dev/vdc` attached to _foo_, _bar_ and _blah_ respectively.  Up to 8 discs can be attached.

The kernel should be uncompressed.  The initrd may be a gz.  Disc images are raw/flat files (nothing fancy like qcow2).

When starting vftool, you will see output similar to:

~~~
2020-11-25 02:14:33.883 vftool[86864:707935] vftool (v0.1 25/11/2020) starting
2020-11-25 02:14:33.884 vftool[86864:707935] +++ kernel at file:///Users/matt/vm/debian/Image-5.9, initrd at (null), cmdline 'console=hvc0 root=/dev/vda1', 2 cpus, 4096MB memory
2020-11-25 02:14:33.884 vftool[86864:707935] +++ fd 3 connected to /dev/ttys016
2020-11-25 02:14:33.884 vftool[86864:707935] +++ Waiting for connection to:  /dev/ttys016
~~~

vftool is now waiting for a connection to the VM's console -- in this example, it's created `/dev/ttys016` for this.  Continue by attaching to this in another terminal:

~~~
    screen /dev/ttys016
~~~

Note this provides an accurate terminal to your guest, as far as Terminal/screen provide.

At this point, vftool starts the VM.  (Well, vftool validates some items after this point, so if your disc images don't exist then you'll find out now.)


## Kernels/notes

An example working commandline is:
~~~
    vftool -k ~/vm/debian/Image-5.9 -d ~/vm/debian/arm64_debian.img  -p 2 -m 4096 -a "console=hvc0 root=/dev/vda1"
~~~

I've used a plain/defconfig Linux 5.9 build (not gzipped):
~~~
    $ file Image-5.9
    Image-5.9: Linux kernel ARM64 boot executable Image, little-endian, 4K pages
~~~

Note that Virtualization.framework provides all IO as virtio-pci, including the console (i.e. not a UART).  The debian install kernel does not have virtio drivers, unfortunately.  I ended up using debootstrap (`--foreign`) to install to a disc image on a Linux box... but I hear good things about Fedora etc.


## Networking and entitlements

The `-b` option uses a `VZBridgedNetworkDeviceAttachment` to configure a bridged network interface instead of the default 'NAT' interface.  *This does not currently work*.

The bridging requires the binary to have the  `com.apple.vm.networking` entitlement, and Apple docs helpfully give this note:

> Note
> This entitlement is restricted to developers of virtualization software. To request this entitlement, contact your Apple representative.

This seems to be saying that one requires a paid developer account *and* to ask nicely to be able to use this OS feature.  (Rolls eyes)

Fortunately, the "NAT" default works fine for the outgoing direction, and even permits *incoming* connections -- it appears to be kernel-level NAT from a bridged interface instead of the user-level TCP/IP stuff as used in QEMU.  I end up with a host-side `bridge100` network interface with IP `192.168.64.1` and my guests get `192.168.64.x` addresses which are reachable from the host.  So, at least one can SSH/VNC into guests!


## Issues

Folks have reported problems (I believe with the pty setup) when running in tmux.


## References
-   KhaosT's SimpleVM is a Swift wrapper for Virtualization.framework:  https://github.com/KhaosT/SimpleVM  This does roughly the same thing as vftool, but has a friendlier GUI.  vftool has a little more flexibility in configuration (without hacking sources) and I personally prefer the text-based terminal approach.
-   [https://developer.apple.com/documentation/virtualization?language=objc]


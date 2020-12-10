/*
 * vftool
 *
 * A minimalist wrapper for Virtualization.framework
 *
 * (c) 2020 Matt Evans
 *
 * Licence = MIT
 */

#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>

#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <termios.h>
#include <limits.h>
#include <errno.h>
#include <poll.h>
#include <util.h>

#define VERSION "v0.3 10/12/2020"

#define MAX_DISCS   8

struct disc_info {
    NSString    *path;
    bool        readOnly;
};

/* ******************************************************************** */
/* PTY management*/

static int createPty(bool waitForConnection)
{
    struct termios tos;
    char ptsn[PATH_MAX];
    int sfd;
    int tty_fd;

    if (openpty(&tty_fd, &sfd, ptsn, &tos, NULL) < 0) {
        perror("openpty: ");
        return -1;
    }

    if (tcgetattr(sfd, &tos) < 0) {
        perror("tcgetattr:");
        return -1;
    }

    cfmakeraw(&tos);
    if (tcsetattr(sfd, TCSAFLUSH, &tos)) {
        perror("tcsetattr:");
        return -1;
    }
    close(sfd);

    int f = fcntl(tty_fd, F_GETFL);
    fcntl(tty_fd, F_SETFL, f | O_NONBLOCK);

    NSLog(@"+++ fd %d connected to %s\n", tty_fd, ptsn);
    
    if (waitForConnection) {
        // Causes a HUP:
        close(open(ptsn, O_RDWR | O_NOCTTY));

        NSLog(@"+++ Waiting for connection to:  %s\n", ptsn);

        // Poll for the HUP to go away:
        struct pollfd pfd = {
            .fd = tty_fd,
            .events = POLLHUP
        };
        
        do {
            poll(&pfd, 1, 100);
        } while (pfd.revents & POLLHUP);
    }

    return tty_fd;
}

/* ******************************************************************** */

/* Build VM config.  Returns a VZVirtualMachineConfiguration object* which
 * needs to be externally validated.  Like many of us.
 */
static VZVirtualMachineConfiguration *getVMConfig(unsigned int mem_size_mb,
                                                  unsigned int nr_cpus,
                                                  /* 0 stdout/in, 1 pty */
                                                  unsigned int console_type,
                                                  NSString *cmdline,
                                                  NSString *kernel_path,
                                                  NSString *initrd_path,
                                                  struct disc_info *dinfo,
                                                  unsigned int num_discs,
                                                  NSString *bridged_eth)
{
    /* **************************************************************** */
    /* Linux bootloader setup:
     */
    NSURL *kernelURL = [NSURL fileURLWithPath:kernel_path];
    NSURL *initrdURL = nil;
    NSURL *discURL = nil;
    NSURL *cdromURL = nil;

    if (initrd_path)
        initrdURL = [NSURL fileURLWithPath:initrd_path];

    NSLog(@"+++ kernel at %@, initrd at %@, cmdline '%@', %u cpus, %uMB memory\n",
          kernel_path, initrd_path, cmdline, nr_cpus, mem_size_mb);

    VZLinuxBootLoader *lbl = [[VZLinuxBootLoader alloc] initWithKernelURL:kernelURL];
    [lbl setCommandLine:cmdline];
    if (initrdURL)
        [lbl setInitialRamdiskURL:initrdURL];

    /* Configuration setup:
     * (Note docs don't show an init method on this class....)
     */
    VZVirtualMachineConfiguration *conf = [[VZVirtualMachineConfiguration alloc] init];

    /* I can't seem to access members such as maximumAllowedCPUCount and maximumAllowedMemorySize :( */
    [conf setBootLoader:lbl];
    [conf setCPUCount:nr_cpus];
    [conf setMemorySize:mem_size_mb*1024*1024UL];

    /* **************************************************************** */
    // Devices
    
    // Serial
    int ifd = 0, ofd = 1;

    if (console_type == 1) {
        int pty = createPty(true);
        if (pty < 0) {
            NSLog(@"--- Error creating pty for serial console!\n");
            return nil;
        }
        ifd = pty;
        ofd = pty;
    }

    NSFileHandle *cons_out = [[NSFileHandle alloc] initWithFileDescriptor:ofd];
    NSFileHandle *cons_in = [[NSFileHandle alloc] initWithFileDescriptor:ifd];
    VZSerialPortAttachment *spa = [[VZFileHandleSerialPortAttachment alloc]
                                   initWithFileHandleForReading:cons_in
                                   fileHandleForWriting:cons_out];
    VZVirtioConsoleDeviceSerialPortConfiguration *cons_conf = [[VZVirtioConsoleDeviceSerialPortConfiguration alloc] init];
    [cons_conf setAttachment:spa];
    [conf setSerialPorts:@[cons_conf]];

    
    // Network
    NSArray *bni = [VZBridgedNetworkInterface networkInterfaces];
    VZBridgedNetworkInterface *iface = nil;
    for (id o in bni) {
        if (![[o identifier] compare:bridged_eth]) {
            NSLog(@"+++ Found bridged interface object for %@ (%@)\n", [o identifier], [o localizedDisplayName]);
            iface = o;
        }
    }

    if (bridged_eth && !iface) {
        NSLog(@"--- Warning: ethernet interface %@ not found\n", bridged_eth);
    }

    VZNetworkDeviceAttachment *nda = nil;

    if (iface) {
        // Attempt to create a bridged attachment:
        nda = [[VZBridgedNetworkDeviceAttachment alloc] initWithInterface:iface];
    }
    // Otherwise, or if failed, create a NAT attachment:
    if (!nda) {
        nda = [[VZNATNetworkDeviceAttachment alloc] init];
    }
    
    VZVirtioNetworkDeviceConfiguration *net_conf = [[VZVirtioNetworkDeviceConfiguration alloc] init];
    [net_conf setAttachment:nda];
    [conf setNetworkDevices:@[net_conf]];
    

    // Entropy
    VZEntropyDeviceConfiguration *entropy_conf = [[VZVirtioEntropyDeviceConfiguration alloc] init];
    [conf setEntropyDevices:@[entropy_conf]];
    

    // Storage/disc
    NSArray *discs = @[];

    for (unsigned int i = 0; i < num_discs; i++) {
        NSString *disc_path = dinfo[i].path;
        NSURL *discURL = [NSURL fileURLWithPath:disc_path];
        NSLog(@"+++ Attaching disc %@\n", disc_path);

        VZDiskImageStorageDeviceAttachment *disc_sda = [[VZDiskImageStorageDeviceAttachment alloc]
                                                        initWithURL:discURL
                                                        readOnly:dinfo[i].readOnly error:nil];
        if (disc_sda) {
            VZStorageDeviceConfiguration *disc_conf = [[VZVirtioBlockDeviceConfiguration alloc]
                                                       initWithAttachment:disc_sda];
            discs = [discs arrayByAddingObject:disc_conf];
        } else {
            NSLog(@"--- Couldn't open disc%d at %@ (URL %@)\n", i, disc_path, discURL);
        }
    }

    [conf setStorageDevices:discs];

    return conf;
}


static void usage(const char *me)
{
    fprintf(stderr, "vftool version " VERSION "\n\n"
                    "Syntax:\n\t%s <options>\n\n"
                    "Options:\n"
                    "\t-k <kernel path>                 [REQUIRED]\n"
                    "\t-a <kernel cmdline arguments>\n"
                    "\t-i <initrd path>\n"
                    "\t-d <disc image path>\n"
                    "\t-c <CDROM image path>            (As -d, but read-only)\n"
                    "\t-b <bridged ethernet interface>  (Default NAT)\n"
                    "\t-p <number of processors>        (Default 1)\n"
                    "\t-m <memory size in MB>           (Default 512MB)\n"
                    "\t-t <tty type>                    (0 = stdio, 1 = pty (default))\n"
                    "\n\tSpecify multiple discs with multiple -d/-c options, in order (max %d)\n",
                    me, MAX_DISCS);
}


int main(int argc, char *argv[])
{
    @autoreleasepool {
        NSString *kern_path = NULL;
        NSString *cmdline = NULL;
        NSString *initrd_path = NULL;
        NSString *disc_path = NULL;
        NSString *cdrom_path = NULL;
        NSString *eth_if = NULL;
        unsigned int cpus = 0;
        unsigned int mem = 0;
        unsigned int tty_type = 1;

        struct disc_info dinfo[MAX_DISCS];
        unsigned int num_discs = 0;

        int ch;
        while ((ch = getopt(argc, argv, "k:a:i:d:c:b:p:m:t:h")) != -1) {
            switch (ch) {
                case 'k':
                    kern_path = [NSString stringWithUTF8String:optarg];
                    break;
                case 'a':
                    cmdline = [NSString stringWithUTF8String:optarg];
                    break;
                case 'i':
                    initrd_path = [NSString stringWithUTF8String:optarg];
                    break;
                case 'd':
                case 'c':
                    if (num_discs > MAX_DISCS-1) {
                        usage(argv[0]);
                        fprintf(stderr, "\nError: Too many discs specified (max %d)\n\n", MAX_DISCS);
                        return 1;
                    }
                    dinfo[num_discs].path = [NSString stringWithUTF8String:optarg];
                    dinfo[num_discs].readOnly = (ch == 'c');
                    num_discs++;
                    break;
                case 'b':
                    eth_if = [NSString stringWithUTF8String:optarg];
                    break;
                case 'p':
                    cpus = atoi(optarg);
                    break;
                case 'm':
                    mem = atoi(optarg);
                    break;
                case 't':
                    tty_type = atoi(optarg);
                    if (tty_type > 1) {
                        usage(argv[0]);
                        fprintf(stderr, "\nError: Unknown tty type %d\n\n", tty_type);
                        return 1;
                    }
                    break;

                case 'h':
                default:
                    usage(argv[0]);
                    return 1;
            }
        }

        if (!kern_path) {
            usage(argv[0]);
            fprintf(stderr, "\nError: Need a kernel path!\n\n");
            return 1;
        }

        if (!cmdline) {
            cmdline = @"console=hvc0";
        }
        
        if (cpus == 0) {
            cpus = 1;
        }
        
        if (mem == 0) {
            mem = 512;
        }
        
        NSLog(@"vftool (" VERSION ") starting");

        /* **************************************************************** */
        // Create config

        VZVirtualMachineConfiguration *conf = getVMConfig(mem, cpus, tty_type, cmdline,
                                                          kern_path, initrd_path,
                                                          dinfo, num_discs,
                                                          eth_if);
 
        if (!conf) {
            NSLog(@"Couldn't create configuration for VM.\n");
            return 1;
        }

        /* **************************************************************** */
        // Validate config
        
        NSError *confErr = NULL;
        [conf validateWithError:&confErr];

        if (confErr) {
            NSLog(@"-- Configuration vaildation failure! %@\n", confErr);
            return 1;
        }
        NSLog(@"+++ Configuration validated.\n");
        
        /* **************************************************************** */
        // Create VM

        // Create a secondary dispatch queue because I don't want to use dispatch_main here
        // (i.e. the blocks/interaction works on the main queue unless we do this).
        dispatch_queue_t queue = dispatch_queue_create("Secondary queue", NULL);
        
        VZVirtualMachine *vm = [[VZVirtualMachine alloc] initWithConfiguration:conf queue:queue];
        
        dispatch_sync(queue, ^{
            NSLog(@"+++ canStart = %d, vm state %d\n", vm.canStart, (int)vm.state);
            if (!vm.canStart) {
                NSLog(@"--- VM is not startable :(\n");
                exit(1);
            }
        });

        // Start VM
        dispatch_sync(queue, ^{
            [vm startWithCompletionHandler:^(NSError *errorOrNil){
                if (errorOrNil) {
                    NSLog(@"--- VM start error: %@\n", errorOrNil);
                    exit(1);
                } else {
                    NSLog(@"+++ VM started\n");
                }
            }];
        });
        
        // We could register a delegate and get async updates from the state, e.g. shutdown.
        do {
            sleep(1);
        } while(vm.state == VZVirtualMachineStateRunning ||
                vm.state == VZVirtualMachineStateStarting);
        
        NSLog(@"+++ Done, state = %d\n", (int)vm.state);
    }

    return 0;
}

<div align="center">

# Linux on Mac

This project was forked from [evansm7/vftool](https://github.com/evansm7/vftool), which is a simple tool to run virtual machines on macOS using the Virtualization.framework.

Here you can find a written guide to running Linux virtual machine on macOS.

[Before You Begin](#before-you-begin) •
[Getting Started](#getting-started) •
[References](#references)

</div>

## Before You Begin

Please find the original README from the upstream [here](./docs/VFTOOL.md). I am using Ubuntu Server in this guide, feel free to use your favourite distro.

## Getting Started

### Pre-requisite

1. Build the project.

   - ```bash
     make
     ```

1. Download the image, initrd (initial ramdisk) and kernel from this [site](https://cloud-images.ubuntu.com) into the `build` folder. For example,

   - ```bash
     # image
     jammy-server-cloudimg-amd64.img
     # initrd
     ubuntu-22.04-server-cloudimg-arm64-initrd-generic
     # kernel
     ubuntu-22.04-server-cloudimg-arm64-vmlinuz-generic
     ```

1. Unzip the kernel.

   - ```bash
     mv /path/to/kernel /path/to/kernel.gz
     gunzip /path/to/kernel.gz
     ```

### Setup the Virtual Machine

1. First, start the virtual machine without specifying a root. This allows us to run some basic setup such as **creating a root mount point**, **disabling cloud init**, **setting a root password** and a **static IP**.

   - ```bash
     ./vftool \
	   -k /path/to/kernel \
	   -i /path/to/initrd \
	   -d /path/to/image \
	   -m 8192 \
	   -a "console=hvc0" 
     ```

1. Look for the indicated terminal input device (e.g. `Waiting for connection to:  /dev/ttys001`), and connect to it from another terminal session.

   - ```bash
     screen /dev/ttys001
     ```

1. Wait for the virtual machine to finish booting up with `initramfs` prompt.

   - ```bash
     ...
     ...
     ...
     (initramfs)
     ```

1. Create a root mount point.

   - ```bash
     mkdir /mnt
     mount /dev/vda /mnt
     chroot /mnt
     ```

1. Disable clout init.

   - ```bash
     touch /etc/cloud/cloud-init.disabled
     ```

1. Set the root password to `root`.

   - ```bash
     echo 'root:root' | chpasswd
     ```

1. Set a static IP.

   - ```bash
     cat <<EOF> /etc/netplan/01-dhcp.yaml
     network:
       ethernets:
         enp0s1:
           dhcp4: true
           addresses: [192.168.64.18/20]
       version: 2
     EOF
     ```

1. Exit and unmount.

   - ```bash
     exit
     umount /dev/vda
     ```

1. Manually kill the virtual machine with `Ctrl+C` from the original terminal session.

### Allocating Storage Space

1. Allocate storage space to the virtual machine by resizing the image. In this example, I am allocating 32GB to the virtual machine.

   - ```bash
     dd if=/dev/zero bs=1m count=32000 >> /path/to/image
     ```

1. Start the virtual machine with a root specified this time.

   - ```bash
     ./vftool \
	   -k /path/to/kernel \
	   -i /path/to/initrd \
	   -d /path/to/image \
	   -p 4 \
	   -m 8192 \
	   -a "root=/dev/vda rw console=hvc0" 
     ```

1. Repeat **Step 2** in [Setup the Virtual Machine](#setup-the-virtual-machine) and login as `root`.

1. Check if the image resizing worked.

   - ```bash
     df -h | grep vda
     ```

1. If the size is not what specified in **Step 1**, check if the `dd` command worked.

   - ```bash
     parted
     (parted) print devices
     (parted) quit
     ```

1. If `/dev/vda/` shows the correct size allocated in **Step 1**, resize the partition to the max.

   - ```bash
     resize2fs /dev/vda
     ```

1. Repeat **Step 4**, and you should now see the correct allocated size for `/dev/vda`.

### Create a New User

1. Before we continue any further, instead of using `root` to access the virtual machine, let's create a new user and set a password.

   - ```bash
     adduser <YOUR_USERNAME>
     ```

1. Add this user to the `sudo` group.

   - ```bash
     usermod -aG sudo <YOUR_USERNAME>
     ```

1. Login as the new user.

   - ```bash
     su - <YOUR_USERNAME>
     ```

### Setup SSH

My intention here is to use the [remote development](https://code.visualstudio.com/docs/remote/ssh) feature from the IDE.

1. Re-install `openssh-server`.

   - ```bash
     sudo apt update
     sudo apt --reinstall install openssh-server
     ```

1. Disable the `ssh.socket`.

   - ```bash
     sudo systemctl disable ssh.socket --now
     ```

1. Enable the `ssh.service`.

   - ```bash
     sudo systemctl enable ssh.service --now
     ```

1. Assert that the `ssh.service` is enabled and running.

   - ```bash
     sudo systemctl status sshd
     ```

1. On your local machine, [generate a SSH key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#generating-a-new-ssh-key) and add the public key to the `~/.ssh/authorized_keys` file in the virtual machine.

1. Now you should be able to SSH into the virtual machine using the static IP specified in **Step 7** of [Setup the Virtual Machine](#setup-the-virtual-machine).

   - ```bash
     ssh -i /path/to/private-key <YOUR_USERNAME>@192.168.64.18
     ```

### Setup Docker (Optional)

1. Install a few prerequisite packages.

   - ```bash
     sudo apt update
     sudo apt install apt-transport-https ca-certificates curl software-properties-common
     ```

1. Add Docker repository to APT sources:

   - ```bash
     curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
     echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
     ```

1. Install `docker-ce`.

   - ```bash
     sudo apt update
     apt-cache policy docker-ce
     sudo apt install docker-ce
     ```

1. Assert that `docker` is enabled and running.

   - ```bash
     sudo systemctl status docker
     ```

1. Assert that images can be downloaded from the Docker hub.

   - ```bash
     docker run --rm hello-world
     ```

### Setup Virtual Host (Optional)

1. A static IP was set in **Step 7** of [Setup the Virtual Machine](#setup-the-virtual-machine).

1. On your local machine, point this IP to your favourite hostname in the `/etc/hosts` file. For example:

   - ```
     192.168.64.18  your.favourite.hostname
     ```

1. Now you can access the virtual machine using this hostname.

## References

* [Setting up Linux VM on Apple Silicon for Docker](https://piyush-agrawal.medium.com/setting-up-linux-vm-on-apple-silicon-for-docker-e5b9924fd09)
* [How To Install and Use Docker on Ubuntu 22.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-22-04)

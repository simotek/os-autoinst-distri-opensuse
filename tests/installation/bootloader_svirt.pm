# SUSE's openQA tests
#
# Copyright © 2016 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

use base "installbasetest";

use strict;
use warnings;

use File::Basename;

use testapi;
use utils;

sub run() {

    my $self = shift;

    my $arch             = get_var('ARCH',             'x86_64');
    my $vmm_family       = get_var('VIRSH_VMM_FAMILY', 'kvm');
    my $vmm_type         = get_var('VIRSH_VMM_TYPE',   'hvm');
    my $vmware_datastore = get_var('VMWARE_DATASTORE', '');

    my $svirt = select_console('svirt');
    my $name  = $svirt->name;
    my $repo;

    my $xenconsole = "xvc0";
    if (get_var('VERSION', '') =~ /12-SP2/) {
        $xenconsole = "hvc0";    # on 12-SP2 we use pvops, thus /dev/hvc0
    }

    if (!is_jeos) {
        my $cmdline = get_var('VIRSH_CMDLINE') . " ";

        $repo = "ftp://openqa.suse.de/" . get_var('REPO_0');
        $cmdline .= "install=$repo ";

        if (check_var("VIDEOMODE", "text")) {
            $cmdline .= "ssh=1 ";    # trigger ssh-text installation
        }
        else {
            $cmdline .= "sshd=1 vnc=1 VNCPassword=$testapi::password ";    # trigger default VNC installation
        }

        # we need ssh access to gather logs
        # 'ssh=1' and 'sshd=1' are equal, both together don't work
        # so let's just set the password here
        $cmdline .= "sshpassword=$testapi::password ";

        if ($vmm_family eq 'xen' && $vmm_type eq 'linux') {
            $cmdline .= "xenfb.video=4,1024,768 console=$xenconsole console=tty0 ";
        }
        else {
            $cmdline .= "console=ttyS0 ";
        }

        $svirt->change_domain_element(os => initrd => "/var/lib/libvirt/images/$name.initrd");
        # <os><kernel>...</kernel></os> defaults to grub.xen, we need to remove
        # content first if booting kernel diretly
        if ($vmm_family eq 'xen' && $vmm_type eq 'linux') {
            $svirt->change_domain_element(os => kernel => undef);
        }
        $svirt->change_domain_element(os => kernel  => "/var/lib/libvirt/images/$name.kernel");
        $svirt->change_domain_element(os => cmdline => $cmdline);

        # after installation we need to redefine the domain, so just shutdown
        $svirt->change_domain_element(on_reboot => 'destroy');
    }

    my $file = get_var('HDD_1');
    if ($vmm_family eq 'vmware') {
        $file = "[$vmware_datastore] openQA/" . basename($file);
    }

    my $size_i = get_var('HDDSIZEGB', '24');
    # in JeOS we have the disk, we just need to deploy it
    if (is_jeos) {
        $svirt->add_disk({size => $size_i . 'G', file => $file});
    }
    else {
        $svirt->add_disk({size => $size_i . 'G', file => $file, create => 1});
    }

    my $console_target_type;
    if ($vmm_family eq 'xen' && $vmm_type eq 'linux') {
        $console_target_type = 'xen';
    }
    else {
        $console_target_type = 'serial';
    }
    # esx driver in libvirt does not support `virsh console' command. We need
    # to export it on our own via TCP.
    my $pty_dev_type;
    if ($vmm_family eq 'vmware') {
        $pty_dev_type = 'tcp';
    }
    else {
        $pty_dev_type = 'pty';
    }
    my $protocol_type;
    my $source = 0;
    if ($vmm_family eq 'vmware') {
        $protocol_type = 'raw';
        $source        = 1;
    }
    $svirt->add_pty({pty_dev => 'console', pty_dev_type => $pty_dev_type, target_type => $console_target_type, target_port => '0', protocol_type => $protocol_type, source => $source});
    if (!($vmm_family eq 'xen' && $vmm_type eq 'linux')) {
        $svirt->add_pty({pty_dev => 'serial', pty_dev_type => $pty_dev_type, target_port => '0', protocol_type => $protocol_type, source => $source});
    }

    $svirt->add_vnc({port => get_var('VIRSH_INSTANCE', 1) + 5900});

    my %ifacecfg = ();

    # All but Xen PV VMs should be specified with known-to-work
    # network interface. Xen PV and Hyper-V use streams.
    my $iface_model;
    if ($vmm_family eq 'kvm') {
        $iface_model = 'virtio';
    }
    elsif ($vmm_family eq 'xen' && $vmm_type eq 'hvm') {
        $iface_model = 'netfront';
    }
    elsif ($vmm_family eq 'vmware') {
        $iface_model = 'e1000';
    }

    if ($iface_model) {
        $ifacecfg{'model'} = {type => $iface_model};
    }

    if ($vmm_family eq 'vmware') {
        # `virsh iface-list' won't produce correct bridge name for VMware.
        # It should be provided by the worker or relied upon the default.
        $ifacecfg{'type'} = 'bridge';
        $ifacecfg{'source'} = {bridge => get_var('VMWARE_BRIDGE', 'VM Network')};
    }
    else {
        # We can use bridge or network as a base for network interface. Network named 'default'
        # happens to be omnipresent on workstations, bridges (br0, ...) on servers. If both 'default'
        # network and bridge are defined and active, bridge should be prefered as 'default' network
        # does not work.
        if (my $bridges = $svirt->get_cmd_output("virsh iface-list | grep -w active | awk '{ print \$1 }' | tail -n1 | tr -d '\\n'")) {
            $ifacecfg{'type'} = 'bridge';
            $ifacecfg{'source'} = {bridge => $bridges};
        }
        elsif (my $networks = $svirt->get_cmd_output("virsh net-list | grep -w active | awk '{ print \$1 }' | tail -n1 | tr -d '\\n'")) {
            $ifacecfg{'type'} = 'network';
            $ifacecfg{'source'} = {network => $networks};
        }
    }

    $svirt->add_interface(\%ifacecfg);

    if (!is_jeos) {
        my $loader = "loader";
        my $xen    = "";
        my $linux  = "linux";
        if ($vmm_family eq 'xen' && $vmm_type eq 'linux') {
            $loader = "";
            $xen    = "-xen";
            $linux  = "vmlinuz";
        }
        # Show this on screen. The sleeps are necessary for the main process
        # to wait for the downloads otherwise it would continue and could
        # start the VM with uncomplete kernel/initrd, and thus fail. The time
        # to wait is pure guesswork.
        type_string "wget $repo/boot/$arch/$loader/$linux$xen -O /var/lib/libvirt/images/$name.kernel\n";
        sleep 10;    # TODO: assert_screen
        type_string "wget $repo/boot/$arch/$loader/initrd$xen -O /var/lib/libvirt/images/$name.initrd\n";
        sleep 10;    # TODO: assert_screen
    }

    $svirt->define_and_start;

    # This sets kernel argument so needle-matching works on Xen PV. It's being
    # done via host's PTY device because we don't see anything unless kernel
    # sets framebuffer (this is a GRUB2's limitation bsc#961638).
    if ($vmm_family eq 'xen') {
        if ($vmm_type eq 'linux') {
            type_string "export pty=`virsh dumpxml $name | grep \"console type=\" | sed \"s/'/ /g\" | awk '{ print \$5 }'`\n";
            type_string "echo \$pty\n";
            type_string "echo e > \$pty\n";    # edit
            for (1 .. 4) { type_string "echo -en '\\033[B' > \$pty\n"; }    # four-times key down
            type_string "echo -en '\\033[K' > \$pty\n";                     # end of line
            type_string "echo -en ' xenfb.video=4,1024,768' > \$pty\n";     # set kernel framebuffer
            type_string "echo -en '\\x18' > \$pty\n";                       # send Ctrl-x to boot guest kernel
        }
    }
    # select_console does not select TTY in traditional sense, but
    # connects to a guest VNC session
    if (is_jeos) {
        select_console('sut');
    }
    else {
        if (check_var("VIDEOMODE", "text")) {
            wait_serial("run 'yast.ssh'", 500) || die "linuxrc didn't finish";
            select_console("installation");
            type_string("yast.ssh\n");
        }
        else {
            wait_serial(' Starting YaST2 ', 500) || die "yast didn't start";
            select_console('installation');
        }
    }
}

1;

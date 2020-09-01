# SUSE's openQA tests
#
# Copyright © 2020 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: Test transactional updates
#   Installs & remove ptf, update, rollback
#   Check that system was rebooted and mounted snapshot changed
#   Check that expected package version match
# Maintainer: Martin Kravec <mkravec@suse.com>
# Tags: poo#14444

use strict;
use warnings;
use base "opensusebasetest";
use testapi;
use version_utils qw(is_caasp is_staging is_opensuse is_leap);
use transactional;
use utils;


=head2 check_package

check_package([stage => $stage, package => $package]);

Check that package presence & version are as expected

Optional C<$stage> can be specified with possible values are 'no', 'in' and 'up'. default is 'no'.
Optional C<$package> can be specified name of rpm file. default is 'update-test-security'.

=cut
sub check_package {
    my (%args)  = @_;
    my $stage   = $args{stage}   // 'no';
    my $package = $args{package} // 'update-test-security';
    my $in_vr   = rpmver('vr');

    if ($stage eq 'no') {
        assert_script_run "! rpm -q $package";
    } elsif ($stage eq 'in') {
        assert_script_run "rpm -q --qf '%{V}-%{R}' $package | grep -x $in_vr";
    } elsif ($stage eq 'up') {
        my ($in_ver, $in_rel) = split '-', $in_vr;
        my ($up_ver, $up_rel) = split '-', script_output("rpm -q --qf '%{V}-%{R}' $package");

        $up_rel =~ s/lp\d+\.(?:mo\.)?//;
        $in_ver = version->declare($in_ver);
        $in_rel = version->declare($in_rel);
        $up_ver = version->declare($up_ver);
        $up_rel = version->declare($up_rel);

        return if $up_ver > $in_ver;
        return if $up_rel > $in_rel && $up_ver == $in_ver;
        die "Bad version: in:$in_ver-$in_rel up:$up_ver-$up_rel";
    } else {
        die "Unknown stage: $stage";
    }
}

sub run {
    select_console 'root-console';

    script_run "rebootmgrctl set-strategy off";

    if (is_opensuse && get_var('BETA')) {
        record_info 'Remove pkgs', 'Remove preinstalled packages on Leap BETA';
        trup_call "pkg remove update-test-[^t]*";
        process_reboot(trigger => 1);
    }

    get_utt_packages;

    record_info 'Install ptf', 'Install package - snapshot #1';
    trup_call "ptf install" . rpmver('security');
    check_reboot_changes;
    check_package(stage => 'in');

    # Find snapshot number for rollback
    my $f    = is_caasp('<=4.0') ? 2 : 1;
    my $snap = script_output "snapper list | tail -1 | cut -d'|' -f$f | tr -d ' *'";

    # Don't use tests requiring repos in staging
    unless (is_opensuse && is_staging) {
        record_info 'Update #1', 'Add repository and update - snapshot #2';
        # openSUSE does not need additional repo
        zypper_call 'ar utt.repo' unless is_opensuse;
        trup_call 'cleanup up';
        check_reboot_changes;
        check_package(stage => 'up');

        record_info 'Update #2', 'System should be up to date - no changes expected';
        trup_call 'cleanup up';
        check_reboot_changes 0;
    }

    # Check that zypper does not return 0 if update was aborted
    record_info 'Broken pkg', 'Install broken package poo#18644 - snapshot #3';
    trup_call "pkg install" . rpmver('broken');
    check_reboot_changes;
    # Systems with repositories would downgrade on DUP
    my $upcmd = is_caasp('caasp') ? 'dup' : 'up';
    if (is_leap) {
        record_info 'Broken packages test skipped';
    } else {
        trup_call "cleanup $upcmd", 2;
        check_reboot_changes 0;
    }

    record_info 'Remove pkg', 'Remove package - snapshot #4';
    trup_call 'pkg remove update-test-security';
    check_reboot_changes;
    check_package;

    record_info 'Continue', 'Continue modifying an snapshot -snapshots #5 and #6';
    trup_call "pkg install" . rpmver('feature');
    trup_call "--continue pkg install" . rpmver('optional');
    check_reboot_changes;
    check_package(stage => 'in', package => 'update-test-feature');
    check_package(stage => 'in', package => 'update-test-optional');

    record_info 'Rollback', 'Revert to snapshot with initial rpm';
    trup_call "rollback $snap";
    check_reboot_changes;
    check_package(stage => 'in');
}

sub test_flags {
    return {no_rollback => 1};
}

1;

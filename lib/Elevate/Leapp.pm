package Elevate::Leapp;

=encoding utf-8

=head1 NAME

Elevate::Leapp

Object to install and execute the leapp script

=cut

use cPstrict;

use Cpanel::Binaries ();
use Cpanel::JSON     ();
use Cpanel::LoadFile ();
use Cpanel::Pkgr     ();

use Elevate::OS        ();
use Elevate::PkgMgr    ();
use Elevate::StageFile ();

use Config::Tiny ();

use Log::Log4perl qw(:easy);

use constant LEAPP_REPORT_JSON       => q[/var/log/leapp/leapp-report.json];
use constant LEAPP_REPORT_TXT        => q[/var/log/leapp/leapp-report.txt];
use constant LEAPP_UPGRADE_LOG       => q[/var/log/leapp/leapp-upgrade.log];
use constant LEAPP_FAIL_CONT_FILE    => q[/var/cpanel/elevate_leap_fail_continue];
use constant LEAPP_COMPLETION_STRING => qr/Starting stage After of phase FirstBoot/;

our $time_to_wait_for_leapp_completion = 10 * 60;

use Simple::Accessor qw{
  cpev
};

sub _build_cpev {
    die q[Missing cpev];
}

sub install ($self) {

    unless ( Cpanel::Pkgr::is_installed('elevate-release') ) {
        my $elevate_rpm_url = Elevate::OS::elevate_rpm_url();
        Elevate::PkgMgr::install_pkg_via_url($elevate_rpm_url);
        $self->beta_if_enabled;    # If --leappbeta was passed, then enable it.
    }

    my $leapp_data_pkg = Elevate::OS::leapp_data_pkg();

    unless ( Cpanel::Pkgr::is_installed('leapp-upgrade') && Cpanel::Pkgr::is_installed($leapp_data_pkg) ) {
        Elevate::PkgMgr::install( 'leapp-upgrade', $leapp_data_pkg );
    }

    return;
}

sub beta_if_enabled ($self) {
    return unless $self->cpev->getopt('leappbeta');
    my $yum_config = Cpanel::Binaries::path('yum-config-manager');
    $self->cpev->ssystem_and_die( $yum_config, '--disable', Elevate::OS::leapp_repo_prod() );
    $self->cpev->ssystem_and_die( $yum_config, '--enable',  Elevate::OS::leapp_repo_beta() );

    return 1;
}

sub remove_kernel_devel ($self) {

    if ( Cpanel::Pkgr::is_installed('kernel-devel') ) {
        Elevate::PkgMgr::remove('kernel-devel');
    }

    return;
}

sub preupgrade ($self) {

    INFO("Running leapp preupgrade checks");

    my $out = $self->cpev->ssystem_hide_and_capture_output( '/usr/bin/leapp', 'preupgrade' );

    INFO("Finished running leapp preupgrade checks");

    return $out;
}

sub upgrade ($self) {

    return unless $self->cpev->upgrade_distro_manually();

    $self->cpev->run_once(
        setup_answer_file => sub {
            $self->setup_answer_file();
        },
    );

    my $leapp_flag = Elevate::OS::leapp_flag();
    my $leapp_bin  = '/usr/bin/leapp';
    my @leapp_args = ('upgrade');
    push( @leapp_args, $leapp_flag ) if $leapp_flag;

    INFO("Running leapp upgrade");

    my $ok = eval {
        local $ENV{LEAPP_OVL_SIZE} = Elevate::StageFile::read_stage_file('env')->{'LEAPP_OVL_SIZE'} || 3000;
        $self->cpev->ssystem_and_die( { keep_env => 1 }, $leapp_bin, @leapp_args );
        1;
    };

    return 1 if $ok;

    $self->_report_leapp_failure_and_die();
    return;
}

sub search_report_file_for_inhibitors ( $self, @ignored_blockers ) {

    my @blockers;
    my $leapp_json_report = LEAPP_REPORT_JSON;

    if ( !-e $leapp_json_report ) {
        ERROR("Leapp did not generate the expected report file: $leapp_json_report");
        return [
            {
                title   => "Leapp did not generate $leapp_json_report",
                summary => "It is expected that leapp generate a JSON report file",
            }
        ];
    }

    my $report = eval { Cpanel::JSON::LoadFile($leapp_json_report) } // {};
    if ( my $exception = $@ ) {
        ERROR("Unable to parse leapp report file ($leapp_json_report): $exception");
        return [
            {
                title   => "Unable to parse leapp report file $leapp_json_report",
                summary => "The JSON report file generated by LEAPP is unreadable or corrupt",
            }
        ];
    }

    my $entries = $report->{entries};
    return [] unless ( ref $entries eq 'ARRAY' );

    foreach my $entry (@$entries) {
        next unless ( ref $entry eq 'HASH' );

        # If it is a blocker, then it will contain an array
        # of flags one of which will be named "inhibitor"
        my $flags = $entry->{flags};
        next unless ( ref $flags eq 'ARRAY' );
        next unless scalar grep { $_ eq 'inhibitor' } @$flags;

        # Some blockers we ignore because we fix them before upgrade
        next if scalar grep { $_ eq $entry->{actor} } @ignored_blockers;

        my $blocker = {
            title   => $entry->{title},
            summary => $entry->{summary},
        };

        if ( ref $entry->{detail}{remediations} eq 'ARRAY' ) {
            foreach my $rem ( @{ $entry->{detail}{remediations} } ) {
                next unless ( $rem->{type} && $rem->{context} );
                if ( $rem->{type} eq 'hint' ) {
                    $blocker->{hint} = $rem->{context};
                }
                if ( $rem->{type} eq 'command' && ref $rem->{context} eq 'ARRAY' ) {
                    $blocker->{command} = join ' ', @{ $rem->{context} };
                }
            }
        }

        push @blockers, $blocker;
    }

    return \@blockers;
}

sub extract_error_block_from_output ( $self, $text_ar ) {

    # The fatal errors will appear there in a block that looks like this:
    # =========================================
    #               ERRORS
    # =========================================
    #
    # Info about the errors
    #
    # =========================================
    #             END OF ERRORS
    # =========================================

    my $error_block = '';

    my $found_banner_line        = 0;
    my $found_second_banner_line = 0;
    my $in_error_block           = 0;

    foreach my $line (@$text_ar) {

        # Keep looking for a "banner" line (a line full of "=")
        if ( !$found_banner_line ) {
            $found_banner_line = 1 if $line =~ /^={10}/;
            next;
        }

        # We've found the banner line, check if this is the error block
        if ( !$in_error_block ) {
            if ( $line =~ /^\s+ERRORS/ ) {
                $in_error_block = 1;
            }
            else {
                # not the error block, go back to looking for a banner line
                $found_banner_line = 0;
            }
            next;
        }

        # We can't start harvesting the error info until we pass the second banner line
        if ( !$found_second_banner_line ) {
            $found_second_banner_line = 1 if $line =~ /^={10}/;
            next;
        }

        # If we come across another banner line, we are done with the error block
        last if $line =~ /^={10}/;

        $error_block .= $line . "\n";
    }

    return $error_block;
}

# Returns 0 on failure.

sub wait_for_leapp_completion ($self) {
    return 1 unless Elevate::OS::needs_leapp();

    # No use waiting for leapp to complete if we did not run leapp
    return 1 unless $self->cpev->upgrade_distro_manually();

    my $upgrade_log = LEAPP_UPGRADE_LOG;

    if ( !-e $upgrade_log ) {
        ERROR("No LEAPP upgrade log detected at [$upgrade_log]");
        return 0;
    }

    my $elapsed    = 0;
    my $sleep_time = 3;    # Time to sleep, in seconds, between checks

    # Wait to see the completion message from leapp. It may take a little after boot.
    while ( $elapsed < $time_to_wait_for_leapp_completion ) {
        my $contents = Cpanel::LoadFile::loadfile(LEAPP_UPGRADE_LOG) // '';
        return 1 if $contents =~ LEAPP_COMPLETION_STRING;

        # Check each loop so they can drop the skip file in live.
        if ( -e LEAPP_FAIL_CONT_FILE ) {
            INFO( 'LEAPP does not appear to have completed successfully, but continuing anyway because [' . LEAPP_FAIL_CONT_FILE . '] exists' );
            return 2;
        }

        if ( $elapsed % 30 == 0 ) {
            INFO('Waiting for the LEAPP upgrade process to complete.');
            if ( $elapsed == 0 ) {    # First loop give extra advice
                INFO( 'This process may take up to ' . int( $time_to_wait_for_leapp_completion / 60 ) . ' minutes.' );
                INFO( 'You can `touch ' . LEAPP_FAIL_CONT_FILE . '` if you would like to skip this check.' );
            }
        }

        sleep $sleep_time;
        $elapsed += $sleep_time;
    }

    # We failed to find the completion message within 10 minutes.

    my $touch_file = LEAPP_FAIL_CONT_FILE;
    my $leapp_txt  = LEAPP_REPORT_TXT;
    my $msg        = <<~"END";
    The command 'leapp upgrade' did not complete successfully. Please investigate and resolve the issue.
    Once resolved, you can continue the upgrade by running the following commands:
        touch $touch_file
        /scripts/elevate-cpanel --continue
    The following log files may help in your investigation.
        $upgrade_log
        $leapp_txt
    END
    ERROR($msg);

    return 0;
}

sub _report_leapp_failure_and_die ($self) {

    my $msg = <<'EOS';
The 'leapp upgrade' process failed.

Please investigate, resolve then re-run the following command to continue the update:

    /scripts/elevate-cpanel --continue

EOS

    my $entries = $self->search_report_file_for_inhibitors;
    if ( ref $entries eq 'ARRAY' ) {
        foreach my $e (@$entries) {
            $msg .= "\n$e->{summary}" if $e->{summary};

            if ( $e->{command} ) {

                my $cmd = $e->{command};
                $cmd =~ s[^leapp][/usr/bin/leapp];

                $msg .= "\n\n";
                $msg .= <<"EOS";
Consider running this command:

    $cmd

EOS
            }
        }
    }

    if ( -e LEAPP_REPORT_TXT ) {
        $msg .= qq[\nYou can read the full leapp report at: ] . LEAPP_REPORT_TXT;
    }

    die qq[$msg\n];
}

sub setup_answer_file ($self) {
    my $leapp_dir = '/var/log/leapp';
    mkdir $leapp_dir unless -d $leapp_dir;

    my $answerfile_path = $leapp_dir . '/answerfile';
    system touch => $answerfile_path unless -e $answerfile_path;

    my $do_write;    # no point in overwriting the file if nothing needs to change

    my $ini_obj = Config::Tiny->read( $answerfile_path, 'utf8' );
    LOGDIE( 'Failed to read leapp answerfile: ' . Config::Tiny->errstr ) unless $ini_obj;

    my $SECTION = 'remove_pam_pkcs11_module_check';

    if ( not defined $ini_obj->{$SECTION}->{'confirm'} or $ini_obj->{$SECTION}->{'confirm'} ne 'True' ) {
        $do_write = 1;
        $ini_obj->{$SECTION}->{'confirm'} = 'True';
    }

    if ($do_write) {
        $ini_obj->write( $answerfile_path, 'utf8' )    #
          or LOGDIE( 'Failed to write leapp answerfile: ' . $ini_obj->errstr );
    }

    return;
}

1;

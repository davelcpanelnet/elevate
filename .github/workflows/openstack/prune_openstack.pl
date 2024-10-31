#!/usr/bin/env perl

use Env;

use Data::Dumper;    # DEBUG

use constant OS_AUTH_TYPE            => 'v3applicationcredential';
use constant OS_AUTH_URL             => 'https://keystone.hou-01.cloud.prod.cpanel.net:5000/v3';
use constant OS_IDENTITY_API_VERSION => '3';
use constant OS_REGION_NAME          => 'RegionOne';
use constant OS_INTERFACE            => 'public';

use constant OS_APPLICATION_CREDENTIAL_ID     => $ENV{OS_APPLICATION_CREDENTIAL_ID};
use constant OS_APPLICATION_CREDENTIAL_SECRET => $ENV{OS_APPLICATION_CREDENTIAL_SECRET};

# The should ultimately end up as secrets for repo reusability esported into env like the APPLICATION info
use constant VM_NAME  => "elevate.github.cpanel.net";
use constant KEY_NAME => "deletethis";

# two hours ago
my $time_cmd = qq/ date -d '-2 hour' --utc +"%Y-%m-%dT%H:%M:%SZ"/;

my $hammer_time = `$time_cmd`;

remove_stale_instances();

remove_stale_keys();

sub get_keys {
    my $cmd = qq{ openstack keypair list -f json  | jq -r .[].Name };

    my $keys = {};

    my @list = split( '\n', eval { `$cmd` } );
    die $@ if $@;

    print Dumper \@list;

    foreach my $key_name ( @list ) {
        my $created_cmd = qq{ openstack keypair show -f json "$key_name" | jq -r '.id + "," + .created_at + "," + .name' };
        ( $keys->{$key_name}->{'id'}, $keys->{$key_name}->{'created_on'}, $keys->{$key_name}->{'name'} ) = split( ',', eval { `$created_cmd` } );
    }

    return $keys;
}

sub get_instances {
    my $cmd = qq{ openstack server list -f json --no-name-lookup | jq -r .[].ID };

    my $instances = {};

    my @list = split( '\n', eval { `$cmd` } );
    die $@ if $@;

    foreach my $VM (@list) {
        my $created_cmd = qq{ openstack server show -f json "$VM" | jq -r '.id + "," + .created + "," + .name' };
        ( $instances->{$VM}->{'id'}, $instances->{$VM}->{'created_on'}, $instances->{$VM}->{'name'} ) = split( ',', eval { `$created_cmd` } );
    }

    return $instances;
}

sub remove_stale_keys {
    my $keys = get_keys();

    print Dumper \$keys;

    foreach my $key ( keys %$keys ) {
        if ( $keys->{$key}->{name} !~ /deletethis/ ) {
            delete $keys->{$key};
        }
    }

    foreach my $key ( keys %$keys ) {
        if ( $instances->{$id}->{'created_on'} < $hammer_time ) {
            print "deleting: $keys->{$key}->{name}, $keys->{$key}->{created_on}\n";
#            openstack keypair delete "$ID"
        }
    }
}

sub remove_stale_instances {
    my $instances = get_instances();

    foreach my $id ( keys %$instances ) {
        if ( $instances->{$id}->{name} !~ /elevate\.github\.cpanel\.net/ ) {
            delete $instances->{$id};
        }
    }

    foreach my $id ( keys %$instances ) {
        if ( $instances->{$id}->{'created_on'} < $hammer_time ) {
            print "deleting: $instances->{$id}->{name}, $instances->{$id}->{created_on}\n";
#            openstack server delete "$instances->{$id}"
        }
    }

    print Dumper \$instances;

    return 0;
}

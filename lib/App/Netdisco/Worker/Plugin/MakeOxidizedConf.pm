package App::Netdisco::Worker::Plugin::MakeOxidizedConf;

use strict;
use warnings;

use Dancer ':syntax';
use Dancer::Plugin::DBIC;

use App::Netdisco::Worker::Plugin;
use aliased 'App::Netdisco::Worker::Status';

use Path::Class;
use List::Util qw/pairkeys pairfirst/;
use File::Slurper qw/read_lines write_text/;
use App::Netdisco::Util::Permission 'check_acl_no';


register_worker({ phase => 'main' }, sub {
    my ($job, $workerconf) = @_;
    my $config = setting( 'oxidized' ) || {};
    my $default_group = $config->{default_group} || 'default';
    my $down_age  = $config->{down_age} || '1 day';
    my $delimiter = $config->{'text'}->{'delimiter'} || ';';
    my $om = $config->{'output'} || 'none';

    my @devices = schema('netdisco')->resultset('Device')->search({},
      {
        '+columns' => {
          old => \"age(now(), last_discover) > interval '$down_age'"
        }
      })->all;

    my $devs = {};


    $config->{groups}    ||= { default => 'any' };
    $config->{vendormap} ||= {};
    $config->{excluded}  ||= {};


    my $oh;
    my $dbh;

    if ($om eq 'text') {
        my $path = $config->{'text'}->{'path'} || './router.db';
        open ($oh, ">", $path) or  return Status->error("Could not open $path: $!");
    }
    elsif ($om eq 'db') {
        my $db = $config->{'db'};
        my $username = $config->{'username'} || '';
        my $password = $config->{'username'} || '';

        $dbh = DBI->connect($db->{'source'}, $username, $password)
              or return Status->error($DBI::errstr);

        $dbh->do('CREATE TABLE IF NOT EXISTS oxidized (
                  ip TEXT PRIMARY KEY,
                  hostname TEXT, vendor text,
                  "group" text
                  );');

        $oh = $dbh->prepare('INSERT INTO oxidized(hostname,ip,vendor,"group") VALUES (?, ?, ?, ?)
            ON CONFLICT(ip) DO UPDATE SET
            hostname=excluded.hostname,
            vendor=excluded.vendor,
            "group"=excluded."group"');
    }
    else {
        return Status->error("$om is not a valid output method!");
    }

    my @routerdb;
    foreach my $device (@devices) {
        my $model = $device->model;
        if (check_acl_no($device, $config->{excluded})) {
          print " skipping $device: device excluded from export\n";
          next
        }
        my ($group) =
          (pairkeys pairfirst { check_acl_no($device, $b) } %{ $config->{groups} }) || $default_group;
        my ($vendor) =
          (pairkeys pairfirst { check_acl_no($device, $b) } %{ $config->{vendormap} }) || $device->os;
        my $name = $device->name;
        my $ip = $device->ip;
        my $desc  = $device->description;
        my $domain;
        if (not $vendor) {
            debug "No vendor, skipping";
            next;
        }

        push(@routerdb, [$name, $ip, $vendor, $group]);
    }

    foreach my $d (@routerdb) {
        if ($om eq 'text') {
            print $oh join($delimiter, @$d)."\n";
        }
        elsif ($om eq 'db') {
            $oh->execute(@$d);
        }
    }
    if ($om eq 'text') {
        close $om or warn "Could not close file: $!\n";
    }
    elsif ($om eq 'db') {
        $dbh->disconnect
            or warn "Could not disconnect: $DBI::errstr\n";
    }
    return Status->done('Wrote oxidized configuration.');
});

true;

=encoding utf8

=head1 NAME

MakeOxidizedConf - Generate oxidized Configuration

=head1 INTRODUCTION

This worker will generate an oxidized configuration for all devices in Netdisco.

Optionally you can provide configuration to control the output. You can configure
it to either push to a database (eg. PostgreSQL, SQLite, etc.) or write to a
router.db file, similar to rancid. Note for the databases you will need to install
a driver for the DBI class. PostgreSQL and SQLite are both already installed.

You could run this worker at 09:05 each day using the following configuration:

 schedule:
   makeoxidizedconf:
     when: '5 9 * * *'

Since MakeOxidizedConf is a worker module it can also be run via C<netdisco-do>:

 ~/bin/netdisco-do makeoxidizedconf

Skipped devices and the reason for skipping them can be seen by using C<-D>:

 ~/bin/netdisco-do makerancidconf -D

=head1 CONFIGURATION

Here is a complete example of the configuration, which must be called
C<oxidized>. 

 oxidized:
   down_age:        '1 day'                      # default
   default_group:   'default'                    # default
   type: 'text'                                  # default
   text:
      path: './rancid.conf'                      # default
      delimiter: ';'                             # default
   db:
     username: ''                                # default
     password: ''                                # default 
   source: 'DBI:Pg:dbname=oxidized;host=localhost'
   excluded:
     excludegroup1: 'host_group1_acl'
     excludegroup2: 'host_group2_acl'
   groups:
     groupname1:    'host_group3_acl'
     groupname2:    'host_group4_acl'
   vendormap:
     vname1:        'host_group5_acl'
     vname2:        'host_group6_acl'

Any values above that are a host group ACL will take either a single item or
a list of network identifiers or device properties. See the L<ACL
documentation|https://github.com/netdisco/netdisco/wiki/Configuration#access-control-lists>
wiki page for full details. We advise you to use the C<host_groups> setting
and then refer to named entries in that, for example:

 host_groups:
   coredevices: '192.0.2.0/24'
   edgedevices: '172.16.0.0/16'
   grp-nxos:    'os:nx-os'

 rancid:
   by_ip:          'any'

  oxidized:
   groups:
     core_devices: 'group:coredevices'
     edge_devices: 'group:edgedevices'
   vendormap:
     cisco-nx:     'group:grp-nxos'
    excluded:
      - 'os:CM'
    groups:
      huawei: 'os:VRP'
      edgse: 'model:.*EX2300.*'
    vendormap:
      vrp: 'os:vrp'
    output: 'db'
    db:
      username: ''
      password: ''
      source: 'DBI:Pg:dbname=oxidized;host=localhost'
    text:
      path: '/Users/rgasik/Documents/blah.db'
      delimiter: ':'

=head2 C<output>

The type of output to write. Either 'db' or 'text'.

=head3 C<text>

Configuration for text config.

=head3 C<path>

The path to write the file to.

=head3 C<delimeter>

Set this to the delimiter character for your F<router.db> entries if needed to
be different from the default, the default is C<;>.

=head2 C<db>

Config for writing to a database.

=head3 C<source>

The C<data_source> for C<DBI> to use.

B<Examples:>

=over 

=item * PostgreSQL: C<DBI:Pg:dbname=oxidized;host=localhost>

=item * SQLite: C<dbi:SQLite:dbname=baz.sqlite>

=back

Note that the oxidized table in the database needs to be created with the schema:

  CREATE TABLE oxidized (
    ip text primary key,
    hostname text,
    vendor text,
    "group" text
  );

This module will attempt to create the table if it does not exist.

=head3 C<username>

The username if needed for accessing the database.

=head3 C<password>

The password if needed for accessing the database.

=head2 C<down_age>

This should be the same or greater than the interval between regular discover
jobs on your network. Devices which have not been discovered within this time
will be marked as C<down> to rancid.

The format is any time interval known and understood by PostgreSQL, such as at
L<https://www.postgresql.org/docs/10/static/functions-datetime.html>.

=head2 C<default_group>

Put devices into this group if they do not match any other groups defined.

=head2 C<excluded>

This dictionary defines a list of devices that you do not wish to export to
oxidized configuration.

The value should be a L<Netdisco ACL|https://github.com/netdisco/netdisco/wiki/Configuration#access-control-lists>
to select devices in the Netdisco database.

=head2 C<groups>

This dictionary maps oxidized group names with configuration which will match
devices in the Netdisco database.

The left hand side (key) should be the oxidized group name, the right hand side
(value) should be a L<Netdisco
ACL|https://github.com/netdisco/netdisco/wiki/Configuration#access-control-lists>
to select devices in the Netdisco database.

=head2 C<vendormap>

If the vendor for oxidized is not the same as the os in Netdisco, enter it here.

The left hand side (key) should be the oxidized device type, the right hand side
(value) should be a L<Netdisco
ACL|https://github.com/netdisco/netdisco/wiki/Configuration#access-control-lists>
to select devices in the Netdisco database.

Note that vendors might have a large array of operating systems which require
different oxidized modules. Mapping operating systems to oxidized device types is
a good solution to use the correct device type. Examples:

 host_groups:
   grp-ciscosb:   'os:ros'

 oxidized:
   vendormap:
     cisco-sb:    'group:grp-ciscosb'


=head1 SEE ALSO

=over 4

=item *

L<https://github.com/ytti/oxidized>

=item *

L<https://github.com/netdisco/netdisco/wiki/Configuration#access-control-lists>

=back

=cut

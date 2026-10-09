#!/usr/bin/perl -w
use 5.020;
use experimental 'signatures';
use DateTime;
use DateTime::Duration;
use Image::ExifTool;
use Data::Dumper;
use File::Glob qw(bsd_glob);
use File::Basename qw(basename dirname);
use File::Spec;
use File::Copy qw(cp move);
use Memoize qw(memoize);
use Term::Output::List;
use File::XDG;
use Net::CalDAV::FindEntry;
#use Text::CleanFragment;
use YAML::Tiny 'LoadFile';

BEGIN {
    if ($^O =~ /\bMSWin32\b|\bcygwin\b/) {
        require Win32API::File;
        Win32API::File->import(qw<SetErrorMode SEM_FAILCRITICALERRORS>);

        SetErrorMode( SEM_FAILCRITICALERRORS() | SetErrorMode(0) );
    };
};

use Getopt::Long;
use Pod::Usage;

GetOptions(
    'target|t=s'      => \my $target,
    'archive|a'       => \my $archive_dir,
    'verbose|v'       => \my $verbose,
    'buffer-size|b=i' => \my $bufsize,
    'dry-run|n'       => \my $dry_run,
    'action=s'        => \my $action,
    'rsync=s'         => \my $rsync,
    'config=s'        => \my $config_file,
    'unsafe|k'        => \my $unsafe_ssl,
) or pod2usage(1);

$bufsize //= 65536 * 1024 * 1024;
if ($archive_dir) {
    $archive_dir = 'archive';
};

$action //= 'copy';
$rsync //= 'rsync';

$config_file //= File::XDG->new( name => 'import-images', api => 1 )->lookup_config_file( 'calendar.yml' );

{ no experimental 'signatures';
sub take($;@) {
    my $list = shift;
    @_[ @$list ]
}

sub take_first($;@) {
    my $count = shift;
    take([0..$count-1],@_);
}
}

$target ||= File::Spec->catdir($ENV{USERPROFILE}, 'Eigene Dateien', 'Eigene Bilder');

my $exif = Image::ExifTool->new( $_ );
sub capture_date {
    my ($image) = @_;
    my $info = $exif->ImageInfo($image);
    my $ts = $exif->GetValue('DateTimeOriginal') || "";
    if (my @t = ($ts =~ /^(\d+):(\d+):(\d+) (\d+):(\d+):(\d{2})/)) {
        my %opts;
        @opts{qw(year month day hour minute second)} = @t;
        return DateTime->new(%opts);
    } else {
        return DateTime->from_epoch(epoch => (stat $image)[9]);
    }
}

memoize('capture_date');
my $printer = Term::Output::List->new( hook_warnings => 1 );

sub currently( @msg ) {
    $printer->output_list( @msg );
}

currently("Collecting files");

if (! @ARGV) {
    if( $^O =~ /mswin/i ) {
        # XXX Should check all "removable drives" instead of hardcoding
        @ARGV = (qw(
            F:/DCIM/*
            G:/DCIM/*
            H:/DCIM/*
            I:/DCIM/*
        ),
        );
    } elsif( $ENV{TERMUX_PP_PID} ) {
        @ARGV = (glob "$ENV{HOME}/storage/dcim/*");
    } else {
        my %seen;
        # Get all mounted gvfs directories with a DCIM subdirectory
        # and all other mounted directories with a DCIM subdirectory
        # Yes, this is highly Debian/Linux-specific
        @ARGV = (
                 glob("$ENV{XDG_RUNTIME_DIR}/gvfs/*/*/DCIM/*"),
                 map { bsd_glob("$_/*") }
                 grep { ! $seen{ $_ }++ }
                 grep { -d }
                 map { m!-> file://(.*)\s*\z!    ? "$1/DCIM"
                     : m!-> gphoto2://(.*)\s*\z! ? "$ENV{XDG_RUNTIME_DIR}/gvfs/gphoto2:host=${1}DCIM"
                     : m!-> mtp://(.*)\s*\z!     ? "$ENV{XDG_RUNTIME_DIR}/gvfs/mtp:host=${1}Interner gemeinsamer Speicher/DCIM"
                     : ()
                     } `gio mount -l`
                );
    };
};

if ($verbose) {
    local $" = ",";
    $printer->output_permanent( "Scanning @ARGV" );
}

sub archive_dir {
    my ($file) =  @_;
    if ($archive_dir) {
        my $dir = dirname $file;
        my $adir = File::Spec->catdir($dir,$archive_dir);
        if( ! -d $adir) {
            mkdir $adir
                or do {
                    warn "Couldn't create archive directory '$adir'";
                    return undef
                }
        };
        return $adir
    }
    return undef
}
memoize('archive_dir');

sub archive_file {
    my ($file) = @_;
    if (defined( my $archive = archive_dir($file))) {
        if( $dry_run ) {
            $printer->output_permanent("move $_[0] => $archive" );
        } else {
            move $_[0] => $archive
                or warn "Couldn't archive $_[0]: $!";
        }
    }
}

currently("Collecting file dates");
my %c;
my @files = #take_first 3,
            grep { -f }
            map  { ;
                   ; currently("Collecting file dates for $_");
                   ; bsd_glob "$_/*"
                 }
            @ARGV;

# Now, look at the first file, to get our calendar starting point and also the
# first target directory to scan. We do this before reading the capture date
# because reading the capture date is slow
my $earliest_date;
for my $f (@files) {
    my $ts;
    if( $f =~ m/(20\d\d)([01]\d)([0123]\d).([012]\d)([0-5]\d)([0-5]\d)/ ) {
        # Guess from filename
        $ts = "$1$2$3-$4$5$6";
    } else {
        # take from file
        $ts = capture_date( $f )->strftime('%Y%m%d-%H%M%S');
    }
    $earliest_date //= $ts;
    if( $earliest_date gt $ts ) {
        $earliest_date = $ts;
    }
}
$printer->output_permanent("Earliest is " . $earliest_date);

sub r_readdir($dir, $type="d") {
    if( $dir =~ m!^ssh:(?<host>(\w+\@)?[^:]+):(?<path>.*)! ) {
        my $p = $-{path}->[0];

        my $cmd = "ssh '$-{host}->[0]' 'find \"$p\" -type $type'";

        currently("Reading '$p'");
        if($verbose) {
            $printer->output_permanent($cmd);
        }

        return map { s!^\Q$dir\E[/\\]?!!r }
               split /\r?\n/,readpipe( $cmd );
    } else {
        opendir my $dh, $dir
            or die "Can't read '$dir': $!";
        return readdir($dh);
    }
}

sub existing_directories( $dir, $earliest_date ) {
    $earliest_date =~ s/-.*//; # just take the whole day

    return
        sort
        grep { /^\d\d\d\d/ and $_ ge $earliest_date }
        #map { $printer->output_permanent("$_ / $earliest_date"); $_ }
        grep { !/^\./ }
        r_readdir( $dir, 'd' );
}
my @dirs = existing_directories( $target, $earliest_date );

# Now go two months before the earliest date and use all calendar entries
# since then to get overlapping multi-day entries correct under the assumption
# that we will not have multi-day entries longer than 2 months
if( $earliest_date and $earliest_date =~ /(\d\d\d\d)(\d\d)(\d\d)/ ) {
    $earliest_date = DateTime->new( year => $1, month => $2, day => $3)->add( months => -2);
}

# This needs to (also) become an ssh invocation, maybe simply `find @dirs`,
# but we have whitespace in directories, so that needs quoting...
sub existing_files( $target_directory, @directories ) {
    my %res;
    for my $d (@directories) {
        my $dir = "$target_directory/$d";
        my @files = r_readdir( $dir, 'f' );

        for my $file (@files) {
            $res{ $file } //= $dir;
        }
    }
    return \%res
}

my $exists = existing_files( $target, @dirs );
# We only need capture_date() for the files that have no place already
my @new_files = sort { capture_date($a) <=> capture_date($b) }
                grep { ! $exists->{ $_ } }
                @files;

# Images taken 5 hours apart get a new directory:
my $distance = DateTime::Duration->new( hours => 5  );
my $reference = DateTime->now;

if( scalar @files ) {
    currently(sprintf "%s unsorted images", scalar @files);
};

my %target_directories;

my $last_time = DateTime->from_epoch( epoch => 1 );
my $total = @files;
my $calendar;
my ($title, $ts);
for my $image (@files) {
    # @files contains @new_files, so we do everything
    my $target_directory;

    if( ! $exists->{ basename($image) }) {
        my $capture_date = capture_date($image)->strftime('%Y%m%d-%H%M');
        my $this_distance = (capture_date($image) - $last_time);

        if( ! $calendar ) {
            my $calendar_config;
            my $calendar_config_file = File::XDG->new( name => 'import-images', api => 1 )->lookup_config_file( 'calendar.yml' );
            if( $calendar_config_file ) {
                $calendar_config = LoadFile($calendar_config_file);
                $calendar = Net::CalDAV::FindEntry->new($calendar_config);

                if( $unsafe_ssl ) {
                    $calendar->ua->verify_SSL(0);
                }
            }
        };

        if ($reference+$this_distance > $reference+$distance) {
            $ts = capture_date($image)->strftime('%Y%m%d-%H%M');
        }

        if( $calendar ) {
            # Add calendar entry to directory name
            my $cts = capture_date($image)->strftime('%Y-%m-%dT%H:%M:%S');
            my @events = $calendar->get_events(
                after    => $cts,
                before   => $cts,
            );
            my ($ev) = sort { $b->{start} cmp $a->{start} } @events;
            if( $ev ) {
                if( $ev->{title} ne $title ) {
                    $ts = capture_date($image)->strftime('%Y%m%d-%H%M');
                    $title = $ev->{title};
                }
            };
        }

        my $album_directory = $ts;
        if( $title ) {
            $album_directory .= " - $title";
        }
        $target_directory = File::Spec->catdir($target, $album_directory =~ s/[:]//gr);

        $last_time = capture_date($image);

        #currently("Processing $capture_date ($album_directory)");
    } else {
        # In case an image was half-copied, rsync can pick up from there
        $target_directory = $exists->{ basename($image) };
    }

    $target_directories{ $target_directory } //= [];
    push $target_directories{ $target_directory }->@*, $image;

    currently(
        map { my $d = $_;
              $d =~ s/^(ssh:)?\Q$target\E//;
              sprintf "%s - %s\t\t%d", " ", $d, scalar $target_directories{ $_ }->@*
            }
        sort keys %target_directories
    );
}

my %done;
for my $target_directory (sort keys %target_directories) {
    $done{ $target_directory } = ".";
    currently(
        map { my $d = $_;
              $d =~ s/^(ssh:)?\Q$target\E//;
              sprintf "%s - %s\t\t%d", $done{ $_ }, $d, scalar $target_directories{ $_ }->@*
            }
        sort keys %target_directories
    );

    # Sort again by source directory
    my %source_directory;
    for my $image ($target_directories{ $target_directory }->@*) {
        $source_directory{ dirname $image } //= [];
        push $source_directory{ dirname $image }->@*, basename $image;
    };

    for my $dir (sort keys %source_directory) {
        $target_directory =~ s!^ssh:!!;
        my @cmd = ($rsync, '-az', '--no-relative', '--files-from=-', $dir, $target_directory );
        if( $dry_run ) {
            $printer->output_permanent( join " ", @cmd  );
            $printer->output_permanent( $source_directory{$dir}->@* );

        } else {
            local $SIG{PIPE} = sub { die "Rsync connection broke" };
            my $pid = open my $rsync_in, '|-', @cmd
                or die "Couldn't launch $rsync: $!";
            print $rsync_in join "\n", $source_directory{ $dir }->@*;
            close $rsync_in;
            my $err = $? >> 8;

            if( $err ) {
                $printer->output_permanent("rsync failed with $err");

            } else {

                for my $image ( $source_directory{ $dir }->@* ) {
                    my $target_name = archive_dir("$dir/$image");
                    if( $target_name ) {
                        $printer->output_permanent("$image -> $dir/$archive_dir/");
                        if(! move "$dir/$image" => $target_name) {
                            $printer->output_permanent( "Couldn't move '$dir/$image' to '$target_name': $!" );
                        };
                    }
                }
            }
        }
    };
    $done{ $target_directory } = "x";
};

$printer->output_list();

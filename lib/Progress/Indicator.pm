package Progress::Indicator;
use strict;
use Time::HiRes;
use POSIX qw(strftime);

use vars qw'%indicator $VERSION $line_width';

$VERSION = '0.10';

$line_width = 80; # a best guess

eval { 
    require Term::Size::Any;
    Term::Size::Any->import('chars');
    my ($out) = select;
    return if (! -t $out);
    $line_width = chars($out);
}

sub handle_unsized {
    my ($i) = @_;
    my $now = time();
    if (my $u = $i->{per_item}) {
        $u->($i);
    };
    if ($i->{last} + $i->{interval} <= $now ) {
        local $|;
        $| = 1;
        $i->{position} = $i->{get_position}->($i);
        my $elapsed = $now - $i->{start};
        my $per_sec = $i->{position} / $elapsed; # /
        my $line = sprintf "%s\t(%d)\t\t%0.2f/s",
            $i->{info},
            $i->{position}, 
            $per_sec
            ;
        my $lastline = $i->{lastline};
        $i->{lastline} = $line;
        while (length $line < length($lastline)) {
            $line .= " ";
        }
        print "$line\r";
        $i->{last} = $now;
    }
}

sub handle_sized {
    my ($i) = @_;
    my $now = time();
    if (my $u = $i->{per_item}) {
        $u->($i);
    };
    if ($i->{last} + $i->{interval} <= $now ) {
        local $|;
        $| = 1;
        $i->{position} = $i->{get_position}->($i);
        my $perc = $i->{position} / $i->{total}; #  /
        my $elapsed = $now - $i->{start};
        my $per_sec = $i->{position} / $elapsed; # /
        my $remaining = int (($i->{total} - $i->{position}) / $per_sec);
        #warn $remaining;
        $remaining = strftime( '%H:%M:%S', gmtime($remaining));
        my $line = sprintf "%s\t%d%% (%d of %d)\t\t%0.2f/s\t\tRemaining: %s",
            $i->{info},
            $perc * 100,
            $i->{position}, 
            $i->{total},
            $per_sec,
            $remaining;
        my $lastline = $i->{lastline};
        $i->{lastline} = $line;
        while (length $line < length($lastline)) {
            $line .= " ";
        }
        print "$line\r";
        $i->{last} = $now;
    }
}

sub new_indicator {
    my ($item,$info,$options) = @_;
    $options ||= {};
    $options->{interval} ||= 10;
    my $now = time();

    my ($per_item,$position,$total,$handler,$get_position);
    if (ref $item eq 'ARRAY') {
        # An array which we can size
        $position = 0;
        $total = @$item;
        $per_item = sub { $_[0]->{position}++ };
        $get_position = sub { $_[0]->{position} };
    } elsif (ref $item eq 'GLOB' or ref $item eq 'IO::Handle') {
        # A file which we can maybe size        
        if (seek $item, 0,0) { # seekable, we can trust -s ??
            $position = tell $item;
            $total = -s $item;
            $get_position = sub { tell $item };
            $per_item = undef;
        } else {
            $position = 0;
            $per_item = sub { $_[0]->{position}++ };
            $total = undef;
            $get_position = sub { $_[0]->{position} };
        }
    } else { # item of unknown size
        $position = 0;
        $per_item = sub { $_[0]->{position}++ };
        $total = undef;
        $get_position = sub { $_[0]->{position} };
    };
    
    $handler = defined $total ? \&handle_sized : \&handle_unsized;

    $indicator{ $item } = {
        start    => $now,
        last     => $now,
        position => $position,
        total    => $total,
        info     => $info,
        lastline => '',
        handler  => $handler,
        per_item => $per_item,
        get_position => $get_position,
        %$options,
    };
}

sub progress {
    my ($item,$info,$options) = @_;
    
    # No output if we're not interactive
    my ($out) = select;
    return if (! -t $out);
    
    my $i = $indicator{ $item };
    goto &new_indicator
        if (! defined $i);
    $i->{handler}->($i);
}

sub import {
    my ($this,$name) = @_;
    if (! defined $name) {
        $name = 'progress';
    };
    my $target = caller();
    no strict 'refs';
    *{"$target\::$name"} = \&progress;
}

1;
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
};

sub build_line {
    my ($i) = @_;
    
    # build the items
    my @visuals;
    my %info;
    
    # calculate some helpers
    my $now = time();
    $i->{position} = $i->{get_position}->($i);
    $info{ elapsed }= ($now - $i->{start}) || 1;
    my $per_sec =$i->{position} / $info{ elapsed }; # /
    $info{ per_sec }= sprintf "%0.2f/s", $per_sec;
    $info{ position }= sprintf "%d", $i->{position};
    $info{ info }= $i->{ info };

    if ($i->{total}) {
        $info{ position }= sprintf "(%d of %d)", $i->{position}, $i->{total};
        $info{ percent_done }= sprintf "%0.2f%%", $i->{position} / $i->{total} * 100; #  /
        $info{ remaining }= int( ($i->{total} - $i->{position}) / $per_sec );
        $info{ remaining }= strftime( 'Remaining: %H:%M:%S', gmtime($info{ remaining }));
    };
    
    my @columns;
    if ($i->{total}) {
        @columns = qw(info percent_done position per_sec remaining);
    } else {
        @columns = qw(info position per_sec);
    };
    
    # add them while there's still place
    my $line = $info{ +shift @columns };
    for (@columns) {
        return $line if length($line . " $info{$_}") > $line_width-1;
        $line .= " $info{ $_ }";
    }
    return $line
};

sub handle_unsized {
    my ($i) = @_;
    my $now = time();
    if (my $u = $i->{per_item}) {
        $u->($i);
    };
    if ($i->{last} + $i->{interval} <= $now ) {
        local $|;
        $| = 1;
        my $line = build_line($i);
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
        my $line = build_line($i);
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
    } elsif (ref $item eq 'SCALAR') {
        # A total number
        $position = 0;
        $total = $options->{total};
        $get_position = sub { $$item };
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
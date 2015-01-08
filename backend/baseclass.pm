#!/usr/bin/perl -w

# this is an abstract class
package backend::baseclass;
use strict;
use threads;
use threads::shared;
use Carp;
use Carp::Always;
use JSON qw( to_json );
use File::Copy qw(cp);
use File::Basename;
use Time::HiRes qw(gettimeofday);

my $framecounter    = 0;    # screenshot counter
our $MAGIC_PIPE_CLOSE_STRING = "xxxQUITxxx\n";

sub new {
    my $class = shift;
    my $self = bless( { class => $class }, $class );
    $self->init();
    $self->{'started'} = 0;
    return $self;
}

sub run {
    my ($self, $cmdpipe, $rsppipe) = @_;

    #$SIG{__DIE__} = sub { alarm 3 };

    my $io = IO::Handle->new();
    $io->fdopen( $cmdpipe, "r" ) || die "r fdopen $!";
    $self->{'cmdpipe'} = $io;

    $io = IO::Handle->new();
    $io->fdopen( $rsppipe, "w" ) || die "w fdopen $!";
    $rsppipe = $io;
    $io->autoflush(1);
    $self->{'rsppipe'} = $io;

    printf STDERR "$$: cmdpipe %d, rsppipe %d\n", fileno($self->{'cmdpipe'}), fileno($self->{'rsppipe'});

    bmwqemu::diag "started mgmt loop with thread id " . threads->tid();

    $self->{'select'} = IO::Select->new();
    $self->{'select'}->add($self->{'cmdpipe'});

    $self->do_run();
}

# new api

sub start_encoder() {
    my ($self) = @_;

    my $cwd = Cwd::getcwd();
    open($self->{'encoder_pipe'}, "|nice $bmwqemu::scriptdir/videoencoder $cwd/video.ogv")
      ||die "can't call $bmwqemu::scriptdir/videoencoder";
}

sub post_start_hook($) {
    my $self = shift; # ignored in base
    return 0;
}

sub stop_vm($) {
    my $self = shift;
    return unless $self->{'started'};
    close($self->{'encoder_pipe'});
    unlink('backend.run');
    $self->do_stop_vm();
    $self->{'started'} = 0;
}

sub alive($) {
    my $self = shift;
    if ( $self->{'started'} ) {
        if ( $self->file_alive() and $self->raw_alive() ) {
            return 1;
        }
        else {
            bmwqemu::diag("ALARM: backend.run got deleted! - exiting...");
            alarm 3;
        }
    }
    return 0;
}

my $iscrashedfile           = 'backend.crashed';
sub unlink_crash_file {
    unlink($iscrashedfile) if -e $iscrashedfile;
}

sub write_crash_file {
    if (open(my $fh, ">", $iscrashedfile )) {
        print $fh "crashed\n";
        close $fh;
    }
    else {
        warn "cannot write '$iscrashedfile'";
    }
}

# new api end

# virtual methods
sub notimplemented() { confess "backend method not implemented" }

sub init() {
    # static setup.  don't start the backend yet.
    notimplemented
}

sub power($) {

    # parameters: acpi, reset, (on), off
    notimplemented;
}

sub insert_cd($;$) { notimplemented }
sub eject_cd(;$)   { notimplemented }

sub do_start_vm($) {
    # start up the vm
    notimplemented
}

sub do_stop_vm($) { notimplemented }

sub stop         { notimplemented }
sub cont         { notimplemented }
sub do_savevm($) { notimplemented }
sub do_loadvm($) { notimplemented }
sub do_delvm($)  { notimplemented }

## MAY be overwritten:

sub get_backend_info($) {

    # returns hashref
    my $self = shift;
    return {};
}

sub cpu_stat($) {

    # vm's would return
    # (userstat, systemstat)
    return undef;
}

# see http://en.wikipedia.org/wiki/IBM_PC_keyboard
my  %charmap = (
    # minus is special as it splits key combinations
    "-"  => "minus",
    # first line of US layout
    "~"  => "shift-`",
    "!"  => "shift-1",
    "@"  => "shift-2",
    "#"  => "shift-3",
    "\$"  => "shift-4",
    "%"  => "shift-5",
    "^"  => "shift-6",
    "&"  => "shift-7",
    "*"  => "shift-8",
    "("  => "shift-9",
    ")"  => "shift-0",
    "_"  => "shift-minus",
    "+"  => "shift-=",

    # second line
    "{"  => "shift-[",
    "}"  => "shift-]",
    "|"  => "shift-\\",

    # third line
    ":"  => "shift-;",
    '"'  => "shift-'",

    # fourth line
    "<"  => "shift-,",
    ">"  => "shift-.",
    '?'  => "shift-/",

    "\t" => "tab",
    "\n" => "ret",
    "\b" => "backspace",
);


sub map_letter($) {
    my ($self, $letter) = @_;
    return $charmap{$letter} if $charmap{$letter};
    return $letter;
}

sub type_string($$) {
    my ($self, $string, $maxinterval) = @_;

    my $typedchars  = 0;
    my @letters = split( "", $string );
    while (@letters) {
        my $letter = $self->map_letter( shift @letters );
        send_key $letter, 0;
        if ( $typedchars++ >= $maxinterval ) {
            wait_still_screen(1.6);
            $typedchars = 0;
        }
    }
    wait_still_screen(1.6) if ( $typedchars > 0 );
}


sub screenshot_interval() {
    my ($self) = @_;

    return $bmwqemu::vars{SCREENSHOTINTERVAL} || .5;
}

our $lastscreenshot;
our $lastscreenshotName = '';

sub enqueue_screenshot() {
    my ($self, $image) = @_;

    return unless $image;
    my ( $s2, $usec2 ) = gettimeofday();
    my $rest = $self->screenshot_interval() -( $s2 - $self->{'screenshot'}->{'sec'} ) -( $usec2 - $self->{'screenshot'}->{'usec'} ) / 1e6;

    # don't overdo it
    return unless $rest < 0.05;
    $image = $image->scale( 1024, 768 );

    $framecounter++;

    my $filename = $bmwqemu::screenshotpath . sprintf( "/shot-%010d.png", $framecounter );

    #print STDERR $filename,"\n";

    # linking identical files saves space

    # 54 is based on t/data/user-settings-*
    my $sim = 0;
    $sim = $lastscreenshot->similarity($image) if $lastscreenshot;

    ( $self->{'screenshot'}->{'sec'}, $self->{'screenshot'}->{'usec'} ) = gettimeofday();

    #bmwqemu::diag "similarity is $sim";
    if ( $sim > 54 ) {
        symlink( basename($lastscreenshotName), $filename ) || warn "failed to create $filename symlink: $!\n";
    }
    else {    # new
        $image->write($filename) || die "write $filename";
        # copy new one to shared directory, remove old one and change symlink
        cp($filename, $bmwqemu::liveresultpath);
        unlink($bmwqemu::liveresultpath .'/'. basename($lastscreenshotName)) if $lastscreenshot;
        $bmwqemu::screenshotQueue->enqueue($filename);
        $lastscreenshot          = $image;
        $lastscreenshotName      = $filename;
        unless(symlink(basename($filename), $bmwqemu::liveresultpath.'/tmp.png')) {
            # try to unlink file and try again
            unlink($bmwqemu::liveresultpath.'/tmp.png');
            symlink(basename($filename), $bmwqemu::liveresultpath.'/tmp.png');
        }
        rename($bmwqemu::liveresultpath.'/tmp.png', $bmwqemu::liveresultpath.'/last.png');

        #my $ocr=get_ocr($image);
        #if($ocr) { diag "ocr: $ocr" }
    }
    if ( $sim > 50 ) { # we ignore smaller differences
        $self->{'encoder_pipe'}->print("R\n");
    }
    else {
        $self->{'encoder_pipe'}->print("E $lastscreenshotName\n");
    }
    $self->{'encoder_pipe'}->flush();
}

sub close_pipes() {
    my ($self) = @_;

    if ($self->{'cmdpipe'}) {
        close($self->{'cmdpipe'})   || die "close $!\n";
        $self->{'cmdpipe'} = undef;
    }

    return unless $self->{'rsppipe'};

    # XXX: perl does not really close the fd here due to threads!?
    $self->{'rsppipe'}->print($MAGIC_PIPE_CLOSE_STRING);
    close($self->{'rsppipe'}) || die "close $!\n";
}

# this is called for all sockets ready to read from
sub check_socket {
    my ($self, $fh) = @_;

    if ( $fh == $self->{'cmdpipe'} ) {
        my $cmd = backend::driver::_read_json($self->{'cmdpipe'});

        if ( $cmd->{cmd} ) {
            my $rsp = $self->handle_command($cmd);
            $self->{'rsppipe'}->print(JSON::to_json( { "rsp" => $rsp } ));
            $self->{'rsppipe'}->print("\n");
        }
        else {
            die "no command in " . Dumper($cmd);
        }
        return 1;
    }
    return 0;
}

1;
# vim: set sw=4 et:

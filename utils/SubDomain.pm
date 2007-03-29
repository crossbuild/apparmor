# $Id$
#
# ----------------------------------------------------------------------
#    Copyright (c) 2006 Novell, Inc. All Rights Reserved.
#
#    This program is free software; you can redistribute it and/or
#    modify it under the terms of version 2 of the GNU General Public
#    License as published by the Free Software Foundation.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, contact Novell, Inc.
#
#    To contact Novell about this file by physical or electronic mail,
#    you may find current contact information at www.novell.com.
# ----------------------------------------------------------------------

package Immunix::SubDomain;

use strict;
use warnings;

use Carp;
use Cwd qw(cwd realpath);
use File::Basename;
use Data::Dumper;

use Locale::gettext;
use POSIX;

use Immunix::Severity;

require Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw(
    %sd
    %qualifiers
    %include
    %helpers

    $filename
    $profiledir
    $parser
    $UI_Mode
    $running_under_genprof

    which
    getprofilefilename
    get_full_path
    fatal_error

    getprofileflags
    setprofileflags
    complain
    enforce

    autodep
    reload

    UI_GetString
    UI_GetFile
    UI_YesNo
    UI_Important
    UI_Info
    UI_PromptUser

    getkey

    do_logprof_pass

    readconfig
    loadincludes
    readprofile
    readprofiles
    writeprofile

    check_for_subdomain

    setup_yast
    shutdown_yast
    GetDataFromYast
    SendDataToYast

    checkProfileSyntax
    checkIncludeSyntax

    isSkippableFile
);

our $confdir = "/etc/apparmor";

our $running_under_genprof = 0;
our $finishing             = 0;

our $DEBUGGING;

our $unimplemented_warning = 0;

# keep track of if we're running under yast or not - default to text mode
our $UI_Mode = "text";

our $sevdb;

# initialize Term::ReadLine if it's available
our $term;
eval {
    require Term::ReadLine;
    import Term::ReadLine;
    $term = new Term::ReadLine 'AppArmor';
};

# initialize the local poo
setlocale(LC_MESSAGES, "");
textdomain("apparmor-utils");

# where do we get our log messages from?
our $filename;
if (-f "/var/log/audit/audit.log") {
    $filename = "/var/log/audit/audit.log";
} elsif (-f "/etc/slackware-version") {
    $filename = "/var/log/syslog";
} else {
    $filename = "/var/log/messages";
}

our $profiledir = "/etc/apparmor.d";

# we keep track of the included profile fragments with %include
my %include;

my %existing_profiles;

our $ldd    = "/usr/bin/ldd";
our $parser = "/sbin/subdomain_parser";
$parser = "/sbin/apparmor_parser" if -f "/sbin/apparmor_parser";

our $seenevents = 0;

# behaviour tweaking
our %qualifiers;
our %required_hats;
our %defaulthat;
our %globmap;
our @custom_includes;

# these are globs that the user specifically entered.  we'll keep track of
# them so that if one later matches, we'll suggest it again.
our @userglobs;

### THESE VARIABLES ARE USED WITHIN LOGPROF
our %t;
our %transitions;
our %sd;    # we keep track of the original profiles in %sd

my @log;
my %pid;

my %seen;
my %profilechanges;
my %prelog;
my %log;
my %changed;
my %skip;
our %helpers;    # we want to preserve this one between passes

my %variables;   # variables in config files

### THESE VARIABLES ARE USED WITHIN LOGPROF

sub debug ($) {
    my $message = shift;

    print DEBUG "$message\n" if $DEBUGGING;
}

BEGIN {
    use POSIX qw(:termios_h);

    my ($term, $oterm, $echo, $noecho, $fd_stdin);

    $fd_stdin = fileno(STDIN);

    $term = POSIX::Termios->new();
    $term->getattr($fd_stdin);
    $oterm = $term->getlflag();

    $echo   = ECHO | ECHOK | ICANON;
    $noecho = $oterm & ~$echo;

    sub cbreak {
        $term->setlflag($noecho);
        $term->setcc(VTIME, 1);
        $term->setattr($fd_stdin, TCSANOW);
    }

    sub cooked {
        $term->setlflag($oterm);
        $term->setcc(VTIME, 0);
        $term->setattr($fd_stdin, TCSANOW);
    }

    sub getkey {
        my $key = '';
        cbreak();
        sysread(STDIN, $key, 1);
        cooked();
        return $key;
    }

    # set things up to log extra info if they want...
    if ($ENV{LOGPROF_DEBUG}) {
        $DEBUGGING = 1;
        open(DEBUG, ">/tmp/logprof_debug_$$.log");
        my $oldfd = select(DEBUG);
        $| = 1;
        select($oldfd);
    } else {
        $DEBUGGING = 0;
    }
}

END {
    # reset the terminal state
    cooked();

    $DEBUGGING && debug "Exiting...";

    # close the debug log if necessary
    close(DEBUG) if $DEBUGGING;
}

# returns true if the specified program contains references to LD_PRELOAD or
# LD_LIBRARY_PATH to give the PX/UX code better suggestions
sub check_for_LD_XXX ($) {
    my $file = shift;

    return undef unless -f $file;

    # limit our checking to programs/scripts under 10k to speed things up a bit
    my $size = -s $file;
    return undef unless ($size && $size < 10000);

    my $found = undef;
    if (open(F, $file)) {
        while (<F>) {
            $found = 1 if /LD_(PRELOAD|LIBRARY_PATH)/;
        }
        close(F);
    }

    return $found;
}

sub fatal_error ($) {
    my $message = shift;

    my $details = "$message\n";

    if ($DEBUGGING) {

        # we'll include the stack backtrace if we're debugging...
        $details = Carp::longmess($message);

        # write the error to the log
        print DEBUG $details;
    }

    # we'll just shoot ourselves in the head if it was one of the yast
    # interface functions that ran into an error.  it gets really ugly if
    # the yast frontend goes away and we try to notify the user of that
    # problem by trying to send the yast frontend a pretty dialog box
    my $caller = (caller(1))[3];
    exit 1 if $caller =~ /::(Send|Get)Data(To|From)Yast$/;

    # tell the user what the hell happened
    UI_Important($details);

    # make sure the frontend exits cleanly...
    shutdown_yast();

    # die a horrible flaming death
    exit 1;
}

sub setup_yast {

    # set up the yast connection if we're running under yast...
    if ($ENV{YAST_IS_RUNNING}) {

        # load the yast module if available.
        eval { require ycp; };
        unless ($@) {
            import ycp;

            $UI_Mode = "yast";

            # let the frontend know that we're starting
            SendDataToYast({
                type   => "initial_handshake",
                status => "backend_starting"
            });

            # see if the frontend is just starting up also...
            my ($ypath, $yarg) = GetDataFromYast();
            unless ($yarg
                && (ref($yarg)      eq "HASH")
                && ($yarg->{type}   eq "initial_handshake")
                && ($yarg->{status} eq "frontend_starting"))
            {

                # something's broken, die a horrible, painful death
                fatal_error "Yast frontend is out of sync from backend agent.";
            }

            # the yast connection seems to be working okay
            return 1;
        }

    }

    # couldn't init yast
    return 0;
}

sub shutdown_yast {
    if ($UI_Mode eq "yast") {
        SendDataToYast({ type => "final_shutdown" });
        my ($ypath, $yarg) = GetDataFromYast();
    }
}

sub check_for_subdomain () {

    my ($support_subdomainfs, $support_securityfs);
    if (open(MOUNTS, "/proc/filesystems")) {
        while (<MOUNTS>) {
            $support_subdomainfs = 1 if m/subdomainfs/;
            $support_securityfs  = 1 if m/securityfs/;
        }
        close(MOUNTS);
    }

    my $sd_mountpoint = "";
    if (open(MOUNTS, "/proc/mounts")) {
        while (<MOUNTS>) {
            if ($support_subdomainfs) {
                $sd_mountpoint = $1 if m/^\S+\s+(\S+)\s+subdomainfs\s/;
            } elsif ($support_securityfs) {
                if (m/^\S+\s+(\S+)\s+securityfs\s/) {
                    if (-e "$1/apparmor") {
                        $sd_mountpoint = "$1/apparmor";
                    } elsif (-e "$1/subdomain") {
                        $sd_mountpoint = "$1/subdomain";
                    }
                }
            }
        }
        close(MOUNTS);
    }

    # make sure that subdomain is actually mounted there
    $sd_mountpoint = undef unless -f "$sd_mountpoint/profiles";

    return $sd_mountpoint;
}

sub which ($) {
    my $file = shift;

    foreach my $dir (split(/:/, $ENV{PATH})) {
        return "$dir/$file" if -x "$dir/$file";
    }

    return undef;
}

# we need to convert subdomain regexps to perl regexps
sub convert_regexp ($) {
    my $regexp = shift;

    # escape regexp-special characters we don't support
    $regexp =~ s/(?<!\\)(\+|\$)/\\$1/g;

    # escape . characters
    $regexp =~ s/(?<!\\)\./SDPROF_INTERNAL_DOT/g;

    # convert ** globs to match anything
    $regexp =~ s/(?<!\\)\*\*/.SDPROF_INTERNAL_GLOB/g;

    # convert * globs to match anything at current path level
    $regexp =~ s/(?<!\\)\*/[^\/]SDPROF_INTERNAL_GLOB/g;

    # convert ? globs to match a single character at current path level
    $regexp =~ s/(?<!\\)\?/[^\/]/g;

    # convert {foo,baz} to (foo|baz)
    $regexp =~ y/\{\}\,/\(\)\|/ if $regexp =~ /\{.*\,.*\}/;

    # twiddle the escaped * chars back
    $regexp =~ s/SDPROF_INTERNAL_GLOB/\*/g;

    # twiddle the escaped . chars back
    $regexp =~ s/SDPROF_INTERNAL_DOT/\\./g;

    return $regexp;
}

sub get_full_path ($) {
    my $originalpath = shift;

    my $path = $originalpath;

    # keep track so we can break out of loops
    my $linkcount = 0;

    # if we don't have any directory foo, look in the current dir
    $path = cwd() . "/$path" if $path !~ m/\//;

    # beat symlinks into submission
    while (-l $path) {

        if ($linkcount++ > 64) {
            fatal_error "Followed too many symlinks resolving $originalpath";
        }

        # split out the directory/file components
        if ($path =~ m/^(.*)\/(.+)$/) {
            my ($dir, $file) = ($1, $2);

            # figure out where the link is pointing...
            my $link = readlink($path);
            if ($link =~ /^\//) {
                # if it's an absolute link, just replace it
                $path = $link;
            } else {
                # if it's relative, let abs_path handle it
                $path = $dir . "/$link";
            }
        }
    }

    if (-f $path) {
        my ($dir, $file) = $path =~ m/^(.*)\/(.+)$/;
        $path = realpath($dir) . "/$file";
    } else {
        $path = realpath($path);
    }

    return $path;
}

sub findexecutable ($) {
    my $bin = shift;

    my $fqdbin;
    if (-e $bin) {
        $fqdbin = get_full_path($bin);
        chomp($fqdbin);
    } else {
        if ($bin !~ /\//) {
            my $which = which($bin);
            if ($which) {
                $fqdbin = get_full_path($which);
            }
        }
    }

    unless ($fqdbin && -e $fqdbin) {
        return undef;
    }

    return $fqdbin;
}

sub complain ($) {
    my $bin    = shift;
    my $fqdbin = findexecutable($bin)
      or fatal_error(sprintf(gettext('Can\'t find %s.'), $bin));

    # skip directories
    return unless -f $fqdbin;

    UI_Info(sprintf(gettext('Setting %s to complain mode.'), $fqdbin));

    my $filename = getprofilefilename($fqdbin);
    setprofileflags($filename, "complain");
}

sub enforce ($) {
    my $bin = shift;

    my $fqdbin = findexecutable($bin)
      or fatal_error(sprintf(gettext('Can\'t find %s.'), $bin));

    # skip directories
    return unless -f $fqdbin;

    UI_Info(sprintf(gettext('Setting %s to enforce mode.'), $fqdbin));

    my $filename = getprofilefilename($fqdbin);
    setprofileflags($filename, "");
}

sub head ($) {
    my $file = shift;

    my $first = "";
    if (open(FILE, $file)) {
        $first = <FILE>;
        close(FILE);
    }

    return $first;
}

sub get_output (@) {
    my ($program, @args) = @_;

    my $ret = -1;

    my $pid;
    my @output;

    if (-x $program) {
        $pid = open(KID_TO_READ, "-|");
        unless (defined $pid) {
            fatal_error "can't fork: $!";
        }

        if ($pid) {
            while (<KID_TO_READ>) {
                chomp;
                push @output, $_;
            }
            close(KID_TO_READ);
            $ret = $?;
        } else {
            ($>, $)) = ($<, $();
            open(STDERR, ">&STDOUT")
              || fatal_error "can't dup stdout to stderr";
            exec($program, @args) || fatal_error "can't exec program: $!";

            # NOTREACHED
        }
    }

    return ($ret, @output);
}

sub get_reqs ($) {
    my $file = shift;

    my @reqs;
    my ($ret, @ldd) = get_output($ldd, $file);

    if ($ret == 0) {
        for my $line (@ldd) {
            last if $line =~ /not a dynamic executable/;
            last if $line =~ /cannot read header/;
            last if $line =~ /statically linked/;

            # avoid new kernel 2.6 poo
            next if $line =~ /linux-(gate|vdso(32|64)).so/;

            if ($line =~ /^\s*\S+ => (\/\S+)/) {
                push @reqs, $1;
            } elsif ($line =~ /^\s*(\/\S+)/) {
                push @reqs, $1;
            }
        }
    }

    return @reqs;
}

sub handle_binfmt ($$) {
    my ($profile, $fqdbin) = @_;

    my %reqs;
    my @reqs = get_reqs($fqdbin);

    while (my $library = shift @reqs) {

        $library = get_full_path($library);

        push @reqs, get_reqs($library) unless $reqs{$library}++;

        # does path match anything pulled in by includes in original profile?
        my $combinedmode = matchincludes($profile, $library);

        # if we found any matching entries, do the modes match?
        next if $combinedmode;

        $library = globcommon($library);
        chomp $library;
        next unless $library;

        $profile->{path}->{$library} = "mr";
    }

    return $profile;
}

sub autodep ($) {
    my $bin = shift;

    # findexecutable() might fail if we're running on a different system
    # than the logs were collected on.  ugly.  we'll just hope for the best.
    my $fqdbin = findexecutable($bin) || $bin;

    # try to make sure we have a full path in case findexecutable failed
    return unless $fqdbin =~ /^\//;

    # ignore directories
    return if -d $fqdbin;

    my $profile = {
        flags   => "complain",
        include => { "abstractions/base" => 1 },
        path    => { $fqdbin => "mr" }
    };

    # if the executable exists on this system, pull in extra dependencies
    if (-f $fqdbin) {
        my $hashbang = head($fqdbin);
        if ($hashbang =~ /^#!\s*(\S+)/) {
            my $interpreter = get_full_path($1);
            $profile->{path}->{$interpreter} = "ix";
            if ($interpreter =~ /perl/) {
                $profile->{include}->{"abstractions/perl"} = 1;
            } elsif ($interpreter =~ m/\/bin\/(bash|sh)/) {
                $profile->{include}->{"abstractions/bash"} = 1;
            }
            $profile = handle_binfmt($profile, $interpreter);
        } else {
            $profile = handle_binfmt($profile, $fqdbin);
        }
    }

    # stick the profile into our data structure.
    $sd{$fqdbin}{$fqdbin} = $profile;

    # instantiate the required infrastructure hats for this changehat app
    for my $hatglob (keys %required_hats) {
        if ($fqdbin =~ /$hatglob/) {
            for my $hat (split(/\s+/, $required_hats{$hatglob})) {
                $sd{$fqdbin}{$hat} = { flags => "complain" };
            }
        }
    }

    if (-f "$profiledir/tunables/global") {
        my $file = getprofilefilename($fqdbin);

        unless (exists $variables{$file}) {
            $variables{$file} = {};
        }
        $variables{$file}{"#tunables/global"} = 1;    # sorry
    }

    # write out the profile...
    writeprofile($fqdbin);
}

sub getprofilefilename ($) {
    my $profile = shift;

    my $filename = $profile;
    $filename =~ s/\///;                              # strip leading /
    $filename =~ s/\//./g;                            # convert /'s to .'s

    return "$profiledir/$filename";
}

sub setprofileflags ($$) {
    my $filename = shift;
    my $newflags = shift;

    if (open(PROFILE, "$filename")) {
        if (open(NEWPROFILE, ">$filename.new")) {
            while (<PROFILE>) {
                if (m/^\s*("??\/.+?"??)\s+(flags=\(.+\)\s+)*\{\s*$/) {
                    my ($binary, $flags) = ($1, $2);

                    if ($newflags) {
                        $_ = "$binary flags=($newflags) {\n";
                    } else {
                        $_ = "$binary {\n";
                    }
                } elsif (m/^(\s*\^\S+)\s+(flags=\(.+\)\s+)*\{\s*$/) {
                    my ($hat, $flags) = ($1, $2);

                    if ($newflags) {
                        $_ = "$hat flags=($newflags) {\n";
                    } else {
                        $_ = "$hat {\n";
                    }
                }
                print NEWPROFILE;
            }
            close(NEWPROFILE);
            rename("$filename.new", "$filename");
        }
        close(PROFILE);
    }
}

sub profile_exists($) {
    my $program = shift || return 0;

    # if it's already in the cache, return true
    return 1 if $existing_profiles{$program};

    # if the profile exists, mark it in the cache and return true
    my $profile = getprofilefilename($program);
    if (-e $profile) {
        $existing_profiles{$program} = 1;
        return 1;
    }

    # couldn't find a profile, so we'll return false
    return 0;
}

##########################################################################
# Here are the console/yast interface functions

sub UI_Info ($) {
    my $text = shift;

    $DEBUGGING && debug "UI_Info: $UI_Mode: $text";

    if ($UI_Mode eq "text") {
        print "$text\n";
    } else {
        ycp::y2milestone($text);
    }
}

sub UI_Important ($) {
    my $text = shift;

    $DEBUGGING && debug "UI_Important: $UI_Mode: $text";

    if ($UI_Mode eq "text") {
        print "\n$text\n";
    } else {
        SendDataToYast({ type => "dialog-error", message => $text });
        my ($path, $yarg) = GetDataFromYast();
    }
}

sub UI_YesNo ($$) {
    my $text    = shift;
    my $default = shift;

    $DEBUGGING && debug "UI_YesNo: $UI_Mode: $text $default";

    my $ans;
    if ($UI_Mode eq "text") {

        my $yes = gettext("(Y)es");
        my $no  = gettext("(N)o");

        # figure out our localized hotkeys
        my $usrmsg = "PromptUser: " . gettext("Invalid hotkey for");
        $yes =~ /\((\S)\)/ or fatal_error "$usrmsg '$yes'";
        my $yeskey = lc($1);
        $no =~ /\((\S)\)/ or fatal_error "$usrmsg '$no'";
        my $nokey = lc($1);

        print "\n$text\n";
        if ($default eq "y") {
            print "\n[$yes] / $no\n";
        } else {
            print "\n$yes / [$no]\n";
        }
        $ans = getkey() || (($default eq "y") ? $yeskey : $nokey);

        # convert back from a localized answer to english y or n
        $ans = (lc($ans) eq $yeskey) ? "y" : "n";
    } else {

        SendDataToYast({ type => "dialog-yesno", question => $text });
        my ($ypath, $yarg) = GetDataFromYast();
        $ans = $yarg->{answer} || $default;

    }

    return $ans;
}

sub UI_YesNoCancel ($$) {
    my $text    = shift;
    my $default = shift;

    $DEBUGGING && debug "UI_YesNoCancel: $UI_Mode: $text $default";

    my $ans;
    if ($UI_Mode eq "text") {

        my $yes    = gettext("(Y)es");
        my $no     = gettext("(N)o");
        my $cancel = gettext("(C)ancel");

        # figure out our localized hotkeys
        my $usrmsg = "PromptUser: " . gettext("Invalid hotkey for");
        $yes =~ /\((\S)\)/ or fatal_error "$usrmsg '$yes'";
        my $yeskey = lc($1);
        $no =~ /\((\S)\)/ or fatal_error "$usrmsg '$no'";
        my $nokey = lc($1);
        $cancel =~ /\((\S)\)/ or fatal_error "$usrmsg '$cancel'";
        my $cancelkey = lc($1);

        $ans = "XXXINVALIDXXX";
        while ($ans !~ /^(y|n|c)$/) {
            print "\n$text\n";
            if ($default eq "y") {
                print "\n[$yes] / $no / $cancel\n";
            } elsif ($default eq "n") {
                print "\n$yes / [$no] / $cancel\n";
            } else {
                print "\n$yes / $no / [$cancel]\n";
            }

            $ans = getkey();

            if ($ans) {
                # convert back from a localized answer to english y or n
                $ans = lc($ans);
                if ($ans eq $yeskey) {
                    $ans = "y";
                } elsif ($ans eq $nokey) {
                    $ans = "n";
                } elsif ($ans eq $cancelkey) {
                    $ans = "c";
                }
            } else {
                $ans = $default;
            }
        }
    } else {

        SendDataToYast({ type => "dialog-yesnocancel", question => $text });
        my ($ypath, $yarg) = GetDataFromYast();
        $ans = $yarg->{answer} || $default;

    }

    return $ans;
}

sub UI_GetString ($$) {
    my $text    = shift;
    my $default = shift;

    $DEBUGGING && debug "UI_GetString: $UI_Mode: $text $default";

    my $string;
    if ($UI_Mode eq "text") {

        if ($term) {
            $string = $term->readline($text, $default);
        } else {
            local $| = 1;
            print "$text";
            $string = <STDIN>;
            chomp($string);
        }

    } else {

        SendDataToYast({
            type    => "dialog-getstring",
            label   => $text,
            default => $default
        });
        my ($ypath, $yarg) = GetDataFromYast();
        $string = $yarg->{string};

    }
    return $string;
}

sub UI_GetFile ($) {
    my $f = shift;

    $DEBUGGING && debug "UI_GetFile: $UI_Mode";

    my $filename;
    if ($UI_Mode eq "text") {

        local $| = 1;
        print "$f->{description}\n";
        $filename = <STDIN>;
        chomp($filename);

    } else {

        $f->{type} = "dialog-getfile";

        SendDataToYast($f);
        my ($ypath, $yarg) = GetDataFromYast();
        if ($yarg->{answer} eq "okay") {
            $filename = $yarg->{filename};
        }
    }

    return $filename;
}

my %CMDS = (
    CMD_ALLOW            => "(A)llow",
    CMD_DENY             => "(D)eny",
    CMD_ABORT            => "Abo(r)t",
    CMD_FINISHED         => "(F)inish",
    CMD_INHERIT          => "(I)nherit",
    CMD_PROFILE          => "(P)rofile",
    CMD_PROFILE_CLEAN    => "(P)rofile Clean Exec",
    CMD_UNCONFINED       => "(U)nconfined",
    CMD_UNCONFINED_CLEAN => "(U)nconfined Clean Exec",
    CMD_NEW              => "(N)ew",
    CMD_GLOB             => "(G)lob",
    CMD_GLOBEXT          => "Glob w/(E)xt",
    CMD_ADDHAT           => "(A)dd Requested Hat",
    CMD_USEDEFAULT       => "(U)se Default Hat",
    CMD_SCAN             => "(S)can system log for SubDomain events",
    CMD_HELP             => "(H)elp",
);

sub UI_PromptUser ($) {
    my $q = shift;

    my ($cmd, $arg);
    if ($UI_Mode eq "text") {

        ($cmd, $arg) = Text_PromptUser($q);

    } else {

        $q->{type} = "wizard";

        SendDataToYast($q);
        my ($ypath, $yarg) = GetDataFromYast();

        $cmd = $yarg->{selection} || "CMD_ABORT";
        $arg = $yarg->{selected};
    }

    return ($cmd, $arg);
}

##########################################################################
# here are the interface functions to send data back and forth between
# the yast frontend and the perl backend

# this is super ugly, but waits for the next ycp Read command and sends data
# back to the ycp front end.

sub SendDataToYast {
    my $data = shift;

    $DEBUGGING && debug "SendDataToYast: Waiting for YCP command";

    while (<STDIN>) {
        $DEBUGGING && debug "SendDataToYast: YCP: $_";
        my ($ycommand, $ypath, $yargument) = ycp::ParseCommand($_);

        if ($ycommand && $ycommand eq "Read") {

            if ($DEBUGGING) {
                my $debugmsg = Data::Dumper->Dump([$data], [qw(*data)]);
                debug "SendDataToYast: Sending--\n$debugmsg";
            }

            ycp::Return($data);
            return 1;

        } else {

            $DEBUGGING && debug "SendDataToYast: Expected 'Read' but got-- $_";

        }
    }

    # if we ever break out here, something's horribly wrong.
    fatal_error "SendDataToYast: didn't receive YCP command before connection died";
}

# this is super ugly, but waits for the next ycp Write command and grabs
# whatever the ycp front end gives us

sub GetDataFromYast {

    $DEBUGGING && debug "GetDataFromYast: Waiting for YCP command";

    while (<STDIN>) {
        $DEBUGGING && debug "GetDataFromYast: YCP: $_";
        my ($ycmd, $ypath, $yarg) = ycp::ParseCommand($_);

        if ($DEBUGGING) {
            my $debugmsg = Data::Dumper->Dump([$yarg], [qw(*data)]);
            debug "GetDataFromYast: Received--\n$debugmsg";
        }

        if ($ycmd && $ycmd eq "Write") {

            ycp::Return("true");
            return ($ypath, $yarg);

        } else {
            $DEBUGGING && debug "GetDataFromYast: Expected 'Write' but got-- $_";
        }
    }

    # if we ever break out here, something's horribly wrong.
    fatal_error "GetDataFromYast: didn't receive YCP command before connection died";
}

##########################################################################
# this is the hideously ugly function that descends down the flow/event
# trees that we've generated by parsing the logfile

sub handlechildren {
    my $profile = shift;
    my $hat     = shift;
    my $root    = shift;

    my @entries = @$root;
    for my $entry (@entries) {
        fatal_error "$entry is not a ref" if not ref($entry);

        if (ref($entry->[0])) {
            handlechildren($profile, $hat, $entry);
        } else {

            my @entry = @$entry;
            my $type  = shift @entry;

            if ($type eq "fork") {
                my ($pid, $p, $h) = @entry;

                if (   ($p !~ /null(-complain)*-profile/)
                    && ($h !~ /null(-complain)*-profile/))
                {
                    $profile = $p;
                    $hat     = $h;
                }

                $profilechanges{$pid} = $profile;

            } elsif ($type eq "unknown_hat") {
                my ($pid, $p, $h, $sdmode, $uhat) = @entry;

                if ($p !~ /null(-complain)*-profile/) {
                    $profile = $p;
                }

                if ($sd{$profile}{$uhat}) {
                    $hat = $uhat;
                    next;
                }

                # figure out what our default hat for this application is.
                my $defaulthat;
                for my $hatglob (keys %defaulthat) {
                    $defaulthat = $defaulthat{$hatglob}
                      if $profile =~ /$hatglob/;
                }

                # keep track of previous answers for this run...
                my $context = $profile;
                $context .= " -> ^$uhat";
                my $ans = $transitions{$context} || "";

                unless ($ans) {
                    my $q = {};
                    $q->{headers} = [];
                    push @{ $q->{headers} }, gettext("Profile"), $profile;
                    if ($defaulthat) {
                        push @{ $q->{headers} }, gettext("Default Hat"), $defaulthat;
                    }
                    push @{ $q->{headers} }, gettext("Requested Hat"), $uhat;

                    $q->{functions} = [];
                    push @{ $q->{functions} }, "CMD_ADDHAT";
                    push @{ $q->{functions} }, "CMD_USEDEFAULT" if $defaulthat;
                    push @{ $q->{functions} }, "CMD_DENY";
                    push @{ $q->{functions} }, "CMD_ABORT";
                    push @{ $q->{functions} }, "CMD_FINISHED";

                    $q->{default} = ($sdmode eq "PERMITTING") ? "CMD_ADDHAT" : "CMD_DENY";

                    $seenevents++;

                    my $arg;
                    ($ans, $arg) = UI_PromptUser($q);

                    $transitions{$context} = $ans;
                }

                # ugh, there's a bug here.  if they pick "abort" or "finish"
                # and then say "well, no, I didn't really mean that", we need
                # to ask the question again, but we currently go on to the
                # next one.  oops.
                if ($ans eq "CMD_ADDHAT") {
                    $hat = $uhat;
                    $sd{$profile}{$hat}{flags} = $sd{$profile}{$profile}{flags};
                } elsif ($ans eq "CMD_USEDEFAULT") {
                    $hat = $defaulthat;
                } elsif ($ans eq "CMD_DENY") {
                    return;
                } elsif ($ans eq "CMD_ABORT") {
                    my $ans = UI_YesNo(gettext("Are you sure you want to abandon this set of profile changes and exit?"), "n");
                    if ($ans eq "y") {
                        UI_Info(gettext("Abandoning all changes."));
                        shutdown_yast();
                        exit 0;
                    }
                } elsif ($ans eq "CMD_FINISHED") {
                    my $ans = UI_YesNo(gettext("Are you sure you want to save the current set of profile changes and exit?"), "n");
                    if ($ans eq "y") {
                        UI_Info(gettext("Saving all changes."));
                        $finishing = 1;

                        # XXX - BUGBUG - this is REALLY nasty, but i'm in
                        # a hurry...
                        goto SAVE_PROFILES;
                    }
                }

            } elsif ($type eq "capability") {
               my ($pid, $p, $h, $prog, $sdmode, $capability) = @entry;

                if (   ($p !~ /null(-complain)*-profile/)
                    && ($h !~ /null(-complain)*-profile/))
                {
                    $profile = $p;
                    $hat     = $h;
                }

                # print "$pid $profile $hat $prog $sdmode capability $capability\n";

                next unless $profile && $hat;

                $prelog{$sdmode}{$profile}{$hat}{capability}{$capability} = 1;
            } elsif (($type eq "path") || ($type eq "exec")) {
                my ($pid, $p, $h, $prog, $sdmode, $mode, $detail) = @entry;

                if (   ($p !~ /null(-complain)*-profile/)
                    && ($h !~ /null(-complain)*-profile/))
                {
                    $profile = $p;
                    $hat     = $h;
                }

                next unless $profile && $hat;

                my $domainchange = ($type eq "exec") ? "change" : "nochange";

                # escape special characters that show up in literal paths
                $detail =~ s/(\[|\]|\+|\*|\{|\})/\\$1/g;

                # we need to give the Execute dialog if they're requesting x
                # access for something that's not a directory - we'll force
                # a "ix" Path dialog for directories
                my $do_execute  = 0;
                my $exec_target = $detail;
                if ($mode =~ s/x//g) {
                    if (-d $exec_target) {
                        $mode .= "ix";
                    } else {
                        $do_execute = 1;
                    }
                }

                if ($mode eq "link") {
                    $mode = "l";
                    if ($detail =~ m/^from (.+) to (.+)$/) {
                        my ($path, $target) = ($1, $2);

                        my $frommode = "lr";
                        if (defined $prelog{$sdmode}{$profile}{$hat}{path}{$path}) {
                            $frommode .= $prelog{$sdmode}{$profile}{$hat}{path}{$path};
                        }
                        $frommode = collapsemode($frommode);
                        $prelog{$sdmode}{$profile}{$hat}{path}{$path} = $frommode;

                        my $tomode = "lr";
                        if (defined $prelog{$sdmode}{$profile}{$hat}{path}{$target}) {
                            $tomode .= $prelog{$sdmode}{$profile}{$hat}{path}{$target};
                        }
                        $tomode = collapsemode($tomode);
                        $prelog{$sdmode}{$profile}{$hat}{path}{$target} = $tomode;

                        # print "$pid $profile $hat $prog $sdmode $path:$frommode -> $target:$tomode\n";
                    } else {
                        next;
                    }
                } elsif ($mode) {
                    my $path = $detail;

                    if (defined $prelog{$sdmode}{$profile}{$hat}{path}{$path}) {
                        $mode .= $prelog{$sdmode}{$profile}{$hat}{path}{$path};
                        $mode = collapsemode($mode);
                    }

                    $prelog{$sdmode}{$profile}{$hat}{path}{$path} = $mode;

                    # print "$pid $profile $hat $prog $sdmode $mode $path\n";
                }

                if ($do_execute) {

                    my $context = $profile;
                    $context .= "^$hat" if $profile ne $hat;
                    $context .= " -> $exec_target";
                    my $ans = $transitions{$context} || "";

                    my ($combinedmode, $cm, @m);

                    # does path match any regexps in original profile?
                    ($cm, @m) = rematchfrag($sd{$profile}{$hat}, $exec_target);
                    $combinedmode .= $cm if $cm;

                    # does path match anything pulled in by includes in
                    # original profile?
                    ($cm, @m) = matchincludes($sd{$profile}{$hat}, $exec_target);
                    $combinedmode .= $cm if $cm;

                    my $exec_mode;
                    if (contains($combinedmode, "ix")) {
                        $ans       = "CMD_INHERIT";
                        $exec_mode = "ixr";
                    } elsif (contains($combinedmode, "px")) {
                        $ans       = "CMD_PROFILE";
                        $exec_mode = "px";
                    } elsif (contains($combinedmode, "ux")) {
                        $ans       = "CMD_UNCONFINED";
                        $exec_mode = "ux";
                    } elsif (contains($combinedmode, "Px")) {
                        $ans       = "CMD_PROFILE_CLEAN";
                        $exec_mode = "Px";
                    } elsif (contains($combinedmode, "Ux")) {
                        $ans       = "CMD_UNCONFINED_CLEAN";
                        $exec_mode = "Ux";
                    } else {
                        my $options = $qualifiers{$exec_target} || "ipu";

                        # force "ix" as the only option when the profiled
                        # program executes itself
                        $options = "i" if $exec_target eq $profile;

                        # we always need deny...
                        $options .= "d";

                        # figure out what our default option should be...
                        my $default;
                        if ($options =~ /p/
                            && -e getprofilefilename($exec_target))
                        {
                            $default = "CMD_PROFILE";
                        } elsif ($options =~ /i/) {
                            $default = "CMD_INHERIT";
                        } else {
                            $default = "CMD_DENY";
                        }

                        # ugh, this doesn't work if someone does an ix before
                        # calling this particular child process.  at least
                        # it's only a hint instead of mandatory to get this
                        # right.
                        my $parent_uses_ld_xxx = check_for_LD_XXX($profile);

                        my $severity = $sevdb->rank($exec_target, "x");

                        # build up the prompt...
                        my $q = {};
                        $q->{headers} = [];
                        push @{ $q->{headers} }, gettext("Profile"), combine_name($profile, $hat);
                        if ($prog && $prog ne "HINT") {
                            push @{ $q->{headers} }, gettext("Program"), $prog;
                        }
                        push @{ $q->{headers} }, gettext("Execute"),  $exec_target;
                        push @{ $q->{headers} }, gettext("Severity"), $severity;

                        $q->{functions} = [];

                        my $prompt = "\n$context\n";
                        push @{ $q->{functions} }, "CMD_INHERIT"
                          if $options =~ /i/;
                        push @{ $q->{functions} }, "CMD_PROFILE"
                          if $options =~ /p/;
                        push @{ $q->{functions} }, "CMD_UNCONFINED"
                          if $options =~ /u/;
                        push @{ $q->{functions} }, "CMD_DENY";
                        push @{ $q->{functions} }, "CMD_ABORT";
                        push @{ $q->{functions} }, "CMD_FINISHED";

                        $q->{default} = $default;

                        $options = join("|", split(//, $options));

                        $seenevents++;

                        my $arg;
                        while ($ans !~ m/^CMD_(INHERIT|PROFILE|PROFILE_CLEAN|UNCONFINED|UNCONFINED_CLEAN|DENY)$/) {
                            ($ans, $arg) = UI_PromptUser($q);

                            # check for Abort or Finish
                            if ($ans eq "CMD_ABORT") {
                                my $ans = UI_YesNo(gettext("Are you sure you want to abandon this set of profile changes and exit?"), "n");
                                $DEBUGGING && debug "back from abort yesno";
                                if ($ans eq "y") {
                                    UI_Info(gettext("Abandoning all changes."));
                                    shutdown_yast();
                                    exit 0;
                                }
                            } elsif ($ans eq "CMD_FINISHED") {
                                my $ans = UI_YesNo(gettext("Are you sure you want to save the current set of profile changes and exit?"), "n");
                                if ($ans eq "y") {
                                    UI_Info(gettext("Saving all changes."));
                                    $finishing = 1;

                                    # XXX - BUGBUG - this is REALLY nasty,
                                    # but i'm in a hurry...
                                    goto SAVE_PROFILES;
                                }
                            } elsif ($ans eq "CMD_PROFILE") {
                                my $px_default = "n";
                                my $px_mesg    = gettext("Should AppArmor sanitize the environment when\nswitching profiles?\n\nSanitizing the environment is more secure,\nbut some applications depend on the presence\nof LD_PRELOAD or LD_LIBRARY_PATH.");
                                if ($parent_uses_ld_xxx) {
                                    $px_mesg = gettext("Should AppArmor sanitize the environment when\nswitching profiles?\n\nSanitizing the environment is more secure,\nbut this application appears to use LD_PRELOAD\nor LD_LIBRARY_PATH and clearing these could\ncause functionality problems.");
                                }
                                my $ynans = UI_YesNo($px_mesg, $px_default);
                                if ($ynans eq "y") {
                                    $ans = "CMD_PROFILE_CLEAN";
                                }
                            } elsif ($ans eq "CMD_UNCONFINED") {
                                my $ynans = UI_YesNo(sprintf(gettext("Launching processes in an unconfined state is a very\ndangerous operation and can cause serious security holes.\n\nAre you absolutely certain you wish to remove all\nAppArmor protection when executing \%s?"), $exec_target), "n");
                                if ($ynans eq "y") {
                                    my $ynans = UI_YesNo(gettext("Should AppArmor sanitize the environment when\nrunning this program unconfined?\n\nNot sanitizing the environment when unconfining\na program opens up significant security holes\nand should be avoided if at all possible."), "y");
                                    if ($ynans eq "y") {
                                        $ans = "CMD_UNCONFINED_CLEAN";
                                    }
                                } else {
                                    $ans = "INVALID";
                                }
                            }
                        }
                        $transitions{$context} = $ans;

                        # if we're inheriting, things'll bitch unless we have r
                        if ($ans eq "CMD_INHERIT") {
                            $exec_mode = "ixr";
                        } elsif ($ans eq "CMD_PROFILE") {
                            $exec_mode = "px";
                        } elsif ($ans eq "CMD_UNCONFINED") {
                            $exec_mode = "ux";
                        } elsif ($ans eq "CMD_PROFILE_CLEAN") {
                            $exec_mode = "Px";
                        } elsif ($ans eq "CMD_UNCONFINED_CLEAN") {
                            $exec_mode = "Ux";
                        } else {

                            # skip all remaining events if they say to deny
                            # the exec
                            return if $domainchange eq "change";
                        }

                        unless ($ans eq "CMD_DENY") {
                            if (defined $prelog{PERMITTING}{$profile}{$hat}{path}{$exec_target}) {
                                $exec_mode .= $prelog{PERMITTING}{$profile}{$hat}{path}{$exec_target};
                                $exec_mode = collapsemode($exec_mode);
                            }
                            $prelog{PERMITTING}{$profile}{$hat}{path}{$exec_target} = $exec_mode;
                            $log{PERMITTING}{$profile}              = {};
                            $sd{$profile}{$hat}{path}{$exec_target} = $exec_mode;

                            # mark this profile as changed
                            $changed{$profile} = 1;

                            if ($ans eq "CMD_INHERIT") {
                                if ($exec_target =~ /perl/) {
                                    $sd{$profile}{$hat}{include}{"abstractions/perl"} = 1;
                                } elsif ($detail =~ m/\/bin\/(bash|sh)/) {
                                    $sd{$profile}{$hat}{include}{"abstractions/bash"} = 1;
                                }
                                my $hashbang = head($exec_target);
                                if ($hashbang =~ /^#!\s*(\S+)/) {
                                    my $interpreter = get_full_path($1);
                                    $sd{$profile}{$hat}{path}->{$interpreter} = "ix";
                                    if ($interpreter =~ /perl/) {
                                        $sd{$profile}{$hat}{include}{"abstractions/perl"} = 1;
                                    } elsif ($interpreter =~ m/\/bin\/(bash|sh)/) {
                                        $sd{$profile}{$hat}{include}{"abstractions/bash"} = 1;
                                    }
                                }
                            } elsif ($ans =~ /^CMD_PROFILE/) {

                                # if they want to use px, make sure a profile
                                # exists for the target.
                                unless (-e getprofilefilename($exec_target)) {
                                    $helpers{$exec_target} = "enforce";
                                    autodep($exec_target);
                                    reload($exec_target);
                                }
                            }
                        }
                    }

                    # print "$pid $profile $hat EXEC $exec_target $ans $exec_mode\n";

                    # update our tracking info based on what kind of change
                    # this is...
                    if ($ans eq "CMD_INHERIT") {
                        $profilechanges{$pid} = $profile;
                    } elsif ($ans =~ /^CMD_PROFILE/) {
                        if ($sdmode eq "PERMITTING") {
                            if ($domainchange eq "change") {
                                $profile              = $exec_target;
                                $hat                  = $exec_target;
                                $profilechanges{$pid} = $profile;
                            }
                        }
                    } elsif ($ans =~ /^CMD_UNCONFINED/) {
                        $profilechanges{$pid} = "unconstrained";
                        return if $domainchange eq "change";
                    }
                }
            }
        }
    }
}

sub add_to_tree ($@) {
    my ($pid, $type, @event) = @_;

    unless (exists $pid{$pid}) {
        my $arrayref = [];
        push @log, $arrayref;
        $pid{$pid} = $arrayref;
    }

    push @{ $pid{$pid} }, [ $type, $pid, @event ];
}

sub do_logprof_pass {
    my $logmark = shift || "";

    # zero out the state variables for this pass...
    %t              = ();
    %transitions    = ();
    %seen           = ();
    %sd             = ();
    %profilechanges = ();
    %prelog         = ();
    %log            = ();
    %changed        = ();
    %skip           = ();
    %variables      = ();

    UI_Info(sprintf(gettext('Reading log entries from %s.'),      $filename));
    UI_Info(sprintf(gettext('Updating AppArmor profiles in %s.'), $profiledir));

    readprofiles();

    my $seenmark = $logmark ? 0 : 1;

    $sevdb = new Immunix::Severity("$confdir/severity.db", gettext("unknown"));

    my $stuffed = undef;
    my $last;

    # okay, done loading the previous profiles, get on to the good stuff...
    open(LOG, $filename)
      or fatal_error "Can't read AppArmor logfile $filename: $!";
    while (($_ = $stuffed) || ($_ = <LOG>)) {
        chomp;

        $stuffed = undef;

        $seenmark = 1 if /$logmark/;

        next unless $seenmark;

        # all we care about is subdomain messages
        next
          unless (/^.* audit\(/
            || /type=(APPARMOR|UNKNOWN\[1500\]) msg=audit\([\d\.\:]+\):/
            || /SubDomain/);

        # workaround for syslog uglyness.
        if (s/(PERMITTING|REJECTING)-SYSLOGFIX/$1/) {
            s/%%/%/g;
        }

        if (m/LOGPROF-HINT unknown_hat (\S+) pid=(\d+) profile=(.+) active=(.+)/) {
            my ($uhat, $pid, $profile, $hat) = ($1, $2, $3, $4);

            $last = $&;

            # we want to ignore entries for profiles that don't exist - they're
            # most likely broken entries or old entries for deleted profiles
            next
              if ( ($profile ne 'null-complain-profile')
                && (!profile_exists($profile)));

            add_to_tree($pid, "unknown_hat", $profile, $hat, "PERMITTING", $uhat);
        } elsif (m/LOGPROF-HINT (unknown_profile|missing_mandatory_profile) image=(.+) pid=(\d+) profile=(.+) active=(.+)/) {
            my ($image, $pid, $profile, $hat) = ($2, $3, $4, $5);

            next if $last =~ /PERMITTING x access to $image/;
            $last = $&;

            # we want to ignore entries for profiles that don't exist - they're
            # most likely broken entries or old entries for deleted profiles
            next
              if ( ($profile ne 'null-complain-profile')
                && (!profile_exists($profile)));

            add_to_tree($pid, "exec", $profile, $hat, "HINT", "PERMITTING", "x", $image);

        } elsif (m/(PERMITTING|REJECTING) (\S+) access (.+) \((.+)\((\d+)\) profile (.+) active (.+)\)/) {
            my ($sdmode, $mode, $detail, $prog, $pid, $profile, $hat) = ($1, $2, $3, $4, $5, $6, $7);

            my $domainchange = "nochange";
            if ($mode =~ /x/) {

                # we need to try to check if we're doing a domain transition
                if ($sdmode eq "PERMITTING") {
                    do {
                        $stuffed = <LOG>;
                    } until ((! $stuffed) || ($stuffed =~ /AppArmor|audit/));

                    if ($stuffed && ($stuffed =~ m/changing_profile/)) {
                        $domainchange = "change";
                        $stuffed      = undef;
                    }
                }
            } else {

                # we want to ignore duplicates for things other than executes...
                next if $seen{$&};
                $seen{$&} = 1;
            }

            $last = $&;

            # we want to ignore entries for profiles that don't exist - they're
            # most likely broken entries or old entries for deleted profiles
            if (   ($profile ne 'null-complain-profile')
                && (!profile_exists($profile)))
            {
                $stuffed = undef;
                next;
            }

            # currently no way to stick pipe mediation in a profile, ignore
            # any messages like this
            next if $detail =~ /to pipe:/;

            # strip out extra extended attribute info since we don't currently
            # have a way to specify it in the profile and instead just need to
            # provide the access to the base filename
            $detail =~ s/\s+extended attribute \S+//;

            # kerberos code checks to see if the krb5.conf file is world
            # writable in a stupid way so we'll ignore any w accesses to
            # krb5.conf
            next if (($detail eq "to /etc/krb5.conf") && contains($mode, "w"));

            # strip off the (deleted) tag that gets added if it's a deleted file
            $detail =~ s/\s+\(deleted\)$//;

#            next if (($detail =~ /to \/lib\/ld-/) && ($mode =~ /x/));

            $detail =~ s/^to\s+//;

            if ($domainchange eq "change") {
                add_to_tree($pid, "exec", $profile, $hat, $prog, $sdmode, $mode, $detail);
            } else {
                add_to_tree($pid, "path", $profile, $hat, $prog, $sdmode, $mode, $detail);
            }

        } elsif (m/(PERMITTING|REJECTING) (?:mk|rm)dir on (.+) \((.+)\((\d+)\) profile (.+) active (.+)\)/) {
            my ($sdmode, $path, $prog, $pid, $profile, $hat) = ($1, $2, $3, $4, $5, $6);

            # we want to ignore duplicates for things other than executes...
            next if $seen{$&}++;

            $last = $&;

            # we want to ignore entries for profiles that don't exist - they're
            # most likely broken entries or old entries for deleted profiles
            next
              if ( ($profile ne 'null-complain-profile')
                && (!profile_exists($profile)));

            add_to_tree($pid, "path", $profile, $hat, $prog, $sdmode, "w", $path);

        } elsif (m/(PERMITTING|REJECTING) xattr (\S+) on (.+) \((.+)\((\d+)\) profile (.+) active (.+)\)/) {
            my ($sdmode, $xattr_op, $path, $prog, $pid, $profile, $hat) = ($1, $2, $3, $4, $5, $6, $7);

            # we want to ignore duplicates for things other than executes...
            next if $seen{$&}++;

            $last = $&;

            # we want to ignore entries for profiles that don't exist - they're
            # most likely broken entries or old entries for deleted profiles
            next
              if ( ($profile ne 'null-complain-profile')
                && (!profile_exists($profile)));

            my $xattrmode;
            if ($xattr_op eq "get" || $xattr_op eq "list") {
                $xattrmode = "r";
            } elsif ($xattr_op eq "set" || $xattr_op eq "remove") {
                $xattrmode = "w";
            }

            if ($xattrmode) {
                add_to_tree($pid, "path", $profile, $hat, $prog, $sdmode, $xattrmode, $path);
            }

        } elsif (m/(PERMITTING|REJECTING) attribute \((.*?)\) change to (.+) \((.+)\((\d+)\) profile (.+) active (.+)\)/) {
            my ($sdmode, $change, $path, $prog, $pid, $profile, $hat) = ($1, $2, $3, $4, $5, $6, $7);

            # we want to ignore duplicates for things other than executes...
            next if $seen{$&};
            $seen{$&} = 1;

            $last = $&;

            # we want to ignore entries for profiles that don't exist - they're
            # most likely broken entries or old entries for deleted profiles
            next
              if ( ($profile ne 'null-complain-profile')
                && (!profile_exists($profile)));

            # kerberos code checks to see if the krb5.conf file is world
            # writable in a stupid way so we'll ignore any w accesses to
            # krb5.conf
            next if $path eq "/etc/krb5.conf";

            add_to_tree($pid, "path", $profile, $hat, $prog, $sdmode, "w", $path);

        } elsif (m/(PERMITTING|REJECTING) access to capability '(\S+)' \((.+)\((\d+)\) profile (.+) active (.+)\)/) {
            my ($sdmode, $capability, $prog, $pid, $profile, $hat) = ($1, $2, $3, $4, $5, $6);

            next if $seen{$&};

            $seen{$&} = 1;
            $last = $&;

            # we want to ignore entries for profiles that don't exist - they're
            # most likely broken entries or old entries for deleted profiles
            next
              if ( ($profile ne 'null-complain-profile')
                && (!profile_exists($profile)));

            add_to_tree($pid, "capability", $profile, $hat, $prog, $sdmode, $capability);

        } elsif (m/Fork parent (\d+) child (\d+) profile (.+) active (.+)/
            || m/LOGPROF-HINT fork pid=(\d+) child=(\d+) profile=(.+) active=(.+)/
            || m/LOGPROF-HINT fork pid=(\d+) child=(\d+)/)
        {
            my ($parent, $child, $profile, $hat) = ($1, $2, $3, $4);

            $profile ||= "null-complain-profile";
            $hat     ||= "null-complain-profile";

            $last = $&;

            # we want to ignore entries for profiles that don't exist - they're
            # most likely broken entries or old entries for deleted profiles
            next
              if ( ($profile ne 'null-complain-profile')
                && (!profile_exists($profile)));

            my $arrayref = [];
            if (exists $pid{$parent}) {
                push @{ $pid{$parent} }, $arrayref;
            } else {
                push @log, $arrayref;
            }
            $pid{$child} = $arrayref;
            push @{$arrayref}, [ "fork", $child, $profile, $hat ];
        } else {
            $DEBUGGING && debug "UNHANDLED: $_";
        }
    }
    close(LOG);

    for my $root (@log) {
        handlechildren(undef, undef, $root);
    }

    for my $pid (sort { $a <=> $b } keys %profilechanges) {
        setprocess($pid, $profilechanges{$pid});
    }

    collapselog();

    my $found;

    # do the magic foo-foo
    for my $sdmode (sort keys %log) {

        # let them know what sort of changes we're about to list...
        if ($sdmode eq "PERMITTING") {
            UI_Info(gettext("Complain-mode changes:"));
        } elsif ($sdmode eq "REJECTING") {
            UI_Info(gettext("Enforce-mode changes:"));
        } else {

            # if we're not permitting and not rejecting, something's broken.
            # most likely  the code we're using to build the hash tree of log
            # entries - this should never ever happen
            fatal_error(sprintf(gettext('Invalid mode found: %s'), $sdmode));
        }

        for my $profile (sort keys %{ $log{$sdmode} }) {

            $found++;

            # this sorts the list of hats, but makes sure that the containing
            # profile shows up in the list first to keep the question order
            # rational
            my @hats =
              grep { $_ ne $profile } keys %{ $log{$sdmode}{$profile} };
            unshift @hats, $profile
              if defined $log{$sdmode}{$profile}{$profile};

            for my $hat (@hats) {

                # step through all the capabilities first...
                for my $capability (sort keys %{ $log{$sdmode}{$profile}{$hat}{capability} }) {

                    # we don't care about it if we've already added it to the
                    # profile
                    next if $sd{$profile}{$hat}{capability}{$capability};

                    my $severity = $sevdb->rank(uc("cap_$capability"));

                    my $q = {};
                    $q->{headers} = [];
                    push @{ $q->{headers} }, gettext("Profile"), combine_name($profile, $hat);
                    push @{ $q->{headers} }, gettext("Capability"), $capability;
                    push @{ $q->{headers} }, gettext("Severity"),   $severity;

                    $q->{functions} = [ "CMD_ALLOW", "CMD_DENY", "CMD_ABORT", "CMD_FINISHED" ];

                    # complain-mode events default to allow - enforce defaults
                    # to deny
                    $q->{default} = ($sdmode eq "PERMITTING") ? "CMD_ALLOW" : "CMD_DENY";

                    $seenevents++;

                    # what did the grand exalted master tell us to do?
                    my ($ans, $arg) = UI_PromptUser($q);

                    if ($ans eq "CMD_ALLOW") {

                        # they picked (a)llow, so...

                        # stick the capability into the profile
                        $sd{$profile}{$hat}{capability}{$capability} = 1;

                        # mark this profile as changed
                        $changed{$profile} = 1;

                        # give a little feedback to the user
                        UI_Info(sprintf(gettext('Adding capability %s to profile.'), $capability));
                    } elsif ($ans eq "CMD_DENY") {
                        UI_Info(sprintf(gettext('Denying capability %s to profile.'), $capability));
                    } elsif ($ans eq "CMD_ABORT") {

                        # if we're in yast, they've already been asked for
                        # confirmation
                        if ($UI_Mode eq "yast") {
                            UI_Info(gettext("Abandoning all changes."));
                            shutdown_yast();
                            exit 0;
                        }
                        my $ans = UI_YesNo(gettext("Are you sure you want to abandon this set of profile changes and exit?"), "n");
                        if ($ans eq "y") {
                            UI_Info(gettext("Abandoning all changes."));
                            shutdown_yast();
                            exit 0;
                        } else {
                            redo;
                        }
                    } elsif ($ans eq "CMD_FINISHED") {

                        # if we're in yast, they've already been asked for
                        # confirmation
                        if ($UI_Mode eq "yast") {
                            UI_Info(gettext("Saving all changes."));
                            $finishing = 1;

                            # XXX - BUGBUG - this is REALLY nasty, but i'm in
                            # a hurry...
                            goto SAVE_PROFILES;
                        }
                        my $ans = UI_YesNo(gettext("Are you sure you want to save the current set of profile changes and exit?"), "n");
                        if ($ans eq "y") {
                            UI_Info(gettext("Saving all changes."));
                            $finishing = 1;

                            # XXX - BUGBUG - this is REALLY nasty, but i'm in
                            # a hurry...
                            goto SAVE_PROFILES;
                        } else {
                            redo;
                        }
                    }
                }

                # and then step through all of the path entries...
                for my $path (sort keys %{ $log{$sdmode}{$profile}{$hat}{path} }) {

                    my $mode = $log{$sdmode}{$profile}{$hat}{path}{$path};

                    # if we had an access(X_OK) request or some other kind of
                    # event that generates a "PERMITTING x" syslog entry,
                    # first check if it was already dealt with by a i/p/x
                    # question due to a exec().  if not, ask about adding ix
                    # permission.
                    if ($mode =~ /X/) {

                        # get rid of the access() markers.
                        $mode =~ s/X//g;

                        my $combinedmode = "";

                        my ($cm, @m);

                        # does path match any regexps in original profile?
                        ($cm, @m) = rematchfrag($sd{$profile}{$hat}, $path);
                        $combinedmode .= $cm if $cm;

                        # does path match anything pulled in by includes in
                        # original profile?
                        ($cm, @m) = matchincludes($sd{$profile}{$hat}, $path);
                        $combinedmode .= $cm if $cm;

                        if ($combinedmode) {
                            if (   contains($combinedmode, "ix")
                                || contains($combinedmode, "px")
                                || contains($combinedmode, "ux")
                                || contains($combinedmode, "Px")
                                || contains($combinedmode, "Ux"))
                            {
                            } else {
                                $mode .= "ix";
                            }
                        } else {
                            $mode .= "ix";
                        }
                    }

                    # if we had an mmap(PROT_EXEC) request, first check if we
                    # already have added an ix rule to the profile
                    if ($mode =~ /m/) {
                        my $combinedmode = "";
                        my ($cm, @m);

                        # does path match any regexps in original profile?
                        ($cm, @m) = rematchfrag($sd{$profile}{$hat}, $path);
                        $combinedmode .= $cm if $cm;

                        # does path match anything pulled in by includes in
                        # original profile?
                        ($cm, @m) = matchincludes($sd{$profile}{$hat}, $path);
                        $combinedmode .= $cm if $cm;

                        # ix implies m.  don't ask if they want to add an "m"
                        # rule when we already have a matching ix rule.
                        if ($combinedmode && contains($combinedmode, "ix")) {
                            $mode =~ s/m//g;
                        }
                    }

                    next unless $mode;

                    my $combinedmode = "";
                    my @matches;

                    my ($cm, @m);

                    # does path match any regexps in original profile?
                    ($cm, @m) = rematchfrag($sd{$profile}{$hat}, $path);
                    if ($cm) {
                        $combinedmode .= $cm;
                        push @matches, @m;
                    }

                    # does path match anything pulled in by includes in
                    # original profile?
                    ($cm, @m) = matchincludes($sd{$profile}{$hat}, $path);
                    if ($cm) {
                        $combinedmode .= $cm;
                        push @matches, @m;
                    }

                    unless ($combinedmode && contains($combinedmode, $mode)) {

                        my $defaultoption = 1;
                        my @options       = ();

                        # check the path against the available set of include
                        # files
                        my @newincludes;
                        my $includevalid;
                        for my $incname (keys %include) {
                            $includevalid = 0;

                            # don't suggest it if we're already including it,
                            # that's dumb
                            next if $sd{$profile}{$hat}{$incname};

                            # only match includes that can be suggested to
                            # the user
                            for my $incmatch (@custom_includes) {
                                $includevalid = 1 if $incname =~ /$incmatch/;
                            }
                            $includevalid = 1 if $incname =~ /abstractions/;
                            next if ($includevalid == 0);

                            ($cm, @m) = matchinclude($incname, $path);
                            if ($cm && contains($cm, $mode)) {
                                unless (grep { $_ eq "/**" } @m) {
                                    push @newincludes, $incname;
                                }
                            }
                        }

                        # did any match?  add them to the option list...
                        if (@newincludes) {
                            push @options,
                              map { "#include <$_>" }
                              sort(uniq(@newincludes));
                        }

                        # include the literal path in the option list...
                        push @options, $path;

                        # match the current path against the globbing list in
                        # logprof.conf
                        my @globs = globcommon($path);
                        if (@globs) {
                            push @matches, @globs;
                        }

                        # suggest any matching globs the user manually entered
                        for my $userglob (@userglobs) {
                            push @matches, $userglob
                              if matchliteral($userglob, $path);
                        }

                        # we'll take the cheesy way and order the suggested
                        # globbing list by length, which is usually right,
                        # but not always always
                        push @options,
                          sort { length($b) <=> length($a) }
                          grep { $_ ne $path }
                          uniq(@matches);
                        $defaultoption = $#options + 1;

                        my $severity = $sevdb->rank($path, $mode);

                        my $done = 0;
                        while (not $done) {

                            my $q = {};
                            $q->{headers} = [];
                            push @{ $q->{headers} }, gettext("Profile"), combine_name($profile, $hat);
                            push @{ $q->{headers} }, gettext("Path"), $path;

                            # merge in any previous modes from this run
                            if ($combinedmode) {
                                $combinedmode = collapsemode($combinedmode);
                                push @{ $q->{headers} }, gettext("Old Mode"), $combinedmode;
                                $mode = collapsemode("$mode$combinedmode");
                                push @{ $q->{headers} }, gettext("New Mode"), $mode;
                            } else {
                                push @{ $q->{headers} }, gettext("Mode"), $mode;
                            }
                            push @{ $q->{headers} }, gettext("Severity"), $severity;

                            $q->{options}  = [@options];
                            $q->{selected} = $defaultoption - 1;

                            $q->{functions} = [ "CMD_ALLOW", "CMD_DENY", "CMD_GLOB", "CMD_GLOBEXT", "CMD_NEW", "CMD_ABORT", "CMD_FINISHED" ];

                            $q->{default} =
                              ($sdmode eq "PERMITTING")
                              ? "CMD_ALLOW"
                              : "CMD_DENY";

                            $seenevents++;

                            # if they just hit return, use the default answer
                            my ($ans, $selected) = UI_PromptUser($q);

                            if ($ans eq "CMD_ALLOW") {
                                $path = $selected;
                                $done = 1;
                                if ($path =~ m/^#include <(.+)>$/) {
                                    my $inc = $1;

                                    my $deleted = 0;
                                    for my $entry (keys %{ $sd{$profile}{$hat}{path} }) {

                                        next if $path eq $entry;

                                        my $cm = matchinclude($inc, $entry);
                                        if ($cm
                                            && contains($cm, $sd{$profile}{$hat}{path}{$entry}))
                                        {
                                            delete $sd{$profile}{$hat}{path}{$entry};
                                            $deleted++;
                                        }
                                    }

                                    # record the new entry
                                    $sd{$profile}{$hat}{include}{$inc} = 1;

                                    $changed{$profile} = 1;
                                    UI_Info(sprintf(gettext('Adding #include <%s> to profile.'), $inc));
                                    UI_Info(sprintf(gettext('Deleted %s previous matching profile entries.'), $deleted)) if $deleted;
                                } else {
                                    if ($sd{$profile}{$hat}{path}{$path}) {
                                        $mode = collapsemode($mode . $sd{$profile}{$hat}{path}{$path});
                                    }

                                    my $deleted = 0;
                                    for my $entry (keys %{ $sd{$profile}{$hat}{path} }) {

                                        next if $path eq $entry;

                                        if (matchregexp($path, $entry)) {

                                            # regexp matches, add it's mode to
                                            # the list to check against
                                            if (contains($mode, $sd{$profile}{$hat}{path}{$entry})) {
                                                delete $sd{$profile}{$hat}{path}{$entry};
                                                $deleted++;
                                            }
                                        }
                                    }

                                    # record the new entry
                                    $sd{$profile}{$hat}{path}{$path} = $mode;

                                    $changed{$profile} = 1;
                                    UI_Info(sprintf(gettext('Adding %s %s to profile.'), $path, $mode));
                                    UI_Info(sprintf(gettext('Deleted %s previous matching profile entries.'), $deleted)) if $deleted;
                                }
                            } elsif ($ans eq "CMD_DENY") {

                                # go on to the next entry without saving this
                                # one
                                $done = 1;
                            } elsif ($ans eq "CMD_NEW") {
                                if ($selected !~ /^#include/) {
                                    $ans = UI_GetString(gettext("Enter new path: "), $selected);
                                    if ($ans) {
                                        unless (matchliteral($ans, $path)) {
                                            my $ynprompt = gettext("The specified path does not match this log entry:") . "\n\n";
                                            $ynprompt .= "  " . gettext("Log Entry") . ":    $path\n";
                                            $ynprompt .= "  " . gettext("Entered Path") . ": $ans\n\n";
                                            $ynprompt .= gettext("Do you really want to use this path?") . "\n";

                                            # we default to no if they just hit return...
                                            my $key = UI_YesNo($ynprompt, "n");

                                            next if $key eq "n";
                                        }

                                        # save this one for later
                                        push @userglobs, $ans;

                                        push @options, $ans;
                                        $defaultoption = $#options + 1;
                                    }
                                }
                            } elsif ($ans eq "CMD_GLOB") {

                                # do globbing if they don't have an include
                                # selected
                                unless ($selected =~ /^#include/) {
                                    my $newpath = $selected;

                                    # do we collapse to /* or /**?
                                    if ($newpath =~ m/\/\*{1,2}$/) {
                                        $newpath =~ s/\/[^\/]+\/\*{1,2}$/\/\*\*/;
                                    } else {
                                        $newpath =~ s/\/[^\/]+$/\/\*/;
                                    }
                                    if ($newpath ne $selected) {
                                        push @options, $newpath;
                                        $defaultoption = $#options + 1;
                                    }
                                }
                            } elsif ($ans eq "CMD_GLOBEXT") {

                                # do globbing if they don't have an include
                                # selected
                                unless ($selected =~ /^#include/) {
                                    my $newpath = $selected;

                                    # do we collapse to /*.ext or /**.ext?
                                    if ($newpath =~ m/\/\*{1,2}\.[^\/]+$/) {
                                        $newpath =~ s/\/[^\/]+\/\*{1,2}(\.[^\/]+)$/\/\*\*$1/;
                                    } else {
                                        $newpath =~ s/\/[^\/]+(\.[^\/]+)$/\/\*$1/;
                                    }
                                    if ($newpath ne $selected) {
                                        push @options, $newpath;
                                        $defaultoption = $#options + 1;
                                    }
                                }
                            } elsif ($ans =~ /\d/) {
                                $defaultoption = $ans;
                            } elsif ($ans eq "CMD_ABORT") {
                                $ans = UI_YesNo(gettext("Are you sure you want to abandon this set of profile changes and exit?"), "n");
                                if ($ans eq "y") {
                                    UI_Info(gettext("Abandoning all changes."));
                                    shutdown_yast();
                                    exit 0;
                                }
                            } elsif ($ans eq "CMD_FINISHED") {
                                $ans = UI_YesNo(gettext("Are you sure you want to save the current set of profile changes and exit?"), "n");
                                if ($ans eq "y") {
                                    UI_Info(gettext("Saving all changes."));
                                    $finishing = 1;

                                    # XXX - BUGBUG - this is REALLY nasty, but
                                    # i'm in a hurry...
                                    goto SAVE_PROFILES;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if ($UI_Mode eq "yast") {
        if (not $running_under_genprof) {
            if ($seenevents) {
                my $w = { type => "wizard" };
                $w->{explanation} = gettext("The profile analyzer has completed processing the log files.\nAll updated profiles will be reloaded");
                $w->{functions} = [ "CMD_ABORT", "CMD_FINISHED" ];
                SendDataToYast($w);
                my $foo = GetDataFromYast();
            } else {
                my $w = { type => "wizard" };
                $w->{explanation} = gettext("No unhandled AppArmor events were found in the system log.");
                $w->{functions} = [ "CMD_ABORT", "CMD_FINISHED" ];
                SendDataToYast($w);
                my $foo = GetDataFromYast();
            }
        }
    }

  SAVE_PROFILES:

    # make sure the profile changes we've made are saved to disk...
    for my $profile (sort keys %changed) {
        writeprofile($profile);
        reload($profile);
    }

    # if they hit "Finish" we need to tell the caller that so we can exit
    # all the way instead of just going back to the genprof prompt
    return $finishing ? "FINISHED" : "NORMAL";
}

sub setprocess ($$) {
    my ($pid, $profile) = @_;

    # don't do anything if the process exited already...
    return unless -e "/proc/$pid/attr/current";

    return unless open(CURR, "/proc/$pid/attr/current");
    my $current = <CURR>;
    chomp $current;
    close(CURR);

    # only change null profiles
    return unless $current =~ /null(-complain)*-profile/;

    return unless open(STAT, "/proc/$pid/stat");
    my $stat = <STAT>;
    chomp $stat;
    close(STAT);

    return unless $stat =~ /^\d+ \((\S+)\) /;
    my $currprog = $1;

    open(CURR, ">/proc/$pid/attr/current") or return;
    print CURR "setprofile $profile";
    close(CURR);
}

sub collapselog () {
    for my $sdmode (keys %prelog) {
        for my $profile (keys %{ $prelog{$sdmode} }) {
            for my $hat (keys %{ $prelog{$sdmode}{$profile} }) {
                for my $path (keys %{ $prelog{$sdmode}{$profile}{$hat}{path} }) {

                    my $mode = $prelog{$sdmode}{$profile}{$hat}{path}{$path};

                    # we want to ignore anything from the log that's already
                    # in the profile
                    my $combinedmode = "";

                    # is it in the original profile?
                    if ($sd{$profile}{$hat}{path}{$path}) {
                        $combinedmode .= $sd{$profile}{$hat}{path}{$path};
                    }

                    # does path match any regexps in original profile?
                    $combinedmode .= rematchfrag($sd{$profile}{$hat}, $path);

                    # does path match anything pulled in by includes in
                    # original profile?
                    $combinedmode .= matchincludes($sd{$profile}{$hat}, $path);

                    # if we found any matching entries, do the modes match?
                    unless ($combinedmode && contains($combinedmode, $mode)) {

                        # merge in any previous modes from this run
                        if ($log{$sdmode}{$profile}{$hat}{path}{$path}) {
                            $mode = collapsemode($mode . $log{$sdmode}{$profile}{$hat}{path}{$path});
                        }

                        # record the new entry
                        $log{$sdmode}{$profile}{$hat}{path}{$path} = collapsemode($mode);
                    }
                }

                for my $capability (keys %{ $prelog{$sdmode}{$profile}{$hat}{capability} }) {

                    # if we don't already have this capability in the profile,
                    # add it
                    unless ($sd{$profile}{$hat}{capability}{$capability}) {
                        $log{$sdmode}{$profile}{$hat}{capability}{$capability} = 1;
                    }
                }
            }
        }
    }
}

sub profilemode ($) {
    my $mode = shift;

    my $modifier = ($mode =~ m/[iupUP]/)[0];
    if ($modifier) {
        $mode =~ s/[iupUPx]//g;
        $mode .= $modifier . "x";
    }

    return $mode;
}

# kinky.
sub commonprefix (@) { (join("\0", @_) =~ m/^([^\0]*)[^\0]*(\0\1[^\0]*)*$/)[0] }
sub commonsuffix (@) { reverse(((reverse join("\0", @_)) =~ m/^([^\0]*)[^\0]*(\0\1[^\0]*)*$/)[0]); }

sub uniq (@) {
    my %seen;
    my @result = sort grep { !$seen{$_}++ } @_;
    return @result;
}

sub collapsemode ($) {
    my $old = shift;

    my %seen;
    my $new = join "", sort
      grep { !$seen{$_}++ } $old =~ m/\G(r|w|l|m|ix|px|ux|Px|Ux)/g;
    return $new;
}

sub contains ($$) {
    my ($glob, $single) = @_;

    $glob = "" unless defined $glob;

    my %h;
    $h{$_}++ for ($glob =~ m/\G(r|w|l|m|ix|px|ux|Px|Ux)/g);

    for my $mode ($single =~ m/\G(r|w|l|m|ix|px|ux|Px|Ux)/g) {
        return 0 unless $h{$mode};
    }

    return 1;
}

# isSkippableFile - return true if filename matches something that
# should be skipped (rpm backup files, dotfiles, emacs backup files
sub isSkippableFile($) {
    my $path = shift;

    return ($path =~ /(^|\/)\.[^\/]*$/
            || $path =~ /\.rpm(save|new)$/
            || $path =~ /\~$/);
}

sub checkIncludeSyntax($) {
    my $errors = shift;

    if (opendir(SDDIR, $profiledir)) {
        my @incdirs = grep { (!/^\./) && (-d "$profiledir/$_") } readdir(SDDIR);
        close(SDDIR);
        while (my $id = shift @incdirs) {
            if (opendir(SDDIR, "$profiledir/$id")) {
                for my $path (grep { !/^\./ } readdir(SDDIR)) {
                    chomp($path);
                    next if isSkippableFile($path);
                    if (-f "$profiledir/$id/$path") {
                        my $file = "$id/$path";
                        $file =~ s/$profiledir\///;
                        my $err = loadinclude($file, \&printMessageErrorHandler);
                        if ($err ne 0) {
                            push @$errors, $err;
                        }
                    } elsif (-d "$id/$path") {
                        push @incdirs, "$id/$path";
                    }
                }
                closedir(SDDIR);
            }
        }
    }
    return $errors;
}

sub checkProfileSyntax ($) {
    my $errors = shift;

    # Check the syntax of profiles

    opendir(SDDIR, $profiledir)
      or fatal_error "Can't read AppArmor profiles in $profiledir.";
    for my $file (grep { -f "$profiledir/$_" } readdir(SDDIR)) {
        next if isSkippableFile($file);
        my $err = readprofile("$profiledir/$file", \&printMessageErrorHandler);
        if (defined $err and $err ne 1) {
            push @$errors, $err;
        }
    }
    closedir(SDDIR);
    return $errors;
}

sub printMessageErrorHandler ($) {
    my $message = shift;
    return $message;
}

sub readprofiles () {
    opendir(SDDIR, $profiledir)
      or fatal_error "Can't read AppArmor profiles in $profiledir.";
    for my $file (grep { -f "$profiledir/$_" } readdir(SDDIR)) {
        next if isSkippableFile($file);
        readprofile("$profiledir/$file", \&fatal_error);
    }
    closedir(SDDIR);
}

sub readprofile ($$) {
    my $file          = shift;
    my $error_handler = shift;
    if (open(SDPROF, "$file")) {
        my ($profile, $hat, $in_contained_hat);
        my $initial_comment = "";
        while (<SDPROF>) {
            chomp;

            # we don't care about blank lines
            next if /^\s*$/;

            # start of a profile...
            if (m/^\s*("??\/.+?"??)\s+(flags=\(.+\)\s+)*\{\s*$/) {

                # if we run into the start of a profile while we're already in a
                # profile, something's wrong...
                if ($profile) {
                    return &$error_handler("$profile profile in $file contains syntax errors.");
                }

                # we hit the start of a profile, keep track of it...
                $profile = $1;
                my $flags = $2;
                $in_contained_hat = 0;

                # hat is same as profile name if we're not in a hat
                ($profile, $hat) = split /\^/, $profile;

                # deal with whitespace in profile and hat names.
                $profile = $1 if $profile =~ /^"(.+)"$/;
                $hat     = $1 if $hat && $hat =~ /^"(.+)"$/;

                # if we run into old-style hat declarations mark the profile as
                # changed so we'll write it out as new-style
                if ($hat && $hat ne $profile) {
                    $changed{$profile} = 1;
                }

                $hat ||= $profile;

                # keep track of profile flags
                if ($flags && $flags =~ /^flags=\((.+)\)\s*$/) {
                    $flags = $1;
                    $sd{$profile}{$hat}{flags} = $flags;
                }

                $sd{$profile}{$hat}{netdomain} = [];

                # store off initial comment if they have one
                $sd{$profile}{$hat}{initial_comment} = $initial_comment
                  if $initial_comment;
                $initial_comment = "";

            } elsif (m/^\s*\}\s*$/) {    # end of a profile...

                # if we hit the end of a profile when we're not in one,
                # something's wrong...
                if (not $profile) {
                    return &$error_handler(sprintf(gettext('%s contains syntax errors.'), $file));
                }

                if ($in_contained_hat) {
                    $hat              = $profile;
                    $in_contained_hat = 0;
                } else {

                    # if we're finishing a profile, make sure that any required
                    # infrastructure hats for this changehat application exist
                    for my $hatglob (keys %required_hats) {
                        if ($profile =~ /$hatglob/) {
                            for my $hat (split(/\s+/, $required_hats{$hatglob})) {
                                unless ($sd{$profile}{$hat}) {
                                    $sd{$profile}{$hat} = {};

                                    # if we had to auto-instantiate a hat, we
                                    # want to write out an updated version of
                                    # the profile
                                    $changed{$profile} = 1;
                                }
                            }
                        }
                    }

                    # mark that we're outside of a profile now...
                    $profile         = undef;
                    $initial_comment = "";
                }

            } elsif (m/^\s*capability\s+(\S+)\s*,\s*$/) {    # capability entry
                if (not $profile) {
                    return &$error_handler(sprintf(gettext('%s contains syntax errors.'), $file));
                }

                my $capability = $1;
                $sd{$profile}{$hat}{capability}{$capability} = 1;

            } elsif (/^\s*(\$\{?[[:alpha:]][[:alnum:]_]*\}?)\s*=\s*(true|false)\s*$/i) {              # boolean definition
            } elsif (/^\s*(@\{?[[:alpha:]][[:alnum:]_]+\}?)\s*\+=\s*(.+)\s*$/) {                      # variable additions
            } elsif (/^\s*(@\{?[[:alpha:]][[:alnum:]_]+\}?)\s*=\s*(.+)\s*$/) {                        # variable definitions
            } elsif (m/^\s*if\s+(not\s+)?(\$\{?[[:alpha:]][[:alnum:]_]*\}?)\s*\{\s*$/) {              # conditional -- boolean
            } elsif (m/^\s*if\s+(not\s+)?defined\s+(@\{?[[:alpha:]][[:alnum:]_]+\}?)\s*\{\s*$/) {     # conditional -- variable defined
            } elsif (m/^\s*if\s+(not\s+)?defined\s+(\$\{?[[:alpha:]][[:alnum:]_]+\}?)\s*\{\s*$/) {    # conditional -- boolean defined
            } elsif (m/^\s*([\"\@\/].*)\s+(\S+)\s*,\s*$/) {                                           # path entry
                if (not $profile) {
                    return &$error_handler(sprintf(gettext('%s contains syntax errors.'), $file));
                }

                my ($path, $mode) = ($1, $2);

                # strip off any trailing spaces.
                $path =~ s/\s+$//;

                $path = $1 if $path =~ /^"(.+)"$/;

                # make sure they don't have broken regexps in the profile
                my $p_re = convert_regexp($path);
                eval { "foo" =~ m/^$p_re$/; };
                if ($@) {
                    return &$error_handler(sprintf(gettext('Profile %s contains invalid regexp %s.'), $file, $path));
                }

                $sd{$profile}{$hat}{path}{$path} = $mode;

            } elsif (m/^\s*#include <(.+)>\s*$/) {    # include stuff
                my $include = $1;

                if ($profile) {
                    $sd{$profile}{$hat}{include}{$include} = 1;
                } else {
                    unless (exists $variables{$file}) {
                        $variables{$file} = {};
                    }
                    $variables{$file}{ "#" . $include } = 1;    # sorry
                }
                my $ret = loadinclude($include, $error_handler);
                return $ret if ($ret != 0);

            } elsif (/^\s*(tcp_connect|tcp_accept|udp_send|udp_receive)/) {
                if (not $profile) {
                    return &$error_handler(sprintf(gettext('%s contains syntax errors.'), $file));
                }

                # XXX - BUGBUGBUG - don't strip netdomain entries

                unless ($sd{$profile}{$hat}{netdomain}) {
                    $sd{$profile}{$hat}{netdomain} = [];
                }

                # strip leading spaces and trailing comma
                s/^\s+//;
                s/,\s*$//;

                # keep track of netdomain entries...
                push @{ $sd{$profile}{$hat}{netdomain} }, $_;

            } elsif (m/^\s*\^(\"?.+?)\s+(flags=\(.+\)\s+)*\{\s*$/) {
                # start of a hat

                # if we hit the start of a contained hat when we're not
                # in a profile something is wrong...
                if (not $profile) {
                    return &$error_handler(sprintf(gettext('%s contains syntax errors.'), $file));
                }

                $in_contained_hat = 1;

                # we hit the start of a hat inside the current profile
                $hat = $1;
                my $flags = $2;

                # deal with whitespace in hat names.
                $hat = $1 if $hat =~ /^"(.+)"$/;

                # keep track of profile flags
                if ($flags && $flags =~ /^flags=\((.+)\)\s*$/) {
                    $flags = $1;
                    $sd{$profile}{$hat}{flags} = $flags;
                }

                $sd{$profile}{$hat}{path}      = {};
                $sd{$profile}{$hat}{netdomain} = [];

                # store off initial comment if they have one
                $sd{$profile}{$hat}{initial_comment} = $initial_comment
                  if $initial_comment;
                $initial_comment = "";

            } elsif (/^\s*\#/) {

                # we only currently handle initial comments
                if (not $profile) {

                    # ignore vim syntax highlighting lines
                    next if /^\s*\# vim:syntax/;

                    # ignore Last Modified: lines
                    next if /^\s*\# Last Modified:/;
                    $initial_comment .= "$_\n";
                }
            } else {

                # we hit something we don't understand in a profile...
                return &$error_handler(sprintf(gettext('%s contains syntax errors.'), $file));
            }
        }

        # if we're still in a profile when we hit the end of the file, it's bad
        if ($profile) {
            return &$error_handler("Reached the end of $file while we were still inside the $profile profile.");
        }

        close(SDPROF);
    } else {
        $DEBUGGING && debug "readprofile: can't read $file - skipping";
    }
}

sub escape ($) {
    my $dangerous = shift;

    if ($dangerous =~ m/^"(.+)"$/) {
        $dangerous = $1;
    }
    $dangerous =~ s/((?<!\\))"/$1\\"/g;
    if ($dangerous =~ m/(\s|^$|")/) {
        $dangerous = "\"$dangerous\"";
    }

    return $dangerous;
}

sub writeheader ($$$$) {
    my ($fh, $profile, $hat, $indent) = @_;

    # deal with whitespace in profile names...
    my $p = $profile;
    $p = "\"$p\"" if $p =~ /\s/;

    if ($sd{$profile}{$hat}{flags}) {
        print $fh "$p flags=($sd{$profile}{$hat}{flags}) {\n";
    } else {
        print $fh "$p {\n";
    }
}

sub writeincludes ($$$$) {
    my ($fh, $profile, $hat, $indent) = @_;

    # dump out the includes
    if (exists $sd{$profile}{$hat}{include}) {
        for my $include (sort keys %{ $sd{$profile}{$hat}{include} }) {
            print $fh "$indent  #include <$include>\n";
        }
        print $fh "\n" if keys %{ $sd{$profile}{$hat}{include} };
    }
}

sub writecapabilities ($$$$) {
    my ($fh, $profile, $hat, $indent) = @_;

    # dump out the capability entries...
    if (exists $sd{$profile}{$hat}{capability}) {
        for my $capability (sort keys %{ $sd{$profile}{$hat}{capability} }) {
            print $fh "$indent  capability $capability,\n";
        }
        print $fh "\n" if keys %{ $sd{$profile}{$hat}{capability} };
    }
}

sub writenetdomain ($$$$) {
    my ($fh, $profile, $hat, $indent) = @_;

    # dump out the netdomain entries...
    if (exists $sd{$profile}{$hat}{netdomain}) {
        for my $nd (sort @{ $sd{$profile}{$hat}{netdomain} }) {
            print $fh "$indent  $nd,\n";
        }
        print $fh "\n" if @{ $sd{$profile}{$hat}{netdomain} };
    }
}

sub writepaths ($$$$) {
    my ($fh, $profile, $hat, $indent) = @_;

    if (exists $sd{$profile}{$hat}{path}) {
        for my $path (sort keys %{ $sd{$profile}{$hat}{path} }) {
            my $mode = $sd{$profile}{$hat}{path}{$path};

            # strip out any fake access() modes that might have slipped through
            $mode =~ s/X//g;

            # deal with whitespace in path names
            if ($path =~ /\s/) {
                print $fh "$indent  \"$path\" $mode,\n";
            } else {
                print $fh "$indent  $path $mode,\n";
            }
        }
    }
}

sub writepiece ($$) {
    my ($sdprof, $profile) = @_;

    writeheader($sdprof, $profile, $profile, "");
    writeincludes($sdprof, $profile, $profile, "");
    writecapabilities($sdprof, $profile, $profile, "");
    writenetdomain($sdprof, $profile, $profile, "");
    writepaths($sdprof, $profile, $profile, "");

    for my $hat (grep { $_ ne $profile } sort keys %{ $sd{$profile} }) {

        # deal with whitespace in profile names...
        my $h = $hat;
        $h = "\"$h\"" if $h =~ /\s/;

        if ($sd{$profile}{$hat}{flags}) {
            print $sdprof "\n  ^$h flags=($sd{$profile}{$hat}{flags}) {\n";
        } else {
            print $sdprof "\n  ^$h {\n";
        }

        writeincludes($sdprof, $profile, $hat, "  ");
        writecapabilities($sdprof, $profile, $hat, "  ");
        writenetdomain($sdprof, $profile, $hat, "  ");
        writepaths($sdprof, $profile, $hat, "  ");

        print $sdprof "  }\n";
    }

    print $sdprof "}\n";
}

sub writeprofile ($) {
    my $profile = shift;

    UI_Info(sprintf(gettext('Writing updated profile for %s.'), $profile));

    my $filename = getprofilefilename($profile);

    open(SDPROF, ">$filename")
      or fatal_error "Can't write new AppArmor profile $filename: $!";

    # stick in a vim mode line to turn on AppArmor syntax highlighting
    print SDPROF "# vim:syntax=apparmor\n";

    # keep track of when the file was last updated
    print SDPROF "# Last Modified: " . localtime(time) . "\n";

    # print out initial comment
    if ($sd{$profile}{$profile}{initial_comment}) {
        $sd{$profile}{$profile}{initial_comment} =~ s/\\n/\n/g;
        print SDPROF $sd{$profile}{$profile}{initial_comment};
        print SDPROF "\n";
    }

    # dump variables defined in this file
    if ($variables{$filename}) {
        for my $var (sort keys %{ $variables{$filename} }) {
            if ($var =~ m/^@/) {
                my @values = sort @{ $variables{$filename}{$var} };
                @values = map { escape($_) } @values;
                my $values = join(" ", @values);
                print SDPROF "$var = ";
                print SDPROF $values;
            } elsif ($var =~ m/^\$/) {
                print SDPROF "$var = ";
                print SDPROF ${ $variables{$filename}{$var} };
            } elsif ($var =~ m/^\#/) {
                my $inc = $var;
                $inc =~ s/^\#//;
                print SDPROF "#include <$inc>";
            }
            print SDPROF "\n";
        }
    }

    print SDPROF "\n";

    writepiece(\*SDPROF, $profile);

    close(SDPROF);
}

sub getprofileflags {
    my $filename = shift;

    my $flags = "enforce";

    if (open(PROFILE, "$filename")) {
        while (<PROFILE>) {
            if (m/^\s*\/\S+\s+(flags=\(.+\)\s+)*{\s*$/) {
                $flags = $1;
                close(PROFILE);
                $flags =~ s/flags=\((.+)\)/$1/;
                return $flags;
            }
        }
        close(PROFILE);
    }

    return $flags;
}

sub matchliteral {
    my ($sd_regexp, $literal) = @_;

    my $p_regexp = convert_regexp($sd_regexp);

    # check the log entry against our converted regexp...
    my $matches = eval { $literal =~ /^$p_regexp$/; };

    # doesn't match if we've got a broken regexp
    return undef if $@;

    return $matches;
}

sub reload ($) {
    my $bin = shift;

    # don't try to reload profile if AppArmor is not running
    return unless check_for_subdomain();

    # don't reload the profile if the corresponding executable doesn't exist
    my $fqdbin = findexecutable($bin) or return;

    my $filename = getprofilefilename($fqdbin);

    system("/bin/cat '$filename' | $parser -I$profiledir -r >/dev/null 2>&1");
}

sub loadinclude {
    my $which         = shift;
    my $error_handler = shift;

    # don't bother loading it again if we already have
    return 0 if $include{$which};

    my @loadincludes = ($which);
    while (my $incfile = shift @loadincludes) {

        # load the include from the directory we found earlier...
        open(INCLUDE, "$profiledir/$incfile")
          or fatal_error "Can't find include file $incfile: $!";

        while (<INCLUDE>) {
            chomp;

            if (/^\s*(\$\{?[[:alpha:]][[:alnum:]_]*\}?)\s*=\s*(true|false)\s*$/i) {
                # boolean definition
            } elsif (/^\s*(@\{?[[:alpha:]][[:alnum:]_]+\}?)\s*\+=\s*(.+)\s*$/) {
                # variable additions
            } elsif (/^\s*(@\{?[[:alpha:]][[:alnum:]_]+\}?)\s*=\s*(.+)\s*$/) {
                # variable definitions
            } elsif (m/^\s*if\s+(not\s+)?(\$\{?[[:alpha:]][[:alnum:]_]*\}?)\s*\{\s*$/) {
                # conditional -- boolean
            } elsif (m/^\s*if\s+(not\s+)?defined\s+(@\{?[[:alpha:]][[:alnum:]_]+\}?)\s*\{\s*$/) {
                # conditional -- variable defined
            } elsif (m/^\s*if\s+(not\s+)?defined\s+(\$\{?[[:alpha:]][[:alnum:]_]+\}?)\s*\{\s*$/) {
                # conditional -- boolean defined
            } elsif (m/^\s*\}\s*$/) {
                # end of a profile or conditional
            } elsif (m/^\s*([\"\@\/].*)\s+(\S+)\s*,\s*$/) {
                # path entry

                my ($path, $mode) = ($1, $2);

                # strip off any trailing spaces.
                $path =~ s/\s+$//;

                $path = $1 if $path =~ /^"(.+)"$/;

                # make sure they don't have broken regexps in the profile
                my $p_re = convert_regexp($path);
                eval { "foo" =~ m/^$p_re$/; };
                if ($@) {
                    return &$error_handler(sprintf(gettext('Include file %s contains invalid regexp %s.'), $incfile, $path));
                }

                $include{$incfile}{path}{$path} = $mode;
            } elsif (/^\s*capability\s+(.+)\s*,\s*$/) {

                my $capability = $1;
                $include{$incfile}{capability}{$capability} = 1;

            } elsif (/^\s*#include <(.+)>\s*$/) {
                # include stuff

                my $newinclude = $1;
                push @loadincludes, $newinclude unless $include{$newinclude};
                $include{$incfile}{include}{$newinclude} = 1;

            } elsif (/^\s*(tcp_connect|tcp_accept|udp_send|udp_receive)/) {
            } else {

                # we don't care about blank lines or comments
                next if /^\s*$/;
                next if /^\s*\#/;

                # we hit something we don't understand in a profile...
                return &$error_handler(sprintf(gettext('Include file %s contains syntax errors or is not a valid #include file.'), $incfile));
            }
        }
        close(INCLUDE);
    }

    return 0;
}

sub rematchfrag {
    my ($frag, $path) = @_;

    my $combinedmode = "";
    my @matches;

    for my $entry (keys %{ $frag->{path} }) {

        my $regexp = convert_regexp($entry);

        # check the log entry against our converted regexp...
        if ($path =~ /^$regexp$/) {

            # regexp matches, add it's mode to the list to check against
            $combinedmode .= $frag->{path}{$entry};
            push @matches, $entry;
        }
    }

    return wantarray ? ($combinedmode, @matches) : $combinedmode;
}

sub matchincludes {
    my ($frag, $path) = @_;

    my $combinedmode = "";
    my @matches;

    # scan the include fragments for this profile looking for matches
    my @includelist = keys %{ $frag->{include} };
    while (my $include = shift @includelist) {
        loadinclude($include, \&fatal_error);
        my ($cm, @m) = rematchfrag($include{$include}, $path);
        if ($cm) {
            $combinedmode .= $cm;
            push @matches, @m;
        }

        # check if a literal version is in the current include fragment
        if ($include{$include}{path}{$path}) {
            $combinedmode .= $include{$include}{path}{$path};
        }

        # if this fragment includes others, check them too
        if (keys %{ $include{$include}{include} }) {
            push @includelist, keys %{ $include{$include}{include} };
        }
    }

    return wantarray ? ($combinedmode, @matches) : $combinedmode;
}

sub matchinclude {
    my ($incname, $path) = @_;

    my $combinedmode = "";
    my @matches;

    # scan the include fragments for this profile looking for matches
    my @includelist = ($incname);
    while (my $include = shift @includelist) {
        my ($cm, @m) = rematchfrag($include{$include}, $path);
        if ($cm) {
            $combinedmode .= $cm;
            push @matches, @m;
        }

        # check if a literal version is in the current include fragment
        if ($include{$include}{path}{$path}) {
            $combinedmode .= $include{$include}{path}{$path};
        }

        # if this fragment includes others, check them too
        if (keys %{ $include{$include}{include} }) {
            push @includelist, keys %{ $include{$include}{include} };
        }
    }

    if ($combinedmode) {
        return wantarray ? ($combinedmode, @matches) : $combinedmode;
    } else {
        return;
    }
}

sub readconfig () {

    my $which;

    if (open(LPCONF, "$confdir/logprof.conf")) {
        while (<LPCONF>) {
            chomp;

            next if /^\s*#/;

            if (m/^\[(\S+)\]/) {
                $which = $1;
            } elsif (m/^\s*(\S+)\s*=\s*(.+)\s*$/) {
                my ($key, $value) = ($1, $2);
                if ($which eq "defaulthat") {
                    $defaulthat{$key} = $value;
                } elsif ($which eq "qualifiers") {
                    $qualifiers{$key} = $value;
                } elsif ($which eq "globs") {
                    $globmap{$key} = $value;
                } elsif ($which eq "required_hats") {
                    $required_hats{$key} = $value;
                }
            } elsif (m/^\s*(\S+)\s*$/) {
                my $val = $1;
                if ($which eq "custom_includes") {
                    push @custom_includes, $val;
                }
            }
        }
        close(LPCONF);
    }
}

sub loadincludes {
    if (opendir(SDDIR, $profiledir)) {
        my @incdirs = grep { (!/^\./) && (-d "$profiledir/$_") } readdir(SDDIR);
        close(SDDIR);

        while (my $id = shift @incdirs) {
            if (opendir(SDDIR, "$profiledir/$id")) {
                for my $path (readdir(SDDIR)) {
                    chomp($path);
                    next if isSkippableFile($path);
                    if (-f "$profiledir/$id/$path") {
                        my $file = "$id/$path";
                        $file =~ s/$profiledir\///;
                        loadinclude($file, \&fatal_error);
                    } elsif (-d "$id/$path") {
                        push @incdirs, "$id/$path";
                    }
                }
                closedir(SDDIR);
            }
        }
    }
}

sub globcommon ($) {
    my $path = shift;

    my @globs;

    # glob library versions in both foo-5.6.so and baz.so.9.2 form
    if ($path =~ m/[\d\.]+\.so$/ || $path =~ m/\.so\.[\d\.]+$/) {
        my $libpath = $path;
        $libpath =~ s/[\d\.]+\.so$/*.so/;
        $libpath =~ s/\.so\.[\d\.]+$/.so.*/;
        push @globs, $libpath if $libpath ne $path;
    }

    for my $glob (keys %globmap) {
        if ($path =~ /$glob/) {
            my $globbedpath = $path;
            $globbedpath =~ s/$glob/$globmap{$glob}/g;
            push @globs, $globbedpath if $globbedpath ne $path;
        }
    }

    if (wantarray) {
        return sort { length($b) <=> length($a) } uniq(@globs);
    } else {
        my @list = sort { length($b) <=> length($a) } uniq(@globs);
        return $list[$#list];
    }
}

# this is an ugly, nasty function that attempts to see if one regexp
# is a subset of another regexp
sub matchregexp ($$) {
    my ($new, $old) = @_;

    # bail out if old pattern has {foo,bar,baz} stuff in it
    return undef if $old =~ /\{.*(\,.*)*\}/;

    # are there any regexps at all in the old pattern?
    if ($old =~ /\[.+\]/ or $old =~ /\*/ or $old =~ /\?/) {

        # convert {foo,baz} to (foo|baz)
        $new =~ y/\{\}\,/\(\)\|/ if $new =~ /\{.*\,.*\}/;

        # \001 == SD_GLOB_RECURSIVE
        # \002 == SD_GLOB_SIBLING

        $new =~ s/\*\*/\001/g;
        $new =~ s/\*/\002/g;

        $old =~ s/\*\*/\001/g;
        $old =~ s/\*/\002/g;

        # strip common prefix
        my $prefix = commonprefix($new, $old);
        if ($prefix) {

            # make sure we don't accidentally gobble up a trailing * or **
            $prefix =~ s/(\001|\002)$//;
            $new    =~ s/^$prefix//;
            $old    =~ s/^$prefix//;
        }

        # strip common suffix
        my $suffix = commonsuffix($new, $old);
        if ($suffix) {

            # make sure we don't accidentally gobble up a leading * or **
            $suffix =~ s/^(\001|\002)//;
            $new    =~ s/$suffix$//;
            $old    =~ s/$suffix$//;
        }

        # if we boiled the differences down to a ** in the new entry, it matches
        # whatever's in the old entry
        return 1 if $new eq "\001";

        # if we've paired things down to a * in new, old matches if there are no
        # slashes left in the path
        return 1 if ($new eq "\002" && $old =~ /^[^\/]+$/);

        # we'll bail out if we have more globs in the old version
        return undef if $old =~ /\001|\002/;

        # see if we can match * globs in new against literal elements in old
        $new =~ s/\002/[^\/]*/g;

        return 1 if $old =~ /^$new$/;

    } else {

        my $new_regexp = convert_regexp($new);

        # check the log entry against our converted regexp...
        return 1 if $old =~ /^$new_regexp$/;

    }

    return undef;
}

sub combine_name($$) { return ($_[0] eq $_[1]) ? $_[0] : "$_[0]^$_[1]"; }
sub split_name ($) { my ($p, $h) = split(/\^/, $_[0]); $h ||= $p; ($p, $h); }

##########################
#
# prompt_user($headers, $functions, $default, $options, $selected);
#
# $headers:
#   a required arrayref made up of "key, value" pairs in the order you'd
#   like them displayed to user
#
# $functions:
#   a required arrayref of the different options to display at the bottom
#   of the prompt like "(A)llow", "(D)eny", and "Ba(c)on".  the character
#   contained by ( and ) will be used as the key to select the specified
#   option.
#
# $default:
#   a required character which is the default "key" to enter when they
#   just hit enter
#
# $options:
#   an optional arrayref of the choices like the glob suggestions to be
#   presented to the user
#
# $selected:
#   specifies which option is currently selected
#
# when prompt_user() is called without an $options list, it returns a
# single value which is the key for the specified "function".
#
# when prompt_user() is called with an $options list, it returns an array
# of two elements, the key for the specified function as well as which
# option was currently selected
#######################################################################

sub Text_PromptUser ($) {
    my $question = shift;

    my @headers   = (@{ $question->{headers} });
    my @functions = (@{ $question->{functions} });

    my $default  = $question->{default};
    my $options  = $question->{options};
    my $selected = $question->{selected};

    my $helptext = $question->{helptext};

    push @functions, "CMD_HELP" if $helptext;

    my %keys;
    my @menu_items;
    for my $cmd (@functions) {

        # make sure we know about this particular command
        my $cmdmsg = "PromptUser: " . gettext("Unknown command") . " $cmd";
        fatal_error $cmdmsg unless $CMDS{$cmd};

        # grab the localized text to use for the menu for this command
        my $menutext = gettext($CMDS{$cmd});

        # figure out what the hotkey for this menu item is
        my $menumsg = "PromptUser: " . gettext("Invalid hotkey in") . " '$menutext'";
        $menutext =~ /\((\S)\)/ or fatal_error $menumsg;

        # we want case insensitive comparisons so we'll force things to
        # lowercase
        my $key = lc($1);

        # check if we're already using this hotkey for this prompt
        my $hotkeymsg = "PromptUser: " . gettext("Duplicate hotkey for") . " $cmd: $menutext";
        fatal_error $hotkeymsg if $keys{$key};

        # keep track of which command they're picking if they hit this hotkey
        $keys{$key} = $cmd;

        if ($default && $default eq $cmd) {
            $menutext = "[$menutext]";
        }

        push @menu_items, $menutext;
    }

    # figure out the key for the default option
    my $default_key;
    if ($default && $CMDS{$default}) {
        my $defaulttext = gettext($CMDS{$default});

        # figure out what the hotkey for this menu item is
        my $defmsg = "PromptUser: " . gettext("Invalid hotkey in default item") . " '$defaulttext'";
        $defaulttext =~ /\((\S)\)/ or fatal_error $defmsg;

        # we want case insensitive comparisons so we'll force things to
        # lowercase
        $default_key = lc($1);

        my $defkeymsg = "PromptUser: " . gettext("Invalid default") . " $default";
        fatal_error $defkeymsg unless $keys{$default_key};
    }

    my $widest = 0;
    my @poo    = @headers;
    while (my $header = shift @poo) {
        my $value = shift @poo;
        $widest = length($header) if length($header) > $widest;
    }
    $widest++;

    my $format = '%-' . $widest . "s \%s\n";

    my $function_regexp = '^(';
    $function_regexp .= join("|", keys %keys);
    $function_regexp .= '|\d' if $options;
    $function_regexp .= ')$';

    my $ans = "XXXINVALIDXXX";
    while ($ans !~ /$function_regexp/i) {

        # build up the prompt...
        my $prompt = "\n";
        my @poo    = @headers;
        while (my $header = shift @poo) {
            my $value = shift @poo;
            $prompt .= sprintf($format, "$header:", $value);
        }
        $prompt .= "\n";
        if ($options) {
            for (my $i = 0; $options->[$i]; $i++) {
                my $f = ($selected == $i) ? ' [%d - %s]' : '  %d - %s ';
                $prompt .= sprintf("$f\n", $i + 1, $options->[$i]);
            }
            $prompt .= "\n";
        }
        $prompt .= join(" / ", @menu_items);
        print "$prompt\n";

        # get their input...
        $ans = lc(getkey);

        if ($ans && $keys{$ans} && $keys{$ans} eq "CMD_HELP") {
            print "\n$helptext\n";
            $ans = undef;
        }

        # pick the default if they hit return...
        $ans = $default_key if ord($ans) == 10;

        # ugly code to handle escape sequences so you can up/down in the list
        if (ord($ans) == 27) {
            $ans = getkey;
            if (ord($ans) == 91) {
                $ans = getkey;
                if (ord($ans) == 65) {
                    if ($options) {
                        if ($selected > 0) {
                            $ans = $selected;
                        } else {
                            $ans = "again";
                        }
                    } else {
                        $ans = "again";
                    }
                } elsif (ord($ans) == 66) {
                    if ($options) {
                        if ($selected <= scalar(@$options)) {
                            $ans = $selected + 2;
                        } else {
                            $ans = "again";
                        }
                    }
                } else {
                    $ans = "again";
                }
            } else {
                $ans = "again";
            }
        }

        # handle option poo
        if ($options && ($ans =~ /^\d$/)) {
            if ($ans > 0 && $ans <= scalar(@$options)) {
                $selected = $ans - 1;
            }
            $ans = undef;
        }
    }

    # pull our command back from our hotkey map
    $ans = $keys{$ans} if $keys{$ans};

#  if($options) {
#    die "ERROR: not looking for array when options passed" unless wantarray;
    if ($options) {
        return ($ans, $options->[$selected]);
    } else {
        return ($ans, $selected);
    }

#  } else {
#    die "ERROR: looking for list when options not passed" if wantarray;
#    return $ans;
#  }
}

unless (-x $ldd) {
    $ldd = which("ldd") or fatal_error "Can't find ldd.";
}

unless (-x $parser) {
    $parser = which("apparmor_parser") || which("subdomain_parser")
      or fatal_error "Can't find apparmor_parser.";
}

1;


#!/usr/bin/env perl

use strict;
use warnings;
use v5.10;

use IO::Select;
use IO::Socket::INET;
use Getopt::Std;
use POSIX 'strftime';
use Data::Dumper;

# Name and version
my $prgnam = $0 =~ s/^.*\///r;
my $version = '0.0.1';

# These are defaults that can be overridden with command-line switches
my $bindaddr = "127.0.0.1"; # -l
my $bindport = 8080; # -l, On Linux, authbind(1) can be used to listen on low ports without having to run as root
my $pastedir = 'pastes'; # -d
my $manpath = 'pstd.1'; # -m
my $cltscript = 'pstd.sh'; # -c, we need to know this because we distribute this as (synthetical) paste "0"
my $verbose = 0; # -v
my $myhost = ''; # If not overridden by -H, we figure it out by running hostname(1)
my $logfile = ''; # Don't log by default
my $maxbuflen = 256*1024; # -s, The largest single paste we'll accept, in bytes

# Paste-ID alphabet and the shortest length of IDs we'll hand out
my @idalpha = ("A".."Z", "a".."z", "0".."9");
my $minidlen = 2;

# Map client sockets to their respective read buffers (strings)
my %readbuf;

# Map client sockets to the amount of data we expect from them
my %datalen;

# Map client IP addresses to arrays containing timestamps of their latest
# $ratesmpl attempts to paste.  Rate-limiting occurs once the difference
# between the first and the last element of such an array is smaller than
# $ratetspan.  Not only successful pastes, but also running into the
# rate-limiter count towards it, so trying to paste when already rate-limited
# might keep the rate-limiting in place for arbitrary timespans.  This is
# considered a feature.
my %rateinfo;
my $ratesmpl = 5;
my $ratetspan = 30;

# getopts
my %opts;

my $year = '2015';

my $inforeq;

sub INFO_handler
{
        $inforeq = 1;
}

sub L;
sub now { return strftime('%Y-%m-%d %H:%M:%S %z', localtime); }
sub W { say STDERR "$prgnam: ".now.": ".($_[0] =~ s/[\r\n]/\$/grm); }
sub E { my $msg = $_[0]; L "ERROR: $msg"; W "ERROR: $msg"; exit 1; }
sub D { W "DBG: $_[0]" if $verbose; }
sub L
{
	return if (!$logfile);

	my $fhnd;
	if (!open $fhnd, '>>', "$logfile") {
		W "Failed to open $logfile for appending: $!";
		return;
	}

	say $fhnd "$prgnam: ".now.": ".($_[0] =~ s/[\r\n]/\$/grm);
	close $fhnd;
}

sub usage
{
	my ($str, $ec) = @_;

	print $str "Usage: $prgnam [-hv] [-l [addr:]port] [-H <myhost>]"
	    ." [-d <path>] [-m <path>]\n"
	    ."  -h: Show this usage statement\n"
	    ."  -V: Print version on stdout\n"
	    ."  -v: Be more verbose\n"
	    ."  -l [addr:]port: Listen on port, optionally bind to addr\n"
	    ."  -m path: Path to manual (pstd.1)\n"
	    ."  -d path: Path to paste directory\n"
	    ."  -c path: Path to pstd.sh client-script (becomes a paste\n"
	    ."           referred to by the manpage)\n"
	    ."  -L path: Path to logfile\n"
	    ."  -H FQDN: Our hostname\n"
	    ."  -s size: Maximum paste size in KiB (this isn't exact \n"
	    ."           because it does not account for the HTTP Header\n"
	    ."  -r num:  Rate limit on `num` pastes in `time` (see -R) secs\n"
	    ."  -R time: See -r. Giving 0 (to -r or -R) means no rate-limit\n"
	    ."\nv$version, written by Timo Buhrmester, $year\n";
	exit $ec;
}


# Generate an unused paste ID
sub gen_id
{
	# We're trying 10 times to obtain an unused 2-letter ID,
	# then 10 times to obtain an unused 3-letter ID, and so forth
	# We also remember when we start needing to use something longer,
	# and avoid searching the apparently full-ish shorter ID-space then.
	foreach my $idlen ($minidlen..32) {
		foreach my $attempt (1..10) {
			my $id = '';
			$id .= $idalpha[rand @idalpha] for 1..$idlen;

			if (! -e "$pastedir/$id") {
				D "Generated ID $id";
				if ($idlen > $minidlen) {
					$minidlen = $idlen;
				}
				return $id;
			}
		}
	}

	return '';
}


# Register event and return how many seconds the offender needs to wait
# until they are permitted to paste again
sub ratelimit_check
{
	my ($who) = @_;

	return 0 if (!$ratesmpl or !$ratetspan);

	$rateinfo{$who} = [] if not exists $rateinfo{$who};
	my $aref = $rateinfo{$who};

	shift @$aref if @$aref >= $ratesmpl;
	push @$aref, time;

	if (@$aref >= $ratesmpl) {
		my $tdiff = @{ $aref }[@$aref - 1] - @{ $aref }[0];
		if ($tdiff < $ratetspan) { # going too fast...
			return $ratetspan - (time - @{ $aref }[@$aref - 2]);
		}
	}

	return 0; #okay, not rate limited (yet)
}


# Read and return the man page
sub manpage
{
	my $fhnd;
	if (!open $fhnd, '<', $manpath) {
		W "Failed to open $manpath: $!";
		return "ERROR: Manpage not found\n";
	}

	my @lines = <$fhnd>;
	my $man = join '', @lines;
	close $fhnd;

	return $man =~ s/MYHOST/$myhost/rg;
}


# Deal with a client (most likely a web browser) requesting a paste
# Takes socket and ID as parmeters, returns what we're going to
# pass back to the client (i.e. ideally, the actual paste)
sub process_GET
{
	my ($clt, $id) = @_;
	my $who = $clt->peerhost();

	if (! -e "$pastedir/$id") {
		W "$who: Requested nonexistant paste $id";
		return 'No such paste.';
	}

	my $fhnd;
	if (!open $fhnd, '<', "$pastedir/$id") {
		W "$who: Failed to open $pastedir/$id: $!";
		return 'GET Error 1';
	}

	my @lines = <$fhnd>;
	my $paste = join '', @lines;
	close $fhnd;

	D "$who: Got $id";
	L "$who: Got $id";

	return $paste;
}


# Deal with something (most likely paste.sh or wget) submitting
# a paste.  We don't support much HTTP, so this may not work
# with arbitrary clients. (We require a Content-Length header,
# and no transfer-encoding.  wget --post-file http://.. is okay.
sub process_POST
{
	my ($clt) = @_;
	my $who = $clt->peerhost();

	my $twait = ratelimit_check $who;
	if ($twait) {
		W "$who: Rate limited";
		return "ERROR: Slow down, cowboy.  $twait seconds until you may paste again!\n";
	}


	my $id = gen_id;

	my $paste = $readbuf{$who} =~ s/^(.*?)\r\n\r\n//rs;

	if ($paste eq '') {
		W "$who: Empty paste";
		return "ERROR: Empty paste\n";
	}

	my $fhnd;
	if (!open $fhnd, '>', "$pastedir/$id") {
		W "$who: Failed to open $pastedir/$id for writing: $!";
		return "ERROR: File error\n";
	}

	print $fhnd $paste;
	close $fhnd;

	D "$who: Pasted $id";
	L "$who: Pasted $id";

	return "http://$myhost/$id\n";
}


# This is called once we have a complete header (for a GET)
# or a complete request (for a POST), it dispatches to
# process_GET and process_POST
sub process_dispatch
{
	my ($clt) = @_;
	my $who = $clt->peerhost();

	my $resp;

	D "$who: Processing '$readbuf{$who}'";

	if ($readbuf{$who} =~ /^POST \//) {
		$resp=process_POST($clt);
	} elsif ($readbuf{$who} =~ /^GET \/([a-zA-Z0-9]+)\b/) {
		$resp=process_GET($clt, $1);
	} elsif ($readbuf{$who} =~ /^GET \/ /) {
		$resp=manpage;
		L "$who: Manpage";
	} else {
		W "$who: Request not understood";
		L "$who: Request not understood: '$readbuf{$who}'";
		$resp = "ERROR: Request not understood\n";
	}

	return $resp;
}


# Read some more data for the given client and call process_dispatch
# on it once we have enough. Bail out if we get too much
# Return 0 to drop the client, 1 to keep going
sub handle_clt
{
	my ($clt) = @_;
	my $who = $clt->peerhost();

	D "$who: Handling";

	my $data = '';
	$clt->recv($data, 1024); # XXX can this fail?!

	# I suppose empty data means EOF, but not quite sure. XXX
	if ($data eq '') {
		W "$who: Empty read";
		respond($clt, "ERROR: You what?\n");
		return 0;
	}

	# some early sanity check, this assumes the first couple bytes come in in one chunk, though.
	if (!length $readbuf{$who}) {
		if ($data =~ /^POST \//) {
			$datalen{$who} = -1; #don't know yet
		} elsif ($data =~ /^GET \/(?:[a-zA-Z0-9]+)? HTTP/) {
			$datalen{$who} = 0; #don't care
		} else {
			W "$who: Bad first data chunk '$data'";
			respond($clt, "ERROR: Request not understood\n");
			return 0;
		}
	}

	$readbuf{$who} .= $data;

	my $buflen = length $readbuf{$who};
	if ($buflen > $maxbuflen) {
		W "$who: Too much data ($buflen/$maxbuflen)";
		respond($clt, "ERROR: Too much data\n");
		return 0;
	}

	# $datalen{$who} contains how many bytes we're expecting to receive
	# from $who.  If it is zero, then we read until we have a complete
	# HTTP-header (i.e. till the first \r\n\r\n).  If it is -1, then
	# this is a POST, and we haven't seen the Content-Length header yet.

	if ($datalen{$who} == -1) {
		# POST, see if we have a header yet...
		my $hdr = $readbuf{$who} =~ s/\r\n\r\n.*$//r;
		if ($hdr) {
			#... and extract the Content-Length; bail if none
			my $match = $hdr =~ /Content-Length: ([0-9]+)/;
			if ($match and !$1) {
				W "$who: No Content-Length in header";
				respond($clt, "ERROR: Need Content-Length Header\n");
				return 0;
			}
			$datalen{$who} = $1 + 4 + length $hdr;
			D "$who: Expecting $datalen{$who} bytes in total";

			# Also complain if we happen to see an unsupported TE
			$match = $hdr =~ /Transfer-Encoding: ([a-zA-Z0-9_-]+)/;
			if ($match and $1) {
				if ($1 ne 'Identity' and $1 ne 'None') {
					W "$who: Bad TE '$1'";
					respond($clt, "ERROR: Bad Transfer-Encoding (use Identity)\n");
					return 0;
				}
			}
		}
	} elsif ($datalen{$who} == 0) {
		# a GET, process_dispatch once we have a complete request
		if ($readbuf{$who} =~ /\r\n\r\n/) {
			respond($clt, process_dispatch($clt));
			return 0;
		}
	}

	# datalen may have changed at this point (in the above conditional)

	if ($datalen{$who} > 0) {
		if (length $readbuf{$who} == $datalen{$who}) {
			# a POST, we got everything.
			respond($clt, process_dispatch($clt));
			return 0;
		} elsif (length $readbuf{$who} > $datalen{$who}) {
			# a POST, we got more than advertised.
			W "$who: More data than advertised";
			respond($clt, "ERROR: More data than advertised. Nice try?\n");
			return 0;
		}
	}

	return 1;
}


# respond to client with a fake 200 OK and the actual response
sub respond
{
	my ($clt, $data) = @_;
	my $who = $clt->peerhost();

	my $len = length $data;
	my $resp = "HTTP/1.1 200 OK\r\n".
	           "Content-Type: text/plain; charset=UTF-8\r\n".
	           "Content-Length: $len\r\n".
	           "Connection: close\r\n\r\n$data";

	if (!$clt->send($resp)) {
		W "$who: send: $!";
	}
}


sub dump_state
{
	say STDERR "============ state dump =============";
	say STDERR "\$^O = '$^O'";
	say STDERR "\$0 = '$0'";
	say STDERR "\$prgnam = '$prgnam'";
	say STDERR "\$version = '$version'";
	say STDERR "\$bindaddr = '$bindaddr'";
	say STDERR "\$bindport = '$bindport'";
	say STDERR "\$pastedir = '$pastedir'";
	say STDERR "\$manpath = '$manpath'";
	say STDERR "\$cltscript = '$cltscript'";
	say STDERR "\$verbose = '$verbose'";
	say STDERR "\$myhost = '$myhost'";
	say STDERR "\$logfile = '$logfile'";
	say STDERR "\$maxbuflen = '$maxbuflen'";
	say STDERR "\$minidlen = '$minidlen'";
	say STDERR "\$ratesmpl = '$ratesmpl'";
	say STDERR "\$ratetspan = '$ratetspan'";
	say STDERR "\$year = '$year'";
	say STDERR "\$inforeq = '$inforeq'";

	say STDERR "\@idalpha: '".(join '', @idalpha)."'";

	print STDERR Dumper(\%readbuf) =~ s/\$VAR1/%readbuf/r;
	print STDERR Dumper(\%datalen) =~ s/\$VAR1/%datalen/r;
	print STDERR Dumper(\%rateinfo) =~ s/\$VAR1/%rateinfo/r;
	print STDERR Dumper(\%opts) =~ s/\$VAR1/%opts/r;
	say STDERR "========= End of state dump =========";
}

# -----------------------------------------------------------------------------


# Parse command-line, overriding defaults
usage(\*STDERR, 1) if !getopts("hvVl:d:m:H:c:L:s:r:R:", \%opts);

if (defined $opts{V}) {
	print "$version\n";
	exit 0;
}

usage(\*STDOUT, 0)    if defined $opts{h};
$verbose = 1          if defined $opts{v};
$manpath = $opts{m}   if defined $opts{m};
$pastedir = $opts{d}  if defined $opts{d};
$cltscript = $opts{c} if defined $opts{c};
$myhost = $opts{H}    if defined $opts{H};
$logfile = $opts{L}   if defined $opts{L};
$maxbuflen = $opts{s} if defined $opts{s};
$ratesmpl = $opts{r}  if defined $opts{r};
$ratetspan = $opts{R} if defined $opts{R};

if (defined $opts{l}) {
	my $tmp = $opts{l};
	if (!($tmp =~ /(?:(^.+):)?([0-9]+)$/)) {
		E 'Bad argument to -l (should be "PORT" or "ADDR:PORT")';
	}
	$bindaddr = $1 ? $1 : "0.0.0.0";
	$bindport = $2;
}

E "Could not read man page '$manpath' (Bad -m? Try -h)" if ! -r $manpath;
E "Could not read client script '$cltscript' (Bad -c? Try -h)" if ! -r $cltscript;
E "Could not access paste directory '$pastedir' (Bad -d? Try -h)" if ! -d $pastedir;
E "Invalid maximum paste size '$maxbuflen' (Bad -s? Try -h)" if !($maxbuflen =~ /^[1-9][0-9]*$/);
$maxbuflen *= 1024 if defined $opts{s}; # Is given in KiB on the command line

E "Invalid number of rate limiting samples '$ratesmpl' (Bad -r? Try -h)" if !($ratesmpl =~ /^[0-9]+$/);
E "Invalid timespan for rate-limiting '$ratetspan' (Bad -R? Try -h)" if !($ratetspan =~ /^[0-9]+$/);

L "Logfile created" if $logfile and ! -e $logfile;
E "Cannot write to logfile '$logfile' (Bad -L? Try -h)" if $logfile and ! -w $logfile;

if (!$myhost) {
	my @out = `hostname`;
	$myhost = $out[0];
	chop $myhost;

	E "Failed to figure out hostname, use -H <FQDN>" if !$myhost;
	W "Determined our hostname to be '$myhost' (override with -H)";
}

D "Will listen on $bindaddr:$bindport; accessible as http://$myhost/";

# Generate paste '0' because it contains the client script we advertise in the man page
`sed "s/^site=.*\$/site='$myhost'/" $cltscript >$pastedir/0`;
E "Failed to generate paste 0 (the client script)" if (${^CHILD_ERROR_NATIVE} != 0);

W "NOT doing rate-limiting! (Bad -r and/or -R?)" if (!$ratesmpl || !$ratetspan);

$| = 1;

my $sck = new IO::Socket::INET (
	Type => SOCK_STREAM,
	Proto => 'tcp',
	Listen => 64,
	Reuse => 1,
	Blocking => 1,
	LocalAddr => $bindaddr,
	LocalPort => $bindport
) or E "Could not create socket $!\n";

$SIG{'USR1'} = 'INFO_handler';
$SIG{'INFO'} = 'INFO_handler' if $^O =~ /^(.*bsd)|darwin$/;

my $sel = IO::Select->new();
$sel->add($sck);

while(1)
{
	D "Selecting...";
	my @rdbl = $sel->can_read;

	if ($inforeq) {
		dump_state;
		$inforeq = 0;
	}

	if (!@rdbl) {
		D "Nothing selected";
		next;
	}

	foreach my $s (@rdbl) {
		if ($s == $sck) {
			D "Listener is readable...";
			my $clt = $sck->accept();
			if (!$clt) {
				W "Failed to accept: $!";
				next;
			}
			my $who = $clt->peerhost();
			D "$who: Connected";

			$sel->add($clt);
			$readbuf{$who} = '';
			delete $datalen{$who};

			next;
		}

		my $who = $s->peerhost();
		D "$who: Readable";

		if (!handle_clt($s, $who)) {
			D "$who: Dropping";
			$sel->remove($s);
			$s->close();
		}
	}
}

$sck->close();

#2015, Timo Buhrmester

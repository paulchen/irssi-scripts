use strict;
use vars qw($NAME $VERSION %IRSSI);
use Irssi qw(command_bind signal_add_first settings_get_str settings_add_str get_irssi_dir settings_set_str);
use Date::Calc qw(N_Delta_YMDHMS check_date check_time Add_Delta_Days); # package libdate-calc-perl on ubuntu
use Scalar::Util qw(looks_like_number);
use URI::Escape;
use Data::Dumper;
use JSON;
use Text::Iconv;
use HTML::Entities;
use Encode qw(decode);
require HTTP::Request;
require LWP::UserAgent;

$VERSION = "1.03";
%IRSSI = (
    authors     => "Paul Staroch",
    contact     => "paulchen\@rueckgr.at",
    name        => "fut",
    description => "futcounter, especially for mati",
    license     => "GPL"
);

# === EDIT THE FOLLOWING LINES TO YOUR NEEDS ===

our $dl_url = 'https://github.com/paulchen/irssi-scripts/blob/master/fut.pl';

my $fut_listen_channels = '#chatbox';
my $fut_trigger_channels = '#chatbox';
my $fut_network = 'localhost';
my $fut_trigger_words = 'fut krochn braq fix oida bam gusch ficken';
my $fut_simple_answers = '!bam#^OIDA!~!heast#^KROCHN!~!oida#^BAM!~paulchenbot#^Ich bin kein Bot, sondern ein böser Tutor!~!fi+x#^HEAST!~!braq#^BAM!~!SgtPepper#Ihr habt alle einen ganz kleinen!~^gr($|[^g])#Flachzang~^grgr#muh';
my $fut_complex_answers = '!fresse#i prak da ane, <nick>~!goschn#i hau da in de goschn, <nick>~!gusch#bappn hoidn, <nick>~!mitleid#<nick>: mooooooooh~!deepb#<nick>, DU PENIS!~!huntu#heast, <nick>, anmelden, oida!~!gatsch#hupf in gatsch, <nick>!~!xaz#<nick>, DU VAGINA!';

# === DO NOT EDIT ANYTHING BELOW THIS LINE ===

our %counter;
our %count;

our @limit_queue;

our $insults;

our $iconv = Text::Iconv->new('utf8', 'iso8859-15');
our $iconv2 = Text::Iconv->new('iso8859-15', 'utf8');

sub resultcount {
	# kudos to emptyvi for rewriting this code
	my $query_string = shift;
	my $query_url = 'https://www.google.at/search?q=' . uri_escape($query_string);

	my $user_agent = LWP::UserAgent->new;
	$user_agent->agent( "Mozilla/5.0 (X11; U; Linux i686; de; rv:1.9b5)" );
#	$user_agent->local_address("5.9.110.236");
	my $response = $user_agent -> get( $query_url );

	if( $response -> is_success ){

		if ($response->decoded_content =~ m/([\d.]+)\s*Ergebnis/){

			my $result = $1;
			$result =~ s/\.//g;

			return $result;
		}
	}

	return;
}

sub slogan {
	my $query_string = shift;
	my $query_url = 'http://www.sloganizer.net/outbound.php?slogan=' . $iconv2->convert($query_string);

	my $user_agent = LWP::UserAgent->new;
	my $response = $user_agent -> get( $query_url );
	if( $response -> is_success ){
		my $result = decode_entities(decode_entities(decode('utf-8', $response->decoded_content)));
		$result =~ s/<[^>]*>//g;
		return $result;
	}

	return;
}

sub trim {
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

sub update_database {
	foreach my $word_ (split(' ',settings_get_str('fut_trigger_words')),'deepb-active','deepb-passive','xaz-active','xaz-passive','insult-active','insult-passive','weichei-active','weichei-passive','hartei-active','hartei-passive','fail') {
		my $word=lc($word_);

		my $database = get_irssi_dir."/$word.dat";
		my $database_tmp = get_irssi_dir."/$word.tmp";
		my $database_old = get_irssi_dir."/$word.dat~";

		open DATABASE, ">$database_tmp";
		foreach my $nick (keys %{$counter{$word}}) {
			if ($nick ne '' && $counter{lc($word)}{lc($nick)} gt 0) {
				my $countx=$counter{lc($word)}{lc($nick)};
				chomp $countx;
				print DATABASE lc($nick)." $countx\n";
			}
		}

		close DATABASE;
		rename $database, $database_old;
		rename $database_tmp, $database;
	}
}

sub fut_stats {
	my ($server, $channel, $word) = @_;
	my $message="Top 10 $word spammers: ";

	my $message .= get_stats($word);

	my $msg = "msg $channel $message";
	chomp $msg;
	$server->command($msg);
}

sub get_stats {
	my ($word) = @_;
	my $cnt=0;
	my $message='';

	%count = $counter{$word};
	foreach my $key (sort{$counter{$word}{$b} <=> $counter{$word}{$a}} (keys %{$counter{$word}})) {
		my $value=$counter{$word}{$key};
		chomp $value;

		if($value eq '') {
			next;
		}
		if($key =~ m/^#/ ) {
			next;
		}

		$cnt++;
		if($cnt==11) {
			last;
		}

		$key =~ s/(.)/$1\x{2060}/g;
		if($cnt==1) {
			$message.="$key ($value)";
		}
		else {
			$message.=", $key ($value)";
		}
	}

	return $message;
}

sub build_match_string {
	my ($input)=@_;
	my $output='';
	for(my $a=0;$a<length($input);$a++) {
		$output .= substr($input,$a,1) . '+';
	}
	return $output;
}

sub fut_own {
	my ($server, $msg, $channel) = @_;
	fut($server, $msg, $server->{nick}, "", $channel);
}

sub limiter {
	my ($server, $msg) = @_;

	if(substr($msg,0,index($msg,' ')) eq 'notice') {
		$server->command($msg);
		return;
	}
	if($msg =~ m/.*cb:.*/i) {
		return;
	}

	my $queue_len=10;
	my $queue_time=60;

	$queue_len--;
	if($#limit_queue eq 0) {
		$server->command($msg);
		return;
	}
	my $first=pop(@limit_queue);
	my $output=0;
	if(!(time-$first<$queue_time && $#limit_queue+1 == $queue_len)) {
		$server->command($msg);
		$output=1;
	}
	if($#limit_queue+1 < $queue_len || $output eq 0) {
		push @limit_queue, $first;
	}
	if($output eq 1) {
		unshift @limit_queue, time;
	}
}

sub random_nick {
	my (@nicks, $server) = @_;
	my $ret;
	while(lc($ret=$nicks[rand($#nicks)]->{'nick'}) eq lc(own_nick($server))) {}
	return $ret;
}

sub own_nick {
	my ($server) = @_;

	return $server->{'nick'};
}

sub greater0 {
	my @values = @_;
	my $minimum_count = shift @values;
	foreach(@values) {
		if($_ > 0) {
			$minimum_count--;
		}
	}
	return $minimum_count <= 0;
}

sub calculate_date_diff {
	my ($year2, $month2, $day2, $hour2, $minute2, $seconds2) = @_;

	if (!looks_like_number($year2) || !looks_like_number($month2) || !looks_like_number($day2) ||
		!looks_like_number($hour2) || !looks_like_number($minute2) || !looks_like_number($seconds2)) {
		return 'Invalid date';
	}

	return `/home/ircbot/datediff.py "$year2-$month2-$day2 $hour2:$minute2:$seconds2"`;

	print "$year2 $month2 $day2 $hour2 $minute2 $seconds2";
	if (!check_date($year2, $month2, $day2)) {
		return 'invalid date, dumbass';
	}
	if (!check_time($hour2, $minute2, $seconds2)) {
		return 'invalid time, dumbass';
	}

	my ($seconds1, $minute1, $hour1, $day1, $month1, $year1, $dayOfWeek1, $dayOfYear1, $daylightSavings1) = localtime();
	$year1+=1900;
	$month1++;

	my $reverse = 0;
	my ($years, $months, $days, $hours, $minutes, $seconds) = N_Delta_YMDHMS( $year1, $month1, $day1, $hour1, $minute1, $seconds1,  # earlier
			$year2, $month2, $day2, $hour2, $minute2, $seconds2); # later
	if ($years < 0 or $months < 0 or $days < 0 or $hours < 0 or $minutes < 0 or $seconds < 0) {
		print "!!";
		$reverse = 1;
		($years, $months, $days, $hours, $minutes, $seconds) = (-$years, -$months, -$days, -$hours, -$minutes, -$seconds);
	}

	my $output='';
	print "$years $months $days $hours $minutes $seconds";
	if($years>0) {
		$output.="$years year";
		if($years>1) {
			$output.='s';
		}
		if(greater0(2, $months, $days, $hours, $minutes, $seconds)) {
			$output.=', ';
		}
		elsif(greater0(1, $months, $days, $hours, $minutes, $seconds)) {
			$output.=' and ';
		}
	}
	if($months>0) {
		$output.="$months month";
		if($months>1) {
			$output.='s';
		}
		if(greater0(2, $days, $hours, $minutes, $seconds)) {
			$output.=', ';
		}
		elsif(greater0(1, $days, $hours, $minutes, $seconds)) {
			$output.=' and ';
		}
	}
	if($days>0) {
		$output.="$days day";
		if($days>1) {
			$output.='s';
		}
		if(($hours>0 && $minutes>0) || ($hours>0 && $seconds>0) || ($minutes>0 && $seconds>0)) {
			$output.=', ';
		}
		elsif ($hours>0 || $minutes > 0 || $seconds > 0) {
			$output.=' and ';
		}
	}
	if($hours>0) {
		$output.="$hours hour";
		if($hours>1) {
			$output.='s';
		}
		if($minutes>0 && $seconds>0) {
			$output.=', ';
		}
		elsif ($minutes>0 || $seconds>0) {
			$output.=' and ';
		}
	}
	if($minutes>0) {
		$output.="$minutes minute";
		if($minutes>1) {
			$output.='s';
		}
		if($seconds>0) {
			$output.=' and ';
		}
	}
	if($seconds>0) {
		$output.="$seconds second";
		if($seconds>1) {
			$output.='s';
		}
	}

	if($reverse) {
		return "$output elapsed";
	}
	return "$output remaining";
}

sub fut {
	my ($server, $msg, $nick_asks, $address, $channel) = @_;

	$msg = $iconv->convert($msg);

	my @fut_listen_channels = split(' ',settings_get_str('fut_listen_channels'));
	my @fut_trigger_channels = split(' ',settings_get_str('fut_trigger_channels'));
	my @trigger_words = split(' ',settings_get_str('fut_trigger_words'));
	my @simple_answers = split('~',settings_get_str('fut_simple_answers'));
	my @complex_answers = split('~',settings_get_str('fut_complex_answers'));

	my $fut_network = settings_get_str('fut_network');
	my $channel_found = 0;

	unless ($server->{chatnet} eq $fut_network) {
		return;
	}
	if ($nick_asks =~ m/peszi/ or $nick_asks =~ m/bot$/i ) {
		return;
	}
	chomp $msg;
	foreach(@fut_trigger_channels) {
		if($_ eq $channel) {
			if ($msg =~ m/!gf /) {
				my $input = substr($msg,4);
				my @parts = split(/ vs /, $input);

				if($#parts == 1) {
					$parts[0] =~ s/^\s+|\s+$//g;
					$parts[1] =~ s/^\s+|\s+$//g;

					my $count1 = resultcount($parts[0]);
					my $count2 = resultcount($parts[1]);

					if(not ($count1 =~ m/[0-9]+/i and $count2 =~ m/[0-9]+/i)) {
						next;
					}

					my $result;
					if($count1 == $count2) {
						$result = $parts[0] . ' ties with ' . $parts[1] . " (both $count1 results).";
					}
					elsif($count1 < $count2) {
						$result = $parts[1] . ' beats ' . $parts[0] . " ($count2 vs. $count1 results).";
					}
					else {
						$result = $parts[0] . ' beats ' . $parts[1] . " ($count1 vs. $count2 results).";
					}

					limiter($server, "msg $channel $result");
				}
			}
			elsif ($msg =~ m/!slogan\s*(.*)/i) {
				my $result = slogan($1);
				if ($result) {
					limiter($server, "msg $channel $result");
				}
			}
			elsif ($msg =~ m/!geil( .+)?/i) {
				my $geil_nick;
				if ($msg =~ m/!geil( .+)/i) {
					my @parts = split(' ', $msg);
					$geil_nick = $parts[1];
				}
				else {
					$geil_nick = $nick_asks;
				}

				my $geil;
				if(lc($geil_nick) eq lc(own_nick($server)) or lc($geil_nick) eq 'paulchen' or lc($geil_nick) eq 'sex') {
					$geil = int(rand(10000))/1000+90;
				}
#				elsif($geil_nick =~ m/anwesender/i) {
#					$geil = int(rand(20000))/1000+90;
#				}
				else {
					$geil = int(rand(100000))/1000;
				}
				limiter($server, "msg $channel $geil_nick ist zu $geil% geil");
			}
			elsif ($msg eq '!help') {
				$server->command("notice $nick_asks This is your favourite ".own_nick($server).".");
				my $line = "Currently implemented commands: !<term>stats, !<term>count, !<term>counter, !seen, !insult, !ubszkt, !deepbstats, !xazstats, !insultstats, !newyear, !oldyear, !geil";
				foreach my $answer (@simple_answers) {
					my @pair=split('#',$answer);
					$line=$line.", ".$pair[0];
				}
				foreach my $answer (@complex_answers) {
					my @pair=split('#',$answer);
					$line=$line.", ".$pair[0];
				}
				$server->command("notice $nick_asks $line");
				$server->command("notice $nick_asks <term> can be one of the following terms: ".join(', ',@trigger_words));
				$server->command("notice $nick_asks Send user '".own_nick($server)."' a message if you want a certain term to be added.");
				$server->command("notice $nick_asks If you wanna download me, check this out: $dl_url");
				return;
			}
#			elsif ($msg =~ m/twitter/i ) {
#				$server->command("msg $channel twitter -> tonne");
#				return;
#			}
			elsif ($msg =~ m/^\s*!pizza\s*$/i ) {
				my $difference = calculate_date_diff(2016, 11, 19, 11, 51, 29);
				$difference =~ s/ elapsed//;
				if($difference ne '') {
					$server->command("msg $channel enri owes us pizza for $difference.");
				}
			}
			elsif ($msg =~ m/^\s*!wm\s*$/i ) {
				my $difference = calculate_date_diff(2022, 11, 21, 0, 0, 0);
				if($difference =~ m/remaining/i ) {
					$server->command("msg $channel $difference.");
				}
			}
			elsif ($msg =~ m/^\s*!em\s*$/i ) {
				my $difference = calculate_date_diff(2020, 6, 12, 21, 0, 0);
				if($difference =~ m/remaining/i ) {
					$server->command("msg $channel $difference.");
				}
#				open my $file, '/home/ircbot/irssi-scripts/worldcup/status';
#				while(my $line = <$file>) {
#					$server->command("msg $channel $line");
#				}
#				close $file;
#				$server->command("msg $channel Tippspiel: https://www.kicktipp.de/chatbox/");
			}
			elsif ($msg =~ m/^\s*!t\s*einhorn\s*$/i or $msg =~ m/^\s*!einhorn\s*$/i ) {
				my ($seconds1, $minute1, $hour1, $day1, $month1, $year1, $dayOfWeek1, $dayOfYear1, $daylightSavings1) = localtime();
				my $year = $year1 + 1900;

				print "$day1 $month1 $year1";
				if($month1 == 11) {
					if($day1 == 24) {
						$server->command("msg $channel Heute ist der Internationale Tag des kotzenden Regenbogeneinhorns!");
						return;
					}
					if($day1 > 24) {
						$year++;
					}
				}

				my $difference = calculate_date_diff($year, 12, 24, 0, 0, 0);
				if($difference ne '') {
					$server->command("msg $channel $difference.");
				}
			}
			elsif ($msg =~ m/^\s*!t\s*([0-9]+)\-([0-9]+)\-([0-9]+?)\s*$/i ) {
				my $difference = calculate_date_diff($1, $2, $3, 0, 0, 0);
				if($difference ne '') {
					$server->command("msg $channel $difference.");
				}
			}
			elsif ($msg =~ m/^\s*!t\s*([0-9]+)\.([0-9]+)\.?([0-9]+)?\s*(([0-9]+):([0-9]+))?\s*$/i ) {
				my $month = int($2);
				my $day = int($1);
				my $year = $3;

				my $hour = $5;
				my $minute = $6;
				print "a: $5 $6";
				if(!$hour || !$minute) {
					print "b";
					$hour = 0;
					$minute = 0;
				}
				else {
					print "c";
					$hour = int($hour);
					$minute = int($minute);
				}

				if(!$year) {
					my ($seconds1, $minute1, $hour1, $day1, $month1, $year1, $dayOfWeek1, $dayOfYear1, $daylightSavings1) = localtime();
					$year = $year1 + 1900;

					my $month2 = $month1+1;
					# from the documentation of localtime(): $mday is the day of the month and $mon the month in the range 0..11 , with 0 indicating January and 11 indicating December.
					if($month < $month1+1 or ($month == $month1+1 and $day < $day1)) {
						$year++;
					}
				}
				else {
					$year = int($year);
				}

				my $difference = calculate_date_diff($year, $month, $day, $hour, $minute, 0);
				if($difference ne '') {
					$server->command("msg $channel $difference");
				}
			}
			elsif ($msg =~ m/^\s*!t\s*([0-9]+):([0-9]+)\s*$/i ) {
				my $hour = int($1);
				my $minute = int($2);
				my ($seconds1, $minute1, $hour1, $day1, $month1, $year1, $dayOfWeek1, $dayOfYear1, $daylightSavings1) = localtime();

				$year1 += 1900;
				$month1++;

				print "$hour $hour1 $minute $minute1";
				if ($hour < $hour1 || ($hour == $hour1 && $minute <= $minute1)) {
					($year1, $month1, $day1) = Add_Delta_Days($year1, $month1, $day1, 1);
				}
			
				my $difference = calculate_date_diff($year1, $month1, $day1, $hour, $minute, 0);
				if($difference ne '') {
					$server->command("msg $channel $difference");
				}
			}
			elsif ($msg =~ m/.*!(old|new)year/i ) {
				my ($seconds1, $minute1, $hour1, $day1, $month1, $year1, $dayOfWeek1, $dayOfYear1, $daylightSavings1) = localtime();
				$year1 += 1900;

				my ($year2, $month2, $day2, $hour2, $minute2, $seconds2) = ($year1+1, 1, 1, 0, 0, 0);
				if($msg =~ m/.*!oldyear/i ) {
					$year2--;
				}
				
				my $difference = calculate_date_diff($year2, $month2, $day2, $hour2, $minute2, $seconds2);
				$server->command("msg $channel $difference");
			}
			elsif ($msg =~ m/.*!failstats/i ) {
				$server->command("msg $channel Top 10 people who have failed: ".get_stats('fail'));
			}
			elsif ($msg =~ m/.*!insultstats/i ) {
				$server->command("msg $channel Top 10 people being insulted: ".get_stats('insult-passive'));
				$server->command("msg $channel Top 10 people insulting others: ".get_stats('insult-active'));
			}
			elsif ($msg =~ m/.*!xazstats/i ) {
				$server->command("msg $channel Top 10 people being called VAGINA: ".get_stats('xaz-passive'));
				$server->command("msg $channel Top 10 people calling others VAGINA: ".get_stats('xaz-active'));
			}
			elsif ($msg =~ m/.*!deepbstats/i ) {
				$server->command("msg $channel Top 10 people being called PENIS: ".get_stats('deepb-passive'));
				$server->command("msg $channel Top 10 people calling others PENIS: ".get_stats('deepb-active'));
			}
			elsif ($msg =~ m/.*!weicheistats/i ) {
				$server->command("msg $channel Top 10 people being called Weichei: ".get_stats('weichei-passive'));
				$server->command("msg $channel Top 10 people calling others Weichei: ".get_stats('weichei-active'));
			}
			elsif ($msg =~ m/.*!harteistats/i ) {
				$server->command("msg $channel Top 10 people being called Hartei: ".get_stats('hartei-passive'));
				$server->command("msg $channel Top 10 people calling others Hartei: ".get_stats('hartei-active'));
			}
			elsif (lc($msg) =~ m/^![^ ]+stats/ ) {
				foreach my $word (@trigger_words) {
					if($msg eq "!".$word."stats") {
						fut_stats($server, $channel, $word);
					}
				}
				return;
			}
			elsif ($msg =~ m/!.+count(er)? [^ ]+/) {
				my $nick = trim(substr($msg,index($msg,' ')+1));
				if (substr($msg,0,index($msg,' ')) eq '!deepbcount' or substr($msg,0,index($msg,' ')) eq '!deepbcounter') {
					my $activecount = exists $counter{'deepb-active'}{lc($nick)} ? $counter{'deepb-active'}{lc($nick)} : 0;
					my $passivecount = exists $counter{'deepb-passive'}{lc($nick)} ? $counter{'deepb-passive'}{lc($nick)} : 0;

					chomp $activecount;
					chomp $passivecount;

					$msg = "msg $channel $nick called others PENIS $activecount times and was called PENIS $passivecount times.";
					chomp $msg;
					limiter($server,$msg);
					return;
				}
				if (substr($msg,0,index($msg,' ')) eq '!xazcount' or substr($msg,0,index($msg,' ')) eq '!xazcounter') {
					my $activecount = exists $counter{'xaz-active'}{lc($nick)} ? $counter{'xaz-active'}{lc($nick)} : 0;
					my $passivecount = exists $counter{'xaz-passive'}{lc($nick)} ? $counter{'xaz-passive'}{lc($nick)} : 0;

					chomp $activecount;
					chomp $passivecount;

					$msg = "msg $channel $nick called others VAGINA $activecount times and was called VAGINA $passivecount times.";
					chomp $msg;
					limiter($server,$msg);
					return;
				}
				if (substr($msg,0,index($msg,' ')) eq '!insultcount' or substr($msg,0,index($msg,' ')) eq '!insultcounter') {
					my $activecount = exists $counter{'insulted-active'}{lc($nick)} ? $counter{'insult-active'}{lc($nick)} : 0;
					my $passivecount = exists $counter{'insulted-passive'}{lc($nick)} ? $counter{'insult-passive'}{lc($nick)} : 0;

					chomp $activecount;
					chomp $passivecount;

					$msg = "msg $channel $nick insulted others $activecount times and was insulted $passivecount times.";
					chomp $msg;
					limiter($server,$msg);
					return;
				}
				if (substr($msg,0,index($msg,' ')) eq '!weicheicount' or substr($msg,0,index($msg,' ')) eq '!weicheicounter') {
					my $activecount = exists $counter{'weichei-active'}{lc($nick)} ? $counter{'weichei-active'}{lc($nick)} : 0;
					my $passivecount = exists $counter{'weichei-passive'}{lc($nick)} ? $counter{'weichei-passive'}{lc($nick)} : 0;

					chomp $activecount;
					chomp $passivecount;

					$msg = "msg $channel $nick called others Weichei $activecount times and was called Weichei $passivecount times.";
					chomp $msg;
					limiter($server,$msg);
					return;
				}
				if (substr($msg,0,index($msg,' ')) eq '!harteicount' or substr($msg,0,index($msg,' ')) eq '!harteicounter') {
					my $activecount = exists $counter{'hartei-active'}{lc($nick)} ? $counter{'hartei-active'}{lc($nick)} : 0;
					my $passivecount = exists $counter{'hartei-passive'}{lc($nick)} ? $counter{'hartei-passive'}{lc($nick)} : 0;

					chomp $activecount;
					chomp $passivecount;

					$msg = "msg $channel $nick called others Hartei $activecount times and was called Hartei $passivecount times.";
					chomp $msg;
					limiter($server,$msg);
					return;
				}
				if (substr($msg,0,index($msg,' ')) eq '!failcount' or substr($msg,0,index($msg,' ')) eq '!failcounter') {
					my $failcount = exists $counter{'fail'}{lc($nick)} ? $counter{'fail'}{lc($nick)} : 0;

					chomp $failcount;

					$msg = "msg $channel $nick has failed $failcount times.";
					chomp $msg;
					limiter($server,$msg);
					return;
				}
				foreach my $word (@trigger_words) {
					if (substr($msg,0,index($msg,' ')) eq '!'.$word.'count' or substr($msg,0,index($msg,' ')) eq '!'.$word.'counter') {
						my $futcount = exists $counter{lc($word)}{lc($nick)} ? $counter{lc($word)}{lc($nick)} : 0;
						if(lc($nick) eq 'chuck norris') {
							$futcount='∞';
						}
						$msg = "msg $channel ".$word."counter for $nick: $futcount";
						chomp $msg;
						limiter($server,$msg);
					}
				}
				return;
			}
			elsif ($msg =~ m/!.+count(er)?/) {
				foreach my $word (@trigger_words) {
					if($msg eq "!".$word."count" or $msg eq "!".$word."counter") {
						my $futcount = exists $counter{lc($word)}{lc($channel)} ? $counter{lc($word)}{lc($channel)} : 0;
						$msg = "msg $channel ".$word."counter for $channel: $futcount";
						chomp $msg;
						limiter($server,$msg);
					}
				}
				return;
			}
#			elsif ($msg =~ m/.*!raus +mdk.*/i or $msg =~ m/.*mdk *<-+ *eintopf.*/i) {
#				limiter($server, "msg $channel mdk -> eintopf");
#			}
#			elsif ($msg =~ m/.*!wegschmeissen.*/i) {
#				limiter($server, "msg $channel mdk -> eintopf");
#			}
#			elsif ($msg =~ m/.*!recycle +mdk.*/i or $msg =~ m/.*mdk *<-+ *tonne.*/i) {
#				limiter($server, "msg $channel mdk -> tonne");
#			}
#			elsif ($msg =~ m/.*!abfuhr.*/i) {
#				limiter($server, "msg $channel mdk -> tonne");
#			}
			foreach my $blubb (@simple_answers) {
				my @pair = split('#',$blubb);
				while($msg =~ m/$pair[0]/i ) {
					if(substr($pair[1],0,1) eq "^") {
						limiter($server, "notice $nick_asks ".substr($pair[1],1));
					}
					else {
						limiter($server, "msg $channel ".$pair[1]);
					}
					$msg =~ s/$pair[0]//ig;
				}
			}
			if(lc(substr($msg,0,index($msg,' '))) eq '!weichei' or lc(substr($msg,0,index($msg,' '))) eq '!hartei') {
				my $chan=$server->channel_find($channel);
				my $nick=trim(substr($msg,index($msg,' ')+1));

				my $active=(lc(substr($msg,0,index($msg,' '))) eq '!weichei') ? 'weichei-active' : 'hartei-active';
				my $passive=(lc(substr($msg,0,index($msg,' '))) eq '!weichei') ? 'weichei-passive' : 'hartei-passive';

				my $found=0;
#				if(lc($nick) ne lc(own_nick($server))) {
					foreach my $channel_nick ($chan->nicks()) {
						if(lc($channel_nick->{'nick'}) eq lc($nick)) {
							$counter{$active}{lc($nick_asks)} ++;
							$counter{$passive}{lc($channel_nick->{'nick'})} ++;
							update_database;
							$found=1;
						}
					}
#				}
				if($found eq 0) {
#					my $nick_=(lc($nick_asks) eq lc(own_nick($server))) ? random_nick($chan->nicks(),$server) : $nick_asks;
					my $nick_ = $nick_asks;
					$counter{$active}{lc($nick_)} ++;
					$counter{$passive}{lc($nick_)} ++;
					update_database;
				}
			}
			if(lc(substr($msg,0,index($msg,' '))) eq '!fail') {
				my $chan=$server->channel_find($channel);
				my $nick=trim(substr($msg,index($msg,' ')+1));
				my $found=0;

#				if(lc($nick) ne lc(own_nick($server))) {
					foreach my $channel_nick ($chan->nicks()) {
						if(lc($channel_nick->{'nick'}) eq lc($nick)) {
							$counter{'fail'}{lc($channel_nick->{'nick'})} ++;
							update_database;
							$found=1;
						}
					}
#				}
				if($found eq 0) {
					my $nick_=(lc($nick_asks) eq lc(own_nick($server))) ? random_nick($chan->nicks(),$server) : $nick_asks;
					my $nick_ = $nick_asks;
					$counter{'fail'}{lc($nick_)} ++;
					update_database;
				}
			}
			if(lc(substr($msg,0,index($msg,' '))) eq '!epicfail') {
				my $chan=$server->channel_find($channel);
				my $nick=trim(substr($msg,index($msg,' ')+1));
				my $found=0;

#				if(lc($nick) ne lc(own_nick($server))) {
					foreach my $channel_nick ($chan->nicks()) {
						if(lc($channel_nick->{'nick'}) eq lc($nick)) {
							$counter{'fail'}{lc($channel_nick->{'nick'})} += 10;
							update_database;
							$found=1;
						}
					}
#				}
				if($found eq 0) {
					my $nick_=(lc($nick_asks) eq lc(own_nick($server))) ? random_nick($chan->nicks(),$server) : $nick_asks;
					my $nick_ = $nick_asks;
					$counter{'fail'}{lc($nick_)} += 10;
					update_database;
				}
			}
			if(lc(substr($msg,0,index($msg,' '))) eq '!dirkfail') {
				my $chan=$server->channel_find($channel);
				my $nick=trim(substr($msg,index($msg,' ')+1));
				my $found=0;

#				if(lc($nick) ne lc(own_nick($server))) {
					foreach my $channel_nick ($chan->nicks()) {
						if(lc($channel_nick->{'nick'}) eq lc($nick)) {
							$counter{'fail'}{lc($channel_nick->{'nick'})} += 100;
							update_database;
							$found=1;
						}
					}
#				}
				if($found eq 0) {
					my $nick_=(lc($nick_asks) eq lc(own_nick($server))) ? random_nick($chan->nicks(),$server) : $nick_asks;
					my $nick_ = $nick_asks;
					$counter{'fail'}{lc($nick_)} += 100;
					update_database;
				}
			}
			if(lc(substr($msg,0,index($msg,' '))) eq '!insult' or lc(substr($msg,0,index($msg,' '))) eq '!ubszkt') {
				my $chan=$server->channel_find($channel);
				my $nick=trim(substr($msg,index($msg,' ')+1));
				my $found=0;
				my $answer_id=int(rand($insults));
				my $answer;

				open INSULTS, "/home/ircbot/.irssi/insult.dat" or return;
				my $a=0;
				foreach my $input (<INSULTS>) {
					chomp;
					if ($input ne "") {
						$a++;
						if($a eq $answer_id) {
							$answer=$input;
							last;
						}
					}
				}
				close INSULTS;

				chomp $answer;
				if(lc($nick) ne lc(own_nick($server))) {
					foreach my $channel_nick ($chan->nicks()) {
						if(lc($channel_nick->{'nick'}) eq lc($nick)) {
							$counter{'insult-active'}{lc($nick_asks)} ++;
							$counter{'insult-passive'}{lc($channel_nick->{'nick'})} ++;
							update_database;
							limiter($server, "msg $channel ".$channel_nick->{'nick'}.": $answer");
							$found=1;
						}
					}
				}
				if($found eq 0) {
					my $nick_=(lc($nick_asks) eq lc(own_nick($server))) ? random_nick($chan->nicks(),$server) : $nick_asks;
					my $nick_ = $nick_asks;
					limiter($server, "msg $channel $nick_: $answer");
					$counter{'insult-active'}{lc($nick_)} ++;
					$counter{'insult-passive'}{lc($nick_)} ++;
					update_database;
				}
			}
			foreach my $blubb (@complex_answers) {
				my @pair = split('#',$blubb);
				if(trim(lc($msg)) eq $pair[0]) {
					my $nick_ = $nick_asks;
					my $answer = $pair[1];
					$answer =~ s/<nick>/$nick_/g;
					if($pair[0] eq '!deepb') {
						$counter{'deepb-active'}{lc($nick_)} ++;
						$counter{'deepb-passive'}{lc($nick_)} ++;
						update_database;
					}
					elsif($pair[0] eq '!xaz') {
						$counter{'xaz-active'}{lc($nick_)} ++;
						$counter{'xaz-passive'}{lc($nick_)} ++;
						update_database;
					}
					limiter($server, "msg $channel $answer");

					last;
				}
				if(lc(substr($msg,0,index($msg,' '))) eq lc($pair[0])) {
					my $chan=$server->channel_find($channel);
					my $nick=trim(substr($msg,index($msg,' ')+1));
					my $found=0;
					my $answer=$pair[1];
					foreach my $channel_nick ($chan->nicks()) {
						if(lc($channel_nick->{'nick'}) eq lc($nick)) {
							if(lc($nick) ne lc(own_nick($server))) {
								$answer =~ s/<nick>/$channel_nick->{'nick'}/g;
								limiter($server, "msg $channel $answer");
								$found=1;
								if($pair[0] eq '!deepb') {
									$counter{'deepb-active'}{lc($nick_asks)} ++;
									$counter{'deepb-passive'}{lc($channel_nick->{'nick'})} ++;
									update_database;
								}
								elsif($pair[0] eq '!xaz') {
									$counter{'xaz-active'}{lc($nick_asks)} ++;
									$counter{'xaz-passive'}{lc($channel_nick->{'nick'})} ++;
									update_database;
								}
								last;
							}
						}
					}
					if($found eq 0) {
						my $nick_=(lc($nick_asks) eq lc(own_nick($server))) ? random_nick($chan->nicks(),$server) : $nick_asks;
#						my $nick_ = $nick_asks;
						$answer =~ s/<nick>/$nick_/g;
						if($pair[0] eq '!deepb') {
							$counter{'deepb-active'}{lc($nick_)} ++;
							$counter{'deepb-passive'}{lc($nick_)} ++;
							update_database;
						}
						elsif($pair[0] eq '!xaz') {
							$counter{'xaz-active'}{lc($nick_)} ++;
							$counter{'xaz-passive'}{lc($nick_)} ++;
							update_database;
						}
						limiter($server, "msg $channel $answer");
					}
				}
			}
		}
	}
	foreach(@fut_listen_channels) {
		if($_ eq $channel) {
			foreach my $word (@trigger_words) {
				if (substr($msg,0,index($msg,':')) eq "Top 10 $word spammers" && lc($nick_asks) eq lc($server->{nick})) {
					return;
				}
				if (substr($msg,0,index($msg,':')) eq $word."counter for $channel" && lc($nick_asks) eq lc($server->{nick})) {
					return;
				}
				if (substr($msg,0,index($msg,':')) eq $word."counter for $nick_asks" && lc($nick_asks) eq lc($server->{nick})) {
					return;
				}
				if (substr($msg,0,index($msg,':')) eq "<term> can be one of the following terms:" && lc($nick_asks) eq lc($server->{nick})) {
					return;
				}
			}
			if ($msg eq "If you wanna download me, check this out: $dl_url") {
				return;
			}
			if (substr($msg,0,index($msg,':')) eq 'Currently implemented commands:') {
				return;
			}
			if ($msg eq 'This is your favourite '.own_nick($server).'.') {
				return;
			}
			my $modified=0;
			foreach my $word (@trigger_words) {
				my $match_string = build_match_string($word);
				if ($msg =~ m/$match_string/i ) {
					my $cnt=0;
					while($msg =~ m/$match_string/i ) {
						$cnt++;
						$msg =~ s/$match_string//i;
					}
					$counter{$word}{lc($nick_asks)} += $cnt;
					$counter{$word}{$channel} += $cnt;
					$modified=1;
				}
			}
			if($modified eq 1) {
				update_database;
			}
		}
	}
}

sub read_database {
	my @trigger_words = split(' ',settings_get_str('fut_trigger_words'));
	foreach my $word (@trigger_words,'deepb-active','deepb-passive','xaz-active','xaz-passive','insult-active','insult-passive','weichei-active','weichei-passive','hartei-active','hartei-passive','fail') {
		my $database = get_irssi_dir."/".lc($word).".dat";

		open DATABASE, $database or return;
		foreach my $input (<DATABASE>) {
			chomp;
			if ($input ne "") {
				my $nick=lc(substr($input,0,index($input,' ')));
				my $cnt=substr($input,index($input,' ')+1);
				$counter{lc($word)}{$nick} = $cnt;
			}
		}
		close DATABASE;
	}
}

sub read_insults {
	open INSULTS, "/home/ircbot/.irssi/insult.dat" or return;
	$insults=0;
	foreach my $input (<INSULTS>) {
		chomp;
		if ($input ne "") {
			$insults++;
		}
	}
	close INSULTS;
}

signal_add_first 'message public' => 'fut';
signal_add_first 'message irc action' => 'fut';
signal_add_first 'message own_public' => 'fut_own';
signal_add_first 'message irc own_action' => 'fut_own';

settings_add_str('fut', 'fut_listen_channels', $fut_listen_channels);
settings_add_str('fut', 'fut_trigger_channels', $fut_trigger_channels);
settings_add_str('fut', 'fut_network', $fut_network);
settings_add_str('fut', 'fut_trigger_words', $fut_trigger_words);
settings_add_str('fut', 'fut_simple_answers', $fut_simple_answers);
settings_add_str('fut', 'fut_complex_answers', $fut_complex_answers);

read_database;
read_insults;

command_bind 'fut_add_word' => sub {
	my ($args, $server, $target) = @_;
	my @trigger_words = split(' ',settings_get_str('fut_trigger_words'));
	chomp $args;
	if($args eq '') {
		print 'Missing argument';
		return;
	}
	foreach my $word (@trigger_words) {
		if($word eq $args) {
			print 'Word already in list';
			return;
		}
	}
	$trigger_words[$#trigger_words+1]=$args;
	settings_set_str('fut_trigger_words', join(' ',@trigger_words));

	print "Word $args added";
	read_database;
};

command_bind 'fut_del_word' => sub {
	my ($args, $server, $target) = @_;
	my @trigger_words = split(' ',settings_get_str('fut_trigger_words'));
	my @new_trigger_words;
	my $found=0;
	chomp $args;
	if($args eq '') {
		print 'Missing argument';
		return;
	}
	foreach my $word (@trigger_words) {
		if($word ne $args) {
			$new_trigger_words[$#new_trigger_words+1]=$word;
		}
		else {
			$found=1;
		}
	}
	if($found==0) {
		print 'Word not in list.';
		return;
	}
	settings_set_str('fut_trigger_words', join(' ',@new_trigger_words));
	print "Word $args removed";
};

command_bind 'fut_add_listen_channel' => sub {
	my ($args, $server, $target) = @_;
	my @listen_channels = split(' ',settings_get_str('fut_listen_channels'));
	chomp $args;
	if($args eq '') {
		print 'Missing argument';
		return;
	}
	foreach my $chan (@listen_channels) {
		if($chan eq $args) {
			print 'Channel already in list';
			return;
		}
	}
	$listen_channels[$#listen_channels+1]=$args;
	settings_set_str('fut_listen_channels', join(' ',@listen_channels));

	print "Channel $args added";
};

command_bind 'fut_del_listen_channel' => sub {
	my ($args, $server, $target) = @_;
	my @listen_channels = split(' ',settings_get_str('fut_listen_channels'));
	my @new_listen_channels;
	my $found=0;
	chomp $args;
	if($args eq '') {
		print 'Missing argument';
		return;
	}
	foreach my $chan (@listen_channels) {
		if($chan ne $args) {
			$new_listen_channels[$#new_listen_channels+1]=$chan;
		}
		else {
			$found=1;
		}
	}
	if($found==0) {
		print 'Channel not in list.';
		return;
	}
	settings_set_str('fut_listen_channels', join(' ',@new_listen_channels));
	print "Channel $args removed";
};

command_bind 'fut_add_trigger_channel' => sub {
	my ($args, $server, $target) = @_;
	my @trigger_channels = split(' ',settings_get_str('fut_trigger_channels'));
	chomp $args;
	if($args eq '') {
		print 'Missing argument';
		return;
	}
	foreach my $chan (@trigger_channels) {
		if($chan eq $args) {
			print 'Channel already in list';
			return;
		}
	}
	$trigger_channels[$#trigger_channels+1]=$args;
	settings_set_str('fut_trigger_channels', join(' ',@trigger_channels));

	print "Channel $args added";
};

command_bind 'fut_del_trigger_channel' => sub {
	my ($args, $server, $target) = @_;
	my @trigger_channels = split(' ',settings_get_str('fut_trigger_channels'));
	my @new_trigger_channels;
	my $found=0;
	chomp $args;
	if($args eq '') {
		print 'Missing argument';
		return;
	}
	foreach my $chan (@trigger_channels) {
		if($chan ne $args) {
			$new_trigger_channels[$#new_trigger_channels+1]=$chan;
		}
		else {
			$found=1;
		}
	}
	if($found==0) {
		print 'Channel not in list.';
		return;
	}
	settings_set_str('fut_trigger_channels', join(' ',@new_trigger_channels));
	print "Channel $args removed";
};



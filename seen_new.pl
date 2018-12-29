use strict;
use vars qw($NAME $VERSION %IRSSI);
use Irssi qw(command_bind signal_add_first settings_get_str settings_add_str get_irssi_dir settings_set_str);
use Time::HiRes qw/gettimeofday/;
use DBI;
use LWP::UserAgent;
use URI::Escape;

$VERSION = "1.00";
%IRSSI = (
    authors     => "Paul Staroch",
    contact     => "paulchen\@rueckgr.at",
    name        => "seen_new",
    description => "calls ircdb.py",
    license     => "GPL"
);

# === EDIT THE FOLLOWING LINES TO YOUR NEEDS ===

# === DO NOT EDIT ANYTHING BELOW THIS LINE ===

sub fut {
	my ($server, $msg, $nick_asks, $address, $channel) = @_;

	if($channel ne '#test' and $channel ne '#chatbox') {
		return;
	}

	if($msg =~ m/\s*!seen\s+([^\s]+)/) {
		my $asked_nick = $1;
		my @nicks = ($asked_nick);

		my $ravusbot_username = settings_get_str('seen_ravusbot_username');
		my $ravusbot_password = settings_get_str('seen_ravusbot_password');

		my $query_string = 'https://ondrahosek.com/ravusbot/aliases?nick=' . uri_escape($asked_nick);
		my $user_agent = LWP::UserAgent->new;
		$user_agent->credentials('ondrahosek.com:443', 'Chatbox Credentials', $ravusbot_username, $ravusbot_password);
		$user_agent->timeout(10);
		Irssi::print(gettimeofday . " - Calling RavusBot's API");
		my $response = $user_agent->get($query_string);
		Irssi::print(gettimeofday . " - Called RavusBot's API");
		if($response -> is_success) {
			Irssi::print($response->decoded_content);
			@nicks = map(lc($_), split("\n", $response->decoded_content));
		}
		else {
			$server->command("msg $channel !smsg RavuAlHemio Deine API ist kaputt.");
		}
		push @nicks, lc($asked_nick);

		my $db_host = settings_get_str('seen_db_host');
		my $db_username = settings_get_str('seen_db_username');
		my $db_password = settings_get_str('seen_db_password');
		my $db_database = settings_get_str('seen_db_database');

		my $db = DBI->connect("DBI:Pg:dbname=$db_database;host=$db_host", $db_username, $db_password) || die('Could not connect to database');

		my @param = ();
		foreach my $nick (@nicks) {
			push @param, "?";
		}
		my $param_string = join(', ', @param);

		my $last_nick1 = '';
		my $last_time1 = '';
		my $last_nick2 = '';
		my $last_time2 = '';

#		my $stmt = $db->prepare("select u.username, m.type, max(m.timestamp) from message m join \"user\" u on (m.user_fk = u.user_pk) where LOWER(u.username) IN ($param_string) group by u.username, m.type");
		my $stmt = $db->prepare("select l.username, l.type, l.timestamp from last_seen l where LOWER(l.username) IN ($param_string) group by l.username, l.type");
		$stmt->execute(@nicks);
		while(my @result = $stmt->fetchrow_array()) {
			Irssi::print("$result[0] $result[1] $result[2]");

			if($last_time1 eq '' or $last_time1 le $result[2]) {
				$last_time1 = $result[2];
				$last_nick1 = $result[0];
			}

			if(($result[1] eq 0 or $result[1] eq 3) and ($last_time2 eq '' or $last_time2 le $result[2])) {
				$last_time2 = $result[2];
				$last_nick2 = $result[0];
			}
		}
		$stmt->finish();

=pod		
		my $stmt1 = $db->prepare("select timestamp, u.username from message m join \"user\" u on (m.user_fk = u.user_pk) where lower(u.username) IN ($param_string) order by timestamp desc limit 1");
		my $stmt2 = $db->prepare("select timestamp, u.username from message m join \"user\" u on (m.user_fk = u.user_pk) where lower(u.username) IN ($param_string)  and m.type in (0,3) order by timestamp desc limit 1");
		# TODO		$nick =~ s/^\s+|\s+$//g;

		Irssi::print(gettimeofday . " - executing query 1");
		$stmt1->execute(@nicks);
		if($stmt1->rows > 0) {
			my @result = $stmt1->fetchrow_array();
			my $timestamp = $result[0];
			$last_nick1 = $result[1];
			$last_time1 = $timestamp;
		}
		Irssi::print(gettimeofday . " - executed query 1");

		Irssi::print(gettimeofday . " - executing query 2");
		$stmt2->execute(@nicks);
		if($stmt2->rows > 0) {
			my @result = $stmt2->fetchrow_array();
			my $timestamp = $result[0];
			$last_nick2 = $result[1];
			$last_time2 = $timestamp;
		}
		Irssi::print(gettimeofday . " - executed query 2");
=cut

		if($last_nick1 eq '' and $last_nick2 eq '') {
			$msg = "I've never heard about $asked_nick.";
		}
		elsif($last_nick1 ne '' and $last_nick2 ne '') {
			$msg = "$last_nick2 wrote their last message at $last_time2. $last_nick1\'s last sign of life dates back to $last_time1.";
		}
		elsif($last_nick1 ne '') {
			$msg = "$last_nick1\'s last sign of life dates back to $last_time1.";
		}
		else { # $last_nick2 ne ''
			$msg = "$last_nick2 wrote their last message at $last_time2.";
		}
#		$stmt1->finish();
#		$stmt2->finish();

		$db->disconnect();

		$server->command("msg $channel $msg");
	}
}

sub fut_own {
	my ($server, $msg, $channel) = @_;
	fut($server, $msg, $server->{nick}, "", $channel);
}

signal_add_first 'message public' => 'fut';
signal_add_first 'message irc action' => 'fut';
signal_add_first 'message own_public' => 'fut_own';
signal_add_first 'message irc own_action' => 'fut_own';

settings_add_str('seen', 'seen_db_host', 'localhost');
settings_add_str('seen', 'seen_db_database', 'ircdb');
settings_add_str('seen', 'seen_db_username', 'ircdb');
settings_add_str('seen', 'seen_db_password', '');
settings_add_str('seen', 'seen_ravusbot_username', '');
settings_add_str('seen', 'seen_ravusbot_password', '');


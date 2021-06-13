#!/usr/bin/python3

# vim:ts=4:sw=4:expandtab

import json, dateutil.parser, os, glob, requests, datetime, pytz, tzlocal, logging, sys

path = os.path.dirname(os.path.abspath(__file__))
cache_dir = path + '/cache'
logfile = path + '/log/worldcup.log'

logger = logging.getLogger()
handler = logging.FileHandler(logfile)
handler.setFormatter(logging.Formatter('%(asctime)s %(name)-12s %(levelname)-8s %(message)s'))
logger.addHandler(handler)
logger.setLevel(logging.DEBUG)

logger.debug('Execution started')

api_token = None
with open(path + '/api-token', 'r') as tokenfile:
    api_token = tokenfile.read()

if api_token is None:
    logger.error('API token cannot be read from file "api-token"')
    sys.exit(1)


def parse_json(data_file, downloaded=False):
    json_data = open(data_file).read()
    j = json.loads(json_data)
    j['downloaded'] = downloaded
    return j


def get_data(prefix, url, expiration, force_download=False):
    list_of_files = glob.glob(cache_dir + '/'  + prefix + '-*')

    if not force_download and len(list_of_files) > 0:
        data_file = max(list_of_files, key=os.path.getctime)
        logger.debug('Newest cached file: %s', data_file)

        file_date = datetime.datetime.fromtimestamp(os.path.getmtime(data_file))

        if file_date >= one_hour_ago:
            logger.debug('Not downloading anything')
            return parse_json(data_file)

        logger.debug('File too old (%s), threshold %s', file_date, one_hour_ago)
        
    logger.debug('Downloading data now')
    data_file = cache_dir + '/' + prefix + '-' + datetime.datetime.now().strftime('%Y%m%d%H%M%S') + '.json'

    response = requests.get(url=url, headers={'X-Auth-Token': api_token.strip()})

    logger.debug('Request headers: %s', response.request.headers)
    logger.debug('Response headers: %s', response.headers)
    logger.debug('Status: %s', response.status_code)

    if response.status_code != 200:
        logger.debug('Invalid status code')
        sys.exit(1)

    if response.headers['Content-Type'] != 'application/json;charset=UTF-8':
        logger.debug('Invalid content type: %s', response.headers['Content-Type'])
        sys.exit(1)

    with open(data_file, 'w') as f:
        f.write(response.text)

    return parse_json(data_file, True)


def find_match(data, id):
    for match in data['matches']:
        if match['id'] == id:
            return match
    return None


def get_goals(filename, match_id):
    data = parse_json(filename)
    match = find_match(data, match_id)
    if not match or 'goals' not in match:
        return []
    return match['goals']


now = datetime.datetime.now()
one_hour_ago = now - datetime.timedelta(hours=1)
j = get_data(prefix='matches', url='http://api.football-data.org/v2/competitions/2018/matches', expiration=one_hour_ago)

if not j['downloaded']:
    matches = [m for m in j['matches'] if dateutil.parser.parse(m['utcDate']).astimezone(tz=None).replace(tzinfo=None) > one_hour_ago]
    logger.debug('%s games in future or less than one hour in the past', len(matches))
    redownload = False
    if len(matches) > 0:
        sorted_matches = sorted(matches, key=lambda m: m['utcDate'])
        next_game_date = dateutil.parser.parse(sorted_matches[0]['utcDate']).astimezone(tz=None).replace(tzinfo=None)
        logger.debug('Next game: %s, now: %s', next_game_date, now)
        if next_game_date < now + datetime.timedelta(minutes=5):
            logger.debug('Next game less than 5 minutes in the future or less than one hour in the past')
            redownload = True

        if not redownload:
            in_play = [m for m in j['matches'] if m['status'] in ('IN_PLAY', 'PAUSED')]
            logger.debug('%s games currently in play or paused', len(in_play))
            if len(in_play) > 0:
                redownload = True

        if redownload:
            match_file = get_data(prefix='matches', url='http://api.football-data.org/v2/competitions/2018/matches', expiration=one_hour_ago, force_download=True)


team_data = get_data(prefix='teams', url='http://api.football-data.org/v2/competitions/2018/teams', expiration=now - datetime.timedelta(hours=24))
teams = dict((t['id'], t['tla']) for t in team_data['teams'])


def format_date(date):
    return dateutil.parser.parse(date).astimezone(tz=None).strftime('%d.%m.%Y %H:%M')


def simple_result(result):
    return str(result['homeTeam']) + ":" + str(result['awayTeam'])


def goals_set(result):
    return result['homeTeam'] is not None and result['awayTeam'] is not None


def format_score(result):
    if not goals_set(result['fullTime']):
        return None

    if goals_set(result['extraTime']) in result:
        output = simple_result(result['extraTime']) + " n.V."
        if simple_result(result['fullTime']) != '0:0':
            output += " (" + simple_result(result) + ", " + simple_result(result['halfTime']) + ")"
    else:
        output = simple_result(result['fullTime'])
        if output != '0:0' and goals_set(result['halfTime']):
            output += " (" + simple_result(result['halfTime']) + ")"

    if goals_set(result['penalties']) in result:
        output += ", " + simple_result(result['penalties']) + " i.E."

    return output


def format_team(team):
    if team == '':
        return '?'
    if team['id'] in teams:
        return teams[team['id']]
    return team['name']


def format_game(game):
    date = format_date(game['utcDate'])
    teams = format_team(game['homeTeam']) + "-" + format_team(game['awayTeam'])
    result = format_score(game['score'])
    if result != None:
        return date + ": " + teams + " " + result

    return date + ": " + teams


def process_games(title, games):
    if len(games) == 0:
        return []

    return title + ": " + "; ".join(map(format_game, games))


sorted_matches = sorted(j['matches'], key=lambda m: m['utcDate'])

completed = [m for m in sorted_matches if m['status'] == 'FINISHED'][-3:]
in_play = [m for m in sorted_matches if m['status'] in ('IN_PLAY', 'PAUSED')]
future = [m for m in sorted_matches if m['status'] not in ('FINISHED', 'IN_PLAY', 'PAUSED')][:3]

output = []
output += [process_games('Vergangene Spiele', completed)]
output += [process_games('Laufende Spiele', in_play)]
output += [process_games('Kommende Spiele', future)]

logger.debug('Output: %s', output)

for o in output:
    if o != []:
        print(o)

list_of_files = sorted(glob.glob(cache_dir + '/matches-*'), reverse=True)[0:2]
if len(list_of_files) == 2:
    for m in in_play:
        match_id = m['id']
        formatted_match = format_team(m['homeTeam']) + "-" + format_team(m['awayTeam'])

        goals1 = get_goals(list_of_files[1], m['id'])
        goals2 = get_goals(list_of_files[0], m['id'])

        new_goals = [g for g in goals2 if g not in goals1]
        for g in new_goals:
            with open('/tmp/ircbot', 'a') as ircbot:
                if g['type'] == 'OWN':
                    ircbot.write('%s: Own goal scored in minute %s for %s by %s' % (formatted_match, g['minute'], g['team']['name'], g['scorer']['name']))
                else:
                    ircbot.write('%s: Goal scored in minute %s for %s by %s' % (formatted_match, g['minute'], g['team']['name'], g['scorer']['name']))

logger.debug('Execution finished')


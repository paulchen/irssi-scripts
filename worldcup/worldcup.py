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


def get_data_file(prefix, url, expiration, force_download=False):
    list_of_files = glob.glob(cache_dir + '/'  + prefix + '-*')
    download = force_download

    # TODO simplify this
    if len(list_of_files) == 0:
        logger.debug('No cached files')
        download = True
    else:
        data_file = max(list_of_files, key=os.path.getctime)
        logger.debug('Newest cached file: %s', data_file)

        file_date = datetime.datetime.fromtimestamp(os.path.getmtime(data_file))

        if file_date < one_hour_ago:
            logger.debug('File too old (%s), threshold %s', file_date, one_hour_ago)
            download = True
        else:
            return data_file
        
    if download:
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

    else:
        logger.debug('Not downloading anything')

    return data_file


now = datetime.datetime.now()
one_hour_ago = now - datetime.timedelta(hours=1)
match_file = get_data_file(prefix='matches', url='http://api.football-data.org/v2/competitions/2018/matches', expiration=one_hour_ago)

# TODO avoid redownload
json_data = open(match_file).read()
j = json.loads(json_data)
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
        in_play = [m for m in j['matches'] if m['status'] == 'IN_PLAY']
        logger.debug('%s games currently in play', len(in_play))
        if len(in_play) > 0:
            redownload = True

    if redownload:
	    match_file = get_data_file(prefix='matches', url='http://api.football-data.org/v2/competitions/2018/matches', expiration=one_hour_ago, force_download=True)

team_names = {
        'Russia': 'RUS',
        'Saudi Arabia': 'KSA',
        'Egypt': 'EGY',
        'Uruguay': 'URU',
        'Morocco': 'MAR',
        'Iran': 'IRN',
        'Portugal': 'POR',
        'Spain': 'ESP',
        'France': 'FRA',
        'Australia': 'AUS',
        'Argentina': 'ARG',
        'Iceland': 'ISL',
        'Peru': 'PER',
        'Denmark': 'DEN',
        'Croatia': 'CRO',
        'Nigeria': 'NGA',
        'Costa Rica': 'CRC',
        'Serbia': 'SRB',
        'Germany': 'GER',
        'Mexico': 'MEX',
        'Brazil': 'BRA',
        'Switzerland': 'SUI',
        'Sweden': 'SWE',
        'Korea Republic': 'KOR',
        'Belgium': 'BEL',
        'Panama': 'PAN',
        'Tunisia': 'TUN',
        'England': 'ENG',
        'Colombia': 'COL',
        'Japan': 'JPN',
        'Poland': 'POL',
        'Senegal': 'SEN'
    }

def format_date(date):
    return dateutil.parser.parse(date).astimezone(tz=None).strftime('%d.%m.%Y %H:%M')


def add_results(result1, result2):
    return str(result1['goalsHomeTeam'] + result2['goalsHomeTeam']) + ":" + str(result1['goalsAwayTeam'] + result2['goalsAwayTeam'])

def simple_result(result):
    return str(result['goalsHomeTeam']) + ":" + str(result['goalsAwayTeam'])


def format_score(result):
    return 'wtf'
    if result['goalsHomeTeam'] == None or result['goalsAwayTeam'] == None:
        return None

    if 'extraTime' in result:
        #output = add_results(result['extraTime'], result) + " n.V."
        output = simple_result(result['extraTime']) + " n.V."
        if simple_result(result) != '0:0':
            output += " (" + simple_result(result) + ", " + simple_result(result['halfTime']) + ")"
    else:
        output = simple_result(result)
        if 'halfTime' in result and output != '0:0':
            output += " (" + simple_result(result['halfTime']) + ")"

    if 'penaltyShootout' in result:
        output += ", " + simple_result(result['penaltyShootout']) + " i.E."

    return output


def format_team(team):
    if team == '':
        return '?'
    if team['name'] in team_names:
        return team_names[team['name']]
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


logger.debug('Using data file %s', match_file)
json_data = open(match_file).read()

j = json.loads(json_data)

sorted_matches = sorted(j['matches'], key=lambda m: m['utcDate'])

completed = [m for m in sorted_matches if m['status'] == 'FINISHED'][-3:]
in_play = [m for m in sorted_matches if m['status'] == 'IN_PLAY']
future = [m for m in sorted_matches if m['status'] not in ('FINISHED', 'IN_PLAY')][:3]

output = []
output += [process_games('Vergangene Spiele', completed)]
output += [process_games('Laufende Spiele', in_play)]
output += [process_games('Kommende Spiele', future)]

logger.debug('Output: %s', output)

for o in output:
    if o != []:
        print(o)

logger.debug('Execution finished')


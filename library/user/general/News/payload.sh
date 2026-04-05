#!/bin/bash

# Title: News
# Description: View top news stories from around the world
# Author: spywill
# Version: 1.1

# Check internet connection
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
	LOG green "Online"
else
	LOG red "Offline internet connection is required exiting"
	exit
fi

PROMPT "Title: News

View top news stories from 
around the world.
At end of script custom news search

press any button to continue"

# RSS/XML feeds
feeds="
https://feeds.bbci.co.uk/news/rss.xml
https://www.theguardian.com/world/rss
http://rss.cnn.com/rss/edition.rss
https://feeds.feedburner.com/TheHackersNews
https://krebsonsecurity.com/feed/
https://www.darkreading.com/rss.xml
https://hnrss.org/frontpage
https://stackoverflow.blog/feed/
https://www.exploit-db.com/rss.xml
https://www.securityweek.com/feed/
https://news.google.com/rss/search?q=cybersecurity&hl=en-US&gl=US&ceid=US:en
https://news.google.com/rss/search?q=hacking&hl=en-US&gl=US&ceid=US:en
https://news.google.com/rss/search?q=Technology&hl=en-US&gl=US&ceid=US:en
"

# Reddit JSON feeds
reddit_feeds="
https://www.reddit.com/r/worldnews/.json?limit=10&t=day
https://www.reddit.com/r/news/.json?limit=10&t=day
https://www.reddit.com/r/geopolitics/.json?limit=10&t=day
https://www.reddit.com/r/technology/.json?limit=10&t=day
https://www.reddit.com/r/business/.json?limit=10&t=day
https://www.reddit.com/r/economics/.json?limit=10&t=day
https://www.reddit.com/r/cybersecurity/.json?limit=10&t=day
https://www.reddit.com/r/sports/.json?limit=10&t=day
https://www.reddit.com/r/nfl/.json?limit=10&t=day
https://www.reddit.com/r/nba/.json?limit=10&t=day
https://www.reddit.com/r/soccer/.json?limit=10&t=day
https://www.reddit.com/r/nhl/.json?limit=10&t=day
"

# Finance feeds
Finance_feed="
https://finance.yahoo.com/news/rssindex
https://www.cnbc.com/id/100003114/device/rss/rss.html
https://feeds.a.dj.com/rss/RSSMarketsMain.xml
https://news.google.com/rss/search?q=stock+market&hl=en-US&gl=US&ceid=US:en
"

# Sports feeds
sports_feeds="
https://www.espn.com/espn/rss/news
https://www.skysports.com/rss/12040
https://www.cbssports.com/rss/headlines/
https://news.google.com/rss/search?q=sports&hl=en-US&gl=US&ceid=US:en
https://news.google.com/rss/search?q=nhl&hl=en-US&gl=US&ceid=US:en
https://news.google.com/rss/search?q=nfl&hl=en-US&gl=US&ceid=US:en
https://news.google.com/rss/search?q=nba&hl=en-US&gl=US&ceid=US:en
"

# Stooq feeds
stooq_feed="https://stooq.com"

# user Agent
user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"

print_titles() {
	curl -s --connect-timeout 5 --max-time 8 -A "$user_agent" "$1" |
	tr '\n' ' ' |
	sed 's/<entry>/<item>/g' |
	awk '
	BEGIN{RS="<item>";FS="<title>"}
	NR>1{
		split($2,a,"</title>")
		title=a[1]
		gsub("<!\\[CDATA\\[|\\]\\]>","",title)
		gsub(/&amp;/,"&",title)
		if(length(title)>5)
			print title
	}' |
	sort -u |
	head -n 10 |
	awk '{printf "%2d. %s\n\n", NR, $0}'
}

print_reddit() {
	curl -s --connect-timeout 5 --max-time 8 \
	-H "User-Agent: $user_agent" \
	-H "Accept: application/json" \
	"$1" \
	| jq -r '.data.children[].data.title' \
	| head -n 10 \
	| awk '{print NR ". " $0 "\n"}'
}

# GLOBAL NEWS
LOG ""
LOG red "$(date +"%Y-%m-%d %I:%M %p")"
LOG blue "======================================="
LOG green "GLOBAL NEWS DASHBOARD"
LOG blue "======================================="

for feed in $feeds; do
	domain=$(echo "$feed" | sed -E 's|https?://||; s|/.*||')

	LOG ""
	LOG green "$domain"
	LOG blue "---------------------------------------"

	LOG yellow "$(print_titles "$feed")"
done

# REDDIT NEWS
LOG ""
LOG blue "======================================="
LOG green "REDDIT NEWS DASHBOARD"
LOG blue "======================================="

for feed in $reddit_feeds; do
	sub=$(echo "$feed" | sed -E 's|https://www.reddit.com/r/([^/]+)/.*|\1|')

	LOG ""
	LOG green "Reddit $sub"
	LOG blue "---------------------------------------"

	LOG yellow "$(print_reddit "$feed")"
done

LOG ""
LOG red "Press button A to continue
to Sports News"
WAIT_FOR_BUTTON_PRESS A
LOG ""

# SPORTS NEWS
LOG blue "======================================="
LOG green "SPORTS NEWS DASHBOARD"
LOG blue "======================================="

for feed in $sports_feeds; do
	domain=$(echo "$feed" | sed -E 's|https?://||; s|/.*||')

	LOG ""
	LOG green "$domain"
	LOG blue "---------------------------------------"

	LOG yellow "$(print_titles "$feed")"
done

LOG ""
LOG red "Press button A to continue
to Stock Market News Stories"
WAIT_FOR_BUTTON_PRESS A
LOG ""

# FINANCE NEWS
LOG blue "======================================="
LOG green "STOCK MARKET NEWS"
LOG blue "======================================="

for feed in $Finance_feed; do
	domain=$(echo "$feed" | sed -E 's|https?://||; s|/.*||')

	LOG ""
	LOG green "$domain"
	LOG blue "---------------------------------------"

	LOG yellow "$(print_titles "$feed")"
done

LOG ""
LOG red "Press button A to continue
to Stock market prices"
WAIT_FOR_BUTTON_PRESS A
LOG ""

# Top popular stocks
MARKET_TICKERS=(
AAPL MSFT GOOGL AMZN NVDA META TSLA BRK.B JPM V
UNH XOM LLY AVGO COST PG HD MA ABBV KO
PEP TMO MRK ORCL BAC ADBE CRM CSCO ACN WMT
MCD NFLX DHR TXN LIN AMD INTC NKE PM UPS
QCOM IBM GE CAT BA GS MS BLK SPGI
RTX NOW AMAT INTU ISRG GILD MDLZ BKNG
ADP SYK MMC DE CI CB ZTS CME TGT
PYPL MO EL PGR SHW EOG FISV
)

LOG blue "================ STOCK MARKET ================"
LOG green "Ticker | Price | Change"
LOG blue "=============================================="

for symbol in "${MARKET_TICKERS[@]}"; do
	s=$(echo "$symbol" | tr '[:upper:]' '[:lower:]')
	data=$(curl -s -A "$user_agent" "$stooq_feed/q/l/?s=${s}.us&f=sd2t2ohlcv&h&e=csv")
	IFS=',' read -r sym date time open high low close volume <<< "$(echo "$data" | tail -n 1)"

	if [[ -z "$close" || "$close" == "N/D" ]]; then
		printf "%-6s | %-9s | → N/A\n" "$symbol" "N/A"
		continue
	fi

	prev="$open"   # approximation if prev close not provided

	change=$(awk -v last="$close" -v prev="$prev" \
	'BEGIN {printf "%.2f", ((last-prev)/prev)*100}')

	if (( $(awk -v c="$change" 'BEGIN {print (c>0)}') )); then
		arrow="↑"
	elif (( $(awk -v c="$change" 'BEGIN {print (c<0)}') )); then
		arrow="↓"
	else
		arrow="→"
	fi
	LOG yellow "$(printf "%-6s | \$%-8s | %s %6s%%\n" "$symbol" "$close" "$arrow" "$change")"
done

LOG ""
LOG red "Press button A to continue
to WORLD TEMPERATURE (°C)"
WAIT_FOR_BUTTON_PRESS A

# WORLD TEMPERATURE (°C)
LOG ""
LOG blue "========== WORLD TEMPERATURE (°C) =========="
LOG green "Country  |   Temp"
LOG blue "============================================"

COUNTRIES=(
"USA:Washington"
"Canada:Ottawa"
"UK:London"
"France:Paris"
"Germany:Berlin"
"Italy:Rome"
"Spain:Madrid"
"Netherlands:Amsterdam"
"Switzerland:Zurich"
"Sweden:Stockholm"
"Norway:Oslo"
"Finland:Helsinki"
"Japan:Tokyo"
"South Korea:Seoul"
"China:Beijing"
"India:Delhi"
"Brazil:Brasilia"
"Australia:Canberra"
"South Africa:Pretoria"
"Mexico City:Mexico"
)

for entry in "${COUNTRIES[@]}"; do
	country="${entry%%:*}"
	city="${entry##*:}"

	temp=$(curl -s "https://wttr.in/${city}?format=%t&m")

	LOG yellow "$(printf "%-15s | %s\n" "$country" "$temp")"
done

LOG ""
LOG red "Press button A to continue
to Hak5 News Dashboard"
WAIT_FOR_BUTTON_PRESS A

news() {
	local TITLE="$1"
	local QUERY="$2"
	local ENCODED=$(printf "%s" "$QUERY" | sed 's/ /+/g')

	LOG ""
	LOG blue "======================================="
	LOG green "$TITLE"
	LOG blue "======================================="
	LOG ""

	LOG yellow "$(curl -s -A "$user_agent" \
	"https://news.google.com/rss/search?q=$ENCODED&hl=en-US&gl=US&ceid=US:en" |
	tr '\n' ' ' |
	awk '
	BEGIN{RS="<item>";FS="<title>|</title>|<link>|</link>"}
	NR>1{
		title=$2
		if (match($0, /<description>(.*?)<\/description>/, d)) {
			desc = d[1]
			gsub(/<!\[CDATA\[|\]\]>/, "", desc)
			gsub(/<[^>]*>/,"",desc)
			gsub("&amp;","&",desc)
			gsub(/[ \t\r\n]+/, " ", desc)
		}
		gsub("&amp;","&",title)
		if(length(title)>5){
			printf("[%d] %s\n%s\n\n",++i,title,desc)
		}
		if(i==10) exit
	}')"
}

news "Hak5 News Dashboard" "Hak5"
news "Wifi Pineapple Pager" "Hak5 wifi pineapple pager"

LOG ""
LOG red "Press button A to continue
to User top stories"
WAIT_FOR_BUTTON_PRESS A
LOG ""

# User user custom search
search_news() {
	local QUERY
	QUERY=$(TEXT_PICKER "Enter news search" "breaking news")
	[ -z "$QUERY" ] && return
	news "News Results for: $QUERY" "$QUERY"
}
search_news

#!/bin/bash

# Title: News
# Description: Menu-driven news, technology, cybersecurity, sports, stock market, world temperatures and custom searches.
# Author: spywill
# Version: 2.0

USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"

# Check internet connection.
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
	LOG red "Offline internet connection is required."
	PROMPT "Offline internet connection is required."
	exit 0
fi

PROMPT "Title: News

Select a category from the menu
to browse news and information."

print_titles() {
	curl -fsSL --connect-timeout 5 --max-time 12 \
		-A "$USER_AGENT" "$1" 2>/dev/null |
	tr '\n' ' ' |
	sed 's/<item[^>]*>/\
/g' |
	awk '
	{
		if (match($0, /<title[^>]*>.*<\/title>/)) {
			t=substr($0,RSTART,RLENGTH)
			sub(/^<title[^>]*>/,"",t)
			sub(/<\/title>$/,"",t)

			gsub(/<!\[CDATA\[|\]\]>/,"",t)
			gsub(/&amp;/,"\\&",t)
			gsub(/&quot;/,"\"",t)
			gsub(/&#39;|&apos;/,sprintf("%c",39),t)
			gsub(/&lt;/,"<",t)
			gsub(/&gt;/,">",t)
			gsub(/&#[0-9]+;/,"",t)
			gsub(/<[^>]*>/,"",t)
			gsub(/^[ \t]+|[ \t]+$/,"",t)

			if (length(t)>5 && t !~ /^Hacker News: Newest$/ && !seen[t]++) {
				printf "%s\n\n",t
				count++
			}

			if (count>=10) exit
		}
	}'
}

# Show a selected news feed.
show_feed() {
	spinnerid=$(START_SPINNER "Collecting $1")
	local TITLE="$1"
	local URL="$2"
	local RESULTS

	LOG ""
	LOG blue "======================================="
	LOG green "$TITLE"
	LOG blue "======================================="
	LOG ""

	RESULTS=$(print_titles "$URL")

	if [ -n "$RESULTS" ]; then
		STOP_SPINNER "$spinnerid"
		LOG yellow "$RESULTS"
	else
		STOP_SPINNER "$spinnerid"
		LOG red "No headlines found."
		LOG yellow "The feed may be unavailable or empty."
	fi
	STOP_SPINNER "$spinnerid"

	LOG green "Press A button to return to the menu"
	WAIT_FOR_BUTTON_PRESS A
}

# Google News topic search.
news_search() {
	local TITLE="$1"
	local QUERY="$2"
	local URL

	# Encode spaces for a Google News RSS search.
	QUERY=$(printf '%s' "$QUERY" | sed 's/ /+/g')
	URL="https://news.google.com/rss/search?q=${QUERY}&hl=en-US&gl=US&ceid=US:en"

	show_feed "$TITLE" "$URL"
}

# Build a menu and display the selected RSS feed.
feed_menu() {
	local TITLE="$1"
	local CHOICE
	shift

	while true; do
		CHOICE=$(LIST_PICKER \
		"$TITLE" \
		"$@" \
		"Cancel" \
		"Exit" \
		"Exit"
		) || return

		case "$CHOICE" in
			"Cancel")
				return
			;;
			"Exit")
				exit 0
			;;
			*)
				case "$TITLE:$CHOICE" in

					# World news
					"World News:Sky Top Stories")
						show_feed "Sky News Headlines" \
							"https://feeds.skynews.com/feeds/rss/home.xml" ;;
					"World News:Al Jazeera")
						show_feed "Al Jazeera World News" \
							"https://www.aljazeera.com/xml/rss/all.xml" ;;
					"World News:DW World News")
						show_feed "DW World News" \
							"https://rss.dw.com/rdf/rss-en-world" ;;
					"World News:The Guardian")
						show_feed "The Guardian World" \
							"https://www.theguardian.com/world/rss" ;;
					"World News:Google World News")
						news_search "Google World News" "world news" ;;
					"World News:Google Breaking News")
						news_search "Breaking News" "breaking news" ;;
					"World News:Google USA News")
						news_search "USA News" "USA news" ;;
					"World News:Google Canada News")
						news_search "Canada News" "Canada news" ;;

					# Technology
					"Technology News:Hacker News Front Page")
						show_feed "Hacker News Front Page" \
							"https://news.ycombinator.com/rss" ;;
					"Technology News:Hacker News Newest")
						show_feed "Hacker News Newest" \
							"https://hnrss.org/newest" ;;
					"Technology News:Techmeme")
						show_feed "Techmeme" \
							"https://www.techmeme.com/feed.xml" ;;
					"Technology News:Lobsters")
						show_feed "Lobsters" \
							"https://lobste.rs/rss" ;;
					"Technology News:Stack Overflow Blog")
						show_feed "Stack Overflow Blog" \
							"https://stackoverflow.blog/feed/" ;;
					"Technology News:Google Technology")
						news_search "Technology News" "technology" ;;
					"Technology News:Google Artificial Intelligence")
						news_search "Artificial Intelligence" "artificial intelligence" ;;

					# Cybersecurity
					"Cybersecurity News:The Hacker News")
						show_feed "The Hacker News" \
							"https://feeds.feedburner.com/TheHackersNews" ;;
					"Cybersecurity News:Krebs on Security")
						show_feed "Krebs on Security" \
							"https://krebsonsecurity.com/feed/" ;;
					"Cybersecurity News:Dark Reading")
						show_feed "BleepingComputer Security News" \
							"https://www.bleepingcomputer.com/feed/" ;;
					"Cybersecurity News:SecurityWeek")
						show_feed "SecurityWeek" \
							"https://www.securityweek.com/feed/" ;;
					"Cybersecurity News:Exploit Database")
						show_feed "Exploit Database" \
							"https://www.exploit-db.com/rss.xml" ;;
					"Cybersecurity News:Google Cybersecurity")
						news_search "Cybersecurity News" "cybersecurity" ;;
					"Cybersecurity News:Google Hacking")
						news_search "Hacking News" "hacking" ;;
					"Cybersecurity News:Google Data Breaches")
						news_search "Data Breach News" "data breach" ;;

					# Sports
					"Sports News:ESPN")
						show_feed "ESPN Sports" \
							"https://news.google.com/rss/search?q=when:7d+site:espn.com&hl=en-US&gl=US&ceid=US:en" ;;
					"Sports News:Sky Sports")
						show_feed "Sky Sports" \
							"https://www.skysports.com/rss/11095" ;;
					"Sports News:CBS Sports")
						show_feed "CBS Sports" \
							"https://www.cbssports.com/rss/headlines/" ;;
					"Sports News:NHL")
						news_search "NHL News" "NHL hockey" ;;
					"Sports News:NFL")
						news_search "NFL News" "NFL football" ;;
					"Sports News:NBA")
						news_search "NBA News" "NBA basketball" ;;
					"Sports News:Soccer")
						news_search "Soccer News" "soccer football" ;;

					# Finance
					"Stock Market News:Yahoo Finance")
						show_feed "Yahoo Finance" \
							"https://feeds.finance.yahoo.com/rss/2.0/headline?s=AAPL,MSFT,NVDA&region=US&lang=en-US" ;;
					"Stock Market News:CNBC")
						show_feed "CNBC Finance" \
							"https://www.cnbc.com/id/100003114/device/rss/rss.html" ;;
					"Stock Market News:Wall Street Journal")
						show_feed "Wall Street Journal Markets" \
							"https://feeds.a.dj.com/rss/RSSMarketsMain.xml" ;;
					"Stock Market News:Google Stock Market")
						news_search "Stock Market News" "stock market" ;;
					"Stock Market News:Google Cryptocurrency")
						news_search "Cryptocurrency News" "cryptocurrency" ;;

					*)
						LOG red "Unknown menu selection."
					;;
				esac
			;;
		esac
	done
}

# Stock prices.
show_stocks() {
	local SYMBOL YAHOO_SYMBOL DATA PRICE OPEN CHANGE ARROW

	local MARKET_TICKERS=(
		AAPL MSFT GOOGL AMZN NVDA META TSLA BRK.B JPM V
		UNH XOM LLY AVGO COST PG HD MA ABBV KO
		PEP TMO MRK ORCL BAC ADBE CRM CSCO ACN WMT
		MCD NFLX DHR TXN LIN AMD INTC NKE PM UPS
		QCOM IBM GE CAT BA GS MS BLK SPGI
		RTX NOW AMAT INTU ISRG GILD MDLZ BKNG
		ADP SYK MMC DE CI CB ZTS CME TGT
		PYPL MO EL PGR SHW EOG FISV
	)

	LOG blue "========== STOCK MARKET PRICES =========="
	LOG green "Ticker | Price | Change from Open"
	LOG blue "=========================================="

	# Check that curl and jq are available.
	if ! command -v jq >/dev/null 2>&1; then
		LOG red "Error: jq is required to read stock data."
		WAIT_FOR_BUTTON_PRESS A
		return
	fi

	for SYMBOL in "${MARKET_TICKERS[@]}"; do

		# Convert Berkshire Hathaway's ticker to Yahoo format.
		YAHOO_SYMBOL="$SYMBOL"
		[ "$SYMBOL" = "BRK.B" ] && YAHOO_SYMBOL="BRK-B"

		# Retrieve the current quote and today's opening price.
		DATA=$(curl -fsSL --connect-timeout 3 --max-time 7 \
			-A "${USER_AGENT:-Mozilla/5.0}" \
			"https://query1.finance.yahoo.com/v8/finance/chart/${YAHOO_SYMBOL}?range=1d&interval=1m" \
			2>/dev/null)

		if [ -z "$DATA" ]; then
			LOG yellow "$SYMBOL | Price unavailable"
			continue
		fi

		# Extract the current price and first available opening value.
		DATA=$(printf '%s' "$DATA" | jq -er '
			.chart.result[0] |
			[
				.meta.regularMarketPrice,
				([.indicators.quote[0].open[]? |
					select(. != null)] | first)
			] | @tsv
		' 2>/dev/null)

		if [ -z "$DATA" ]; then
			LOG yellow "$SYMBOL | Price unavailable"
			continue
		fi

		IFS=$'\t' read -r PRICE OPEN <<< "$DATA"

		# Reject missing or invalid prices.
		if [ -z "$PRICE" ] || [ -z "$OPEN" ] ||
			[ "$PRICE" = "null" ] || [ "$OPEN" = "null" ]; then
			LOG yellow "$SYMBOL | Price unavailable"
			continue
		fi

		# Calculate percentage change from the opening price.
		CHANGE=$(awk -v c="$PRICE" -v o="$OPEN" \
			'BEGIN {
				if (o > 0)
					printf "%+.2f", ((c-o)/o)*100
				else
					print "0.00"
			}')

		# Determine price direction.
		ARROW=$(awk -v c="$PRICE" -v o="$OPEN" \
			'BEGIN {
				if (c > o) print "UP"
				else if (c < o) print "DOWN"
				else print "FLAT"
			}')

		LOG yellow "$SYMBOL | \$$PRICE | $ARROW $CHANGE%"
	done
	LOG green "Press A button to return to the menu"
	WAIT_FOR_BUTTON_PRESS A
}

# World temperatures.
show_temperatures() {
	local ENTRY COUNTRY CITY TEMP

	local COUNTRIES=(
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
		"Mexico City:Mexico City"
	)

	LOG blue "========== WORLD TEMPERATURES =========="
	LOG green "Location | Temperature"
	LOG blue "========================================="

	for ENTRY in "${COUNTRIES[@]}"; do
		COUNTRY="${ENTRY%%:*}"
		CITY="${ENTRY#*:}"

		TEMP=$(curl -fsSL --connect-timeout 3 --max-time 6 \
			"https://wttr.in/$(printf '%s' "$CITY" | sed 's/ /+/g')?format=%t&m" \
			2>/dev/null)

		[ -n "$TEMP" ] || TEMP="Unavailable"

		LOG yellow "$COUNTRY | $TEMP"
	done

	LOG green "Press A button to return to the menu"
	WAIT_FOR_BUTTON_PRESS A
}

# Custom news search.
custom_search() {
	local QUERY

	QUERY=$(TEXT_PICKER "Enter news search" "breaking news") || return
	[ -n "$QUERY" ] || return

	news_search "Search: $QUERY" "$QUERY"
}

# Main menu.
while true; do
	RESP=$(LIST_PICKER \
		"NEWS DASHBOARD" \
		"World News" \
		"Technology News" \
		"Cybersecurity News" \
		"Sports News" \
		"Stock Market News" \
		"Stock Prices" \
		"World Temperatures" \
		"Hak5 News" \
		"Custom News Search" \
		"Exit" \
		"Exit") || break

	case "$RESP" in
		"World News")
			feed_menu "World News" \
				"Sky Top Stories" \
				"Al Jazeera" \
				"DW World News" \
				"The Guardian" \
				"Google World News" \
				"Google Breaking News" \
				"Google USA News" \
				"Google Canada News"
		;;
		"Technology News")
			feed_menu "Technology News" \
				"Hacker News Front Page" \
				"Hacker News Newest" \
				"Techmeme" \
				"Lobsters" \
				"Stack Overflow Blog" \
				"Google Technology" \
				"Google Artificial Intelligence"
		;;
		"Cybersecurity News")
			feed_menu "Cybersecurity News" \
				"The Hacker News" \
				"Krebs on Security" \
				"Dark Reading" \
				"SecurityWeek" \
				"Exploit Database" \
				"Google Cybersecurity" \
				"Google Hacking" \
				"Google Data Breaches"
		;;
		"Sports News")
			feed_menu "Sports News" \
				"ESPN" \
				"Sky Sports" \
				"CBS Sports" \
				"NHL" \
				"NFL" \
				"NBA" \
				"Soccer"
		;;
		"Stock Market News")
			feed_menu "Stock Market News" \
				"Yahoo Finance" \
				"CNBC" \
				"Wall Street Journal" \
				"Google Stock Market" \
				"Google Cryptocurrency"
		;;
		"Stock Prices")
			show_stocks
		;;
		"World Temperatures")
			show_temperatures
		;;
		"Hak5 News")
			news_search "Hak5 News" "Hak5"
			news_search "WiFi Pineapple Pager" "Hak5 WiFi Pineapple Pager"
			news_search "USB rubber ducky" "Hak5 usb rubber ducky"
			news_search "Keycroc" "Hak5 keycroc"
			news_search "Shark Jack Display" "Hak5 shark jack display"
			news_search "Packet Squirrel" "Hak5 packet squirrel"
			news_search "Lan Turtle Hub" "Hak5 lan turtle hub"
			news_search "Screen Crab" "Hak5 screen crab"
			news_search "O.MG Cable" "Hak5 O.MG cable"
		;;
		"Custom News Search")
			custom_search
		;;
		"Exit")
			LOG yellow "[NEWS] Exiting News Dashboard."
			break
		;;
	esac
done

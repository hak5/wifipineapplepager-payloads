# 🌍 News Dashboard Script

A Bash-based **Global News & Data Dashboard** that aggregates: - 📰
Global news headlines (RSS) - 🧠 Cybersecurity and technology news - 🧑‍💻
Reddit trending news posts - 📈 Stock market headlines - 💹 Live stock
ticker prices - 🌡️ World temperatures - 🔎 Custom news search

Designed for and compatible with
**Hak5 pager**.

------------------------------------------------------------------------

# ✨ Features

## 📰 Global News Aggregation

Pulls top headlines from major sources including:

-   BBC
-   The Guardian
-   CNN
-   Hacker News
-   SecurityWeek
-   Exploit‑DB
-   Google News (technology, hacking, cybersecurity)

RSS feeds are parsed and the **top 10 unique headlines** are displayed
per source.

------------------------------------------------------------------------

## 🤖 Reddit News Feeds

Fetches trending posts from:

-   r/worldnews
-   r/news
-   r/geopolitics
-   r/technology
-   r/business
-   r/economics
-   r/cybersecurity

Uses Reddit JSON APIs and `jq` to extract titles.

------------------------------------------------------------------------

## 📊 Stock Market News

Displays finance headlines from:

-   Yahoo Finance
-   CNBC
-   Wall Street Journal Markets
-   Google News stock market feed

------------------------------------------------------------------------

## 💹 Live Stock Prices

Displays price and daily percentage change for many major tickers
including:

    AAPL, MSFT, GOOGL, AMZN, NVDA, META, TSLA, JPM,
    BAC, ORCL, AMD, INTC, IBM, GS, CAT, BA

Stock data is fetched from **Stooq market data API**.

Output example:

    Ticker | Price | Change
    AAPL   | $187.54 | ↑ 1.23%
    MSFT   | $415.33 | ↓ -0.82%

------------------------------------------------------------------------

## 🌡️ Global Temperature Dashboard

Shows current temperatures for major world cities using:

    wttr.in

Countries include:

-   USA
-   UK
-   France
-   Germany
-   Japan
-   India
-   Brazil
-   Australia
-   South Africa
-   Mexico

------------------------------------------------------------------------

## 🔎 Custom News Search

Users can run a custom query which pulls the **top 10 headlines from
Google News**.

Example searches:

-   cybersecurity
-   AI
-   global economy
-   space news

------------------------------------------------------------------------

# 🧰 Requirements

Install required tools:

``` bash
curl jq
```

The script also relies on:

-   bash
-   sed
-   awk
-   tr
-   ping

Internet access is required.

------------------------------------------------------------------------

# 🚀 Usage


The dashboard will:

1.  Check internet connectivity
2.  Display global news
3.  Show Reddit headlines
4.  Show finance news
5.  Display stock prices
6.  Display world temperatures
7.  Provide custom search

Navigation prompts will appear throughout the script.

------------------------------------------------------------------------

# 🧠 How It Works

### RSS Parsing

The script uses:

    curl → sed → awk

to convert XML feeds into readable headlines.

### Reddit Parsing

Reddit JSON responses are processed using:

    jq

to extract post titles.

### Market Data

Stock prices are fetched from:

    https://stooq.com

and percentage changes are calculated using `awk`.

------------------------------------------------------------------------

# 🌐 Bash Translator Script

A lightweight Bash-based translator that uses Google's unofficial
translate API to convert text from English into multiple languages.

## ✨ Features

-   Checks internet connectivity before running
-   Accepts user input for translation
-   Supports multiple languages
-   Option to translate into one or all available languages
-   URL encoding for safe API requests
-   Fast and simple CLI interaction

## 📦 Supported Languages

-   Spanish (es)
-   French (fr)
-   German (de)
-   Italian (it)
-   Portuguese (pt)
-   Russian (ru)
-   Arabic (ar)
-   Turkish (tr)
-   Vietnamese (vi)
-   Polish (pl)
-   Dutch (nl)
-   Indonesian (id)
-   Urdu (ur)
-   Persian (fa)

## 🚀 How It Works

1.  Checks for internet connection using ping
2.  Prompts the user to input text
3.  Displays a list of available languages
4.  User selects a language (or all)
5.  Script sends a request to Google Translate API
6.  Outputs translated text

## 🛠 Requirements

-   Bash
-   curl
-   sed
-   Internet connection

## ⚠️ Notes

-   Uses an unofficial Google Translate endpoint (may break in the
    future)
-   Designed for Hak5 pager LOG,
    PROMPT, TEXT_PICKER, NUMBER_PICKER

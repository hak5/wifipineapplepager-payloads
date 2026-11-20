# 🤖 Pager AI Chat

**Free Online AI Assistant for the Hak5 WiFi Pineapple Pager**

Pager AI Chat brings an online AI assistant directly to your Hak5 WiFi Pineapple Pager. Ask questions, get answers, and continue a conversation right from your device — without needing to configure your own API key.

Powered by **Vireonix AI**, with **JarvisClaw AI** as an automatic backup provider, this payload helps keep your AI chat available if the primary service is unavailable.

## ✨ Features

- 🤖 **Online AI Chat** — Ask questions and receive AI-generated answers directly on your Pager.
- 🔑 **No API Key Required** — Uses the configured Vireonix AI and JarvisClaw AI endpoints without requiring you to enter a personal API key.
- 🔄 **Automatic AI Backup** — Tries JarvisClaw AI automatically if Vireonix AI fails or returns an unusable response.
- 💬 **Conversation History** — Retains recent messages so you can continue a conversation without starting from scratch each time.
- 🧠 **Context Awareness** — Keeps the system instructions and recent conversation messages to help maintain context across requests.
- 📟 **Pager-Friendly Interface** — Uses the Hak5 Pager's built-in prompts, logs, and spinner.
- 🌐 **Internet Connectivity Check** — Checks for an internet connection before starting the chat.
- ⚠️ **Error Handling** — Reports connection failures, HTTP errors, missing responses, and request-processing problems. If both AI providers fail, their error messages are displayed.
- 🧹 **Automatic Cleanup** — Removes temporary session files when the payload exits.
- 🚪 **Simple Exit** — Submit a blank message to leave the chat.

## 📋 Requirements

- Hak5 WiFi Pineapple Pager
- Active internet connection
- `curl`
- `jq`
- Access to the Vireonix AI and JarvisClaw AI chat completions endpoints

The payload uses the Pager's built-in commands, including `PROMPT`, `LOG`, `ERROR_DIALOG`, `TEXT_PICKER`, `START_SPINNER`, `STOP_SPINNER`, and `WAIT_FOR_BUTTON_PRESS`.

## 🚀 How It Works

1. **Start the payload** — The Pager displays an introduction explaining the chat and its AI providers.
2. **Check dependencies** — The script checks for `curl`, `jq`, and internet connectivity.
3. **Start a conversation** — The payload creates a temporary conversation history containing its system instructions.
4. **Ask a question** — Enter your message using the Pager's text input.
5. **Try the primary AI** — The payload sends your message and conversation history to Vireonix AI.
6. **Use the backup if needed** — If Vireonix AI fails, returns an HTTP error, or provides no readable answer, the payload automatically tries JarvisClaw AI.
7. **Display the answer** — The successful provider's response appears on the Pager screen, with the provider name shown.
8. **Continue chatting** — Press A to return to the input prompt and ask another question.
9. **Exit** — Submit a blank message to close the chat.

## 🔄 AI Providers

Pager AI Chat uses two providers in order:

| Provider | Role | Model |
|---|---|---|
| Vireonix AI | Primary | `auto` |
| JarvisClaw AI | Automatic backup | `auto/free` |

Vireonix AI is always tried first. JarvisClaw AI is only contacted if the primary request fails. If both providers fail, the payload displays the error reported by each provider and lets you try again.

## 🧠 Conversation History

Pager AI Chat maintains conversation history for the current session.

The script keeps the system instructions and recent messages when preparing each request. It retains the system message plus the latest 12 conversation messages when adding a new user message. The assistant's reply is then added to the history for the next request.

Conversation history is stored in a temporary directory under `/tmp` and is automatically removed when the script exits. It is not designed to preserve conversations between separate runs.

## ⚙️ Configuration

The API endpoints and model selections are defined near the beginning of the script:

```bash
# Primary AI provider
API_URL="https://vireonix.ai/v1/chat/completions"
MODEL="auto"

# Backup AI provider
BACKUP_URL="https://api.jarvisclaw.ai/v1/chat/completions"
BACKUP_MODEL="auto/free"
```

- `API_URL` — Vireonix AI chat completions endpoint.
- `MODEL` — Model selection for Vireonix AI.
- `BACKUP_URL` — JarvisClaw AI chat completions endpoint.
- `BACKUP_MODEL` — Model selection for JarvisClaw AI.

Both providers are expected to support the chat-completions request format used by the payload.

## 🔒 Network & Privacy Notes

- An active internet connection is required.
- Your messages and conversation context are sent to Vireonix AI to generate the primary response.
- If the Vireonix request fails, the same conversation context is sent to JarvisClaw AI as a backup attempt.
- Conversation history is kept locally in temporary files for the active session.
- Local temporary-file cleanup does not control either provider's data retention policies.
- No personal API key is configured in this payload. Provider availability and access requirements may change.

Avoid entering passwords, API keys, or other sensitive information into the chat.

## 🛠️ Built With

- **Bash** — Payload logic and request handling.
- **curl** — HTTPS communication with the AI services.
- **jq** — JSON request construction, response parsing, and conversation history management.
- **Hak5 WiFi Pineapple Pager** — User interface and hardware platform.
- **Vireonix AI** — Primary online AI chat service.
- **JarvisClaw AI** — Automatic backup online AI chat service.

## ⚠️ Disclaimer

This is a payload for the Hak5 WiFi Pineapple Pager. It is not an official Hak5, Vireonix AI, or JarvisClaw AI product.

AI-generated responses may be inaccurate. Verify important information independently. The availability and terms of third-party AI services are controlled by their respective providers.

---

**Enjoy chatting with AI on your Pager!** 🤖📟

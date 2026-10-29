# 🤖 Pager AI Chat

**Free Online AI Assistant for the Hak5 WiFi Pineapple Pager**

Pager AI Chat brings an online AI assistant directly to your Hak5 WiFi Pineapple Pager. Ask questions, get answers, and continue a conversation right from your device — without needing to configure your own API key.

Powered by **Vireonix AI**, this payload uses Bash and the Pager's built-in interface commands to provide a simple, interactive AI chat experience.

## ✨ Features

- 🤖 **Online AI Chat** — Ask questions and receive AI-generated answers directly on your Pager.
- 🔑 **No API Key Required** — Connect to the Vireonix AI service without configuring a personal API key.
- 💬 **Conversation History** — The AI retains recent messages so you can continue a conversation without starting from scratch each time.
- 🧠 **Context Awareness** — Keeps the system instructions and recent conversation messages to help maintain context.
- 📟 **Pager-Friendly Interface** — Uses the Hak5 Pager's built-in prompts, logs, and spinner.
- 🌐 **Internet Connectivity Check** — Checks for an internet connection before starting the chat.
- ⚠️ **Error Handling** — Provides feedback for network failures, HTTP errors, missing responses, and request-processing problems.
- 🧹 **Automatic Cleanup** — Removes temporary session files when the payload exits.
- 🚪 **Simple Exit** — Submit a blank message to leave the chat.

## 📋 Requirements

- Hak5 WiFi Pineapple Pager
- Internet connection
- `curl`
- `jq`
- Access to the Vireonix AI chat completions endpoint

The payload uses the Pager's built-in commands, including `PROMPT`, `LOG`, `TEXT_PICKER`, `START_SPINNER`, `STOP_SPINNER`, and `WAIT_FOR_BUTTON_PRESS`.

## 🚀 How It Works

1. **Start the payload** — The Pager displays an introduction explaining the chat and its requirements.
2. **Check dependencies** — The script checks for `curl`, `jq`, and internet connectivity.
3. **Ask a question** — Enter your message using the Pager's text input.
4. **Send the request** — The payload builds a JSON request and sends it to Vireonix AI using `curl`.
5. **Maintain context** — Recent user messages and AI responses are stored in a temporary JSON conversation history.
6. **Display the answer** — The AI response appears on the Pager screen.
7. **Continue chatting** — Press A to return to the input prompt and ask another question.
8. **Exit** — Submit a blank message to close the chat.

## 🧠 Conversation History

Pager AI Chat maintains a conversation history for the current session.

The script retains the system instructions and the latest 12 messages when preparing a new request. This helps the AI follow the ongoing conversation while keeping the request size manageable.

Conversation history is stored in a temporary directory under `/tmp` and is automatically removed when the script exits. It is not designed to preserve conversations between separate runs.

## ⚙️ Configuration

The API endpoint and model selection are defined near the beginning of the script:

```bash
API_URL="https://vireonix.ai/v1/chat/completions"
MODEL="auto"
```

- `API_URL` — The Vireonix AI chat completions endpoint.
- `MODEL` — Uses automatic model selection.

The script sends requests in JSON format and extracts the AI response from the returned chat completion.

## 🔒 Network & Privacy Notes

- An active internet connection is required.
- User messages and conversation context are sent to the Vireonix AI service to generate responses.
- Conversation history is kept locally in temporary files for the active session.
- Local temporary-file cleanup does not control the provider's data retention policies.
- No personal API key is configured in this payload. Service availability and access requirements depend on Vireonix AI.

Avoid entering passwords, API keys, or other sensitive information into the chat.

## 🛠️ Built With

- **Bash** — Payload logic and request handling.
- **curl** — HTTPS communication with the AI service.
- **jq** — JSON request construction, response parsing, and conversation history management.
- **Hak5 WiFi Pineapple Pager** — User interface and hardware platform.
- **Vireonix AI** — Online AI chat service.

## ⚠️ Disclaimer

This is a payload for the Hak5 WiFi Pineapple Pager. It is not an official Hak5 product or an official Vireonix AI project.

AI-generated responses may be inaccurate. Verify important information independently.

---

**Enjoy chatting with AI on your Pager!** 🤖📟

If you find this project useful, consider giving the repository a ⭐ on GitHub and sharing your feedback.

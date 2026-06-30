# Example PromptQL Connect Prompt

RepoPilot Bridge generates a real prompt with your current tunnel URL.

```text
I started RepoPilot Bridge.

Update the custom API integration:

- provider id: repo-tools
- protocol: api
- base_url: <TUNNEL_URL>
- api_docs_url: <TUNNEL_URL>/openapi.json
- credential header: X-API-Key
- prefix: empty

Do not ask me to send the key in chat. Use a secure connect card.
```
